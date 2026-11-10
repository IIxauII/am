//! What the playback endpoints (`play`, `pause`, `resume`, `stop`, `status`, `signin`, `doctor`,
//! and the TUI's `state`, `watch`, `queue`, `control`, `queue-items`) need from the daemon. `Daemon.playbackHost` is the real one; tests substitute their own.
const std = @import("std");
const apple = @import("../apple.zig");
const channel_mod = @import("channel.zig");
const engine = @import("../engine.zig");
const engine_page = @import("engine_page.zig");
const footprint = @import("../footprint.zig");
const platform = @import("../platform.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const CallResult = channel_mod.Channel.CallResult;
const Io = std.Io;

pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// For memory that outlives one step of a long request (`watch`).
    gpa: Allocator,
    /// The engine page module (`engine_page.zig`): it starts the engine, probes the page for
    /// `am doctor`, and repairs the page for a play or if idle.
    page: engine_page.Page,
    /// The cancel generation of plays and stops.
    plays: *Plays,
    /// The warnings about the settings the daemon runs with (`settings.Settings.warnings`), read
    /// when it started, for `am doctor`.
    settings_warnings: []const []const u8 = &.{},

    /// What a page call can fail with: no page, a page gone or silent, a shutdown.
    pub const CallError = channel_mod.Channel.CallError || Allocator.Error || Io.Cancelable;

    pub const VTable = struct {
        /// Runs `window.am[method](...args)` in the engine page; `args_json` is a JSON array.
        call: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, args_json: []const u8, timeout: Io.Duration) CallError!CallResult,
        /// The stored Music User Token, checked with `GET /v1/me/storefront`; a check that
        /// couldn't be made is `unchecked`, with why.
        userTokenStatus: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!TokenStatus,
        /// Which developer token the engine page gets, and where it came from.
        developerToken: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!DeveloperToken,
        state: *const fn (ptr: *anyopaque, arena: Allocator) Allocator.Error!State,
        footprints: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!Footprints,
        search: *const fn (ptr: *anyopaque, arena: Allocator, storefront: []const u8, term: []const u8) (Allocator.Error || Io.Cancelable)!SearchOutcome,
        availableMemory: *const fn (ptr: *anyopaque) ?u64,
        openSigninWindow: *const fn (ptr: *anyopaque, arena: Allocator, kind: engine.Kind, problem: *[]const u8) EngineError!SigninWindow,
        waitSignin: *const fn (ptr: *anyopaque, arena: Allocator, after: ?u64, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!SigninWait,
        userTokenPath: *const fn (ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8,
        signinPage: *const fn (ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8,
        claimPlayback: *const fn (ptr: *anyopaque) u64,
        playbackClaim: *const fn (ptr: *anyopaque) u64,
        build: *const fn (ptr: *anyopaque) []const u8,
        waitChange: *const fn (ptr: *anyopaque, after: ?u64, timeout: Io.Duration) Io.Cancelable!u64,
        /// The warnings about the settings as they are now, for `am doctor` to set beside
        /// `settings_warnings`; null when the env file can't be read.
        settingsWarningsNow: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?[]const []const u8,
        /// One line for the daemon's log.
        log: *const fn (ptr: *anyopaque, line: []const u8) void,
    };

    /// A line for the daemon's log, cut at 512 bytes.
    pub fn log(h: Host, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        h.vtable.log(h.ptr, w.buffered());
    }

    /// A page call, with a timeout, and anything the page gave up waiting on, in the daemon's
    /// log: a call the user only sees as "didn't answer" is on record there by name.
    pub fn call(h: Host, arena: Allocator, method: []const u8, args_json: []const u8, timeout: Io.Duration) CallError!CallResult {
        const result = h.vtable.call(h.ptr, arena, method, args_json, timeout) catch |e| {
            if (e == error.Timeout) h.log("the engine page didn't answer {s} within {d} s", .{ method, timeout.toSeconds() });
            return e;
        };
        switch (result) {
            .ok => |json| h.logGaveUp(arena, method, json),
            // A call that failed over a give-up (app.js `requireSilent`) says so first, after
            // the error's name (app.js `errText`).
            .page_error => |message| {
                const text = std.mem.cutPrefix(u8, message, "Error | ") orelse message;
                if (std.mem.startsWith(u8, text, "gave up waiting on ")) h.log("the engine page's {s} {s}", .{ method, text });
            },
        }
        return result;
    }

    /// The page's state now (`snapshot`, a JSON object), or null when it doesn't answer with
    /// one within `timeout`.
    pub fn snapshot(h: Host, arena: Allocator, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!?[]const u8 {
        return switch (try h.look(arena, timeout)) {
            .report => |json| json,
            .no_page, .no_answer => null,
        };
    }

    /// What a look at the engine page found (`look`).
    pub const Look = union(enum) {
        /// The page's `snapshot`, a JSON object.
        report: []const u8,
        /// No engine page is connected (`error.NoEnginePage`).
        no_page,
        /// A connected page timed out, disconnected, failed, or answered with something else.
        no_answer,
    };

    /// `snapshot`, telling a page that isn't connected apart from one that didn't answer.
    pub fn look(h: Host, arena: Allocator, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!Look {
        const result = h.call(arena, "snapshot", "[]", timeout) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.NoEnginePage => return .no_page,
            else => return .no_answer,
        };
        return switch (result) {
            .ok => |json| if (std.mem.startsWith(u8, json, "{")) .{ .report = json } else .no_answer,
            .page_error => .no_answer,
        };
    }

    /// The engine page bounds MusicKit's waits that can stay pending, and names each one that
    /// ran out in its answer's `gaveUp` (app.js `settle`) when the call itself still succeeds.
    fn logGaveUp(h: Host, arena: Allocator, method: []const u8, json: []const u8) void {
        if (std.mem.find(u8, json, "\"gaveUp\"") == null) return;
        const answer = std.json.parseFromSliceLeaky(struct { gaveUp: []const []const u8 = &.{} }, arena, json, .{ .ignore_unknown_fields = true }) catch return;
        for (answer.gaveUp) |what| h.log("the engine page's {s} gave up waiting on {s}", .{ method, what });
    }

    /// The running daemon's build id (`daemon.buildId`).
    pub fn build(h: Host) []const u8 {
        return h.vtable.build(h.ptr);
    }

    /// Waits up to `timeout` until the engine page reported again, or an engine launched or went
    /// away, since `after` (a count this returned before). With `after` null, answers at once.
    /// Returns the current count.
    pub fn waitChange(h: Host, after: ?u64, timeout: Io.Duration) Io.Cancelable!u64 {
        return h.vtable.waitChange(h.ptr, after, timeout);
    }

    /// `am play` takes over what the engine plays; an earlier watcher sees `playbackClaim`
    /// move on and stops. Returns this play's claim.
    pub fn claimPlayback(h: Host) u64 {
        return h.vtable.claimPlayback(h.ptr);
    }

    /// The latest `claimPlayback`'s.
    pub fn playbackClaim(h: Host) u64 {
        return h.vtable.playbackClaim(h.ptr);
    }

    /// The engine, if one runs, and the page's latest report.
    pub fn state(h: Host, arena: Allocator) Allocator.Error!State {
        return h.vtable.state(h.ptr, arena);
    }

    /// The daemon's and the engine's footprint, measured over about a second.
    pub fn footprints(h: Host, arena: Allocator) (Allocator.Error || Io.Cancelable)!Footprints {
        return h.vtable.footprints(h.ptr, arena);
    }

    /// A catalog search with the stored tokens.
    pub fn search(h: Host, arena: Allocator, storefront: []const u8, term: []const u8) (Allocator.Error || Io.Cancelable)!SearchOutcome {
        return h.vtable.search(h.ptr, arena, storefront, term);
    }

    /// Bytes of memory available, if the OS says.
    pub fn availableMemory(h: Host) ?u64 {
        return h.vtable.availableMemory(h.ptr);
    }

    /// `am signin --engine`: the sign-in page in a visible window of that engine's profile.
    /// `error.EngineFailed` with `problem`.
    pub fn openSigninWindow(h: Host, arena: Allocator, kind: engine.Kind, problem: *[]const u8) EngineError!SigninWindow {
        return h.vtable.openSigninWindow(h.ptr, arena, kind, problem);
    }

    /// Waits up to `timeout` for a sign-in result newer than `after`; with `after` null,
    /// answers at once with the current count.
    pub fn waitSignin(h: Host, arena: Allocator, after: ?u64, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!SigninWait {
        return h.vtable.waitSignin(h.ptr, arena, after, timeout);
    }

    /// The address of a new sign-in page, for the user's normal browser.
    pub fn signinPage(h: Host, arena: Allocator) Allocator.Error![]const u8 {
        return h.vtable.signinPage(h.ptr, arena);
    }

    /// Where the Music User Token is stored.
    pub fn userTokenPath(h: Host, arena: Allocator) Allocator.Error![]const u8 {
        return h.vtable.userTokenPath(h.ptr, arena);
    }

    /// The stored Music User Token, checked with `GET /v1/me/storefront`.
    pub fn userTokenStatus(h: Host, arena: Allocator) (Allocator.Error || Io.Cancelable)!TokenStatus {
        return h.vtable.userTokenStatus(h.ptr, arena);
    }

    /// Which developer token the engine page gets, and where it came from.
    pub fn developerToken(h: Host, arena: Allocator) (Allocator.Error || Io.Cancelable)!DeveloperToken {
        return h.vtable.developerToken(h.ptr, arena);
    }

    pub fn settingsWarningsNow(h: Host, arena: Allocator) (Allocator.Error || Io.Cancelable)!?[]const []const u8 {
        return h.vtable.settingsWarningsNow(h.ptr, arena);
    }
};

pub const DeveloperToken = union(enum) {
    found: struct {
        /// e.g. `shared, from https://…, kid=… iss=… expires …` (`token_source.Found`).
        line: []const u8,
    },
    problem: []const u8,
};

pub const TokenStatus = union(enum) {
    missing,
    /// Why it couldn't be checked.
    unchecked: []const u8,
    /// Apple's answer: 200 valid, 403 sign in again.
    checked: struct { status: u16, storefront: ?[]const u8 },
};

pub const EngineError = error{
    /// Why is in the caller's `problem`.
    EngineFailed,
} || Allocator.Error || Io.Cancelable;

pub const SearchOutcome = union(enum) {
    result: apple.SearchResult,
    /// Why there was no search: no developer token, Apple unreachable.
    problem: []const u8,
};

pub const EngineState = struct {
    kind: []const u8,
    pid: platform.ProcessId,
    headless: bool,
    /// A sign-in window: no engine page, nothing plays.
    signin_window: bool,
    /// Seconds until the idle close, if nothing plays meanwhile.
    idle_close_in_s: i64,
    /// The keep-engine requests holding it open (`Requests.keepers`): while there is one, the
    /// idle close waits. Always 0 for a sign-in window, which keep-alive doesn't hold.
    keep_engine_requests: u32 = 0,
};

/// One cancel generation for every play, from the daemon to the engine page. A play (`am play`,
/// `am resume`, the TUI's queue, play, toggle, play-next and play-later) takes the current
/// generation and hands it to the page with its call; a stop takes the next one. Once a stop
/// succeeds, every play of an older generation stops at its next step and answers that it
/// stopped before it started: here before the engine launch and before the page call, in the
/// page (app.js `load`) at its start and between its MusicKit steps. A play that began after the
/// stop has the stop's own generation, so that stop never cancels it, however long the stop
/// takes; a stop that fails cancels nothing. The page keeps the newest generation a stop cancelled
/// below, so a call still on its way when the stop landed is cancelled there. A stop with no
/// page connected cancels on its own only the plays on their way that haven't sent their page
/// call (`cancelUnsent`), each by itself: not one that already ended, nor one begun after it.
pub const Plays = struct {
    /// Guards the rest; held only for a few loads and stores.
    lock: std.atomic.Value(bool) = .init(false),
    current: u64 = 0,
    /// Plays below this generation are cancelled: a stop the page answered (`cancel`).
    cancelled_below: u64 = 0,
    /// Plays on their way: from their start until the page answered them.
    slots: [max_pending]Slot = @splat(.{}),
    /// Plays on their way past `max_pending`: counted as older than any stop, with their page
    /// call sent, so a stop that can't reach the page never claims to have cancelled them.
    overflow: usize = 0,
    /// Every play begun so far. A play that began and ended between two reads of `activity`
    /// still moves it, so a caller deciding about the engine page sees it came by.
    begun: u64 = 0,

    pub const max_pending = 64;

    const Slot = struct {
        used: bool = false,
        generation: u64 = 0,
        /// The page call went out (`Play.send`).
        sent: bool = false,
        /// A stop that couldn't reach the page cancelled this play (`cancelUnsent`).
        cancelled: bool = false,
    };

    pub const Play = struct {
        plays: *Plays,
        generation: u64,
        /// Index into `slots` while `open`; null past `max_pending`.
        slot: ?usize,
        open: bool = true,
        /// The slot's `cancelled`, kept at `end`: by then the slot may belong to a newer play.
        cancelled_unsent: bool = false,

        /// A stop that began after this play has succeeded since, or one that couldn't reach
        /// the page cancelled it.
        pub fn cancelled(p: *const Play) bool {
            p.plays.acquire();
            defer p.plays.release();
            return p.cancelledLocked();
        }

        fn cancelledLocked(p: *const Play) bool {
            if (p.generation < p.plays.cancelled_below) return true;
            if (!p.open) return p.cancelled_unsent;
            return if (p.slot) |i| p.plays.slots[i].cancelled else false;
        }

        /// Right before the page call: false when a stop cancelled the play; else the call
        /// counts as sent, so a stop that can't reach the page no longer cancels it alone.
        pub fn send(p: *Play) bool {
            const ps = p.plays;
            ps.acquire();
            defer ps.release();
            if (p.cancelledLocked()) return false;
            if (p.slot) |i| ps.slots[i].sent = true;
            return true;
        }

        /// The page call reached no page after all: none was connected, or the browser that got
        /// it is gone. The play counts as unsent again until its next `send`, so a stop that
        /// can't reach the page cancels it.
        pub fn unsend(p: *Play) void {
            if (!p.open) return;
            const ps = p.plays;
            ps.acquire();
            defer ps.release();
            if (p.slot) |i| ps.slots[i].sent = false;
        }

        /// The page answered, or the play ended before it got there: no longer on its way.
        pub fn end(p: *Play) void {
            if (!p.open) return;
            p.open = false;
            const ps = p.plays;
            ps.acquire();
            defer ps.release();
            if (p.slot) |i| {
                p.cancelled_unsent = ps.slots[i].cancelled;
                ps.slots[i] = .{};
            } else ps.overflow -= 1;
        }
    };

    /// Pair with `Play.end`.
    pub fn begin(ps: *Plays) Play {
        ps.acquire();
        defer ps.release();
        ps.begun += 1;
        for (&ps.slots, 0..) |*s, i| if (!s.used) {
            s.* = .{ .used = true, .generation = ps.current };
            return .{ .plays = ps, .generation = ps.current, .slot = i };
        };
        ps.overflow += 1;
        return .{ .plays = ps, .generation = ps.current, .slot = null };
    }

    pub const Stop = struct {
        /// For `cancel`, and for the page's stop.
        generation: u64,
        /// Plays were on their way when the stop began: all of them began before it.
        older_pending: bool,
    };

    /// A stop begins: from now on plays take its generation.
    pub fn beginStop(ps: *Plays) Stop {
        ps.acquire();
        defer ps.release();
        ps.current += 1;
        var pending = ps.overflow > 0;
        for (ps.slots) |s| pending = pending or s.used;
        return .{ .generation = ps.current, .older_pending = pending };
    }

    /// The stop succeeded: every play older than it is cancelled.
    pub fn cancel(ps: *Plays, stop: Stop) void {
        ps.acquire();
        defer ps.release();
        ps.cancelled_below = @max(ps.cancelled_below, stop.generation);
    }

    pub const Unsent = enum {
        /// No play older than the stop is on its way.
        none,
        /// They were all still here, and are cancelled.
        cancelled,
        /// One has sent its page call: only the page can stop it, and nothing is cancelled.
        in_flight,
    };

    /// A stop that can't reach the page: cancels the older plays on their way if none has sent
    /// its page call yet. Only those: a play that already ended (its page call answered) or began
    /// after the stop isn't cancelled. Decided together with `Play.send`, so a play either sees
    /// the cancel or counts as sent here.
    pub fn cancelUnsent(ps: *Plays, stop: Stop) Unsent {
        ps.acquire();
        defer ps.release();
        if (ps.overflow > 0) return .in_flight;
        var older = false;
        for (ps.slots) |s| if (s.used and s.generation < stop.generation) {
            if (s.sent) return .in_flight;
            older = true;
        };
        if (!older) return .none;
        for (&ps.slots) |*s| if (s.used and s.generation < stop.generation) {
            s.cancelled = true;
        };
        return .cancelled;
    }

    /// Plays on their way: begun and not yet ended.
    pub fn onTheirWay(ps: *Plays) usize {
        return ps.activity().on_their_way;
    }

    /// What a caller deciding about the engine page reads before it looks at the page: a play
    /// on its way may be about to send music to it, and one begun since may have done so.
    pub const Activity = struct { on_their_way: usize, begun: u64 };

    /// `onTheirWay` and `begun`, read together.
    pub fn activity(ps: *Plays) Activity {
        ps.acquire();
        defer ps.release();
        var n = ps.overflow;
        for (ps.slots) |s| n += @intFromBool(s.used);
        return .{ .on_their_way = n, .begun = ps.begun };
    }

    fn acquire(ps: *Plays) void {
        while (ps.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(ps: *Plays) void {
        ps.lock.store(false, .release);
    }
};

test "a stop that succeeds cancels the plays older than it, not those that began after it" {
    var ps: Plays = .{};
    var old = ps.begin();
    defer old.end();
    const stop = ps.beginStop();
    try std.testing.expect(stop.older_pending);
    var new = ps.begin();
    defer new.end();
    try std.testing.expectEqual(stop.generation, new.generation);
    // Not before it succeeded.
    try std.testing.expect(!old.cancelled());
    ps.cancel(stop);
    try std.testing.expect(old.cancelled());
    try std.testing.expect(!new.cancelled());
    // The next stop finds only the newer play on its way, and once that ended, none.
    old.end();
    try std.testing.expect(ps.beginStop().older_pending);
    new.end();
    try std.testing.expect(!ps.beginStop().older_pending);
}

test "a stop that can't reach the page cancels only plays that haven't sent their page call" {
    var ps: Plays = .{};
    var waiting = ps.begin();
    defer waiting.end();
    const first = ps.beginStop();
    try std.testing.expectEqual(Plays.Unsent.cancelled, ps.cancelUnsent(first));
    try std.testing.expect(!waiting.send());

    var sent = ps.begin();
    defer sent.end();
    try std.testing.expect(sent.send());
    const second = ps.beginStop();
    try std.testing.expectEqual(Plays.Unsent.in_flight, ps.cancelUnsent(second));
    try std.testing.expect(!sent.cancelled());
    // One begun after the stop isn't its to cancel.
    sent.end();
    waiting.end();
    var later = ps.begin();
    defer later.end();
    try std.testing.expectEqual(Plays.Unsent.none, ps.cancelUnsent(second));

    // Past the tracked slots, plays count as sent: never cancelled without the page.
    var many: [Plays.max_pending]Plays.Play = undefined;
    for (&many) |*p| p.* = ps.begin();
    var extra = ps.begin();
    try std.testing.expectEqual(@as(?usize, null), extra.slot);
    try std.testing.expectEqual(Plays.Unsent.in_flight, ps.cancelUnsent(ps.beginStop()));
    extra.end();
    for (&many) |*p| p.end();
    later.end();
    try std.testing.expectEqual(@as(usize, 0), ps.onTheirWay());
}

test "a stop that can't reach the page cancels the plays it found unsent, not one that already ended, nor one begun after it" {
    var ps: Plays = .{};
    // Its page call answered, and it is waiting for the music.
    var answered = ps.begin();
    try std.testing.expect(answered.send());
    answered.end();
    var unsent = ps.begin();
    defer unsent.end();
    const stop = ps.beginStop();
    try std.testing.expectEqual(Plays.Unsent.cancelled, ps.cancelUnsent(stop));
    try std.testing.expect(unsent.cancelled());
    try std.testing.expect(!answered.cancelled());
    var later = ps.begin();
    defer later.end();
    try std.testing.expect(!later.cancelled());
    try std.testing.expect(later.send());
}

test "a play a stop cancelled without the page stays cancelled once it ended, and a new play in its slot isn't" {
    var ps: Plays = .{};
    var cancelled = ps.begin();
    const slot = cancelled.slot;
    try std.testing.expectEqual(Plays.Unsent.cancelled, ps.cancelUnsent(ps.beginStop()));
    try std.testing.expect(!cancelled.send());
    cancelled.end();
    try std.testing.expect(cancelled.cancelled());
    var next = ps.begin();
    defer next.end();
    try std.testing.expectEqual(slot, next.slot);
    try std.testing.expect(!next.cancelled());
    try std.testing.expect(cancelled.cancelled());
}

test "Plays counts the plays begun and those on their way, read together" {
    var ps: Plays = .{};
    try std.testing.expectEqual(Plays.Activity{ .on_their_way = 0, .begun = 0 }, ps.activity());
    var first = ps.begin();
    var second = ps.begin();
    try std.testing.expectEqual(Plays.Activity{ .on_their_way = 2, .begun = 2 }, ps.activity());
    // One that ended is no longer on its way, and it still counts as begun.
    first.end();
    try std.testing.expectEqual(@as(usize, 1), ps.onTheirWay());
    second.end();
    try std.testing.expectEqual(Plays.Activity{ .on_their_way = 0, .begun = 2 }, ps.activity());
    // A play that began and ended between two reads still shows in `begun`.
    var brief = ps.begin();
    brief.end();
    try std.testing.expectEqual(Plays.Activity{ .on_their_way = 0, .begun = 3 }, ps.activity());
}

test "a page call that failed over a give-up is in the daemon's log, as the page names the error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // app.js `errText`: the error's name, then its message.
    var f: Fake = .{ .arena = a, .calls = &.{
        .{ .method = "stop", .results = &.{.{ .page_error = "Error | gave up waiting on pause() after 2 s; MusicKit still plays" }} },
        .{ .method = "pause", .results = &.{.{ .page_error = "Error | MusicKit still plays after pause()" }} },
    } };
    _ = try f.host().call(a, "stop", "[1]", .fromSeconds(10));
    _ = try f.host().call(a, "pause", "[]", .fromSeconds(10));
    try std.testing.expectEqual(@as(usize, 1), f.logged.items.len);
    try std.testing.expectEqualStrings("the engine page's stop gave up waiting on pause() after 2 s; MusicKit still plays", f.logged.items[0]);
}

pub const State = struct {
    engine: ?EngineState,
    /// The engine page's latest report (JSON), if it sent one since its launch.
    report: ?[]const u8,
    report_age_ms: u64 = 0,
};

pub const Footprints = struct {
    daemon_pid: platform.ProcessId,
    daemon: footprint.Footprint,
    /// Empty when no engine runs.
    engine_pids: []const platform.ProcessId = &.{},
    engine: ?footprint.Footprint = null,
    /// Why the engine's tree couldn't be listed.
    engine_error: ?[]const u8 = null,
};

pub const SigninWindow = struct {
    pid: platform.ProcessId,
    url: []const u8,
};

pub const SigninWait = struct {
    count: u64,
    /// The newest result's JSON, if newer than `after`.
    result: ?[]const u8,
    /// Whether a sign-in window is open.
    window_open: bool,
};

/// Test double: canned answers, scripted where a command reads the same thing repeatedly, and a
/// canned engine page (`start`, `probe`, `repair`, `waitOutInFlight`). Tests of the endpoints
/// that drive the engine page itself run on `fake_page.PageHost` instead.
pub const Fake = struct {
    /// `state` answers these in turn; the last repeats.
    states: []const State = &.{.{ .engine = null, .report = null }},
    /// `call` answers by method, each in turn, the last repeating.
    calls: []const Call = &.{},
    footprint: Footprints = .{ .daemon_pid = 1, .daemon = .{} },
    search_result: SearchOutcome = .{ .result = .{ .songs = &.{} } },
    available: ?u64 = 8 << 30,
    signin_waits: []const SigninWait = &.{.{ .count = 0, .result = null, .window_open = false }},
    token: TokenStatus = .{ .checked = .{ .status = 200, .storefront = "gb" } },
    developer: DeveloperToken = .{ .found = .{ .line = "your own, kid=KEY iss=TEAM expires 2027-04-01 00:00 UTC" } },
    settings_warnings: []const []const u8 = &.{},
    /// What `settingsWarningsNow` answers; null: the same as `settings_warnings`.
    settings_warnings_now: ?[]const []const u8 = null,
    /// The canned engine page (`Host.page`): what `start` and `probe` answer.
    page_started: engine_page.Started = .{ .kind = "chrome", .pid = 4242, .started = false, .headless = true, .ready = true, .report = .{} },
    page_probe: engine_page.Probe = .{ .h264 = "probably", .aac = "probably", .mseAac = true, .widevine = true },
    /// `repair` answers these in turn, the last repeating; `says` is printed first.
    outcomes: []const engine_page.Outcome = &.{.{ .report = .{ .configured = true, .isAuthorized = true, .browserSupportsVideoDrm = true }, .verdict = .ready }},
    says: []const u8 = "",
    /// What `reloadInFlight` answers.
    page_reloading: bool = false,
    /// `waitOutInFlight` prints this first, as the module prints its line for waiting on a reload.
    join_says: []const u8 = "",
    /// A stop elsewhere succeeds while a control play joins a reload.
    stop_while_joining: bool = false,
    /// `waitChange` answers these in turn; null, or running out, cancels the request (as a
    /// daemon shutdown would).
    changes: []const ?u64 = &.{},

    state_hits: usize = 0,
    claims: u64 = 0,
    /// From this many `state` calls on, another play holds the claim.
    claim_taken_at_state: ?usize = null,
    signin_hits: usize = 0,
    change_hits: usize = 0,
    /// One per entry of `calls`, allocated on the first call.
    call_hits: []usize = &.{},
    /// `method args` of every page call, for assertions.
    called: std.ArrayList([]const u8) = .empty,
    /// Page methods whose calls time out.
    timeouts: []const []const u8 = &.{},
    /// Every line for the daemon's log.
    logged: std.ArrayList([]const u8) = .empty,
    arena: Allocator,
    engine_started: bool = false,
    window_opened: ?engine.Kind = null,
    plays: Plays = .{},
    /// A stop elsewhere succeeds while the engine starts, or while the token is checked.
    stop_while_starting: bool = false,
    stop_while_checking_token: bool = false,
    /// A stop elsewhere succeeds while the page is repaired.
    stop_while_repairing: bool = false,
    /// From this many `state` calls on, a stop elsewhere has succeeded.
    stop_at_state: ?usize = null,
    /// How often the page was asked to repair.
    repairs: usize = 0,
    /// How often a control play waited out a launch or a reload in flight (`waitOutInFlight`).
    joins: usize = 0,
    /// The `user_token_ok` the last repair if idle was asked with.
    idle_user_token_ok: ?bool = null,

    pub const Call = struct { method: []const u8, results: []const CallResult };

    pub fn host(f: *Fake) Host {
        return .{
            .ptr = f,
            .gpa = std.testing.allocator,
            .plays = &f.plays,
            .settings_warnings = f.settings_warnings,
            .vtable = &.{
                .call = fakeCall,
                .userTokenStatus = fakeTokenStatus,
                .developerToken = fakeDeveloperToken,
                .state = fakeState,
                .footprints = fakeFootprints,
                .search = fakeSearch,
                .availableMemory = fakeAvailable,
                .openSigninWindow = fakeOpenWindow,
                .waitSignin = fakeWaitSignin,
                .userTokenPath = fakeTokenPath,
                .signinPage = fakeSigninPage,
                .claimPlayback = fakeClaimPlayback,
                .playbackClaim = fakePlaybackClaim,
                .build = fakeBuild,
                .waitChange = fakeWaitChange,
                .settingsWarningsNow = fakeSettingsWarningsNow,
                .log = fakeLog,
            },
            .page = .{ .ptr = f, .vtable = &.{
                .start = fakeStart,
                .probe = fakeProbe,
                .repair = fakeRepair,
                .reloadInFlight = fakeReloadInFlight,
                .waitOutInFlight = fakeWaitOutInFlight,
            } },
        };
    }

    pub fn wasCalled(f: *const Fake, method_and_args: []const u8) bool {
        for (f.called.items) |c| if (std.mem.startsWith(u8, c, method_and_args)) return true;
        return false;
    }

    fn of(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn fakeCall(ptr: *anyopaque, _: Allocator, method: []const u8, args_json: []const u8, _: Io.Duration) Host.CallError!CallResult {
        const f = of(ptr);
        if (f.call_hits.len != f.calls.len) {
            f.call_hits = try f.arena.alloc(usize, f.calls.len);
            @memset(f.call_hits, 0);
        }
        try f.called.append(f.arena, try f.arena.print("{s} {s}", .{ method, args_json }));
        for (f.timeouts) |m| if (std.mem.eql(u8, m, method)) return error.Timeout;
        for (f.calls, 0..) |c, i| if (std.mem.eql(u8, c.method, method)) {
            const result = c.results[@min(f.call_hits[i], c.results.len - 1)];
            f.call_hits[i] += 1;
            return result;
        };
        return error.NoEnginePage;
    }
    fn fakeState(ptr: *anyopaque, _: Allocator) Allocator.Error!State {
        const f = of(ptr);
        defer f.state_hits += 1;
        if (f.stop_at_state) |at_hit| if (f.state_hits == at_hit) f.stopNow();
        return f.states[@min(f.state_hits, f.states.len - 1)];
    }
    fn fakeFootprints(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!Footprints {
        return of(ptr).footprint;
    }
    fn fakeSearch(ptr: *anyopaque, _: Allocator, _: []const u8, _: []const u8) (Allocator.Error || Io.Cancelable)!SearchOutcome {
        return of(ptr).search_result;
    }
    fn fakeAvailable(ptr: *anyopaque) ?u64 {
        return of(ptr).available;
    }
    fn fakeOpenWindow(ptr: *anyopaque, _: Allocator, kind: engine.Kind, _: *[]const u8) EngineError!SigninWindow {
        of(ptr).window_opened = kind;
        return .{ .pid = 77, .url = "http://localhost:47823/?signin&engine=5555" };
    }
    fn fakeWaitSignin(ptr: *anyopaque, _: Allocator, _: ?u64, _: Io.Duration) (Allocator.Error || Io.Cancelable)!SigninWait {
        const f = of(ptr);
        defer f.signin_hits += 1;
        return f.signin_waits[@min(f.signin_hits, f.signin_waits.len - 1)];
    }
    fn fakeTokenPath(_: *anyopaque, _: Allocator) Allocator.Error![]const u8 {
        return "/home/u/.config/am/music-user-token";
    }
    fn fakeClaimPlayback(ptr: *anyopaque) u64 {
        const f = of(ptr);
        f.claims += 1;
        return f.claims;
    }
    fn fakePlaybackClaim(ptr: *anyopaque) u64 {
        const f = of(ptr);
        const taken = if (f.claim_taken_at_state) |at| f.state_hits >= at else false;
        return if (taken) f.claims + 1 else f.claims;
    }
    fn fakeBuild(_: *anyopaque) []const u8 {
        return "0123456789abcdef";
    }
    fn fakeWaitChange(ptr: *anyopaque, _: ?u64, _: Io.Duration) Io.Cancelable!u64 {
        const f = of(ptr);
        defer f.change_hits += 1;
        if (f.change_hits >= f.changes.len) return error.Canceled;
        return f.changes[f.change_hits] orelse error.Canceled;
    }
    fn fakeSettingsWarningsNow(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!?[]const []const u8 {
        const f = of(ptr);
        return f.settings_warnings_now orelse f.settings_warnings;
    }
    fn fakeLog(ptr: *anyopaque, line: []const u8) void {
        const f = of(ptr);
        f.logged.append(f.arena, f.arena.dupe(u8, line) catch return) catch {};
    }
    fn fakeSigninPage(_: *anyopaque, _: Allocator) Allocator.Error![]const u8 {
        return "http://localhost:47823/?signin&engine=5555";
    }
    fn fakeStart(ptr: *anyopaque, _: Allocator, _: *[]const u8) engine_page.StartError!engine_page.Started {
        const f = of(ptr);
        f.engine_started = true;
        if (f.stop_while_starting) f.stopNow();
        return f.page_started;
    }
    fn fakeProbe(ptr: *anyopaque, _: *protocol.Reply) protocol.Reply.Error!engine_page.Probe {
        return of(ptr).page_probe;
    }
    /// As the engine page module answers: a play a stop cancelled gets `cancelled`.
    fn fakeRepair(ptr: *anyopaque, r: *protocol.Reply, intent: engine_page.Intent) protocol.Reply.Error!engine_page.Outcome {
        const f = of(ptr);
        defer f.repairs += 1;
        if (f.says.len > 0) try r.print("{s}", .{f.says});
        if (f.stop_while_repairing) f.stopNow();
        const outcome = f.outcomes[@min(f.repairs, f.outcomes.len - 1)];
        switch (intent) {
            .for_play => |play| if (play.cancelled()) return .{ .report = outcome.report, .verdict = .cancelled },
            .if_idle => |idle| f.idle_user_token_ok = idle.user_token_ok,
        }
        return outcome;
    }
    fn fakeReloadInFlight(ptr: *anyopaque, _: Allocator) Allocator.Error!bool {
        return of(ptr).page_reloading;
    }
    fn fakeWaitOutInFlight(ptr: *anyopaque, r: *protocol.Reply, _: ?*const Plays.Play) protocol.Reply.Error!void {
        const f = of(ptr);
        f.joins += 1;
        if (f.join_says.len > 0) try r.print("{s}", .{f.join_says});
        if (f.stop_while_joining) f.stopNow();
    }
    fn fakeTokenStatus(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!TokenStatus {
        const f = of(ptr);
        if (f.stop_while_checking_token) f.stopNow();
        return f.token;
    }
    fn fakeDeveloperToken(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!DeveloperToken {
        return of(ptr).developer;
    }

    /// A stop elsewhere that succeeds.
    fn stopNow(f: *Fake) void {
        f.plays.cancel(f.plays.beginStop());
    }
};
