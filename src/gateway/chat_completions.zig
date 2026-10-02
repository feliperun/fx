const std = @import("std");
const codec = @import("chat_completions_protocol.zig");
const client_mod = @import("client.zig");
const definitions = @import("../core/config/configured_provider.zig");
const streams = @import("../core/agent/stream_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog_metadata = @import("../core/gateway/model_catalog_metadata.zig");
const classifier = @import("../core/permissions/auto_classifier.zig");
const gateway_step = @import("../core/agent/runtime/gateway_step.zig");
const review_messages = @import("vercel_protocol.zig");
const io = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const Allocator = std.mem.Allocator;

/// Every callback borrows the immutable definition from the owning profile runtime.
pub fn bundle(definition: *const definitions.Definition) provider_set.Bundle {
    const context: *anyopaque = @ptrCast(@constCast(definition));
    return .{
        .agent_stream = .{ .context = context, .stream_fn = stream, .build_request_fn = build, .project_replay_fn = project_replay },
        .model_catalog = .{ .context = context, .fetch_fn = fetch_catalog, .lookup_capabilities_fn = lookup_capabilities, .provider_id = bound_identity(definition) },
        .cli_model_catalog = .{ .context = context, .fetch_fn = fetch_cli_catalog },
        .permission_reviewer = .{ .context = context, .review_fn = review },
    };
}

fn definition_at(raw: ?*anyopaque) *const definitions.Definition {
    return @ptrCast(@alignCast(raw.?));
}

fn bound_identity(definition: *const definitions.Definition) model_provider.ProviderId {
    var identity = model_provider.parse(definition.id).?;
    identity.configured.binding = definition.binding_identity();
    return identity;
}

fn build(raw: ?*anyopaque, alloc: Allocator, request: streams.RequestData) ![]u8 {
    const definition = definition_at(raw);
    const identity = bound_identity(definition);
    for (request.messages) |message| if (message.provider_replay) |replay| {
        if (!replay.matches(.{ .provider = identity, .model = request.model })) {
            debug_trace.logf("gateway", "provider_replay_omitted reason=source_mismatch", .{});
            break;
        }
    };
    return codec.build_request(alloc, request, .{
        .tool_choice_mode = definition.tool_choice_mode,
        .provider = &identity,
        .effort = request_effort(definition, &request),
    });
}

/// The wire form of the requested reasoning level. A level the profile
/// declared carries its own fields; one learned from the service's model list
/// goes out as `reasoning_effort`. Capability resolution only lets a level
/// through when the model offers it, so null here means none was requested.
///
/// Takes the request by pointer: the level's name borrows the effort's inline
/// bytes, which must outlive serialization.
fn request_effort(definition: *const definitions.Definition, request: *const streams.RequestData) ?codec.Effort {
    const requested = if (request.provider_options.reasoning) |*value| value else return null;
    const name = switch (requested.*) {
        .auto => return null,
        .named => requested.label(),
    };
    if (definition.model(request.model)) |metadata| {
        if (metadata.effort(name)) |option| return .{ .name = option.name, .members = option.bodyMembers() };
    }
    return .{ .name = name };
}

fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, text: bool, reasoning: bool) !?types.ProviderReplay {
    const selected = try codec.project_replay(alloc, replay, calls, text, reasoning);
    if (replay != null and selected == null) debug_trace.logf("gateway", "provider_replay_omitted reason={s}", .{if (reasoning) "associated_calls_removed" else "reasoning_removed"});
    return selected;
}

test "chat completions adapter binds replay to endpoint authority and wires projection" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"}}}
    );
    defer registry.deinit(alloc);
    var changed_registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:5678/v1","auth":{"type":"none"}}}
    );
    defer changed_registry.deinit(alloc);
    const definition = registry.get("local").?;
    const adapter = bundle(definition).agent_stream.?;
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = bundle(definition).model_catalog.?.provider_id, .model = "model" },
        .parts_json = "{\"reasoning_details\":[{\"signature\":\"signed\"}],\"_tool_call_ids\":[]}",
    };
    const selected = (try adapter.projectReplay(alloc, replay, &.{}, false, true)).?;
    try std.testing.expect(selected.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try adapter.projectReplay(alloc, replay, &.{}, true, false) == null);
    const request: streams.RequestData = .{
        .model = "model",
        .instructions = &.{.{ .role = .system, .content = "instructions" }},
        .messages = &.{.{ .role = .assistant, .content = "answer", .provider_replay = replay }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const matching = try adapter.build_request_fn.?(adapter.context, alloc, request);
    defer alloc.free(matching);
    try std.testing.expect(std.mem.find(u8, matching, "reasoning_details") != null);
    const other = bundle(changed_registry.get("local").?).agent_stream.?;
    const stripped = try other.build_request_fn.?(other.context, alloc, request);
    defer alloc.free(stripped);
    try std.testing.expect(std.mem.find(u8, stripped, "reasoning_details") == null);
    try std.testing.expect(request.messages[0].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

fn stream(raw: ?*anyopaque, alloc: Allocator, request: streams.ModelRequest) !streams.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const definition = definition_at(raw);
    if (request.credential.credentialSource() != .configured) return error.ConfiguredProviderCredentialRequired;
    const token = request.credential.secret();
    if (token) |value| {
        if (value.len > 16 * 1024) return error.InvalidConfiguredProviderCredential;
        for (value) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidConfiguredProviderCredential;
    }
    switch (definition.auth) {
        .none => if (token != null) return error.UnexpectedConfiguredProviderCredential,
        .bearer => if (token == null) return error.MissingConfiguredProviderCredential,
    }
    const payload = request.prepared_request_body orelse try build(raw, alloc, request.data());
    defer if (request.prepared_request_body == null) alloc.free(payload);
    return post(alloc, definition, request, token, payload) catch |err| {
        request.attempt_evidence.network_failure = client_mod.networkFailureEvidence(err, request.delivery.load());
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (request.deadline) |deadline| if (expired(deadline)) return error.Timeout;
        return err;
    };
}

fn expired(deadline: std.Io.Clock.Timestamp) bool {
    return !std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io.getIo(), .awake), .lt, deadline);
}

fn phase_deadline(milliseconds: i64, caller: ?std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
    const phase = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(milliseconds) });
    if (caller) |deadline| if (std.Io.Clock.Timestamp.compare(deadline, .lt, phase)) return deadline;
    return phase;
}

fn post(alloc: Allocator, definition: *const definitions.Definition, request: streams.ModelRequest, token: ?[]const u8, payload: []const u8) !streams.Result {
    const url = try definition.chat_url(alloc);
    defer alloc.free(url);
    const authorization = if (token) |value| try std.fmt.allocPrint(alloc, "Bearer {s}", .{value}) else null;
    defer if (authorization) |value| secret.zeroAndFree(alloc, value);
    var client: std.http.Client = .{ .allocator = alloc, .io = io.getIo() };
    defer client.deinit();
    var uri = try std.Uri.parse(url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) "http" else return error.UnsupportedUriScheme;
    var header_buffer: [2]std.http.Header = .{ .{ .name = "accept", .value = "text/event-stream" }, undefined };
    var header_count: usize = 1;
    if (definition.session_header) |name| if (request.session_id) |session| if (session.len > 0) {
        header_buffer[header_count] = .{ .name = name, .value = session };
        header_count += 1;
    };
    var operation = client_mod.PostOperation{
        .client = &client,
        .uri = uri,
        .authorization = authorization,
        .extra_headers = header_buffer[0..header_count],
    };
    try request.admission.admit();
    var opened = try client_mod.openBoundedPost(alloc, request.cancel_flag, phase_deadline(30_000, request.deadline), &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var watch: client_mod.CancelWatch = .{};
    defer watch.stop();
    const head_deadline = phase_deadline(120_000, request.deadline);
    if (http.connection) |connection| try watch.start(request.cancel_flag, head_deadline, connection.stream_writer.stream);
    http.transfer_encoding = .{ .content_length = payload.len };
    var buffer: [8192]u8 = undefined;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    request.delivery.markPossiblySent();
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(payload);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = http.receiveHead(&.{}) catch |err| {
        if (expired(head_deadline)) return error.Timeout;
        return err;
    };
    watch.stop();
    if (http.connection) |connection| try watch.start(request.cancel_flag, if (response.head.status == .ok) request.deadline else phase_deadline(30_000, request.deadline), connection.stream_writer.stream);
    var retry_after: ?u64 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
        retry_after = std.fmt.parseUnsigned(u64, std.mem.trim(u8, header.value, " \t"), 10) catch null;
        break;
    };
    var transfer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer);
    if (response.head.status != .ok) {
        var detail = reader.allocRemaining(alloc, .limited(64 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => try alloc.dupe(u8, "Provider error response exceeded the local limit"),
            else => return err,
        };
        errdefer alloc.free(detail);
        if (token) |value| {
            const redacted = try codec.redact_error_detail(alloc, detail, value);
            alloc.free(detail);
            detail = redacted;
        }

        return .{ .failed = .{ .kind = switch (response.head.status) {
            .bad_request => .invalid_request,
            .unauthorized => .unauthorized,
            .forbidden => .forbidden,
            .payload_too_large => .request_too_large,
            .too_many_requests => .rate_limited,
            .internal_server_error => .server_error,
            .bad_gateway => .bad_gateway,
            .service_unavailable => .unavailable,
            .gateway_timeout => .gateway_timeout,
            else => .provider_error,
        }, .detail = detail, .retry_after_seconds = retry_after, .ownership = .owned } };
    }
    var limits: codec.Limits = .{};
    if (request.content_capture_limit) |limit| limits.content_bytes = @min(limit, limits.content_bytes);
    return codec.consume_stream(alloc, reader, request.data(), limits, request.events, request.cancel_flag);
}

/// The returned entry borrows its strings; fetch_catalog replaces them with owned copies.
fn metadata_entry(metadata: definitions.ModelMetadata) catalog.ModelCatalogEntry {
    const vision = metadata.supports_vision orelse false;
    return .{
        .id = @constCast(metadata.id),
        .model_type = @constCast("language"),
        .has_tool_use = metadata.supports_tool_use orelse false,
        // Chat completions sends images as inline base64 content parts, so
        // vision support implies file input through the same path.
        .has_vision = vision,
        .has_file_input = vision,
        .context_window = metadata.context_window orelse 0,
        .max_tokens = metadata.max_output_tokens orelse 0,
    };
}

fn lookup_capabilities(raw: ?*anyopaque, model: []const u8) model_capabilities.Capabilities {
    const metadata = definition_at(raw).model(model) orelse return .{};
    var gateway_metadata = model_catalog_metadata.fromCatalogEntry(metadata_entry(metadata.*));
    gateway_metadata.reasoning_efforts = metadata_efforts(metadata.*);
    gateway_metadata.supports_reasoning = gateway_metadata.reasoning_efforts.len > 0;
    return model_capabilities.mergeCapabilities(.{}, gateway_metadata);
}

/// The levels a profile declared for this model, as fx's effort values. A name
/// fx cannot represent is skipped rather than failing the whole catalog.
fn metadata_efforts(metadata: definitions.ModelMetadata) model_capabilities.ReasoningEffortOptions {
    var levels: model_capabilities.ReasoningEffortOptions = .{};
    for (metadata.reasoning_efforts) |option| {
        if (levels.len == levels.values.len) break;
        levels.values[levels.len] = types.ReasoningEffort.parse(option.name) orelse continue;
        levels.len += 1;
    }
    return levels;
}

fn fetch_catalog(raw: ?*anyopaque, alloc: Allocator, input: catalog.FetchInput) Allocator.Error!catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    const definition = definition_at(raw);
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    errdefer catalog.freeModelCatalog(alloc, &entries);
    for (definition.model_metadata) |metadata| {
        var entry = metadata_entry(metadata);
        entry.id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(entry.id);
        entry.model_type = try alloc.dupe(u8, entry.model_type);
        errdefer alloc.free(entry.model_type);
        const levels = metadata_efforts(metadata);
        try entry.reasoning_efforts.appendSlice(alloc, levels.slice());
        errdefer entry.reasoning_efforts.deinit(alloc);
        entry.has_reasoning = levels.len > 0;
        try entries.append(alloc, entry);
    }
    try discover_efforts(alloc, definition, input, &entries);
    return .{ .catalog = entries };
}

const discovery_timeout_ms: i64 = 10_000;
const max_discovery_bytes: usize = 4 * 1024 * 1024;

/// Adds the reasoning levels the service itself lists for each model, after
/// the ones the profile declared. DeepSeek reports them under
/// `effort.supported_levels` in `/models`; a service that reports none, or a
/// failed request, leaves the declared levels as they are.
///
/// Runs only when the caller names an endpoint: the picker's synchronous
/// refresh passes none, so it never waits on the network.
fn discover_efforts(
    alloc: Allocator,
    definition: *const definitions.Definition,
    input: catalog.FetchInput,
    entries: *std.ArrayList(catalog.ModelCatalogEntry),
) Allocator.Error!void {
    if (input.endpoint.len == 0 or entries.items.len == 0) return;
    // The same environment slot the stream credential is read from.
    const token: ?[]const u8 = switch (definition.auth) {
        .none => null,
        .bearer => |env| io.getenv(env) orelse return,
    };
    const url = try std.mem.concat(alloc, u8, &.{ definition.base_url, "/models" });
    defer alloc.free(url);
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(discovery_timeout_ms) });
    var operation = ModelsRequest{ .alloc = alloc, .url = url, .token = token };
    var response = client_mod.runBoundedHttpOperation(ModelsResponse, alloc, input.cancel_flag orelse &fallback_cancel, deadline, &operation) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("gateway", "effort_discovery_failed provider={s} err={s}", .{ definition.id, @errorName(err) });
        return;
    };
    defer response.deinit(alloc);
    if (response.status != .ok) {
        debug_trace.logf("gateway", "effort_discovery_failed provider={s} status={d}", .{ definition.id, @intFromEnum(response.status) });
        return;
    }
    try merge_discovered_efforts(alloc, response.body, entries.items);
}

fn merge_discovered_efforts(alloc: Allocator, body: []const u8, entries: []catalog.ModelCatalogEntry) Allocator.Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const data = parsed.value.object.get("data") orelse return;
    if (data != .array) return;
    for (data.array.items) |model| {
        if (model != .object) continue;
        const id = model.object.get("id") orelse continue;
        const effort = model.object.get("effort") orelse continue;
        if (id != .string or effort != .object) continue;
        const levels = effort.object.get("supported_levels") orelse continue;
        if (levels != .array) continue;
        for (entries) |*entry| {
            if (!std.mem.eql(u8, entry.id, id.string)) continue;
            for (levels.array.items) |level| {
                if (level != .string) continue;
                const value = types.ReasoningEffort.parse(level.string) orelse continue;
                if (value == .auto or has_effort(entry.reasoning_efforts.items, value)) continue;
                if (entry.reasoning_efforts.items.len >= types.ReasoningEffort.max_options) break;
                try entry.reasoning_efforts.append(alloc, value);
            }
            entry.has_reasoning = entry.reasoning_efforts.items.len > 0;
        }
    }
}

fn has_effort(levels: []const types.ReasoningEffort, value: types.ReasoningEffort) bool {
    for (levels) |level| if (level.eql(value)) return true;
    return false;
}

const ModelsResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *ModelsResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const ModelsRequest = struct {
    alloc: Allocator,
    url: []const u8,
    token: ?[]const u8,

    pub fn run(self: *@This()) !ModelsResponse {
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io.getIo() };
        defer client.deinit();
        var authorization: ?[]u8 = null;
        defer if (authorization) |value| secret.zeroAndFree(self.alloc, value);
        var headers: std.http.Client.Request.Headers = .{
            .user_agent = .{ .override = client_mod.user_agent },
            .accept_encoding = .omit,
        };
        if (self.token) |token| {
            authorization = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{token});
            headers.authorization = .{ .override = authorization.? };
        }
        const buffer = try self.alloc.alloc(u8, max_discovery_bytes + 1);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const result = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = headers,
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.ModelListTooLarge,
            else => return err,
        };
        const body = writer.buffered();
        if (body.len > max_discovery_bytes) return error.ModelListTooLarge;
        return .{ .status = result.status, .body = try self.alloc.dupe(u8, body) };
    }
};

test "configured capability lookup matches catalog projection and preserves unknowns" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"local":{"protocol":"openai-chat-completions","base_url":"http://localhost:1234/v1","auth":{"type":"none"},"model_metadata":{"small":{"context_window":8192,"max_output_tokens":512,"supports_tool_use":true,"supports_vision":true},"large":{"context_window":32768,"max_output_tokens":1024,"supports_tool_use":false},"partial":{"max_output_tokens":128},"unknown":{}}}}
    );
    defer registry.deinit(alloc);
    const provider = bundle(registry.get("local").?).model_catalog.?;
    var fetched = try provider.fetch(alloc, .{ .endpoint = "" });
    defer catalog.freeModelCatalog(alloc, &fetched.catalog);
    for (fetched.catalog.items) |entry| {
        const actual = provider.lookupCapabilities(entry.id).?;
        try std.testing.expectEqualDeep(model_capabilities.mergeCapabilities(.{}, model_catalog_metadata.fromCatalogEntry(entry)), actual);
        const declared_vision = std.mem.eql(u8, entry.id, "small");
        try std.testing.expectEqual(declared_vision, actual.supports_vision);
        try std.testing.expectEqual(
            if (declared_vision) model_capabilities.ImageInputSupport.native else model_capabilities.ImageInputSupport.non_native,
            actual.image_input_support,
        );
    }
    try std.testing.expectEqual(@as(?u32, 512), provider.lookupCapabilities("small").?.max_output_tokens);
    try std.testing.expectEqual(@as(?u32, 1024), provider.lookupCapabilities("large").?.max_output_tokens);
    try std.testing.expect(provider.lookupCapabilities("partial").?.context_window == null);
    try std.testing.expect(provider.lookupCapabilities("unknown").?.max_output_tokens == null);
    try std.testing.expectEqualDeep(model_capabilities.Capabilities{}, provider.lookupCapabilities("missing-fast").?);
}

fn fetch_cli_catalog(raw: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const provenance = catalog.Provenance{ .access = catalog.AccessMetadata.init(input.access) };
    const result = fetch_catalog(raw, alloc, .{ .access = input.access, .endpoint = input.endpoint, .cancel_flag = input.cancel_flag }) catch
        return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
    switch (result) {
        .failure => |failure| return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = failure } },
        .catalog => |value| {
            var entries = value;
            defer catalog.freeModelCatalog(alloc, &entries);
            const ids = catalog.projectModelIds(alloc, entries.items) catch return .{ .failure = .{ .access = provenance.access, .anonymous_fallback_used = false, .failure = .{ .category = .resource_exhausted } } };
            return .{ .loaded = .{ .ids = ids, .provenance = provenance } };
        },
    }
}

const Review = struct { definition: *const definitions.Definition, input: classifier.ProviderInput };
fn review(raw: ?*anyopaque, alloc: Allocator, input: classifier.ProviderInput, request: classifier.ReviewRequest) !classifier.ParseOutcome {
    var state = Review{ .definition = definition_at(raw), .input = input };
    return classifier.Reviewer.withTransportModel(.{ .context = &state, .build_fn = build_review, .send_fn = send_review }, input.cancel_flag, classifier.Reviewer.default_timeout_ms, state.definition.reviewer_model orelse request.review_turn.model).review(alloc, request);
}
fn build_review(raw: *anyopaque, alloc: Allocator, model: []const u8, _: []const u8, instructions: []const types.ChatMessage, messages: []const types.ChatMessage, target_id: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) ![]u8 {
    const state: *Review = @ptrCast(@alignCast(raw));
    const expanded = try review_messages.expandPendingToolReviewMessages(alloc, messages, target_id, deadline, cancel);
    defer alloc.free(expanded);
    const output_limit = if (state.definition.model(model)) |metadata| @min(metadata.max_output_tokens orelse 2048, 2048) else 2048;
    return build(@ptrCast(@constCast(state.definition)), alloc, .{ .model = model, .instructions = instructions, .messages = expanded, .tools = .{ .additional_functions = &.{classifier.function_schema} }, .tool_choice = .required, .provider_options = .{}, .max_output_tokens = output_limit });
}
fn ignore_event(_: *anyopaque, _: streams.Event) void {}
fn free_result(raw: *anyopaque, alloc: Allocator) void {
    const result: *streams.Result = @ptrCast(@alignCast(raw));
    result.deinit(alloc);
    alloc.destroy(result);
}
fn send_review(raw: *anyopaque, alloc: Allocator, model: []const u8, payload: []const u8, deadline: std.Io.Clock.Timestamp, cancel: *std.atomic.Value(bool)) !classifier.TransportOutcome {
    const state: *Review = @ptrCast(@alignCast(raw));
    var delivery: streams.DeliveryCertainty = .init();
    var evidence: streams.AttemptEvidence = .{};
    var event_context: u8 = 0;
    var result = gateway_step.streamModelCompletion(bundle(state.definition).agent_stream.?, alloc, .{
        .credential = .{ .direct = .{ .secret_bytes = state.input.credential, .source = state.input.credential_source } },
        .model = model,
        .retry_count = 1,
        .messages = &.{},
        .tools = .{ .additional_functions = &.{classifier.function_schema} },
        .tool_choice = .required,
        .provider_options = .{},
        .prepared_request_body = payload,
        .trace_ctx = .{},
        .content_capture_limit = 16 * 1024,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &event_context, .emit_fn = ignore_event },
        .cancel_flag = cancel,
    }, state.input.usage, state.input.usage_allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Cancelled => return .cancelled,
        error.Timeout => return .timed_out,
        error.RequiredToolMissing => return .{ .completion = .{ .completion = .{} } },
        else => return .permanent_failure,
    };
    errdefer result.deinit(alloc);
    if (result == .failed) {
        result.deinit(alloc);
        return .permanent_failure;
    }
    const owned = try alloc.create(streams.Result);
    owned.* = result;
    return .{ .completion = .{ .completion = owned.completed.completion, .context = owned, .deinit_fn = free_result } };
}

test "configured reasoning levels reach the effort step and the request body" {
    const alloc = std.testing.allocator;
    var registry = try definitions.Registry.parse_json(alloc,
        \\{"deepseek":{"protocol":"openai-chat-completions","base_url":"https://api.deepseek.com","auth":{"type":"none"},
        \\"model_metadata":{"deepseek-flash":{"reasoning_efforts":[{"name":"off","body":{"thinking":{"type":"disabled"}}},"low"]},"plain":{}}}}
    );
    defer registry.deinit(alloc);
    const definition = registry.get("deepseek").?;
    const provider = bundle(definition).model_catalog.?;

    // Declared levels keep their order, lowest first, for the picker's effort step.
    const capabilities = provider.lookupCapabilities("deepseek-flash").?;
    try std.testing.expect(capabilities.supports_reasoning);
    try std.testing.expectEqual(@as(usize, 2), capabilities.reasoning_efforts.len);
    try std.testing.expectEqualStrings("off", capabilities.reasoning_efforts.values[0].label());
    try std.testing.expectEqual(@as(usize, 0), provider.lookupCapabilities("plain").?.reasoning_efforts.len);

    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hi" }};
    const cases = [_]struct { effort: ?types.ReasoningEffort, model: []const u8, expected: ?[]const u8 }{
        .{ .effort = types.ReasoningEffort.literal("off"), .model = "deepseek-flash", .expected = "\"thinking\":{\"type\":\"disabled\"}" },
        .{ .effort = types.ReasoningEffort.literal("low"), .model = "deepseek-flash", .expected = "\"reasoning_effort\":\"low\"" },
        // A level learned from the service's model list goes out by name.
        .{ .effort = types.ReasoningEffort.literal("max"), .model = "deepseek-flash", .expected = "\"reasoning_effort\":\"max\"" },
        .{ .effort = null, .model = "deepseek-flash", .expected = null },
    };
    for (cases) |case| {
        const body = try build(@ptrCast(@constCast(definition)), alloc, .{
            .model = case.model,
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{ .reasoning = case.effort },
        });
        defer alloc.free(body);
        if (case.expected) |fragment| {
            try std.testing.expect(std.mem.find(u8, body, fragment) != null);
        } else {
            try std.testing.expect(std.mem.find(u8, body, "reasoning_effort") == null);
            try std.testing.expect(std.mem.find(u8, body, "thinking") == null);
        }
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        parsed.deinit();
    }
}

test "levels a service reports are added after the declared ones" {
    const alloc = std.testing.allocator;
    var entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty;
    defer catalog.freeModelCatalog(alloc, &entries);
    for ([_][]const u8{ "deepseek-flash", "undeclared" }) |id| {
        try entries.append(alloc, .{ .id = try alloc.dupe(u8, id), .model_type = try alloc.dupe(u8, "language") });
    }
    try entries.items[0].reasoning_efforts.append(alloc, types.ReasoningEffort.literal("off"));
    try merge_discovered_efforts(alloc,
        \\{"object":"list","data":[{"id":"deepseek-flash","effort":{"supported_levels":["low","high","max","off","default"],"default_level":"high"}},
        \\{"id":"not-listed","effort":{"supported_levels":["low"]}},{"id":"undeclared"},{"id":7}]}
    , entries.items);
    const levels = entries.items[0].reasoning_efforts.items;
    try std.testing.expectEqual(@as(usize, 4), levels.len);
    for ([_][]const u8{ "off", "low", "high", "max" }, levels) |expected, level| {
        try std.testing.expectEqualStrings(expected, level.label());
    }
    try std.testing.expect(entries.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 0), entries.items[1].reasoning_efforts.items.len);

    // A body that is not a model list leaves the entries alone.
    try merge_discovered_efforts(alloc, "not json", entries.items);
    try merge_discovered_efforts(alloc, "{\"data\":{}}", entries.items);
    try std.testing.expectEqual(@as(usize, 4), entries.items[0].reasoning_efforts.items.len);
}
