//! Feeds the /model picker with the models of every connection that is not the
//! active one. When the active connection changes, configured connections are
//! listed at once from their profile settings. A background pass then refreshes
//! them with the reasoning levels each service reports for its models, and
//! fetches the signed-in Codex catalog, so the effort step after choosing a row
//! offers that model's own levels.
//!
//! Rows reach the picker as `connection/model` (see `model_cache_runtime`), and
//! choosing one switches connection through the same path as `/model`.
const std = @import("std");
const auth_runtime = @import("../auth/auth_runtime.zig");
const chatgpt_oauth = @import("../auth/chatgpt_oauth.zig");
const configured_provider = @import("../config/configured_provider.zig");
const credentials = @import("../auth/credentials.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_cache_runtime = @import("model_cache_runtime.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const provider_set = @import("../gateway/provider_set.zig");

const Allocator = std.mem.Allocator;

const codex_connection = "codex";
const refresh_interval_ms: i64 = 5 * 60 * 1000;
/// Any non-empty endpoint asks a configured catalog to read the service's own
/// model list (see `chat_completions.discover_efforts`).
const discovery_endpoint = "/models";

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(true),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Zero until a background pass has started; throttles it to one per
    /// interval so opening the picker repeatedly does not hit the network.
    started_ms: i64 = 0,
    /// The connection the rows were last computed for. A change relists the
    /// configured connections at once and asks for a fresh background pass.
    last_active: ?model_provider.ProviderId = null,

    pub fn init(alloc: Allocator) Self {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Self) void {
        self.cancel_requested.store(true, .seq_cst);
        self.joinThread();
    }

    /// Recomputes the sibling rows for the current active connection. Never
    /// blocks on the network and never fails the caller: a picker without the
    /// extra rows is still the working picker it was.
    pub fn refresh(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        set: provider_set.Set,
        active: model_provider.ProviderId,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        host_managed: bool,
        /// False at launch: the background pass is network work for a picker
        /// that may never open, so it waits until one does.
        reach_network: bool,
    ) void {
        self.finishThreadIfDone();
        // The Gateway already prefixes ids with the publisher, so only the
        // other routes get their connection label in front.
        cache.setActiveConnection(if (active == .gateway) null else active.label());
        const changed = if (self.last_active) |last| !last.eql(active) else true;
        if (changed) {
            self.last_active = active;
            self.listDeclared(cache, set, active);
            if (active == .codex) cache.replaceSiblings(codex_connection, .empty) catch {};
            self.started_ms = 0;
        }
        if (reach_network) self.startBackground(cache, set, active, transport, secret_store, host_managed);
    }

    /// Profile-declared models only, without touching the network.
    fn listDeclared(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        set: provider_set.Set,
        active: model_provider.ProviderId,
    ) void {
        const factory = set.configured_fn orelse return;
        for (set.definitions) |*definition| {
            if (isActive(active, definition.id)) {
                cache.replaceSiblings(definition.id, .empty) catch {};
                continue;
            }
            const provider = factory(definition).model_catalog orelse continue;
            const result = provider.fetch(self.alloc, .{
                .access = .{ .public_only = .no_credential },
                .endpoint = "",
            }) catch continue;
            switch (result) {
                .catalog => |entries| cache.replaceSiblings(definition.id, entries) catch {},
                .failure => {},
            }
        }
    }

    fn startBackground(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        set: provider_set.Set,
        active: model_provider.ProviderId,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        host_managed: bool,
    ) void {
        if (self.thread != null) return;
        const now = io_mod.milliTimestamp();
        if (self.started_ms != 0 and now - self.started_ms < refresh_interval_ms) return;
        var work = Work.init(self.alloc, set, active, transport, secret_store, host_managed) catch return;
        if (work.isEmpty()) {
            work.deinit(self.alloc);
            return;
        }
        self.started_ms = now;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, backgroundMain, .{ self, cache, work }) catch {
            work.deinit(self.alloc);
            self.done.store(true, .release);
            self.started_ms = 0;
            return;
        };
    }

    fn backgroundMain(self: *Self, cache: *model_cache_runtime.Runtime, work: Work) void {
        defer self.done.store(true, .release);
        var owned = work;
        defer owned.deinit(self.alloc);
        if (owned.factory) |factory| for (owned.definitions) |*definition| {
            if (self.cancel_requested.load(.seq_cst)) return;
            const provider = factory(definition).model_catalog orelse continue;
            const result = provider.fetch(self.alloc, .{
                .access = .{ .public_only = .no_credential },
                .endpoint = discovery_endpoint,
                .cancel_flag = &self.cancel_requested,
            }) catch continue;
            switch (result) {
                .catalog => |entries| cache.replaceSiblings(definition.id, entries) catch {},
                .failure => {},
            }
        };
        if (owned.codex) |provider| self.fetchCodex(cache, provider, owned.transport, owned.secret_store);
    }

    fn fetchCodex(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        provider: model_catalog.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) void {
        const signed_in = chatgpt_oauth.sourceExists(self.alloc) catch false;
        if (!signed_in or self.cancel_requested.load(.seq_cst)) return;
        var credential = (auth_runtime.prepareCredential(
            self.alloc,
            transport,
            secret_store,
            .codex,
            null,
        ) catch return) orelse return;
        defer credential.deinit(self.alloc);
        if (self.cancel_requested.load(.seq_cst)) return;
        const result = provider.fetch(self.alloc, .{
            .access = credentials.catalogAccessForCredentialAndAccount(
                credential.source,
                credential.token,
                credential.gatewayTeam(),
                credential.accountId(),
            ),
            .endpoint = "",
            .cancel_flag = &self.cancel_requested,
            .view = .picker,
        }) catch return;
        switch (result) {
            .catalog => |entries| cache.replaceSiblings(codex_connection, entries) catch {},
            .failure => {},
        }
    }

    fn finishThreadIfDone(self: *Self) void {
        if (self.thread != null and self.done.load(.acquire)) self.joinThread();
    }

    fn joinThread(self: *Self) void {
        const thread = self.thread orelse return;
        thread.join();
        self.thread = null;
    }
};

fn isActive(active: model_provider.ProviderId, connection: []const u8) bool {
    return active == .configured and std.mem.eql(u8, active.label(), connection);
}

/// What one background pass needs, copied so it outlives a settings reload
/// that replaces the profile's definitions.
const Work = struct {
    definitions: []configured_provider.Definition,
    factory: ?*const fn (*const configured_provider.Definition) provider_set.Bundle,
    codex: ?model_catalog.Provider,
    transport: oauth_transport.Provider,
    secret_store: host.SecretStore,

    fn init(
        alloc: Allocator,
        set: provider_set.Set,
        active: model_provider.ProviderId,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
        host_managed: bool,
    ) Allocator.Error!Work {
        var definitions: std.ArrayList(configured_provider.Definition) = .empty;
        errdefer {
            for (definitions.items) |definition| definition.deinit(alloc);
            definitions.deinit(alloc);
        }
        if (set.configured_fn != null) for (set.definitions) |definition| {
            if (isActive(active, definition.id)) continue;
            const copy = try definition.clone(alloc);
            definitions.append(alloc, copy) catch |err| {
                copy.deinit(alloc);
                return err;
            };
        };
        return .{
            .definitions = try definitions.toOwnedSlice(alloc),
            .factory = set.configured_fn,
            .codex = if (active == .codex or host_managed) null else set.codex.model_catalog,
            .transport = transport,
            .secret_store = secret_store,
        };
    }

    fn isEmpty(self: Work) bool {
        return self.definitions.len == 0 and self.codex == null;
    }

    fn deinit(self: *Work, alloc: Allocator) void {
        for (self.definitions) |definition| definition.deinit(alloc);
        alloc.free(self.definitions);
        self.* = undefined;
    }
};

test "configured connections other than the active one become picker rows" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"deepseek":{"protocol":"openai-chat-completions","base_url":"https://api.deepseek.com",
        \\"auth":{"type":"bearer","env":"DEEPSEEK_API_KEY"},
        \\"model_metadata":{"deepseek-flash":{}}},
        \\"glm":{"protocol":"openai-chat-completions","base_url":"https://api.z.ai/api/coding/paas/v4",
        \\"auth":{"type":"bearer","env":"ZAI_API_KEY"},
        \\"model_metadata":{"glm-5.3":{},"glm-5.3-flash":{}}}}
    , .{});
    defer parsed.deinit();
    var registry = try configured_provider.Registry.parse(alloc, parsed.value);
    defer registry.deinit(alloc);

    var cache = model_cache_runtime.Runtime.init(alloc, "/v1/models");
    defer cache.deinit();
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    const set = provider_set.Set{
        .gateway = .{},
        .codex = .{},
        .grok = .{},
        .definitions = registry.definitions,
        .configured_fn = @import("../../gateway/chat_completions.zig").bundle,
    };

    runtime.refresh(&cache, set, model_provider.parse("deepseek").?, oauth_transport.unavailable_provider, host.unavailable_secret_store, true, false);
    try std.testing.expectEqual(@as(usize, 2), cache.siblings.items.len);
    try std.testing.expectEqualStrings("glm/glm-5.3", cache.siblings.items[0].id);

    // Switching to glm swaps which connection is listed.
    runtime.refresh(&cache, set, model_provider.parse("glm").?, oauth_transport.unavailable_provider, host.unavailable_secret_store, true, false);
    try std.testing.expectEqual(@as(usize, 1), cache.siblings.items.len);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", cache.siblings.items[0].id);
}
