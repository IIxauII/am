//! `am daemon [--detach]` runs the background process in the foreground; `am daemon stop` asks a
//! running one to shut down.
const std = @import("std");
const commands = @import("../commands.zig");
const daemon = @import("../daemon.zig");

const Allocator = std.mem.Allocator;
const Context = commands.Context;

pub fn run(ctx: *const Context, gpa: Allocator, detach: bool) !void {
    try ctx.out.flush();
    daemon.run(.{
        .io = ctx.io,
        .gpa = gpa,
        .environ = ctx.environ,
        .config_dir = ctx.config_dir,
        .settings = &ctx.settings,
        .detach = detach,
        .err = ctx.err,
    }) catch return error.Reported;
}

pub fn stop(ctx: *const Context, gpa: Allocator) !void {
    const client = commands.connectDaemon(ctx, gpa, .{ .start = false }) catch |e| switch (e) {
        error.NotRunning => {
            try ctx.out.writeAll("am daemon is not running\n");
            return;
        },
        else => |other| return other,
    };
    const timeout = daemon.client.stop_timeout;
    switch (client.stopAndWait(ctx.arena, ctx.out, ctx.err, timeout) catch |e|
        return ctx.fail("can't reach the background process: {t}", .{e})) {
        .stopped => try ctx.out.writeAll("am daemon stopped\n"),
        .refused => return error.Reported,
        .still_running => return ctx.fail("the background process is still running after {d} s", .{timeout.toSeconds()}),
    }
}
