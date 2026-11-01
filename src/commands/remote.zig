//! CLI commands that the background process runs (`am doctor`, the playback commands): the CLI
//! only sends the request and prints what comes back. The endpoints are in
//! `daemon/endpoints.zig`.
const std = @import("std");
const commands = @import("../commands.zig");
const daemon = @import("../daemon.zig");

const Allocator = std.mem.Allocator;
const Context = commands.Context;

/// Runs `endpoint` with the JSON `body`, starting the background process if needed.
pub fn run(ctx: *const Context, gpa: Allocator, endpoint: []const u8, body: []const u8) !void {
    const client = try commands.connectDaemon(ctx, gpa, .{});
    try runOn(ctx, &client, endpoint, body);
}

/// What a command that needs a running background process does without one.
pub const NotRunning = union(enum) {
    /// Prints this and succeeds.
    print: []const u8,
    /// Fails with this message.
    fail: []const u8,
};

/// Runs `endpoint` only if a background process is running; never starts one.
pub fn runIfRunning(ctx: *const Context, gpa: Allocator, endpoint: []const u8, body: []const u8, not_running: NotRunning) !void {
    const client = commands.connectDaemon(ctx, gpa, .{ .start = false }) catch |e| switch (e) {
        error.NotRunning => switch (not_running) {
            .print => |text| return ctx.out.writeAll(text),
            .fail => |message| return ctx.fail("{s}", .{message}),
        },
        else => |other| return other,
    };
    try runOn(ctx, &client, endpoint, body);
}

/// Runs `endpoint` and returns what it prints instead of printing it.
pub fn capture(ctx: *const Context, client: *const daemon.client.Client, endpoint: []const u8, body: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    const code = client.run(ctx.arena, endpoint, body, &out.writer, ctx.err) catch |e|
        return ctx.fail("lost the background process during {s}: {t}", .{ endpoint, e });
    if (code != 0) return error.Reported;
    return out.written();
}

/// Runs `endpoint` on a background process that is already connected.
pub fn runOn(ctx: *const Context, client: *const daemon.client.Client, endpoint: []const u8, body: []const u8) !void {
    try ctx.out.flush();
    const code = client.run(ctx.arena, endpoint, body, ctx.out, ctx.err) catch |e|
        return ctx.fail("lost the background process during {s}: {t}", .{ endpoint, e });
    if (code != 0) return error.Reported;
}
