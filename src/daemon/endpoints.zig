//! The CLI's endpoints on the background process: `POST /cli/<name>`, answered as a stream of
//! lines for the CLI to print (see `protocol.zig`).
//!
//! To add a command:
//! 1. write `fn (d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void` below, printing
//!    with `r.print` and failing with `r.fail`; `body` is the JSON the CLI sent;
//! 2. list it in `all`, with `.uses_engine = true` if it uses the engine (the idle close then
//!    waits for it), or `.keeps_engine = true` if it only holds the engine open (keep-alive);
//! 3. in `main.zig`, run it with `commands.remote.run(ctx, gpa, "<name>", body)`.
const std = @import("std");
const daemon = @import("../daemon.zig");
const control = @import("control.zig");
const doctor = @import("doctor.zig");
const keep_engine = @import("keep_engine.zig");
const play = @import("play.zig");
const player = @import("player.zig");
const protocol = @import("protocol.zig");
const signin = @import("signin.zig");

const Daemon = daemon.Daemon;
const Reply = protocol.Reply;

pub const Endpoint = struct {
    /// The `<name>` in `/cli/<name>`.
    name: []const u8,
    /// Counts as engine activity for as long as it runs, so the idle close never interrupts it.
    uses_engine: bool = false,
    /// Carries on when its client goes away, and keeps the daemon meanwhile (see
    /// `Reply.outlives_client`): a TUI killed right after Enter, and the music still starts. A
    /// TUI that quits with q stops its own queue first, while nothing is audible from it yet
    /// (`Daemon.stopIfUnused`, #55).
    outlives_client: bool = false,
    /// Holds the engine open while its client is there, so the idle close waits (keep-alive).
    /// Unlike `uses_engine`, nothing it asks of the engine is on its way: `stop-if-unused`
    /// doesn't wait for it, and doesn't count the quitting TUI's own.
    keeps_engine: bool = false,
    run: *const fn (d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void,
};

pub const all = [_]Endpoint{
    // Answers once the daemon is up; the CLI's auto-start waits for it.
    .{ .name = "ping", .run = ping },
    .{ .name = "stop", .run = stop },
    // The TUI's q: stop unless something else uses the daemon.
    .{ .name = "stop-if-unused", .run = stopIfUnused },
    .{ .name = "doctor", .uses_engine = true, .run = runDoctor },
    .{ .name = "play", .uses_engine = true, .run = runPlay },
    controlEndpoint(.pause),
    controlEndpoint(.@"resume"),
    controlEndpoint(.stop),
    // Only reads: a look at the status doesn't keep an idle engine open.
    .{ .name = "status", .run = runStatus },
    .{ .name = "signin-page", .run = runSigninPage },
    // Keeps a sign-in window open while it waits.
    .{ .name = "signin", .uses_engine = true, .run = runSignin },
    // The TUI's (see `player.zig`). Looking, or watching for hours, doesn't keep an idle engine open.
    .{ .name = "state", .run = runState },
    .{ .name = "watch", .run = runWatch },
    .{ .name = "queue", .uses_engine = true, .outlives_client = true, .run = runQueue },
    .{ .name = "control", .uses_engine = true, .run = runControl },
    .{ .name = "queue-items", .run = runQueueItems },
    // Keep-alive: the TUI holds it open while the setting is on.
    .{ .name = "keep-engine", .keeps_engine = true, .run = runKeepEngine },
};

pub fn find(name: []const u8) ?*const Endpoint {
    for (&all) |*e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

/// Answers with the build id: `{"build":"<16 hex digits>"}`.
fn ping(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    try r.data(try r.arena.print("{{\"build\":{f}}}", .{std.json.fmt(d.build_id, .{})}));
}

fn runState(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    return player.state(d.playbackHost(), r);
}

fn runWatch(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    return player.watch(d.playbackHost(), d.io, r, .{});
}

fn runQueue(d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void {
    const request = try parseBody(player.QueueRequest, r, body);
    return player.queue(d.playbackHost(), d.io, r, request, .{});
}

fn runControl(d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void {
    const request = try parseBody(player.ControlRequest, r, body);
    return player.control(d.playbackHost(), r, request);
}

fn runQueueItems(d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void {
    const request = try parseBody(player.ItemsRequest, r, body);
    return player.queueItems(d.playbackHost(), r, request);
}

fn runKeepEngine(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    return keep_engine.run(d.playbackHost(), d.io, r, .{});
}

/// The daemon shuts down once the reply is sent; `am daemon stop` waits for the port to close.
fn stop(d: *Daemon, _: *Reply, _: []const u8) Reply.Error!void {
    d.requestStop("am daemon stop");
}

/// Shuts down as `stop` does unless something besides the asking TUI uses the daemon (see
/// `Daemon.stopIfUnused`). Answers `{"kept":"<why>"}`, or `{"kept":null}` when it stops.
fn stopIfUnused(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    const asker: *const daemon.Requests.Ticket = @ptrCast(@alignCast(r.request.?));
    if (try d.stopIfUnused(r.arena, asker)) |why| {
        try r.print("kept: {s}\n", .{why});
        return r.data(try r.arena.print("{{\"kept\":{f}}}", .{std.json.fmt(why, .{})}));
    }
    try r.print("stopping\n", .{});
    try r.data("{\"kept\":null}");
}

fn runDoctor(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    const h = d.playbackHost();
    try play.warnIfLowMemory(h, r);
    return doctor.run(h, r);
}

fn runPlay(d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void {
    const request = try parseBody(play.Request, r, body);
    return play.run(d.playbackHost(), d.io, r, request, .{});
}

fn controlEndpoint(comptime action: control.Action) Endpoint {
    return .{ .name = action.endpoint(), .uses_engine = true, .run = struct {
        fn run(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
            return control.control(d.playbackHost(), r, action);
        }
    }.run };
}

fn runStatus(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    return control.status(d.playbackHost(), r);
}

fn runSignin(d: *Daemon, r: *Reply, body: []const u8) Reply.Error!void {
    const request = try parseBody(signin.Request, r, body);
    _ = d.signins_waiting.fetchAdd(1, .monotonic);
    defer _ = d.signins_waiting.fetchSub(1, .monotonic);
    return signin.run(d.playbackHost(), d.io, r, request, .{});
}

fn runSigninPage(d: *Daemon, r: *Reply, _: []const u8) Reply.Error!void {
    return signin.newPage(d.playbackHost(), r);
}

fn parseBody(comptime T: type, r: *Reply, body: []const u8) Reply.Error!T {
    return std.json.parseFromSliceLeaky(T, r.arena, body, .{ .ignore_unknown_fields = true }) catch
        r.fail("the CLI sent an unexpected request: {s}", .{body});
}

test "endpoint names are unique" {
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
    try std.testing.expect(find("doctor").?.uses_engine);
    // It holds the engine, but asks nothing of it that `stop-if-unused` would wait for.
    try std.testing.expect(find("keep-engine").?.keeps_engine);
    try std.testing.expect(!find("keep-engine").?.uses_engine);
    try std.testing.expectEqual(null, find("call"));
}
