const std = @import("std");
const evaluation = @import("../core/agent/evaluation_provider.zig");
const client = @import("client.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const gateway_endpoint = "https://ai-gateway.vercel.sh/v4/ai/evaluation-model";
const typesafe_endpoint = "https://api.typesafe.ai/v1/systemone";
const max_response_bytes = 1024 * 1024;

const Credentials = struct {
    api_key: []const u8,
    team: ?[]const u8,
};

/// HTTP status maps to a redaction-safe rejection class. Provider response
/// bodies are never inspected or traced, so only the class is recorded.
fn statusError(status: std.http.Status) evaluation.RejectionError {
    return switch (status) {
        .unauthorized => error.EvaluationUnauthorized,
        .forbidden => error.EvaluationForbidden,
        .too_many_requests => error.EvaluationRateLimited,
        else => if (@intFromEnum(status) >= 500) error.EvaluationServerError else error.EvaluationRejected,
    };
}

test "Jev evaluation status mapping separates auth, quota and provider faults" {
    try std.testing.expectEqual(error.EvaluationUnauthorized, statusError(.unauthorized));
    try std.testing.expectEqual(error.EvaluationForbidden, statusError(.forbidden));
    try std.testing.expectEqual(error.EvaluationRateLimited, statusError(.too_many_requests));
    try std.testing.expectEqual(error.EvaluationRejected, statusError(.bad_request));
    try std.testing.expectEqual(error.EvaluationRejected, statusError(.not_found));
    try std.testing.expectEqual(error.EvaluationServerError, statusError(.internal_server_error));
    try std.testing.expectEqual(error.EvaluationServerError, statusError(.bad_gateway));
    try std.testing.expectEqual(error.EvaluationServerError, statusError(.service_unavailable));
}

fn select_credentials(request: evaluation.Request, dedicated_key: ?[]const u8, dedicated_team: ?[]const u8) !Credentials {
    if (dedicated_key) |key| {
        // An explicit evaluation credential must never inherit the inference
        // account's team or silently fall back to its key.
        if (key.len == 0) return error.MissingEvaluationCredential;
        return .{ .api_key = key, .team = if (dedicated_team) |team| if (team.len > 0) team else null else null };
    }
    return .{ .api_key = request.api_key, .team = request.team };
}

/// A direct TypeSafe call authenticates only with its own credential. It never
/// falls back to the Gateway or inference key, and it carries no Gateway team.
fn select_typesafe_credentials(typesafe_key: ?[]const u8) !Credentials {
    const key = typesafe_key orelse return error.MissingEvaluationCredential;
    if (key.len == 0) return error.MissingEvaluationCredential;
    return .{ .api_key = key, .team = null };
}

pub fn evaluate(_: ?*anyopaque, alloc: std.mem.Allocator, request: evaluation.Request) !evaluation.Response {
    const limit = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(10_000) });
    const deadline = if (request.deadline) |outer| if (std.Io.Clock.Timestamp.compare(outer, .lt, limit)) outer else limit else limit;
    var operation = Operation{ .alloc = alloc, .request = request };
    return client.runBoundedHttpOperation(evaluation.Response, alloc, request.cancel_flag, deadline, &operation);
}

const Operation = struct {
    alloc: std.mem.Allocator,
    request: evaluation.Request,

    pub fn run(self: *@This()) !evaluation.Response {
        var http: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer http.deinit();
        const direct_typesafe = self.request.transport == .typesafe;
        const credentials = if (direct_typesafe)
            try select_typesafe_credentials(evaluation.typesafeApiKey())
        else
            try select_credentials(self.request, io_mod.getenv("FX_JEV_GATEWAY_API_KEY"), io_mod.getenv("FX_JEV_GATEWAY_TEAM"));
        const authorization = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{credentials.api_key});
        defer secret.zeroAndFree(self.alloc, authorization);
        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(self.alloc);
        // The Gateway transport names the evaluation model and protocol in
        // headers; direct TypeSafe carries the model in the request body.
        if (!direct_typesafe) try headers.appendSlice(self.alloc, &.{
            .{ .name = "ai-gateway-protocol-version", .value = "0.0.1" },
            .{ .name = "ai-evaluation-model-specification-version", .value = "4" },
            .{ .name = "ai-model-id", .value = "typesafe-ai/jev" },
        });
        if (credentials.team) |team| try headers.append(self.alloc, .{ .name = client.vercel_ai_gateway_team_header, .value = team });
        const buffer = try self.alloc.alloc(u8, max_response_bytes);
        defer self.alloc.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        const url = if (io_mod.getenv("FX_E2E_JEV_URL")) |override| blk: {
            if (!client.isLoopbackHttpUrl(override)) return error.UntrustedEvaluationEndpoint;
            break :blk override;
        } else if (direct_typesafe) typesafe_endpoint else gateway_endpoint;
        const result = try http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = self.request.payload,
            .headers = .{
                .authorization = .{ .override = authorization },
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .omit,
                .user_agent = .{ .override = client.user_agent },
            },
            .extra_headers = headers.items,
            .redirect_behavior = .unhandled,
            .response_writer = &writer,
        });
        // Do not put provider error bodies (which can echo input) into traces.
        if (result.status != .ok) {
            if (self.request.rejection_status) |slot| slot.* = @intFromEnum(result.status);
            return statusError(result.status);
        }
        return .{ .body = try self.alloc.dupe(u8, writer.buffered()) };
    }
};

test "Jev dedicated credentials keep evaluation and inference accounts separate" {
    var cancel = std.atomic.Value(bool).init(false);
    const request: evaluation.Request = .{ .payload = "{}", .api_key = "inference-key", .team = "inference-team", .cancel_flag = &cancel };
    const inherited = try select_credentials(request, null, "ignored-without-dedicated-key");
    try std.testing.expectEqualStrings("inference-key", inherited.api_key);
    try std.testing.expectEqualStrings("inference-team", inherited.team.?);
    const dedicated = try select_credentials(request, "evaluation-key", null);
    try std.testing.expectEqualStrings("evaluation-key", dedicated.api_key);
    try std.testing.expect(dedicated.team == null);
    const scoped = try select_credentials(request, "evaluation-key", "evaluation-team");
    try std.testing.expectEqualStrings("evaluation-team", scoped.team.?);
    try std.testing.expect((try select_credentials(request, "evaluation-key", "")).team == null);
    try std.testing.expectError(error.MissingEvaluationCredential, select_credentials(request, "", null));
    try std.testing.expectEqualStrings("inference-key", request.api_key);
    try std.testing.expectEqualStrings("inference-team", request.team.?);

    // Direct TypeSafe uses only its own credential and never inherits a team.
    const direct = try select_typesafe_credentials("typesafe-key");
    try std.testing.expectEqualStrings("typesafe-key", direct.api_key);
    try std.testing.expect(direct.team == null);
    try std.testing.expectError(error.MissingEvaluationCredential, select_typesafe_credentials(null));
    try std.testing.expectError(error.MissingEvaluationCredential, select_typesafe_credentials(""));
}
