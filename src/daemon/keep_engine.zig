//! The `keep-engine` endpoint: keep-alive's side in the background process. A TUI with
//! keep-alive on holds one open, naming its session as its other requests do. While it is open
//! and its client is there, the daemon counts it as engine use (`Requests.keepers`), so the idle
//! close can't fire; once the last one closes, the idle rules restart from then.
//!
//! On open it launches the engine and waits for its page, as `am doctor` does, but prints
//! nothing and repairs nothing. It never launches again: an engine that fails to start, exits on
//! its own or is closed by `am signin --engine` stays down until the next play launches it.
const std = @import("std");
const host_mod = @import("host.zig");
const protocol = @import("protocol.zig");

const Host = host_mod.Host;
const Io = std.Io;
const Reply = protocol.Reply;

pub const Options = struct {
    /// How often it looks whether its client went (`Reply.client_gone`).
    step: Io.Duration = .fromSeconds(1),
    /// An empty data line at least this often, so a client that went away is noticed where the
    /// server can't tell (`client_gone` null): the write fails.
    heartbeat: Io.Duration = .fromSeconds(15),
};

/// Runs until its client goes or the daemon stops (`error.Canceled`).
pub fn run(host: Host, io: Io, r: *Reply, options: Options) Reply.Error!void {
    var problem: []const u8 = "";
    // Silent and not retried: the next play reports any error.
    if (host.page.start(r.arena, &problem)) |_| {} else |e| switch (e) {
        error.EngineFailed => host.log("keep-alive: the engine didn't start: {s}", .{problem}),
        error.OutOfMemory, error.Canceled => |x| return x,
    }
    var beat: Io.Clock.Timestamp = .now(io, .awake);
    while (!r.clientGone()) {
        try io.sleep(options.step, .awake);
        if (beat.untilNow(io).raw.nanoseconds >= options.heartbeat.nanoseconds) {
            try r.data("{}");
            beat = .now(io, .awake);
        }
    }
}

const testing = std.testing;
const fake = @import("fake_page.zig");
const playback = @import("../playback.zig");
const Deadline = @import("../deadline.zig").Deadline;
const PageHost = fake.PageHost;
const Rig = fake.Rig;

/// Every wait shortened, as the rig's.
const quick: Options = .{ .step = .fromMilliseconds(5) };

/// A keep-engine request held open on a task, as the server runs one for a TUI: its client is
/// there until `close`.
const Held = struct {
    ph: *PageHost,
    t: protocol.TestReply,
    gone: std.atomic.Value(bool) = .init(false),
    ended: std.atomic.Value(bool) = .init(false),
    task: Io.Future(Reply.Error!void) = undefined,

    fn open(h: *Held, ph: *PageHost) !void {
        h.* = .{ .ph = ph, .t = undefined };
        h.t.init(ph.rig.newArena());
        h.t.reply.client_gone = &h.gone;
        h.task = try testing.io.concurrent(runThenMark, .{h});
    }

    fn runThenMark(h: *Held) Reply.Error!void {
        defer h.ended.store(true, .release);
        return run(h.ph.host(), testing.io, &h.t.reply, quick);
    }

    fn isOpen(h: *const Held) bool {
        return !h.ended.load(.acquire);
    }

    /// Its client goes: what the request printed, once it ended.
    fn close(h: *Held) !protocol.TestReply.Printed {
        h.gone.store(true, .release);
        return h.t.finish(h.task.await(testing.io));
    }

    /// The daemon stops (`Q`, `am daemon stop`), which cancels every request.
    fn shutDown(h: *Held) !protocol.TestReply.Printed {
        return h.t.finish(h.task.cancel(testing.io));
    }
};

/// Many of the request's steps, for it to end, launch or call the page on its own if it would.
fn manySteps() !void {
    try testing.io.sleep(.fromMilliseconds(100), .awake);
}

/// Waits until the engine's page is connected and MusicKit configured; fails after 2 s.
fn pageReady(rig: *Rig) !void {
    const a = rig.newArena();
    const deadline: Deadline = .after(rig.io, .fromSeconds(2));
    var seen = try rig.channel.waitChange(null, .zero);
    while (true) {
        if (rig.channel.connected()) if (try rig.channel.lastReport(a)) |last| if (playback.parseReport(a, last.json)) |report|
            if (report.configureDone()) return;
        if (deadline.passed()) return error.NeverReady;
        seen = try rig.channel.waitChange(seen, .fromMilliseconds(20));
    }
}

/// Waits until the daemon's log has `line`; fails after 2 s.
fn logged(ph: *PageHost, line: []const u8) !void {
    const deadline: Deadline = .after(ph.rig.io, .fromSeconds(2));
    while (!ph.hasLogged(line)) {
        if (deadline.passed()) return error.NeverLogged;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "keep-engine launches the engine, printing nothing and repairing nothing, and stays open until its client goes" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    var held: Held = undefined;
    try held.open(&ph);
    try pageReady(&rig);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    try manySteps();
    try testing.expect(held.isOpen());
    const printed = try held.close();
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("", printed.out);
    // Not even a look at the page: no repair.
    try testing.expectEqual(@as(usize, 0), rig.fp.callCount());
    try testing.expectEqual(@as(usize, 0), ph.logLines().len);
}

test "a keep-engine whose engine doesn't start stays open, prints nothing, and doesn't try again" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.launcher.refuse = "firefox not found; install it or set FIREFOX_PATH";
    var held: Held = undefined;
    try held.open(&ph);
    // Only the daemon's log says why.
    try logged(&ph, "keep-alive: the engine didn't start: firefox not found; install it or set FIREFOX_PATH");
    // A launch would work now: none is tried.
    {
        rig.launcher.mutex.lockUncancelable(rig.io);
        defer rig.launcher.mutex.unlock(rig.io);
        rig.launcher.refuse = null;
    }
    try manySteps();
    try testing.expect(held.isOpen());
    try testing.expectEqual(@as(u32, 0), rig.launcher.launches);
    const printed = try held.close();
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("", printed.out);
}

test "keep-engine holds an engine already running as it is and launches none after it exits on its own; the next play does, and the request ends with the daemon" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    // A CLI play started it.
    try ph.warm();
    const load = rig.fp.current();
    var held: Held = undefined;
    try held.open(&ph);
    try manySteps();
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    try testing.expectEqualStrings(load, rig.fp.current());
    try testing.expectEqual(@as(usize, 0), rig.fp.callCount());

    // It exits on its own (or `am signin --engine` closes it): the supervisor stops it.
    rig.launcher.stop();
    try manySteps();
    try testing.expect(held.isOpen());
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    // The next play launches it.
    try ph.warm();
    try testing.expectEqual(@as(u32, 2), rig.launcher.launches);

    const printed = try held.shutDown();
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("error: the background process shut down\n", printed.err);
    try testing.expectEqualStrings("", printed.out);
}

test "where the server can't tell its client went, keep-engine notices at its next heartbeat" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try ph.warm();
    var gone: Io.Writer = .failing;
    var r: Reply = .{ .arena = rig.newArena(), .out = &gone, .flushFn = noFlush, .flush_ctx = &gone };
    try testing.expectError(error.WriteFailed, run(ph.host(), testing.io, &r, .{ .step = .fromMilliseconds(5), .heartbeat = .fromMilliseconds(20) }));
}

fn noFlush(_: *anyopaque) Io.Writer.Error!void {}
