//! `am signin`, `play`, `pause`, `resume`, `stop` and `status`. The background process does the
//! work (see `daemon/play.zig`, `daemon/control.zig`, `daemon/signin.zig`); the CLI sends the
//! request and prints the reply. Only opening the user's browser happens here, in the terminal's
//! session.
const std = @import("std");
const commands = @import("../commands.zig");
const control_endpoint = @import("../daemon/control.zig");
const engine = @import("../engine.zig");
const platform = @import("../platform.zig");
const playback = @import("../playback.zig");
const remote = @import("remote.zig");

const Allocator = std.mem.Allocator;
const Context = commands.Context;
const Io = std.Io;

pub fn play(ctx: *const Context, gpa: Allocator, target: []const u8, mode: playback.Mode) !void {
    // Without a token there's nothing to check with Apple: don't start a background process just
    // to say so. The `play` endpoint checks a stored one.
    if (try ctx.userToken() == null) return ctx.fail("no Music User Token stored: run `am signin` first", .{});
    const live = Io.File.stdout().isTty(ctx.io) catch false;
    try remote.run(ctx, gpa, "play", try playBody(ctx.arena, target, mode, live));
}

/// The `play` endpoint's request (`daemon/play.zig`).
pub fn playBody(arena: Allocator, target: []const u8, mode: playback.Mode, live: bool) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .target = target,
        .seconds = if (mode == .seconds) mode.seconds else null,
        .full = mode == .full,
        .live = live,
    }, .{ .emit_null_optional_fields = false });
}

/// Without a running background process there is no warm engine, so nothing to act on.
pub fn control(ctx: *const Context, gpa: Allocator, action: control_endpoint.Action) !void {
    try remote.runIfRunning(ctx, gpa, action.endpoint(), "{}", .{
        .fail = try ctx.arena.print("nothing to {t}: the background process isn't running (am play starts it)", .{action}),
    });
}

pub fn status(ctx: *const Context, gpa: Allocator) !void {
    try remote.runIfRunning(ctx, gpa, "status", "{}", .{ .print = "nothing playing: the background process isn't running\nengine: not running\n" });
}

pub const SigninOptions = struct {
    /// Open the normal browser; else print the address.
    open: bool = true,
    openUrl: *const fn (Io, []const u8) platform.OpenUrlError!void = platform.openUrl,
};

pub fn signin(ctx: *const Context, gpa: Allocator, kind: ?engine.Kind, open: bool) !void {
    const client = try commands.connectDaemon(ctx, gpa, .{});
    if (kind == null) {
        const url = std.mem.trim(u8, try remote.capture(ctx, &client, "signin-page", "{}"), " \r\n");
        try openSigninPage(ctx, url, .{ .open = open });
    }
    try remote.runOn(ctx, &client, "signin", try std.json.Stringify.valueAlloc(ctx.arena, .{ .engine = kind }, .{}));
}

/// Opens the background process's sign-in page `url` in the user's default browser, or says
/// where it is. The page then waits for a click; the `signin` endpoint waits for its result.
pub fn openSigninPage(ctx: *const Context, url: []const u8, options: SigninOptions) !void {
    if (!options.open) {
        try ctx.out.print("Open {s} in your browser.\n", .{url});
    } else if (options.openUrl(ctx.io, url)) {
        try ctx.out.print("Opened {s} in your default browser.\n", .{url});
    } else |e| try ctx.out.print("Can't open a browser ({t}): open {s} yourself.\n", .{ e, url });
}

const testing = std.testing;

test "play sends the target, the watch mode and whether to redraw in place" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("{\"target\":\"1561837008\",\"full\":false,\"live\":true}", try playBody(a, "1561837008", .until_playing, true));
    try testing.expectEqualStrings("{\"target\":\"shy away\",\"seconds\":20,\"full\":false,\"live\":false}", try playBody(a, "shy away", .{ .seconds = 20 }, false));
    try testing.expectEqualStrings("{\"target\":\"x\",\"full\":true,\"live\":false}", try playBody(a, "x", .full, false));
}

test "play without a stored Music User Token fails before reaching for the background process" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(a);
    try environ.put("AM_CONFIG_DIR", "/nonexistent/am");
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);
    const ctx = try Context.init(testing.io, a, &environ, &out.writer, &err.writer, undefined);
    // `undefined` as the allocator: connecting would use it.
    try testing.expectError(error.Reported, play(&ctx, undefined, "1561837008", .until_playing));
    try testing.expectEqualStrings("error: no Music User Token stored: run `am signin` first\n", err.written());
}

var opened: ?[]const u8 = null;
var opened_buffer: [128]u8 = undefined;

fn fakeOpen(_: Io, url: []const u8) platform.OpenUrlError!void {
    @memcpy(opened_buffer[0..url.len], url);
    opened = opened_buffer[0..url.len];
}

fn failingOpen(_: Io, _: []const u8) platform.OpenUrlError!void {
    return error.FileNotFound;
}

test "the sign-in page opens in the default browser, or the CLI says where it is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var environ: std.process.Environ.Map = .init(a);
    try environ.put("AM_CONFIG_DIR", "/nonexistent/am");
    var out: Io.Writer.Allocating = .init(a);
    var err: Io.Writer.Allocating = .init(a);
    const ctx = try Context.init(testing.io, a, &environ, &out.writer, &err.writer, undefined);
    const url = "http://localhost:47901/?signin&engine=5555";

    opened = null;
    try openSigninPage(&ctx, url, .{ .openUrl = fakeOpen });
    try testing.expectEqualStrings(url, opened.?);
    try openSigninPage(&ctx, url, .{ .openUrl = failingOpen });
    opened = null;
    try openSigninPage(&ctx, url, .{ .open = false, .openUrl = fakeOpen });
    try testing.expectEqual(null, opened);
    try testing.expectEqualStrings(
        \\Opened http://localhost:47901/?signin&engine=5555 in your default browser.
        \\Can't open a browser (FileNotFound): open http://localhost:47901/?signin&engine=5555 yourself.
        \\Open http://localhost:47901/?signin&engine=5555 in your browser.
        \\
    , out.written());
}
