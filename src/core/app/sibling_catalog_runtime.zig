//! Feeds the /model picker with the models of every connection that is not the
//! active one. A configured connection answers from its profile settings on the
//! calling thread. The Codex subscription needs a signed-in catalog fetch, so it
//! runs on one background thread and lands in the cache when it finishes.
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
const codex_refresh_interval_ms: i64 = 5 * 60 * 1000;

pub const Runtime = struct {
    const Self = @This();

    alloc: Allocator,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(true),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    /// Zero until a fetch has been started; throttles the refresh to one per
    /// interval so opening the picker repeatedly does not hit the network.
    codex_started_ms: i64 = 0,

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
    ) void {
        self.finishThreadIfDone();
        self.refreshConfigured(cache, set, active);
        if (active == .codex) {
            cache.replaceSiblings(codex_connection, .empty) catch {};
            self.codex_started_ms = 0;
            return;
        }
        if (host_managed) return;
        self.startCodex(cache, set, transport, secret_store);
    }

    fn refreshConfigured(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        set: provider_set.Set,
        active: model_provider.ProviderId,
    ) void {
        const factory = set.configured_fn orelse return;
        for (set.definitions) |*definition| {
            const is_active = active == .configured and std.mem.eql(u8, active.label(), definition.id);
            if (is_active) {
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

    fn startCodex(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        set: provider_set.Set,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) void {
        if (self.thread != null) return;
        const provider = set.codex.model_catalog orelse return;
        const now = io_mod.milliTimestamp();
        if (self.codex_started_ms != 0 and now - self.codex_started_ms < codex_refresh_interval_ms) return;
        self.codex_started_ms = now;
        self.done.store(false, .release);
        self.thread = std.Thread.spawn(.{}, codexMain, .{ self, cache, provider, transport, secret_store }) catch {
            self.done.store(true, .release);
            self.codex_started_ms = 0;
            return;
        };
    }

    fn codexMain(
        self: *Self,
        cache: *model_cache_runtime.Runtime,
        provider: model_catalog.Provider,
        transport: oauth_transport.Provider,
        secret_store: host.SecretStore,
    ) void {
        defer self.done.store(true, .release);
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
            .failure => self.codex_started_ms = 0,
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

    runtime.refresh(&cache, set, model_provider.parse("deepseek").?, oauth_transport.unavailable_provider, host.unavailable_secret_store, true);
    try std.testing.expectEqual(@as(usize, 2), cache.siblings.items.len);
    try std.testing.expectEqualStrings("glm/glm-5.3", cache.siblings.items[0].id);

    // Switching to glm swaps which connection is listed.
    runtime.refresh(&cache, set, model_provider.parse("glm").?, oauth_transport.unavailable_provider, host.unavailable_secret_store, true);
    try std.testing.expectEqual(@as(usize, 1), cache.siblings.items.len);
    try std.testing.expectEqualStrings("deepseek/deepseek-flash", cache.siblings.items[0].id);
}
