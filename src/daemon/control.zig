//! The `pause`, `resume`, `stop` and `status` endpoints: the engine's current playback. The CLI
//! runs them only against a background process that is already running.
const std = @import("std");
const host_mod = @import("host.zig");
const play = @import("play.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Host = host_mod.Host;
const Play = host_mod.Plays.Play;
const Io = std.Io;
const Reply = protocol.Reply;

/// `am pause`, `am resume`, `am stop`: the page method of the same name, behind this endpoint.
pub const Action = enum {
    pause,
    @"resume",
    stop,

    /// `stop` alone is `am daemon stop`'s.
    pub fn endpoint(a: Action) []const u8 {
        return switch (a) {
            .pause => "pause",
            .@"resume" => "resume",
            .stop => "stop-playback",
        };
    }
};

pub fn control(host: Host, r: *Reply, action: Action) Reply.Error!void {
    if (action == .stop) return stopCommand(host, r);
    const a = r.arena;
    // A resume can be a load (stopped live radio is queued again): a play, for a stop to cancel.
    var resuming: ?Play = if (action == .@"resume") host.plays.begin() else null;
    defer if (resuming) |*p| p.end();
    const state = try host.state(a);
    const engine = state.engine orelse return r.fail("nothing to {t}: the engine isn't running", .{action});
    if (engine.signin_window) return r.fail("nothing to {t}: the engine isn't running (a sign-in window is open)", .{action});
    // A resume looks at, and calls, the new page load, not a reload's gap. It never repairs. A
    // launch since its wait (a relaunch) leaves its look or its call no page: it then waits for
    // that launch's page and starts over on it, once.
    var cp: ?play.ControlPlay = if (resuming) |*p| .{ .play = p, .waited_on = engine.pid } else null;
    while (true) {
        if (resuming) |*p| {
            try host.page.waitOutInFlight(r, p);
            if (p.cancelled()) return r.print("{s}\n", .{play.stopped_before_start});
        }
        // A pause during a reload stops, as `stop` does then, without waiting on the page.
        if (action == .pause and try host.page.reloadInFlight(a)) return replyDuringReload(r, action, cancelForReload(host, host.plays.beginStop()));
        // Straight from the page: the last report can be a second old, from before a `stop`.
        const before = try snapshot(host, r) orelse {
            if (cp) |*c| if (try c.again(host, a, null)) continue;
            return r.fail("nothing to {t}: the engine page didn't answer", .{action});
        };
        // MusicKit drops stopped live radio; the page's resume queues the station again.
        const station = if (action == .@"resume" and before.nowPlaying == null) before.stoppedLive else null;
        if (before.nowPlaying == null and station == null) {
            if (action == .pause) switch (before.music()) {
                .playing, .starting => return pauseUnnamed(host, r, before),
                .none, .paused, .stopped_live => {},
            };
            return r.fail("nothing to {t}: " ++ nothing_loaded, .{action});
        }

        const args = if (resuming) |p| try std.json.Stringify.valueAlloc(a, .{p.generation}, .{}) else "[]";
        if (resuming) |*p| if (!p.send()) return r.print("{s}\n", .{play.stopped_before_start});
        const timeout: Io.Duration = .fromSeconds(10);
        const result = host.call(a, @tagName(action), args, timeout) catch |e| switch (e) {
            error.NoEnginePage, error.Disconnected => {
                if (cp) |*c| if (try c.again(host, a, e)) continue;
                return play.failPageCall(r, e, @tagName(action), timeout);
            },
            else => return play.failPageCall(r, e, @tagName(action), timeout),
        };
        if (resuming) |*p| p.end();
        switch (result) {
            .ok => {},
            .page_error => |message| if (std.mem.eql(u8, message, play.stopped_before_start))
                return r.print("{s}\n", .{play.stopped_before_start})
            else
                return r.fail("the engine page didn't {t}: {s}", .{ action, message }),
        }
        // Done either way; without an answer the line shows the state from before.
        const fresh = try snapshot(host, r);
        const after = fresh orelse before;
        if (after.nowPlaying orelse before.nowPlaying) |item|
            try printItem(r, after, item)
        else if (station) |s|
            // Its stream still loads: MusicKit names no item yet.
            try r.print("restarting live radio: {s}\n", .{s.name orelse s.id});
        // A pending play() can start the music after the page's answer.
        if (action == .pause) if (fresh) |f| if (f.music().plays())
            return r.fail("the music still plays after {t}", .{action});
        return;
    }
}

const nothing_loaded = "nothing is loaded in the engine (am play loads a song)";

/// `am stop`.
fn stopCommand(host: Host, r: *Reply) Reply.Error!void {
    const stopped = switch (try stop(host, r, .{ .look_first = true })) {
        .stopped => |s| s,
        .nothing => |why| return r.fail("nothing to stop: {s}", .{whyNothing(why)}),
    };
    try reportStop(host, r, .stop, stopped, "stopped; the engine stays warm until its idle timeout");
}

/// `am pause` on music that plays or is starting before MusicKit names an item (live radio
/// restarting, a song loading): there is no item to pause, so it stops as `am stop` would. A
/// song still starting is near 0:00 anyway, and `am resume` restarts stopped live radio.
/// `before` is the look the pause has just taken.
fn pauseUnnamed(host: Host, r: *Reply, before: playback.Report) Reply.Error!void {
    var stopped = switch (try stop(host, r, .{ .look_first = false })) {
        .stopped => |s| s,
        // The engine or its page went away since the look.
        .nothing => |why| return r.fail("nothing to pause: {s}", .{whyNothing(switch (why) {
            .no_engine => .no_engine,
            .signin_window => .signin_window,
            .no_page => .no_page,
        })}),
    };
    stopped.before = before;
    try reportStop(host, r, .pause, stopped, "stopped, not paused: MusicKit had no item to pause yet; the engine stays warm until its idle timeout");
}

/// Why there is nothing to stop or pause, in the words after "nothing to stop: ".
fn whyNothing(why: Nothing(.{ .look_first = true })) []const u8 {
    return switch (why) {
        .no_engine => "the engine isn't running",
        .signin_window => "the engine isn't running (a sign-in window is open)",
        .no_page => "no engine page is connected",
        .nothing_loaded => nothing_loaded,
    };
}

/// What a stop for `action` (`am stop`, or `am pause` that stops) did: the item it stopped, a
/// queue that won't start, then `done`. Fails when music plays by the next look
/// (`Music.plays`). During a reload in flight (`Stopped.reloading`) the page wasn't asked:
/// it answers with `replyDuringReload` instead.
fn reportStop(host: Host, r: *Reply, action: Action, stopped: Stopped, done: []const u8) Reply.Error!void {
    if (stopped.reloading) return replyDuringReload(r, action, stopped);
    // No page to ask: the plays on their way were all there was to stop.
    const answer = stopped.answer orelse return r.print(wont_start ++ "\n", .{});
    // A page that didn't answer the first look but stopped: its answer is the state from before.
    const before = stopped.before orelse playback.parseReport(r.arena, answer);
    // Done either way; without an answer the line shows the state from before.
    const fresh = try snapshot(host, r);
    const after = fresh orelse before;
    // MusicKit may drop the item on stop; the line still names what was loaded.
    const item = (if (after) |x| x.nowPlaying else null) orelse (if (before) |b| b.nowPlaying else null);
    if (item) |np|
        try printItem(r, after.?, np)
    else if (stopped.cancelled)
        try r.print(wont_start ++ "\n", .{});
    // A pending play() can start the music after the page's answer.
    if (fresh) |f| if (f.music().plays()) return r.fail("the music still plays after {t}", .{action});
    try r.print("{s}\n", .{done});
}

fn printItem(r: *Reply, report: playback.Report, item: playback.NowPlaying) Reply.Error!void {
    var line: Io.Writer.Allocating = .init(r.arena);
    try playback.writeNowPlaying(&line.writer, report, item);
    try r.print("{s}\n", .{line.written()});
}

const wont_start = "the queue that was loading won't start";

/// A stop or pause during a reload (`cancelForReload`): it stopped the plays on their way, or
/// there was nothing to stop.
fn replyDuringReload(r: *Reply, action: Action, stopped: Stopped) Reply.Error!void {
    if (!stopped.cancelled) return r.fail("nothing to {t}: the engine page is reloading", .{action});
    try r.print("the engine page is reloading; stopped what was on its way\n", .{});
}

/// Why a stop found nothing to stop. Only a stop that looks first can find nothing loaded.
pub fn Nothing(comptime options: StopOptions) type {
    return if (options.look_first)
        enum { no_engine, signin_window, no_page, nothing_loaded }
    else
        enum { no_engine, signin_window, no_page };
}

pub const Stopped = struct {
    /// The page's state before the stop, when the stop looked first and the page answered.
    before: ?playback.Report = null,
    /// The page's answer to its stop: a snapshot. Null when there was no page to ask (no
    /// engine, no page connected, or a reload in flight), and the plays on their way were all
    /// there was to stop.
    answer: ?[]const u8 = null,
    /// A reload was in flight: the page wasn't asked (`cancelForReload`).
    reloading: bool = false,
    /// A play that began before the stop won't start: it was on its way here, or loading in
    /// the page.
    cancelled: bool,
};

pub fn StopOutcome(comptime options: StopOptions) type {
    return union(enum) {
        stopped: Stopped,
        nothing: Nothing(options),
    };
}

pub const StopOptions = struct {
    /// Ask the page for its state first: `am stop` names what it stopped, and says when there
    /// is nothing. The TUI, and `am pause` that has looked already, go straight to the page's
    /// stop, so their `Nothing` has no `nothing_loaded`.
    look_first: bool,
};

/// The stop behind `am stop`, the TUI's, and `am pause` on music MusicKit hasn't named yet
/// (`pauseUnnamed`): stops what the page plays, and, once that succeeded, cancels every play
/// that began before it (`Plays`), wherever it is on its way.
/// With no engine or no page connected, the plays on their way are what it stops, if none has
/// sent its page call yet; one that has can only be stopped by the page, so the stop asks it all
/// the same. A connected page that doesn't answer the first look still gets the stop: the music
/// may be playing. A stop the page fails or doesn't answer ends the request with the reason and
/// cancels nothing. A page whose MusicKit isn't configured yet (a cold engine) has started
/// nothing and answers as stopped (app.js `stop`). During a reload the page isn't asked at all
/// (`cancelForReload`), so a stop never waits on a reload.
pub fn stop(host: Host, r: *Reply, comptime options: StopOptions) Reply.Error!StopOutcome(options) {
    const a = r.arena;
    const s = host.plays.beginStop();
    const state = try host.state(a);
    // No engine: no page call can play either.
    const engine = state.engine orelse return cancelOnly(options, host, s, .no_engine);
    if (engine.signin_window) return cancelOnly(options, host, s, .signin_window);
    if (try host.page.reloadInFlight(a)) return .{ .stopped = cancelForReload(host, s) };
    var before: ?playback.Report = null;
    if (options.look_first) {
        // Straight from the page: the last report can be a second old, from before a `stop`.
        switch (try host.look(a, .fromSeconds(5))) {
            .report => |json| before = playback.parseReport(a, json),
            .no_page => if (withoutPage(options, host, s)) |outcome| return outcome,
            // A busy page, or one reconnecting, may still play: the page's stop decides.
            .no_answer => {},
        }
        if (before) |b| if (!s.older_pending) switch (b.music()) {
            // Stopped live radio is already stopped: MusicKit dropped it, and `resume` restarts it.
            .none, .stopped_live => return .{ .nothing = .nothing_loaded },
            .playing, .starting, .paused => {},
        };
    }
    const args = try std.json.Stringify.valueAlloc(a, .{s.generation}, .{});
    const timeout: Io.Duration = .fromSeconds(10);
    const result = host.call(a, "stop", args, timeout) catch |e| {
        if (e == error.NoEnginePage) if (withoutPage(options, host, s)) |outcome| return outcome;
        return play.failPageCall(r, e, "stop", timeout);
    };
    const answer = switch (result) {
        .ok => |json| json,
        .page_error => |message| return r.fail("the engine page didn't stop: {s}", .{message}),
    };
    host.plays.cancel(s);
    // The page counts the loads it had in flight that this stop cancelled.
    const PageStop = struct { cancelled: u32 = 0 };
    const page = std.json.parseFromSliceLeaky(PageStop, a, answer, .{ .ignore_unknown_fields = true }) catch PageStop{};
    return .{ .stopped = .{ .before = before, .answer = answer, .cancelled = s.older_pending or page.cancelled > 0 } };
}

/// What `stopStarting` found and did.
pub const StopStartingOutcome = union(enum) {
    /// No play of the quitting TUI's own was starting: nothing on its way, and the page not
    /// starting a song; or music is playing, which stays.
    nothing,
    /// One was, and is stopped: no music will start from it.
    stopped,
    /// One was, and couldn't be stopped: why (in the arena).
    failed: []const u8,
};

/// For the TUI's q (`stop-if-unused`), once nothing else uses the daemon: a play on its way,
/// or a song the page is starting, is the quitting TUI's own, sent a moment before q (Space on
/// a cold engine, Enter), and nothing is audible from it yet. Stops it as the TUI's stop would
/// (`stop`), so no song starts once the TUI is gone (#55). `fresh` is the page's state now
/// (null when it didn't answer: then its last report counts). Music that plays is heard and
/// stays, a play of the TUI's own on its way to replace it included: that one plays on.
pub fn stopStarting(host: Host, arena: Allocator, fresh: ?playback.Report) (Allocator.Error || Io.Cancelable)!StopStartingOutcome {
    const report = fresh orelse blk: {
        const json = (try host.state(arena)).report orelse break :blk null;
        break :blk playback.parseReport(arena, json);
    };
    const music: playback.Music = if (report) |r| r.music() else .none;
    if (music == .playing) return .nothing;
    if (music != .starting and host.plays.onTheirWay() == 0) return .nothing;
    // Nobody reads the stop's lines: the TUI that would is quitting.
    var discard: Io.Writer.Discarding = .init(&.{});
    var r: Reply = .discarding(arena, &discard);
    const outcome = stop(host, &r, .{ .look_first = false }) catch |e| switch (e) {
        error.Failed => return .{ .failed = try arena.print("a song is starting and couldn't be stopped: {s}", .{r.failure.?}) },
        error.WriteFailed => unreachable, // Nothing is written.
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
    };
    return switch (outcome) {
        .stopped => .stopped,
        // Over before the stop got to it: the play ended, or the engine closed under it.
        .nothing => .nothing,
    };
}

/// No engine: the stop succeeds if plays were on its way, which it cancels.
fn cancelOnly(comptime options: StopOptions, host: Host, s: host_mod.Plays.Stop, why: Nothing(options)) StopOutcome(options) {
    if (!s.older_pending) return .{ .nothing = why };
    host.plays.cancel(s);
    return .{ .stopped = .{ .cancelled = true } };
}

/// A reload is in flight: it drops the old page load's music, so the plays on their way are all
/// there is to stop. Cancels every one that began before `s`, its page call sent or not, without
/// asking the page, whose stream may be the old load's, dead and not yet noticed.
fn cancelForReload(host: Host, s: host_mod.Plays.Stop) Stopped {
    host.plays.cancel(s);
    return .{ .reloading = true, .cancelled = s.older_pending };
}

/// No page connected: cancels the plays on their way if none has sent its page call. Null when
/// one has: only the page can stop it.
fn withoutPage(comptime options: StopOptions, host: Host, s: host_mod.Plays.Stop) ?StopOutcome(options) {
    return switch (host.plays.cancelUnsent(s)) {
        .none => .{ .nothing = .no_page },
        .cancelled => .{ .stopped = .{ .cancelled = true } },
        .in_flight => null,
    };
}

/// The page's state now; null when it doesn't answer with one.
fn snapshot(host: Host, r: *Reply) (Allocator.Error || Io.Cancelable)!?playback.Report {
    const json = try host.snapshot(r.arena, .fromSeconds(5)) orelse return null;
    return playback.parseReport(r.arena, json);
}

pub fn status(host: Host, r: *Reply) Reply.Error!void {
    const a = r.arena;
    const state = try host.state(a);
    const report = playback.parseReport(a, state.report);

    if (state.engine == null) {
        try r.print("nothing playing: the engine isn't running\n", .{});
    } else if (state.engine.?.signin_window) {
        try r.print("nothing playing: a sign-in window is open\n", .{});
    } else if (report) |rep| {
        if (rep.nowPlaying) |np| {
            var line: Io.Writer.Allocating = .init(a);
            try playback.writeNowPlaying(&line.writer, rep, np);
            try r.print("{s}  ({s})\n", .{ line.written(), rep.playbackState orelse "?" });
        } else try r.print("nothing loaded ({s})\n", .{rep.playbackState orelse "no state"});
        if (state.report_age_ms > playback.stale_after_ms)
            try r.print("stale: the engine page hasn't reported for {d} s, so this may be out of date\n", .{state.report_age_ms / 1000});
    } else try r.print("nothing playing: the engine page hasn't reported yet\n", .{});

    if (state.engine) |e| {
        const what = if (e.signin_window) " sign-in window" else if (e.headless) " (headless)" else "";
        // As the engine's idle close counts it (`Daemon.superviseEngine`); playing wins.
        const playing = if (report) |rep| rep.music().keepsEngineOpen() else false;
        if (playing)
            try r.print("engine: {s}{s}, pid {d}; stays open while playing\n", .{ e.kind, what, e.pid })
        else if (e.keep_engine_requests > 0)
            try r.print("engine: {s}{s}, pid {d}; kept open by keep-alive while a TUI is open\n", .{ e.kind, what, e.pid })
        else
            try r.print("engine: {s}{s}, pid {d}; closes in {f} unless something plays\n", .{ e.kind, what, e.pid, playback.Time{ .seconds = @floatFromInt(e.idle_close_in_s) } });
    } else try r.print("engine: not running\n", .{});

    const f = try host.footprints(a);
    try r.print("background process: pid {d}, {f}\n", .{ f.daemon_pid, f.daemon });
    if (state.engine != null) {
        if (f.engine) |e| try r.print("engine footprint: {f}\n", .{e}) else try r.print("engine footprint: can't measure: {s}\n", .{f.engine_error orelse "unknown"});
    }
}

const testing = std.testing;
const fake = @import("fake_page.zig");
const PageHost = fake.PageHost;
const Rig = fake.Rig;

fn runControl(ph: *PageHost, action: ?Action) !protocol.TestReply.Printed {
    var t: protocol.TestReply = undefined;
    t.init(ph.rig.newArena());
    return t.finish(if (action) |act| control(ph.host(), &t.reply, act) else status(ph.host(), &t.reply));
}

/// The engine runs, and its page holds `holding`.
fn holds(ph: *PageHost, holding: fake.FakePage.Holding) !void {
    try ph.warm();
    ph.rig.fp.setHolding(holding);
    try ph.rig.fp.reportNow();
}

const shy_away_at = struct {
    fn playing(position: f64) fake.FakePage.Holding {
        return .{ .music = .playing, .position = position };
    }
    fn paused(position: f64) fake.FakePage.Holding {
        return .{ .music = .paused, .position = position };
    }
};
const station_playing: fake.FakePage.Holding = .{ .music = .playing, .item = .station };
const station_stopped: fake.FakePage.Holding = .{ .music = .stopped_live, .item = .station };

/// The held op's call never answers.
fn neverAnswers(rig: *Rig, op: fake.FakePage.Op) void {
    rig.fp.hold(op, 1);
    rig.fp.release(op, .silent);
}

/// A page that hadn't connected connects now: for `PageHost.before_call`.
fn connectPage(ph: *PageHost) !void {
    ph.rig.fp.release(.open, .answer);
    try ph.rig.fp.connected();
}

const drop = fake.drop;

/// A queue's page call that outlived the request that sent it: the daemon gave up waiting, and
/// the page loads it on (held at its gate), so only the page knows. Run it on a task, then
/// `arrived(.play_queue)`.
fn queueInPage(rig: *Rig) !void {
    _ = try rig.channel.call(rig.newArena(), "playQueue", "[{\"songs\":[\"1561837008\"]},0]", .fromSeconds(30));
}

/// Another play, begun after the stop or pause, starts a song before its next look: for
/// `PageHost.before_call` on that look's `snapshot`.
fn songPlays(ph: *PageHost) !void {
    ph.rig.fp.setHolding(.{ .music = .playing });
}

/// Live radio starts playing under a state MusicKit doesn't name, before the next look.
fn unnamedPlays(ph: *PageHost) !void {
    ph.rig.fp.setHolding(unnamed_live);
}

/// Live radio under a state MusicKit doesn't name, no item named yet: `isPlaying` says it plays.
const unnamed_live: fake.FakePage.Holding = .{ .music = .playing, .item = .station, .named = false, .state_named = false };

/// What a stop or pause during a reload says.
const reloading_line = "the engine page is reloading; stopped what was on its way\n";

/// What the engine page module prints while a control play waits on another command's reload,
/// and on a launch in flight.
const waiting_line = @import("engine_page.zig").waiting_line;
const starting_line = @import("engine_page.zig").starting_line;

/// Every wait as the rig's, but a reload held in flight has all the time it needs.
const patient: @import("engine_page.zig").Timing = blk: {
    var t = Rig.timing;
    t.reload_wait = .fromSeconds(30);
    t.look = .fromSeconds(30);
    t.check = .fromSeconds(30);
    break :blk t;
};

/// MusicKit signed the page out, and the next page load's MusicKit is held configuring: a
/// repair that reloads the page leaves that reload in flight. Start one on a task (`Rig.doctor`,
/// `Rig.play`), then `arrived(.configure)`.
fn signedOutReloadHeld(ph: *PageHost) !void {
    ph.rig.fp.world.signs_out = true;
    try ph.warm();
    ph.rig.fp.world.signs_out = false;
    ph.rig.fp.hold(.configure, 1);
}

/// As `am pause`, `am resume` and `am stop` run with `c`'s reply, which says what it printed as
/// it goes (`Caller.printed`).
fn runControlAs(ph: *PageHost, c: *fake.Caller, action: Action) !protocol.TestReply.Printed {
    return c.t.finish(control(ph.host(), &c.t.reply, action));
}

test "pause, resume and stop with no warm engine, or nothing loaded, say so and fail" {
    const Setup = enum { no_engine, signin_window, nothing_loaded, page_silent };
    const cases = [_]struct { Setup, Action, []const u8 }{
        .{ .no_engine, .pause, "error: nothing to pause: the engine isn't running\n" },
        .{ .no_engine, .@"resume", "error: nothing to resume: the engine isn't running\n" },
        .{ .no_engine, .stop, "error: nothing to stop: the engine isn't running\n" },
        .{ .signin_window, .pause, "error: nothing to pause: the engine isn't running (a sign-in window is open)\n" },
        // The last report still shows the song, but the page has just been stopped.
        .{ .nothing_loaded, .@"resume", "error: nothing to resume: nothing is loaded in the engine (am play loads a song)\n" },
        .{ .page_silent, .pause, "error: nothing to pause: the engine page didn't answer\n" },
    };
    for (cases) |case| {
        const setup, const action, const err = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        switch (setup) {
            .no_engine => {},
            .signin_window => ph.signin_window = true,
            .nothing_loaded => {
                try holds(&ph, shy_away_at.playing(12));
                rig.fp.set(.none, false);
            },
            .page_silent => {
                try holds(&ph, shy_away_at.playing(12));
                neverAnswers(&rig, .snapshot);
            },
        }
        const printed = try runControl(&ph, action);
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(err, printed.err);
        try testing.expect(!ph.wasCalled(@tagName(action)));
    }
}

test "resume on stopped live radio, nothing loaded, restarts the station and prints its line" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, station_stopped);
    // A stop has been since the engine started: the resume carries a later generation.
    rig.plays.current = 2;
    const printed = try runControl(&ph, .@"resume");
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("", printed.err);
    try testing.expectEqualStrings("▶ Apple Music 1 — Apple Music  0:00 / –:––  [encryptedFull]\n", printed.out);
    try testing.expect(ph.wasCalled("resume [2]"));
    try testing.expectEqual(playback.Music.playing, rig.fp.held());
}

test "resume on stopped live radio that MusicKit hasn't named again yet names the stopped station" {
    // The restart cleared the page's stopped station, and its stream still loads.
    for ([_]?[]const u8{ "Apple Music 1", null }) |name| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        rig.fp.world.live_restart = .loads;
        var stopped = station_stopped;
        stopped.station_name = name;
        try holds(&ph, stopped);
        const printed = try runControl(&ph, .@"resume");
        try testing.expectEqual(@as(u8, 0), printed.code);
        // Stopped before MusicKit had a name for it: the id.
        try testing.expectEqualStrings(if (name != null) "restarting live radio: Apple Music 1\n" else "restarting live radio: ra.978194965\n", printed.out);
        try testing.expect(ph.wasCalled("resume [0]"));
        try testing.expectEqual(playback.Music.starting, rig.fp.held());
        // The page answered past its bound for the restart, which carries on.
        try testing.expectEqualStrings("the engine page's resume gave up waiting on setQueue({station}) and play() after 5 s", ph.logLines()[0]);
    }
}

test "resume on stopped live radio: a stop meanwhile says so and succeeds; a page error fails as for any resume" {
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, station_stopped);
        rig.fp.hold(.@"resume", 1);
        var resuming = try testing.io.concurrent(runControl, .{ &ph, @as(?Action, .@"resume") });
        defer drop(&resuming);
        try rig.fp.arrived(.@"resume");
        // A stop reaches the page while the station's restart is under way, and cancels it.
        const stopped = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), stopped.code);
        try testing.expect(ph.wasCalled("stop [1]"));
        rig.fp.release(.@"resume", .answer);
        const printed = try resuming.await(testing.io);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings("stopped before it started\n", printed.out);
        try testing.expectEqualStrings("", printed.err);
        try testing.expect(ph.wasCalled("resume [0]"));
        // The station stays the one a resume restarts.
        try testing.expectEqual(playback.Music.stopped_live, rig.fp.held());
    }

    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.fp.world.rejects = &.{.{ .method = "resume", .message = "Error | setQueue rejected" }};
    try holds(&ph, station_stopped);
    const printed = try runControl(&ph, .@"resume");
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("", printed.out);
    try testing.expectEqualStrings("error: the engine page didn't resume: Error | setQueue rejected\n", printed.err);
    try testing.expect(ph.wasCalled("resume [0]"));
}

test "resume joins a reload in flight before it looks at the page, never repairs, and resumes on the new page load" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try signedOutReloadHeld(&ph);
    var doctoring = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctoring);
    try rig.fp.arrived(.configure);

    const c = rig.caller();
    var resuming = try testing.io.concurrent(runControlAs, .{ &ph, c, Action.@"resume" });
    defer drop(&resuming);
    try c.printed(waiting_line);
    // What the new page load holds once it lands: a paused song.
    rig.fp.setHolding(shy_away_at.paused(62.3));
    rig.fp.release(.configure, .answer);

    const printed = try resuming.await(testing.io);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(waiting_line ++ "\n▶ Shy Away — Twenty One Pilots  1:02 / 2:55  [encryptedFull]\n", printed.out);
    try testing.expect(ph.wasCalled("resume [0]"));
    try testing.expect(rig.fp.calledOn("2", "resume"));
    try testing.expect(!rig.fp.calledOn("1", "resume"));
    // No repair of its own, no engine start: only the doctor's reload, on the one launch.
    _ = try doctoring.await(testing.io);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
}

test "a resume that a stop cancels while it joins a reload calls nothing on the page, and says it stopped" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try signedOutReloadHeld(&ph);
    var doctoring = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctoring);
    try rig.fp.arrived(.configure);

    const c = rig.caller();
    var resuming = try testing.io.concurrent(runControlAs, .{ &ph, c, Action.@"resume" });
    defer drop(&resuming);
    try c.printed(waiting_line);
    rig.plays.cancel(rig.plays.beginStop());
    // It returns while the reload is still held in flight.
    const printed = try resuming.await(testing.io);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(waiting_line ++ "\n" ++ play.stopped_before_start ++ "\n", printed.out);
    try testing.expectEqual(@as(usize, 0), ph.called.items.len);
    try testing.expect(try rig.page.page().reloadInFlight(rig.newArena()));
    rig.fp.release(.configure, .answer);
    _ = try doctoring.await(testing.io);
}

test "resume during a launch in flight waits for its page before it looks, never repairs, and answers from the ready page" {
    // Its page hasn't connected yet, or its launch call hasn't even set the launch's nonce.
    for ([_]bool{ false, true }) |in_launch_call| {
        var rig: Rig = undefined;
        rig.init(Rig.patientLaunch(patient));
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        // `am play` launches the engine.
        rig.fp.hold(.open, 1);
        if (in_launch_call) rig.launcher.holdLaunch(.before_nonce);
        var problem: []const u8 = "";
        var starting = try testing.io.concurrent(@import("engine_page.zig").EnginePage.start, .{ &rig.page, rig.newArena(), &problem });
        defer drop(&starting);
        if (in_launch_call) try rig.launcher.arrivedLaunch() else try rig.fp.arrived(.open);

        const c = rig.caller();
        var resuming = try testing.io.concurrent(runControlAs, .{ &ph, c, Action.@"resume" });
        defer drop(&resuming);
        if (in_launch_call) {
            // It waits on the engine, which the launch call holds.
            try ph.askedState(1);
            rig.launcher.releaseLaunch();
        }
        try c.printed(starting_line);
        rig.fp.release(.open, .answer);

        const printed = try resuming.await(testing.io);
        // A new page holds nothing: its look reached the page once it was ready, so the reason
        // isn't that the page didn't answer.
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(starting_line ++ "\n", printed.out);
        try testing.expectEqualStrings("error: nothing to resume: " ++ nothing_loaded ++ "\n", printed.err);
        try testing.expect(rig.fp.calledOn("1", "snapshot"));
        try testing.expect((try starting.await(testing.io)).ready);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads + rig.fp.checks + rig.fp.probes);
        try testing.expectEqual(@as(u32, 1), rig.launcher.launchCount());
    }
}

test "resume whose look or call finds the engine relaunched since its wait waits for the new launch's page and starts over on it" {
    // The relaunch comes as the look goes out, or as the resume does after a look that found a
    // paused song.
    for ([_][]const u8{ "snapshot", "resume" }) |method| {
        var rig: Rig = undefined;
        rig.init(Rig.patientLaunch(patient));
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, shy_away_at.paused(62));
        ph.before_call = .{ .method = method, .run = PageHost.relaunchNow };

        const c = rig.caller();
        var resuming = try testing.io.concurrent(runControlAs, .{ &ph, c, Action.@"resume" });
        defer drop(&resuming);
        try c.printed(starting_line);
        rig.fp.release(.open, .answer);

        // The new page holds nothing: its look says so, not that no page answered.
        const printed = try resuming.await(testing.io);
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(starting_line ++ "\n", printed.out);
        try testing.expectEqualStrings("error: nothing to resume: " ++ nothing_loaded ++ "\n", printed.err);
        try testing.expect(rig.fp.calledOn("2", "snapshot"));
        try testing.expectEqual(@as(u32, 2), rig.launcher.launchCount());
    }
}

test "a stop while a play waits for a relaunch it found after its wait cancels it: its call reached no page, and nothing is sent" {
    var rig: Rig = undefined;
    rig.init(Rig.patientLaunch(patient));
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.paused(62));
    ph.before_call = .{ .method = "resume", .run = PageHost.relaunchNow };

    const c = rig.caller();
    var resuming = try testing.io.concurrent(runControlAs, .{ &ph, c, Action.@"resume" });
    defer drop(&resuming);
    try c.printed(starting_line);
    // No page is connected: the stop cancels the plays whose call didn't go out.
    const stopped = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 0), stopped.code);

    const printed = try resuming.await(testing.io);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(starting_line ++ "\n" ++ play.stopped_before_start ++ "\n", printed.out);
    rig.fp.release(.open, .answer);
    try rig.fp.connected();
    try testing.expect(!rig.fp.calledOn("2", "resume"));
}

test "pause calls the page's pause and prints the state after" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.playing(62.3));
    const printed = try runControl(&ph, .pause);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("⏸ Shy Away — Twenty One Pilots  1:02 / 2:55  [encryptedFull]\n", printed.out);
    try testing.expect(ph.wasCalled("pause []"));
    try testing.expectEqual(playback.Music.paused, rig.fp.held());
}

test "stop names what was loaded: the song it rewound, and live radio MusicKit dropped" {
    const cases = [_]struct { fake.FakePage.Holding, []const u8 }{
        .{ shy_away_at.paused(61), "⏸ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]\n" },
        // MusicKit drops the station on stop: the line still names it.
        .{ station_playing, "■ Apple Music 1 — Apple Music  0:00 / –:––  [encryptedFull]\n" },
    };
    for (cases) |case| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, case[0]);
        const printed = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings(try std.mem.concat(rig.newArena(), u8, &.{ case[1], "stopped; the engine stays warm until its idle timeout\n" }), printed.out);
        try testing.expectEqual(@as(usize, 0), ph.logLines().len);
    }
}

test "a stop the page never answers fails, and the daemon's log names the call and its timeout" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.paused(12));
    neverAnswers(&rig, .stop);
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("error: the engine page didn't answer stop within 10 s\n", printed.err);
    try testing.expectEqual(@as(usize, 1), ph.logLines().len);
    try testing.expectEqualStrings("the engine page didn't answer stop within 10 s", ph.logLines()[0]);
}

test "a stop the page disconnects before answering fails with that, and cancels nothing" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.playing(12));
    var on_its_way = rig.plays.begin();
    defer on_its_way.end();
    rig.fp.hold(.stop, 1);
    var stopping = try testing.io.concurrent(runControl, .{ &ph, @as(?Action, .stop) });
    defer drop(&stopping);
    try rig.fp.arrived(.stop);
    // The engine goes away under the stop.
    rig.launcher.stop();
    const printed = try stopping.await(testing.io);
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("", printed.out);
    try testing.expectEqualStrings("error: the engine page disconnected before answering stop\n", printed.err);
    try testing.expect(ph.wasCalled("stop [1]"));
    try testing.expect(!on_its_way.cancelled());
    // Only a call the page never answers is in the daemon's log.
    try testing.expectEqual(@as(usize, 0), ph.logLines().len);
}

test "a stop whose seek the page gave up on succeeds paused where it was, and the log says what it gave up on" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.fp.world.seek_lands = false;
    try holds(&ph, shy_away_at.paused(12));
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("⏸ Shy Away — Twenty One Pilots  0:12 / 2:55  [encryptedFull]\nstopped; the engine stays warm until its idle timeout\n", printed.out);
    try testing.expectEqual(@as(usize, 1), ph.logLines().len);
    try testing.expectEqualStrings("the engine page's stop gave up waiting on seekToTime(0) after 2 s", ph.logLines()[0]);
}

test "q with a play of its own on its way, no page connected yet: the play is stopped before it starts" {
    for ([_]bool{ false, true }) |engine_up| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        if (engine_up) {
            // Its page never connects.
            rig.fp.hold(.open, 1);
            try ph.launch();
        }
        var p = rig.plays.begin();
        defer p.end();
        try testing.expectEqual(StopStartingOutcome.stopped, try stopStarting(ph.host(), rig.newArena(), null));
        try testing.expect(p.cancelled());
    }
}

test "q with no play on its way: a song the page is starting is stopped; a paused one, or nothing loaded, is left as it is" {
    const Page = enum { song_loads, queue_loads, paused, nothing };
    const cases = [_]struct { Page, StopStartingOutcome }{
        // MusicKit loads a song; the page loads a queue, nothing in MusicKit yet.
        .{ .song_loads, .stopped },
        .{ .queue_loads, .stopped },
        .{ .paused, .nothing },
        .{ .nothing, .nothing },
    };
    for (cases) |case| {
        const page, const outcome = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, switch (page) {
            .song_loads => .{ .music = .starting },
            .paused => shy_away_at.paused(12),
            .queue_loads, .nothing => .{ .music = .none },
        });
        if (page == .queue_loads) rig.fp.hold(.play_queue, 1);
        var queue = if (page == .queue_loads) try testing.io.concurrent(queueInPage, .{&rig}) else null;
        defer if (queue) |*q| drop(q);
        if (page == .queue_loads) try rig.fp.arrived(.play_queue);
        const a = rig.newArena();
        const fresh = playback.parseReport(a, try ph.host().snapshot(a, .fromSeconds(5)));
        try testing.expectEqual(outcome, try stopStarting(ph.host(), a, fresh));
        try testing.expectEqual(outcome == .stopped, ph.wasCalled("stop [1]"));
        // Nothing starts any more.
        if (outcome == .stopped) try testing.expect(playback.parseReport(a, try ph.host().snapshot(a, .fromSeconds(5))).?.music() != .starting);
        if (queue) |*q| {
            rig.fp.release(.play_queue, .answer);
            try q.await(testing.io);
        }
    }
    // A page that doesn't answer may still be starting the song its last report named.
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, .{ .music = .starting, .preview = true });
    try testing.expectEqual(StopStartingOutcome.stopped, try stopStarting(ph.host(), rig.newArena(), null));
    try testing.expect(ph.wasCalled("stop [1]"));
}

test "q while music plays: it is heard and stays, a play of its own on its way to replace it included" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.playing(12));
    var p = rig.plays.begin();
    defer p.end();
    const a = rig.newArena();
    const fresh = playback.parseReport(a, try ph.host().snapshot(a, .fromSeconds(5)));
    try testing.expectEqual(StopStartingOutcome.nothing, try stopStarting(ph.host(), a, fresh));
    try testing.expect(!p.cancelled());
    try testing.expect(!ph.wasCalled("stop"));
    try testing.expectEqual(playback.Music.playing, rig.fp.held());
}

test "a stop while a play is still on its way to the page cancels it, with no engine yet or no page connected" {
    for ([_]bool{ false, true }) |engine_up| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        if (engine_up) {
            rig.fp.hold(.open, 1);
            try ph.launch();
        }
        var p = rig.plays.begin();
        defer p.end();
        const printed = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings("the queue that was loading won't start\n", printed.out);
        try testing.expect(p.cancelled());
        // A play that begins after the stop isn't its to cancel.
        var later = rig.plays.begin();
        defer later.end();
        try testing.expect(!later.cancelled());
    }
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    // Nothing on its way: as before.
    const printed = try runControl(&ph, .stop);
    try testing.expectEqualStrings("error: nothing to stop: the engine isn't running\n", printed.err);
    // A pause cancels nothing.
    var p = rig.plays.begin();
    defer p.end();
    _ = try runControl(&ph, .pause);
    try testing.expect(!p.cancelled());
}

test "a stop the page fails cancels nothing; one that succeeds hands the page its generation and cancels the older plays" {
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        rig.fp.world.pause = .keeps_playing;
        try holds(&ph, shy_away_at.playing(12));
        var p = rig.plays.begin();
        defer p.end();
        const failed = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 1), failed.code);
        try testing.expectEqualStrings("error: the engine page didn't stop: Error | MusicKit still plays after pause()\n", failed.err);
        try testing.expect(!p.cancelled());
    }

    // A play whose page call is on its way, nothing loaded yet: the page gets the generation,
    // so the call is cancelled there, and the stop says so.
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, .{ .music = .none });
    var on_its_way = rig.plays.begin();
    defer on_its_way.end();
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("the queue that was loading won't start\nstopped; the engine stays warm until its idle timeout\n", printed.out);
    try testing.expect(ph.wasCalled("stop [1]"));
    try testing.expect(on_its_way.cancelled());
}

test "a stop on a page whose MusicKit isn't configured yet cancels the older play and says the queue won't start" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.fp.world.next = .never;
    try ph.launch();
    try rig.fp.connected();
    var pending = rig.plays.begin();
    defer pending.end();
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("", printed.err);
    try testing.expectEqualStrings("the queue that was loading won't start\nstopped; the engine stays warm until its idle timeout\n", printed.out);
    try testing.expect(ph.wasCalled("stop [1]"));
    try testing.expect(pending.cancelled());
}

test "no page connected at the first look: plays that haven't sent their call are cancelled; one that has is the page's to stop, and only a stop the page answered cancels it" {
    // Still in the engine start: cancelled here, the page isn't asked.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        rig.fp.hold(.open, 1);
        try ph.launch();
        var starting = rig.plays.begin();
        defer starting.end();
        const won_t = try runControl(&ph, .stop);
        try testing.expectEqualStrings("the queue that was loading won't start\n", won_t.out);
        try testing.expect(starting.cancelled());
        try testing.expect(!ph.wasCalled("stop"));
    }

    // Its page call is out: the page's stop decides. The page connects after the first look.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig, .before_call = .{ .method = "stop", .run = connectPage } };
        rig.fp.hold(.open, 1);
        try ph.launch();
        var sent = rig.plays.begin();
        defer sent.end();
        try testing.expect(sent.send());
        const stopped = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), stopped.code);
        try testing.expectEqualStrings("the queue that was loading won't start\nstopped; the engine stays warm until its idle timeout\n", stopped.out);
        try testing.expect(ph.wasCalled("stop [1]"));
        try testing.expect(sent.cancelled());
    }

    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig, .before_call = .{ .method = "stop", .run = connectPage } };
    rig.fp.hold(.open, 1);
    try ph.launch();
    neverAnswers(&rig, .stop);
    var out = rig.plays.begin();
    defer out.end();
    try testing.expect(out.send());
    const failed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expectEqualStrings("error: the engine page didn't answer stop within 10 s\n", failed.err);
    try testing.expect(!out.cancelled());
}

test "no page connected for either the look or the stop, with a play's call already out: the stop fails with that, and cancels nothing" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.fp.hold(.open, 1);
    try ph.launch();
    var sent = rig.plays.begin();
    defer sent.end();
    try testing.expect(sent.send());
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("", printed.out);
    try testing.expectEqualStrings("error: no engine page is connected\n", printed.err);
    try testing.expect(ph.wasCalled("stop [1]"));
    try testing.expect(!sent.cancelled());
}

test "a connected page that doesn't answer the first look still gets the stop, and only its answer cancels" {
    // The look times out, an older play is still in its token check: the page's stop goes out,
    // and once it answered, the play is cancelled.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, .{ .music = .none });
        neverAnswers(&rig, .snapshot);
        var unsent = rig.plays.begin();
        defer unsent.end();
        const with_play = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), with_play.code);
        try testing.expect(ph.wasCalled("stop [1]"));
        try testing.expect(unsent.cancelled());
        try testing.expectEqualStrings("the queue that was loading won't start\nstopped; the engine stays warm until its idle timeout\n", with_play.out);
    }

    // Nothing on its way, the look times out: the stop still goes out.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, .{ .music = .none });
        neverAnswers(&rig, .snapshot);
        const printed = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expect(ph.wasCalled("stop [1]"));
        try testing.expectEqualStrings("stopped; the engine stays warm until its idle timeout\n", printed.out);
    }

    // The look and the stop both time out: the stop fails, and cancels nothing.
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, shy_away_at.playing(12));
    neverAnswers(&rig, .snapshot);
    neverAnswers(&rig, .stop);
    var waiting = rig.plays.begin();
    defer waiting.end();
    const failed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expectEqualStrings("error: the engine page didn't answer stop within 10 s\n", failed.err);
    try testing.expect(!waiting.cancelled());
    try testing.expect(waiting.send());
}

test "a stop or pause while a queue loads, before anything is loaded, cancels it through the page; with nothing loaded or stopped live radio, a pause finds nothing" {
    const cases = [_]struct { Action, []const u8 }{
        .{ .stop, "the queue that was loading won't start\nstopped; the engine stays warm until its idle timeout\n" },
        // MusicKit names no item to pause: the pause stops the queue as `am stop` does.
        .{ .pause, "the queue that was loading won't start\nstopped, not paused: MusicKit had no item to pause yet; the engine stays warm until its idle timeout\n" },
    };
    for (cases) |case| {
        const action, const out = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try ph.warm();
        rig.fp.hold(.play_queue, 1);
        var queue = try testing.io.concurrent(queueInPage, .{&rig});
        defer drop(&queue);
        try rig.fp.arrived(.play_queue);
        const printed = try runControl(&ph, action);
        try testing.expectEqual(@as(u8, 0), printed.code);
        // Nothing on its way here: the page names the play calls it cancelled.
        try testing.expectEqualStrings(out, printed.out);
        try testing.expect(ph.wasCalled("stop [1]"));
        try testing.expect(!ph.wasCalled("pause"));
        // The page waited for the cancelled queue to end, and gave up on it.
        try testing.expectEqual(@as(usize, 1), ph.logLines().len);
        try testing.expectEqualStrings("the engine page's stop gave up waiting on the cancelled loads after 2 s", ph.logLines()[0]);
        // Released, the queue finds itself cancelled: nothing plays.
        rig.fp.release(.play_queue, .answer);
        try queue.await(testing.io);
        try testing.expectEqual(playback.Music.none, rig.fp.held());
    }

    // Nothing loaded, or stopped live radio (`am resume` restarts it): worded as `am stop`'s.
    for ([_]fake.FakePage.Holding{ .{ .music = .none }, station_stopped }) |holding| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, holding);
        const nothing = try runControl(&ph, .pause);
        try testing.expectEqual(@as(u8, 1), nothing.code);
        try testing.expectEqualStrings("error: nothing to pause: nothing is loaded in the engine (am play loads a song)\n", nothing.err);
        try testing.expect(!ph.wasCalled("pause"));
        try testing.expect(!ph.wasCalled("stop"));
    }
}

/// Music that plays or starts before MusicKit names an item.
const unnamed_first_looks = [_]fake.FakePage.Holding{
    // Live radio restarting: playing before MusicKit names the item.
    .{ .music = .playing, .item = .station, .named = false },
    // Live radio under a state MusicKit doesn't name: `isPlaying` says it plays.
    unnamed_live,
    // A song loading before MusicKit names it.
    .{ .music = .starting, .named = false },
};

test "stop sends the page's stop when music plays or starts before MusicKit names it; stopped live radio is nothing to stop" {
    for (unnamed_first_looks) |first_look| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, first_look);
        const printed = try runControl(&ph, .stop);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings("", printed.err);
        try testing.expectEqualStrings("stopped; the engine stays warm until its idle timeout\n", printed.out);
        try testing.expect(ph.wasCalled("stop [1]"));
    }

    // Its difference from what a reload would lose: MusicKit dropped stopped live radio, and
    // `resume` restarts it.
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    try holds(&ph, station_stopped);
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("error: nothing to stop: nothing is loaded in the engine (am play loads a song)\n", printed.err);
    try testing.expect(!ph.wasCalled("stop"));
}

test "pause on music MusicKit hasn't named yet sends the page's stop and says it stopped, not paused" {
    for (unnamed_first_looks) |first_look| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        try holds(&ph, first_look);
        const printed = try runControl(&ph, .pause);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings("", printed.err);
        try testing.expectEqualStrings("stopped, not paused: MusicKit had no item to pause yet; the engine stays warm until its idle timeout\n", printed.out);
        try testing.expect(ph.wasCalled("stop [1]"));
        try testing.expect(!ph.wasCalled("pause"));
    }
}

test "a stop whose pause the page gave up on while the music plays fails with the reason, and the log has it" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    rig.fp.world.pause = .never_settles;
    try holds(&ph, shy_away_at.playing(12));
    const why = "gave up waiting on pause() after 2 s; MusicKit still plays";
    const printed = try runControl(&ph, .stop);
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("", printed.out);
    try testing.expectEqualStrings("error: the engine page didn't stop: Error | " ++ why ++ "\n", printed.err);
    try testing.expectEqual(@as(usize, 1), ph.logLines().len);
    try testing.expectEqualStrings("the engine page's stop " ++ why, ph.logLines()[0]);
}

test "a stop or pause the page answered fails when the music plays again by the next look" {
    const cases = [_]struct { Action, []const u8 }{
        // Another play starts a song from 0:00 before the stop's next look.
        .{ .stop, "▶ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]\n" },
        // A play() still pending in MusicKit starts the music once the page answered.
        .{ .pause, "▶ Shy Away — Twenty One Pilots  0:13 / 2:55  [encryptedFull]\n" },
    };
    for (cases) |case| {
        const action, const out = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        switch (action) {
            .stop => ph.before_call = .{ .method = "snapshot", .nth = 2, .run = songPlays },
            else => rig.fp.world.late_play = true,
        }
        try holds(&ph, shy_away_at.playing(13));
        const printed = try runControl(&ph, action);
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(out, printed.out);
        try testing.expectEqualStrings(try std.fmt.allocPrint(rig.newArena(), "error: the music still plays after {t}\n", .{action}), printed.err);
    }
}

test "a stop or pause the page answered fails when the next look holds music that plays under a state MusicKit doesn't name" {
    const cases = [_]struct { Action, []const u8, fake.FakePage.Holding }{
        .{ .stop, "stop", shy_away_at.playing(13) },
        .{ .pause, "pause", shy_away_at.playing(13) },
        // A pause that stops: MusicKit named no item at the first look.
        .{ .pause, "stop", unnamed_live },
    };
    for (cases) |case| {
        const action, const method, const first_look = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        // Live radio plays by the look after the page's answer.
        var ph: PageHost = .{ .rig = &rig, .before_call = .{ .method = "snapshot", .nth = 2, .run = unnamedPlays } };
        try holds(&ph, first_look);
        const printed = try runControl(&ph, action);
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(try std.fmt.allocPrint(rig.newArena(), "error: the music still plays after {t}\n", .{action}), printed.err);
        try testing.expect(ph.wasCalled(method));
    }
}

test "status with the engine running and playing: the song, the engine, both footprints" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig };
    ph.footprint = .{
        .daemon_pid = 900,
        .daemon = .{ .processes = 1, .memory_bytes = 7654604, .memory = .phys_footprint, .cpu_percent = 0.2 },
        .engine_pids = &.{ 4243, 4244 },
        .engine = .{ .processes = 8, .memory_bytes = 452984832, .memory = .phys_footprint, .cpu_percent = 17.04 },
    };
    try holds(&ph, shy_away_at.playing(42.5));
    const printed = try runControl(&ph, null);
    try testing.expectEqualStrings(
        \\▶ Shy Away — Twenty One Pilots  0:42 / 2:55  [encryptedFull]  (playing)
        \\engine: firefox (headless), pid 4243; stays open while playing
        \\background process: pid 900, 1 process, 7.3 MiB phys_footprint, CPU 0.2% of one core
        \\engine footprint: 8 processes, 432 MiB phys_footprint, CPU 17.0% of one core
        \\
    , printed.out);

    // Live radio under a state MusicKit doesn't name: `isPlaying` says it plays, so the idle
    // close waits, and the line says so.
    rig.fp.setHolding(.{ .music = .playing, .item = .station, .state_named = false });
    try rig.fp.reportNow();
    const l = try runControl(&ph, null);
    // Only the engine line: what the now-playing line says of this state is the display's.
    try testing.expect(std.mem.find(u8, l.out, "\nengine: firefox (headless), pid 4243; stays open while playing\n") != null);
}

test "status with the engine stopped, and paused with the idle close counting and a stale report" {
    const daemon_footprint: host_mod.Footprints = .{ .daemon_pid = 900, .daemon = .{ .processes = 1, .memory_bytes = 7654604, .memory = .pss } };
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig, .footprint = daemon_footprint };
        const s = try runControl(&ph, null);
        try testing.expectEqualStrings(
            \\nothing playing: the engine isn't running
            \\engine: not running
            \\background process: pid 900, 1 process, 7.3 MiB PSS, CPU 0.0% of one core
            \\
        , s.out);
    }

    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig, .footprint = daemon_footprint, .idle_close_in_s = 252, .report_older_by_ms = 25_300 };
    ph.footprint.engine_error = "CantListProcesses";
    try holds(&ph, shy_away_at.paused(62));
    const p = try runControl(&ph, null);
    try testing.expectEqualStrings(
        \\⏸ Shy Away — Twenty One Pilots  1:02 / 2:55  [encryptedFull]  (paused)
        \\stale: the engine page hasn't reported for 25 s, so this may be out of date
        \\engine: firefox (headless), pid 4243; closes in 4:12 unless something plays
        \\background process: pid 900, 1 process, 7.3 MiB PSS, CPU 0.0% of one core
        \\engine footprint: can't measure: CantListProcesses
        \\
    , p.out);

    // A song on its way doesn't hold the engine open: it has the whole idle limit to start.
    ph.idle_close_in_s = 300;
    ph.report_older_by_ms = 0;
    rig.fp.set(.starting, false);
    try rig.fp.reportNow();
    const l = try runControl(&ph, null);
    try testing.expect(std.mem.find(u8, l.out, "\nengine: firefox (headless), pid 4243; closes in 5:00 unless something plays\n") != null);
}

test "status while keep-alive holds an engine that isn't playing says so in place of the countdown; music that plays still stays open while playing" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var ph: PageHost = .{ .rig = &rig, .keep_engine_requests = 1 };
    try holds(&ph, shy_away_at.paused(62));
    const paused = try runControl(&ph, null);
    try testing.expect(std.mem.find(u8, paused.out, "\nengine: firefox (headless), pid 4243; kept open by keep-alive while a TUI is open\n") != null);

    // Nothing loaded: the same.
    rig.fp.set(.none, false);
    try rig.fp.reportNow();
    const idle = try runControl(&ph, null);
    try testing.expect(std.mem.find(u8, idle.out, "\nengine: firefox (headless), pid 4243; kept open by keep-alive while a TUI is open\n") != null);

    // Playing wins.
    rig.fp.setHolding(shy_away_at.playing(70));
    try rig.fp.reportNow();
    const playing = try runControl(&ph, null);
    try testing.expect(std.mem.find(u8, playing.out, "\nengine: firefox (headless), pid 4243; stays open while playing\n") != null);

    // Once none holds it, the countdown is back.
    ph.keep_engine_requests = 0;
    rig.fp.setHolding(shy_away_at.paused(75));
    try rig.fp.reportNow();
    const released = try runControl(&ph, null);
    try testing.expect(std.mem.find(u8, released.out, "\nengine: firefox (headless), pid 4243; closes in 5:00 unless something plays\n") != null);
}

test "a stop or pause during a reload answers at once, with no page call: the play waiting on the reload is cancelled and never plays" {
    // A reload waits up to 30 s: past any page call a stop or pause makes.
    var slow_reload = Rig.timing;
    slow_reload.reload_wait = .fromSeconds(30);
    for ([_]Action{ .stop, .pause }) |action| {
        var rig: Rig = undefined;
        rig.init(slow_reload);
        defer rig.deinit();
        var ph: PageHost = .{ .rig = &rig };
        // MusicKit signed the page out: the next play reloads it.
        rig.fp.world.signs_out = true;
        try ph.warm();
        rig.fp.world.signs_out = false;
        // The new page load doesn't open its stream yet, and the server hasn't noticed that the
        // old one's is dead: a page call now waits out its whole timeout.
        rig.fp.hold(.open, 1);
        rig.fp.hold(.notice, 1);
        var waiting = rig.plays.begin();
        defer waiting.end();
        var playing = try testing.io.concurrent(Rig.play, .{ &rig, &waiting });
        defer drop(&playing);
        try rig.fp.arrived(.notice);

        const began = Io.Clock.awake.now(testing.io);
        const printed = try runControl(&ph, action);
        const took = began.durationTo(Io.Clock.awake.now(testing.io));
        // A page call the page doesn't answer would take its whole (shortened) timeout, 0.5 s
        // for the look.
        try testing.expect(took.toMilliseconds() < 400);
        try testing.expectEqual(@as(u8, 0), printed.code);
        try testing.expectEqualStrings("", printed.err);
        try testing.expectEqualStrings(reloading_line, printed.out);
        try testing.expectEqual(@as(usize, 0), ph.called.items.len);
        try testing.expect(waiting.cancelled());
        try testing.expectEqual(@import("engine_page.zig").Verdict.cancelled, (try playing.await(testing.io)).outcome.verdict);
        rig.fp.release(.notice, .answer);
        rig.fp.release(.open, .answer);
    }
}

test "a stop or pause during a reload cancels only the plays begun before it, and with none on their way finds nothing" {
    for ([_]Action{ .stop, .pause }) |action| {
        for ([_]bool{ true, false }) |plays_on_their_way| {
            var rig: Rig = undefined;
            rig.init(patient);
            defer rig.deinit();
            var ph: PageHost = .{ .rig = &rig };
            // `am doctor`'s repair reloads the page, and that reload is in flight.
            try signedOutReloadHeld(&ph);
            var doctoring = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
            defer drop(&doctoring);
            try rig.fp.arrived(.configure);

            if (plays_on_their_way) {
                // Its page call already went out, to the page load the reload drops.
                var sent = rig.plays.begin();
                defer sent.end();
                try testing.expect(sent.send());
                var unsent = rig.plays.begin();
                defer unsent.end();
                const printed = try runControl(&ph, action);
                try testing.expectEqual(@as(u8, 0), printed.code);
                try testing.expectEqualStrings(reloading_line, printed.out);
                try testing.expect(sent.cancelled());
                try testing.expect(unsent.cancelled());
                var later = rig.plays.begin();
                defer later.end();
                try testing.expect(!later.cancelled());
            } else {
                const nothing = try runControl(&ph, action);
                try testing.expectEqual(@as(u8, 1), nothing.code);
                try testing.expectEqualStrings(try rig.newArena().print("error: nothing to {t}: the engine page is reloading\n", .{action}), nothing.err);
            }
            // Neither waits on the page.
            try testing.expectEqual(@as(usize, 0), ph.called.items.len);
            rig.fp.release(.configure, .answer);
            _ = try doctoring.await(testing.io);
        }
    }
}
