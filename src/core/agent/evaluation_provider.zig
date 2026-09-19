const std = @import("std");
const io_mod = @import("../shared/io.zig");

/// The evaluation service that carries a typed decision. `gateway` routes
/// through Vercel AI Gateway (`typesafe-ai/jev`); `typesafe` calls the TypeSafe
/// API directly with the pinned `jev-1.13.0` model, which avoids a Gateway
/// project/provider allowlist that can deny access.
pub const Transport = enum { gateway, typesafe };

/// Direct TypeSafe credential, preferring fx's namespaced variable and falling
/// back to the skill's conventional `TYPESAFE_KEY`. Only the direct transport
/// reads this; it is never used for Gateway or inference.
pub fn typesafeApiKey() ?[]const u8 {
    if (io_mod.getenv("FX_JEV_TYPESAFE_API_KEY")) |key| {
        if (key.len != 0) return key;
    }
    if (io_mod.getenv("TYPESAFE_KEY")) |key| {
        if (key.len != 0) return key;
    }
    return null;
}

pub const Request = struct {
    payload: []const u8,
    api_key: []const u8,
    team: ?[]const u8 = null,
    cancel_flag: *std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp = null,
    transport: Transport = .gateway,
};

pub const Response = struct {
    body: []u8,
    pub fn deinit(self: *Response, alloc: std.mem.Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

pub const EvaluateFn = *const fn (?*anyopaque, std.mem.Allocator, Request) anyerror!Response;

/// Distinct rejection classes a caller can record without exposing provider
/// error bodies. Status codes are intentionally not carried: the class is the
/// stable, redaction-safe telemetry unit.
pub const RejectionError = error{
    EvaluationUnauthorized,
    EvaluationForbidden,
    EvaluationRejected,
    EvaluationRateLimited,
    EvaluationServerError,
};

/// Failure taxonomy recorded by routing telemetry. Transport and rejection are
/// separate so a policy denial is never reported as evaluator uncertainty.
pub const Failure = enum {
    policy_rejected,
    rate_limited,
    server_error,
    transport_timeout,
    transport_error,
};

/// Maps a provider or transport error to a telemetry failure class. Returns
/// null for control-flow errors (cancellation, allocation) that callers must
/// propagate unchanged.
pub fn classifyFailure(err: anyerror) ?Failure {
    return switch (err) {
        error.EvaluationUnauthorized, error.EvaluationForbidden, error.EvaluationRejected => .policy_rejected,
        error.EvaluationRateLimited => .rate_limited,
        error.EvaluationServerError => .server_error,
        error.Timeout => .transport_timeout,
        error.Cancelled, error.OutOfMemory => null,
        else => .transport_error,
    };
}

test "evaluation failures separate policy rejection, transport and control flow" {
    try std.testing.expectEqual(Failure.policy_rejected, classifyFailure(error.EvaluationForbidden).?);
    try std.testing.expectEqual(Failure.policy_rejected, classifyFailure(error.EvaluationRejected).?);
    try std.testing.expectEqual(Failure.rate_limited, classifyFailure(error.EvaluationRateLimited).?);
    try std.testing.expectEqual(Failure.server_error, classifyFailure(error.EvaluationServerError).?);
    try std.testing.expectEqual(Failure.transport_timeout, classifyFailure(error.Timeout).?);
    try std.testing.expectEqual(Failure.transport_error, classifyFailure(error.ConnectionRefused).?);
    try std.testing.expect(classifyFailure(error.Cancelled) == null);
    try std.testing.expect(classifyFailure(error.OutOfMemory) == null);
}
