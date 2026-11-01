//! `am` (no arguments, on a terminal) and `am tui`: the full-screen player.
const std = @import("std");
const commands = @import("../commands.zig");
const daemon = @import("../daemon.zig");
const term = @import("../tui/term.zig");
const App = @import("../tui/app.zig").App;

const Allocator = std.mem.Allocator;
const Context = commands.Context;

pub fn run(ctx: *const Context, gpa: Allocator) !void {
    if (!term.isTty(ctx.io)) return ctx.fail("am tui needs a terminal: run it in one, with stdin and stdout not redirected", .{});
    const port = try ctx.daemonPort();
    try ctx.out.flush();
    try ctx.err.flush();
    const app = try App.create(.{
        .io = ctx.io,
        .gpa = gpa,
        .environ = ctx.environ,
        .config_dir = ctx.config_dir,
        .settings = &ctx.settings,
        .port = port,
    });
    defer app.destroy();
    const ran = app.run();
    // Never started: nothing to leave, and the error goes out at once.
    if (ran) |_| {} else |e| switch (e) {
        error.NotATerminal => return ctx.fail("am tui needs a terminal", .{}),
        error.AlreadyActive => return ctx.fail("the TUI is already running in this process", .{}),
        else => {},
    }
    // The terminal is restored by now: a slow background process can't freeze it. Also after
    // a session that failed: what it started shouldn't run on with nobody using it.
    if (app.leaveDaemon(daemon.client.stop_timeout)) |stop| switch (stop) {
        .stopped => {},
        // The window may be gone (SIGHUP): nowhere to warn.
        .refused => ctx.err.writeAll("warning: the background process didn't stop; am daemon stop stops it\n") catch {},
        .still_running => ctx.err.print("warning: the background process still runs after {d} s; am daemon stop stops it\n", .{
            daemon.client.stop_timeout.toSeconds(),
        }) catch {},
    };
    try ran;
}
