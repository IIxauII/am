//! The TUI's endpoints: `state`, `watch`, `queue`, `control` and `queue-items`. Besides the
//! usual text lines, they answer with `data` lines (see `protocol.zig`) for a program to parse.
//! Most end with one `State`:
//!
//!     {"build":"…","engine":{kind,pid,headless,signin_window,idle_close_in_s}|null,
//!      "report":<the engine page's snapshot>|null,"report_age_ms":n}
const std = @import("std");
const control_mod = @import("control.zig");
const engine_page = @import("engine_page.zig");
const host_mod = @import("host.zig");
const play = @import("play.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Host = host_mod.Host;
const Io = std.Io;
const Reply = protocol.Reply;

/// The exact failure message `control` and `queue-items` give without an engine page, or when
/// `play` or `toggle` find the page's queue empty (a reloaded or relaunched page); the TUI keys
/// on it to queue its music again.
pub const not_running = "engine-not-running";

/// The engine page's error for `play` and `toggle` with nothing queued.
const nothing_queued = "nothing-queued";

const stopped_before_start = play.stopped_before_start;

/// `State` as JSON. `report` goes in verbatim: the page's snapshot, already valid JSON.
pub fn stateJson(arena: Allocator, build: []const u8, st: host_mod.State) Allocator.Error![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.print("{{\"build\":{f},\"engine\":{f},\"report\":{s},\"report_age_ms\":{d}}}", .{
        std.json.fmt(build, .{}), std.json.fmt(st.engine, .{}), st.report orelse "null", st.report_age_ms,
    }) catch return error.OutOfMemory;
    return out.written();
}

/// The `state` endpoint: one `State`. Cheap: no CPU sampling, unlike `status`.
pub fn state(host: Host, r: *Reply) Reply.Error!void {
    try r.data(try stateJson(r.arena, host.build(), try host.state(r.arena)));
}

pub const WatchOptions = struct {
    /// A `State` at least this often, so a client that went away is noticed.
    heartbeat: Io.Duration = .fromSeconds(15),
};

/// The `watch` endpoint: a `State` now, then on every report from the engine page, every engine
/// launch or close, and every heartbeat. Runs until the client goes away (the write fails) or
/// the daemon stops.
pub fn watch(host: Host, io: Io, r: *Reply, options: WatchOptions) Reply.Error!void {
    // Per line: the request's own arena would grow for as long as the watch runs.
    var scratch: std.heap.ArenaAllocator = .init(host.gpa);
    defer scratch.deinit();
    var seen = try host.waitChange(null, .zero);
    var sent_at: ?Io.Clock.Timestamp = null;
    while (true) {
        if (sent_at) |at| {
            const since = at.untilNow(io).raw;
            const left: Io.Duration = .{ .nanoseconds = @max(0, options.heartbeat.nanoseconds - since.nanoseconds) };
            const now = try host.waitChange(seen, left);
            const changed = now != seen;
            seen = now;
            if (!changed and at.untilNow(io).raw.nanoseconds < options.heartbeat.nanoseconds) continue;
        }
        _ = scratch.reset(.retain_capacity);
        const a = scratch.allocator();
        try r.data(try stateJson(a, host.build(), try host.state(a)));
        sent_at = .now(io, .awake);
    }
}

pub const Repeat = enum { none, one, all };

pub const ContainerType = enum { albums, playlists, @"library-albums", @"library-playlists" };

/// An album or playlist; the engine page reads all its tracks, however many.
pub const Container = struct {
    type: ContainerType,
    id: []const u8,
    /// Shown as what the queue plays from (the snapshot's `nowPlaying.container.name`).
    name: ?[]const u8 = null,
};

pub const StationSeed = struct {
    song: ?[]const u8 = null,
    artist: ?[]const u8 = null,
};

/// What `queue` plays: exactly one of `songs`, `container`, `station` and `stationFor`.
pub const QueueRequest = struct {
    /// Catalog or library (`i.`/`l.`) song ids.
    songs: ?[]const []const u8 = null,
    container: ?Container = null,
    /// A catalog station (`ra.…`), live radio included.
    station: ?[]const u8 = null,
    /// A station made from a song or an artist.
    stationFor: ?StationSeed = null,
    /// Where to start, by index into the songs or tracks (default 0) or by id.
    startIndex: ?u32 = null,
    startId: ?[]const u8 = null,
    /// Seconds into the first item.
    startTime: ?f64 = null,
    shuffle: ?bool = null,
    repeat: ?Repeat = null,
    /// 0 to 1, set before playback starts: a new engine page starts at full volume.
    volume: ?f64 = null,
};

/// What `play_next` and `play_later` add: one of `songs` and `container`.
pub const InsertRequest = struct {
    songs: ?[]const []const u8 = null,
    container: ?Container = null,
};

pub const max_songs = 300;

/// Why a queue request can't be played, if it can't.
fn queueProblem(req: QueueRequest) ?[]const u8 {
    var kinds: u8 = 0;
    if (req.songs) |s| {
        kinds += 1;
        if (songsProblem(s)) |why| return why;
    }
    if (req.container) |c| {
        kinds += 1;
        if (c.id.len == 0) return "the container has no id";
    }
    if (req.station) |s| {
        kinds += 1;
        if (s.len == 0) return "the station has no id";
    }
    if (req.stationFor) |seed| {
        kinds += 1;
        if ((seed.song == null) == (seed.artist == null)) return "stationFor needs one of song and artist";
    }
    if (kinds != 1) return "give exactly one of songs, container, station and stationFor";
    return null;
}

fn songsProblem(songs: []const []const u8) ?[]const u8 {
    if (songs.len == 0) return "no songs given";
    if (songs.len > max_songs) return "more than 300 songs";
    for (songs) |id| if (id.len == 0) return "an empty song id";
    return null;
}

pub const QueueOptions = struct {
    poll: Io.Duration = .fromSeconds(1),
};

/// The `queue` endpoint: replaces the engine's queue and plays it, starting the engine if
/// needed. Returns once MusicKit plays, as `am play` does, and fails the same way on a preview.
pub fn queue(host: Host, io: Io, r: *Reply, req: QueueRequest, options: QueueOptions) Reply.Error!void {
    const a = r.arena;
    if (queueProblem(req)) |why| return r.fail("can't queue that: {s}", .{why});
    var p = host.plays.begin();
    defer p.end();
    // A stop during the token check or the engine start, before the page had the queue: as below.
    const prepared = try play.prepare(host, r, &p, .{ .announce_start = true }) orelse
        return sendState(host, r, try freshSnapshot(host, r.arena));
    var watching: play.Watching = .{
        .started_at = undefined,
        .claim = host.claimPlayback(),
        .engine_pid = prepared.started.pid,
        .load = prepared.ready.load,
        .play = &p,
    };
    var page_req = req;
    if (req.volume) |v| page_req.volume = std.math.clamp(v, 0, 1);
    const args = try std.json.Stringify.valueAlloc(a, .{ page_req, p.generation }, .{ .emit_null_optional_fields = false });
    if (!p.send()) return sendState(host, r, try freshSnapshot(host, r.arena));
    // A long playlist is read 100 tracks a request.
    const answer = try play.pageCall(host, r, "playQueue", args, .fromSeconds(120));
    p.end();
    const snapshot = switch (answer) {
        .ok => |json| json,
        // A stop while it loaded: done, with nothing playing, as the user asked.
        .page_error => |message| if (std.mem.eql(u8, message, stopped_before_start))
            return sendState(host, r, try freshSnapshot(host, r.arena))
        else
            return r.fail("the engine page couldn't play that: {s}", .{message}),
    };
    // The start timeout counts from the page's answer, not from before the reading.
    watching.started_at = .now(io, .awake);
    const result = try play.untilPlaying(host, io, a, watching, playback.parseReport(a, snapshot), options.poll);
    // The last report can be most of a second old.
    try sendState(host, r, try freshSnapshot(host, r.arena));
    // A stop after the page's answer, before the music started: as above.
    if (result.end == .stopped) return;
    if (result.failure) |f| return r.fail("{f}", .{f});
    const np = result.now_playing orelse return r.fail("playback ended before MusicKit named the song", .{});
    if (playback.isPreview(np)) return r.fail(play.preview_message, .{});
}

pub const Action = enum {
    toggle,
    play,
    pause,
    stop,
    next,
    previous,
    seek,
    seek_by,
    volume,
    shuffle,
    repeat,
    autoplay,
    jump,
    play_next,
    play_later,
    remove,
    clear_upcoming,

    /// The engine page's method (`am.*` in `poc/web/app.js`).
    fn method(action: Action) []const u8 {
        return switch (action) {
            .toggle => "toggle",
            .play => "play",
            .pause => "pause",
            .stop => "stop",
            .next => "next",
            .previous => "prev",
            .seek => "seek",
            .seek_by => "seekBy",
            .volume => "setVolume",
            .shuffle => "setShuffle",
            .repeat => "setRepeat",
            .autoplay => "setAutoplay",
            .jump => "jump",
            .play_next => "playNext",
            .play_later => "playLater",
            .remove => "removeAt",
            .clear_upcoming => "clearUpcoming",
        };
    }
};

pub const ControlRequest = struct {
    action: Action,
    value: ?std.json.Value = null,
};

const Args = union(enum) {
    json: []const u8,
    problem: []const u8,
};

/// Actions that may start a queue, so a stop cancels them (`Plays`): resuming stopped live radio
/// queues it again, and play-next or play-later on an empty queue start it.
fn isPlay(action: Action) bool {
    return switch (action) {
        .toggle, .play, .play_next, .play_later => true,
        else => false,
    };
}

/// The page method's arguments, as a JSON array, from the request's `value`; a play's end with
/// its `generation`.
fn controlArgs(arena: Allocator, req: ControlRequest, generation: u64) Allocator.Error!Args {
    const v = req.value orelse std.json.Value.null;
    const json = struct {
        fn of(a: Allocator, value: anytype) Allocator.Error!Args {
            return .{ .json = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false }) };
        }
    }.of;
    switch (req.action) {
        .toggle => return json(arena, .{generation}),
        // No song: resume.
        .play => return json(arena, .{ null, generation }),
        .pause, .stop, .next, .previous, .clear_upcoming => return .{ .json = "[]" },
        .seek => {
            const seconds = number(v) orelse return .{ .problem = "value must be a number of seconds" };
            return json(arena, .{@max(0, seconds)});
        },
        .seek_by => return json(arena, .{number(v) orelse return .{ .problem = "value must be a number of seconds" }}),
        .volume => {
            const volume = number(v) orelse return .{ .problem = "value must be a number from 0 to 1" };
            return json(arena, .{std.math.clamp(volume, 0, 1)});
        },
        .shuffle, .autoplay => switch (v) {
            .bool => |on| return json(arena, .{on}),
            else => return .{ .problem = "value must be true or false" },
        },
        .repeat => {
            const mode = switch (v) {
                .string => |s| std.meta.stringToEnum(Repeat, s),
                else => null,
            } orelse return .{ .problem = "value must be none, one or all" };
            return json(arena, .{@tagName(mode)});
        },
        .jump, .remove => {
            const index = switch (v) {
                .integer => |i| if (i >= 0) i else null,
                else => null,
            } orelse return .{ .problem = "value must be a queue index (0 or more)" };
            return json(arena, .{index});
        },
        .play_next, .play_later => {
            const insert = std.json.parseFromValueLeaky(InsertRequest, arena, v, .{ .ignore_unknown_fields = true }) catch
                return .{ .problem = "value must be {\"songs\":[…]} or {\"container\":{\"type\":…,\"id\":…}}" };
            if ((insert.songs == null) == (insert.container == null)) return .{ .problem = "give one of songs and container" };
            if (insert.songs) |s| if (songsProblem(s)) |why| return .{ .problem = why };
            return json(arena, .{ insert, generation });
        },
    }
}

fn number(v: std.json.Value) ?f64 {
    const n: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

/// The `control` endpoint: one page call on the running engine; never starts one.
pub fn control(host: Host, r: *Reply, req: ControlRequest) Reply.Error!void {
    const a = r.arena;
    if (req.action == .stop) return stop(host, r);
    var p: ?host_mod.Plays.Play = if (isPlay(req.action)) host.plays.begin() else null;
    defer if (p) |*x| x.end();
    const args = switch (try controlArgs(a, req, if (p) |x| x.generation else 0)) {
        .json => |j| j,
        .problem => |why| return r.fail("{t}: {s}", .{ req.action, why }),
    };
    const timeout: Io.Duration = switch (req.action) {
        // A container is read 100 tracks a request.
        .play_next, .play_later => .fromSeconds(120),
        else => .fromSeconds(10),
    };
    // A play makes its page call once a launch's page is ready, and on a reload's new page
    // load, not in its gap, where it would fail as not running and play-next or play-later
    // would drop their songs. It never repairs. The state is read first, as for `am resume`,
    // only to wait out a launch call that hasn't set the launch's nonce yet: then the wait
    // sees the launch.
    if (p) |*x| {
        _ = try host.state(r.arena);
        try host.page.waitOutInFlight(r, x);
        if (!x.send()) return sendState(host, r, try freshSnapshot(host, r.arena));
    }
    const result = try enginePageCall(host, r, req.action.method(), args, timeout);
    if (p) |*x| x.end();
    // Methods answer with a fresh snapshot; anything else leaves the last report.
    try sendState(host, r, if (std.mem.startsWith(u8, result, "{")) result else null);
}

/// The TUI's stop: `am stop`'s (`control.stop`), straight to the page's stop, answered with
/// the state. Plays on their way with no engine or page to stop yet are a stop too; with
/// nothing at all, `not_running`. During a reload the page isn't asked: it answers the last
/// state, whatever was on its way. A page that doesn't answer fails as such.
fn stop(host: Host, r: *Reply) Reply.Error!void {
    switch (try control_mod.stop(host, r, .{ .look_first = false })) {
        .stopped => |s| try sendState(host, r, s.answer),
        // Listed by name: a new reason won't compile until it is handled here.
        .nothing => |why| switch (why) {
            .no_engine, .signin_window, .no_page => return r.fail(not_running, .{}),
        },
    }
}

pub const ItemsRequest = struct {
    offset: u32 = 0,
    limit: u32 = 50,
};

pub const max_items = 200;

/// The `queue-items` endpoint: a window of the engine's queue, as one data line
/// `{"position":p,"length":L,"items":[QueueItem]}`.
pub fn queueItems(host: Host, r: *Reply, req: ItemsRequest) Reply.Error!void {
    const args = try std.json.Stringify.valueAlloc(r.arena, .{ req.offset, @min(req.limit, max_items) }, .{});
    const result = try enginePageCall(host, r, "queueWindow", args, .fromSeconds(10));
    try r.data(if (std.mem.startsWith(u8, result, "{")) result else "{\"position\":-1,\"length\":0,\"items\":[]}");
}

/// A call on the running engine page; `not_running` without one. Returns the result's JSON.
fn enginePageCall(host: Host, r: *Reply, method: []const u8, args: []const u8, timeout: Io.Duration) Reply.Error![]const u8 {
    const s = try host.state(r.arena);
    const engine = s.engine orelse return r.fail(not_running, .{});
    if (engine.signin_window) return r.fail(not_running, .{});
    const result = host.call(r.arena, method, args, timeout) catch |e| switch (e) {
        // The page is still loading, or went away during the call.
        error.NoEnginePage, error.Disconnected => return r.fail(not_running, .{}),
        error.Timeout => return r.fail("the engine page didn't answer {s} within {d} s", .{ method, timeout.toSeconds() }),
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return switch (result) {
        .ok => |json| json,
        .page_error => |message| if (std.mem.eql(u8, message, nothing_queued))
            r.fail(not_running, .{})
        else if (std.mem.eql(u8, message, stopped_before_start))
            // playNext/playLater on an empty queue, or a radio restart, that a stop cancelled:
            // the state after, not an error.
            try freshSnapshot(host, r.arena) orelse "null"
        else
            r.fail("the engine page couldn't {s}: {s}", .{ method, message }),
    };
}

/// The page's snapshot now; null when it doesn't answer with one.
fn freshSnapshot(host: Host, arena: Allocator) (Allocator.Error || Io.Cancelable)!?[]const u8 {
    return host.snapshot(arena, .fromSeconds(5));
}

/// One `State`, with `snapshot` (fresh from the page) in place of the last report if given.
fn sendState(host: Host, r: *Reply, snapshot: ?[]const u8) Reply.Error!void {
    var s = try host.state(r.arena);
    if (snapshot) |json| {
        s.report = json;
        s.report_age_ms = 0;
    }
    try r.data(try stateJson(r.arena, host.build(), s));
}

const testing = std.testing;
const fake = @import("fake_page.zig");
const Fake = host_mod.Fake;
const CallResult = @import("channel.zig").Channel.CallResult;

const chrome: host_mod.EngineState = .{ .kind = "chrome", .pid = 4242, .headless = true, .signin_window = false, .idle_close_in_s = 300 };

/// An endpoint's reply: its text, its data lines and its exit.
const Wire = struct {
    out: []const u8,
    data: []const []const u8,
    code: u8,
    message: ?[]const u8,
};

fn runEndpoint(arena: Allocator, result: anyerror!void, t: *protocol.TestReply) !Wire {
    try t.reply.finish(result);
    var out: Io.Writer.Allocating = .init(arena);
    var data: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, t.wire.written(), '\n');
    while (lines.next()) |line| switch (try protocol.parseLine(arena, line)) {
        .skip => {},
        .out => |text| try out.writer.writeAll(text),
        .data => |json| try data.append(arena, json),
        .exit => |e| return .{ .out = out.written(), .data = data.items, .code = e.code, .message = e.message },
    };
    return error.TestUnexpectedResult;
}

test "state is one data line with the build, the engine and the report verbatim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = "{\"playbackState\":\"playing\",\"volume\":0.15}", .report_age_ms = 420 }} };
    var t: protocol.TestReply = undefined;
    t.init(a);
    const wire = try runEndpoint(a, state(f.host(), &t.reply), &t);
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqualStrings(
        \\{"build":"0123456789abcdef","engine":{"kind":"chrome","pid":4242,"headless":true,"signin_window":false,"idle_close_in_s":300},"report":{"playbackState":"playing","volume":0.15},"report_age_ms":420}
    , wire.data[0]);

    var idle: Fake = .{ .arena = a };
    var t2: protocol.TestReply = undefined;
    t2.init(a);
    const none = try runEndpoint(a, state(idle.host(), &t2.reply), &t2);
    try testing.expectEqualStrings("{\"build\":\"0123456789abcdef\",\"engine\":null,\"report\":null,\"report_age_ms\":0}", none.data[0]);
}

test "watch sends a state now and on every change, not when nothing changed, until the daemon stops" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{
        .arena = a,
        .states = &.{
            .{ .engine = null, .report = null },
            .{ .engine = chrome, .report = null },
            .{ .engine = chrome, .report = "{\"playbackState\":\"playing\"}" },
        },
        // The start; a launch; no change (the wait timed out early); a report; then shutdown.
        .changes = &.{ 0, 1, 1, 2, null },
    };
    var t: protocol.TestReply = undefined;
    t.init(a);
    const wire = try runEndpoint(a, watch(f.host(), testing.io, &t.reply, .{}), &t);
    try testing.expectEqual(@as(u8, 1), wire.code);
    try testing.expectEqualStrings("the background process shut down", wire.message.?);
    try testing.expectEqual(@as(usize, 3), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"engine\":null") != null);
    try testing.expect(std.mem.find(u8, wire.data[1], "\"pid\":4242") != null);
    try testing.expect(std.mem.find(u8, wire.data[2], "\"report\":{\"playbackState\":\"playing\"}") != null);
}

test "watch sends a heartbeat state when nothing changes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .changes = &.{ 5, 5, 5, null } };
    var t: protocol.TestReply = undefined;
    t.init(a);
    const wire = try runEndpoint(a, watch(f.host(), testing.io, &t.reply, .{ .heartbeat = .zero }), &t);
    try testing.expectEqual(@as(usize, 3), wire.data.len);
}

const ready_report =
    \\{"configured":true,"browserSupportsVideoDrm":true,"isAuthorized":true,"storefrontId":"gb","subscriptionActive":true,"load":"l1"}
;
const playing_full =
    \\{"isAuthorized":true,"playbackState":"playing","currentPlaybackTime":0.2,"nowPlaying":{"id":"1440818839","title":"Hey Jude","artist":"The Beatles","playbackType":"encryptedFull","isLive":false,"container":{"type":"albums","id":"1440818588","name":"1"}},"nowPlayingIndex":3,"queue":{"position":3,"length":27,"upcoming":[{"index":4,"id":"1440818840","title":"Get Back","durationSec":191.5,"autoplay":false}]},"shuffle":"off","repeat":"none","autoplay":true,"volume":0.15,"capabilities":{"pause":true,"seek":true,"skipNext":true,"skipPrevious":true,"shuffle":true,"repeat":true,"editQueue":true},"liveInfo":null}
;
const loading = "{\"isAuthorized\":true,\"playbackState\":\"loading\",\"nowPlaying\":null}";

/// The engine page module finds the page ready, as `ready_report` says.
fn queueFake(arena: Allocator, states: []const host_mod.State, play_queue: CallResult) Fake {
    var f: Fake = .{ .arena = arena, .states = states, .calls = arena.dupe(Fake.Call, &.{.{ .method = "playQueue", .results = arena.dupe(CallResult, &.{play_queue}) catch unreachable }}) catch unreachable };
    f.outcomes = arena.dupe(engine_page.Outcome, &.{.{ .report = playback.parseReport(arena, ready_report).?, .verdict = .ready }}) catch unreachable;
    return f;
}

fn runQueue(f: *Fake, arena: Allocator, body: []const u8) !Wire {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    const req = try std.json.parseFromSliceLeaky(QueueRequest, arena, body, .{ .ignore_unknown_fields = true });
    return runEndpoint(arena, queue(f.host(), testing.io, &t.reply, req, .{ .poll = .fromMilliseconds(1) }), &t);
}

test "queue starts the engine, hands the page the request, waits for full playback and ends with the state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Memory check and cold-start check see no engine; then the watch sees it play.
    var f = queueFake(a, &.{ .{ .engine = null, .report = null }, .{ .engine = null, .report = null }, .{ .engine = chrome, .report = loading }, .{ .engine = chrome, .report = playing_full } }, .{ .ok = loading });
    const wire = try runQueue(&f, a,
        \\{"container":{"type":"library-playlists","id":"p.zp6K2avIV1xoDz"},"startIndex":120,"shuffle":false,"repeat":"all","volume":1.5,"junk":1}
    );
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqualStrings("starting the engine…\nengine: chrome (headless), pid 4242 (already running)\n", wire.out);
    try testing.expect(f.wasCalled("playQueue [{\"container\":{\"type\":\"library-playlists\",\"id\":\"p.zp6K2avIV1xoDz\"},\"startIndex\":120,\"shuffle\":false,\"repeat\":\"all\",\"volume\":1},0]"));
    try testing.expectEqual(@as(u64, 1), f.claims);
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"title\":\"Hey Jude\"") != null);
    // The TUI's fields parse.
    const st = try std.json.parseFromSliceLeaky(struct { report: playback.Report }, a, wire.data[0], .{ .ignore_unknown_fields = true });
    try testing.expectEqual(@as(i64, 3), st.report.queue.?.position);
    try testing.expectEqualStrings("Get Back", st.report.queue.?.upcoming[0].title.?);
    try testing.expectEqualStrings("albums", st.report.nowPlaying.?.container.?.type.?);
    try testing.expect(st.report.capabilities.?.editQueue);
}

test "queue returns at once when the page's answer already shows the full track playing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = queueFake(a, &.{.{ .engine = chrome, .report = loading }}, .{ .ok = playing_full });
    const wire = try runQueue(&f, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqualStrings("engine: chrome (headless), pid 4242 (already running)\n", wire.out);
}

test "a queue a stop cancelled while it loaded succeeds with the state, without watching for playback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = queueFake(a, &.{.{ .engine = chrome, .report = loading }}, .{ .page_error = "stopped before it started" });
    const wire = try runQueue(&f, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqual(@as(?[]const u8, null), wire.message);
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"playbackState\":\"loading\"") != null);
}

test "a queue a stop cancelled during the token check or while the engine started never reaches the page and succeeds with the state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = queueFake(a, &.{ .{ .engine = null, .report = null }, .{ .engine = chrome, .report = loading } }, .{ .ok = playing_full });
    f.stop_while_starting = true;
    const wire = try runQueue(&f, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expect(!f.wasCalled("playQueue"));
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expectEqual(@as(usize, 0), f.plays.onTheirWay());

    var checking = queueFake(a, &.{ .{ .engine = null, .report = null }, .{ .engine = chrome, .report = loading } }, .{ .ok = playing_full });
    checking.stop_while_checking_token = true;
    const w = try runQueue(&checking, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 0), w.code);
    // No engine launch for it.
    try testing.expect(!checking.engine_started);
    try testing.expect(!checking.wasCalled("playQueue"));
}

test "a queue a stop cancelled during an engine start that isn't ready answers the state, not the readiness error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cold_snapshot = "{\"configured\":false,\"playbackState\":null,\"nowPlaying\":null}";
    const not_configured: []const engine_page.Outcome = &.{.{ .report = .{ .configureError = "developer token endpoint: HTTP 500" }, .verdict = .{ .not_configured = "developer token endpoint: HTTP 500" } }};
    var f = queueFake(a, &.{ .{ .engine = null, .report = null }, .{ .engine = chrome, .report = null } }, .{ .ok = playing_full });
    f.calls = &.{
        .{ .method = "playQueue", .results = &.{.{ .ok = playing_full }} },
        .{ .method = "snapshot", .results = &.{.{ .ok = cold_snapshot }} },
    };
    f.outcomes = not_configured;
    f.stop_while_starting = true;
    const wire = try runQueue(&f, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqual(@as(?[]const u8, null), wire.message);
    try testing.expect(!f.wasCalled("playQueue"));
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"report\":" ++ cold_snapshot) != null);

    // Not cancelled: the readiness error.
    var not_cancelled = queueFake(a, &.{ .{ .engine = null, .report = null }, .{ .engine = chrome, .report = null } }, .{ .ok = playing_full });
    not_cancelled.outcomes = not_configured;
    const failed = try runQueue(&not_cancelled, a, "{\"songs\":[\"1440818839\"]}");
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expectEqualStrings("MusicKit isn't configured in the engine page: developer token endpoint: HTTP 500", failed.message.?);
}

test "the TUI's stop cancels plays on their way as am stop does, and only once it succeeded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No engine yet: the queue on its way is what it stops.
    var cold: Fake = .{ .arena = a };
    var queued = cold.plays.begin();
    defer queued.end();
    const wire = try runControl(&cold, a, "{\"action\":\"stop\"}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expect(queued.cancelled());
    // Nothing at all: as before.
    var idle: Fake = .{ .arena = a };
    try testing.expectEqualStrings("engine-not-running", (try runControl(&idle, a, "{\"action\":\"stop\"}")).message.?);

    // The page's stop fails: the queue carries on.
    var failing: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{
        .{ .method = "snapshot", .results = &.{.{ .ok = playing_full }} },
        .{ .method = "stop", .results = &.{.{ .page_error = "MusicKit still plays after pause()" }} },
    } };
    var on = failing.plays.begin();
    defer on.end();
    const failed = try runControl(&failing, a, "{\"action\":\"stop\"}");
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expect(!on.cancelled());
    try testing.expect(failing.wasCalled("stop [1]"));
}

test "the TUI's stop with nothing on its way, a sign-in window open or no page connected, answers engine-not-running" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var signin_window = chrome;
    signin_window.signin_window = true;
    for ([_]host_mod.State{ .{ .engine = signin_window, .report = null }, .{ .engine = chrome, .report = null } }) |s| {
        var f: Fake = .{ .arena = a, .states = &.{s} };
        const wire = try runControl(&f, a, "{\"action\":\"stop\"}");
        try testing.expectEqual(@as(u8, 1), wire.code);
        try testing.expectEqualStrings("engine-not-running", wire.message.?);
        try testing.expectEqual(@as(usize, 0), wire.data.len);
    }
}

test "the TUI's stop during a reload cancels the plays on their way without asking the page, and answers the last state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const last = "{\"playbackState\":\"playing\",\"nowPlaying\":null}";
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = last }}, .page_reloading = true, .timeouts = &.{"stop"} };
    var on_its_way = f.plays.begin();
    defer on_its_way.end();
    const wire = try runControl(&f, a, "{\"action\":\"stop\"}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqual(@as(usize, 0), f.called.items.len);
    try testing.expect(on_its_way.cancelled());
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"report\":" ++ last) != null);
}

test "the TUI's stop on a page whose MusicKit isn't configured yet answers that state and cancels the older play" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cold_stop = "{\"configured\":false,\"playbackState\":null,\"nowPlaying\":null,\"cancelled\":0}";
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{
        .{ .method = "stop", .results = &.{.{ .ok = cold_stop }} },
    } };
    var pending = f.plays.begin();
    defer pending.end();
    const wire = try runControl(&f, a, "{\"action\":\"stop\"}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqual(@as(?[]const u8, null), wire.message);
    try testing.expect(f.wasCalled("stop [1]"));
    try testing.expect(pending.cancelled());
    try testing.expectEqual(@as(usize, 1), wire.data.len);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"report\":" ++ cold_stop) != null);
}

test "playNext or playLater that a stop cancelled on an empty queue answers the state, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = loading }}, .calls = &.{
        .{ .method = "playLater", .results = &.{.{ .page_error = "stopped before it started" }} },
        .{ .method = "snapshot", .results = &.{.{ .ok = "{\"playbackState\":\"none\",\"nowPlaying\":null}" }} },
    } };
    const wire = try runControl(&f, a, "{\"action\":\"play_later\",\"value\":{\"songs\":[\"1\"]}}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expectEqual(@as(?[]const u8, null), wire.message);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"playbackState\":\"none\"") != null);
}

test "queue fails on a preview as play does, on a page error, and on a bad request before starting anything" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const preview = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"nowPlaying\":{\"title\":\"Hey Jude\",\"playbackType\":\"preview\"}}";
    var f = queueFake(a, &.{.{ .engine = chrome, .report = preview }}, .{ .ok = "null" });
    const p = try runQueue(&f, a, "{\"station\":\"ra.978194965\"}");
    try testing.expectEqual(@as(u8, 1), p.code);
    try testing.expectEqualStrings("MusicKit is playing the 30 s preview, not the full track; see `am doctor`", p.message.?);
    // The state still goes out: something plays.
    try testing.expectEqual(@as(usize, 1), p.data.len);

    var bad_page = queueFake(a, &.{.{ .engine = chrome, .report = loading }}, .{ .page_error = "NOT_FOUND | One or more items could not be resolved" });
    const e = try runQueue(&bad_page, a, "{\"songs\":[\"1\"]}");
    try testing.expectEqualStrings("the engine page couldn't play that: NOT_FOUND | One or more items could not be resolved", e.message.?);

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{}", "can't queue that: give exactly one of songs, container, station and stationFor" },
        .{ "{\"songs\":[\"1\"],\"station\":\"ra.1\"}", "can't queue that: give exactly one of songs, container, station and stationFor" },
        .{ "{\"songs\":[]}", "can't queue that: no songs given" },
        .{ "{\"stationFor\":{}}", "can't queue that: stationFor needs one of song and artist" },
    };
    for (cases) |case| {
        var bad = queueFake(a, &.{.{ .engine = chrome, .report = loading }}, .{ .ok = "null" });
        const w = try runQueue(&bad, a, case[0]);
        try testing.expectEqualStrings(case[1], w.message.?);
        try testing.expect(!bad.engine_started);
    }
}

fn runControl(f: *Fake, arena: Allocator, body: []const u8) !Wire {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    const req = try std.json.parseFromSliceLeaky(ControlRequest, arena, body, .{ .ignore_unknown_fields = true });
    return runEndpoint(arena, control(f.host(), &t.reply, req), &t);
}

test "control maps each action to its page method with checked arguments, and answers the fresh state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const methods = [_][]const u8{ "toggle", "play", "pause", "stop", "next", "prev", "seek", "seekBy", "setVolume", "setShuffle", "setRepeat", "setAutoplay", "jump", "playNext", "playLater", "removeAt", "clearUpcoming", "snapshot" };
    var calls: [methods.len]Fake.Call = undefined;
    for (&calls, methods) |*c, m| c.* = .{ .method = m, .results = &.{.{ .ok = playing_full }} };
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "{\"action\":\"toggle\"}", "toggle [0]" },
        .{ "{\"action\":\"play\"}", "play [null,0]" },
        .{ "{\"action\":\"stop\"}", "stop [1]" },
        .{ "{\"action\":\"previous\",\"value\":null}", "prev []" },
        .{ "{\"action\":\"seek\",\"value\":62.5}", "seek [62.5]" },
        .{ "{\"action\":\"seek\",\"value\":-3}", "seek [0]" },
        .{ "{\"action\":\"seek_by\",\"value\":-30}", "seekBy [-30]" },
        .{ "{\"action\":\"volume\",\"value\":1.7}", "setVolume [1]" },
        .{ "{\"action\":\"volume\",\"value\":0.15}", "setVolume [0.15]" },
        .{ "{\"action\":\"shuffle\",\"value\":true}", "setShuffle [true]" },
        .{ "{\"action\":\"repeat\",\"value\":\"one\"}", "setRepeat [\"one\"]" },
        .{ "{\"action\":\"jump\",\"value\":12}", "jump [12]" },
        .{ "{\"action\":\"play_later\",\"value\":{\"songs\":[\"i.vMXd5D9UPN0Keo\"]}}", "playLater [{\"songs\":[\"i.vMXd5D9UPN0Keo\"]},0]" },
        .{ "{\"action\":\"play_next\",\"value\":{\"container\":{\"type\":\"albums\",\"id\":\"1440818588\"}}}", "playNext [{\"container\":{\"type\":\"albums\",\"id\":\"1440818588\"}},0]" },
        .{ "{\"action\":\"clear_upcoming\"}", "clearUpcoming []" },
    };
    for (cases) |case| {
        var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = loading }}, .calls = &calls };
        const wire = try runControl(&f, a, case[0]);
        try testing.expectEqual(@as(u8, 0), wire.code);
        try testing.expect(f.wasCalled(case[1]));
        // The page's answer, not the older report.
        try testing.expect(std.mem.find(u8, wire.data[0], "\"report\":{\"isAuthorized\":true,\"playbackState\":\"playing\"") != null);
        try testing.expect(std.mem.find(u8, wire.data[0], "\"report_age_ms\":0") != null);
    }
}

test "control without an engine page fails with engine-not-running; bad values fail before any call" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var signin_window = chrome;
    signin_window.signin_window = true;
    const states = [_]host_mod.State{ .{ .engine = null, .report = null }, .{ .engine = signin_window, .report = null }, .{ .engine = chrome, .report = null } };
    for (states) |s| {
        // The last: an engine whose page hasn't connected (no calls answer).
        var f: Fake = .{ .arena = a, .states = &.{s} };
        const wire = try runControl(&f, a, "{\"action\":\"toggle\"}");
        try testing.expectEqual(@as(u8, 1), wire.code);
        try testing.expectEqualStrings("engine-not-running", wire.message.?);
    }
    // A page that lost its queue (reloaded or relaunched) counts as no engine for play and toggle.
    for ([_][]const u8{ "toggle", "play" }) |method| {
        var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{
            .{ .method = method, .results = &.{.{ .page_error = "nothing-queued" }} },
        } };
        const wire = try runControl(&f, a, try std.fmt.allocPrint(a, "{{\"action\":\"{s}\"}}", .{method}));
        try testing.expectEqualStrings("engine-not-running", wire.message.?);
    }
    // Other page errors pass through.
    var refused: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{
        .{ .method = "playLater", .results = &.{.{ .page_error = "UNSUPPORTED_ERROR" }} },
    } };
    const passed = try runControl(&refused, a, "{\"action\":\"play_later\",\"value\":{\"songs\":[\"1\"]}}");
    try testing.expectEqualStrings("the engine page couldn't playLater: UNSUPPORTED_ERROR", passed.message.?);

    const bad = [_]struct { []const u8, []const u8 }{
        .{ "{\"action\":\"seek\",\"value\":\"soon\"}", "seek: value must be a number of seconds" },
        .{ "{\"action\":\"repeat\",\"value\":\"twice\"}", "repeat: value must be none, one or all" },
        .{ "{\"action\":\"jump\",\"value\":-1}", "jump: value must be a queue index (0 or more)" },
        .{ "{\"action\":\"shuffle\",\"value\":1}", "shuffle: value must be true or false" },
        .{ "{\"action\":\"play_next\",\"value\":{}}", "play_next: give one of songs and container" },
    };
    for (bad) |case| {
        var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }} };
        const wire = try runControl(&f, a, case[0]);
        try testing.expectEqualStrings(case[1], wire.message.?);
        try testing.expectEqual(@as(usize, 0), f.called.items.len);
    }
}

test "a control play (Space, play-next, play-later) joins a reload in flight before its page call and never repairs; other controls don't wait on one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const methods = [_][]const u8{ "toggle", "play", "playNext", "playLater", "pause", "next", "seek", "setVolume" };
    var calls: [methods.len]Fake.Call = undefined;
    for (&calls, methods) |*c, m| c.* = .{ .method = m, .results = &.{.{ .ok = playing_full }} };
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "{\"action\":\"toggle\"}", "toggle [0]", true },
        .{ "{\"action\":\"play\"}", "play [null,0]", true },
        .{ "{\"action\":\"play_next\",\"value\":{\"songs\":[\"1\"]}}", "playNext [{\"songs\":[\"1\"]},0]", true },
        .{ "{\"action\":\"play_later\",\"value\":{\"songs\":[\"1\"]}}", "playLater [{\"songs\":[\"1\"]},0]", true },
        .{ "{\"action\":\"pause\"}", "pause []", false },
        .{ "{\"action\":\"next\"}", "next []", false },
        .{ "{\"action\":\"seek\",\"value\":3}", "seek [3]", false },
        .{ "{\"action\":\"volume\",\"value\":0.5}", "setVolume [0.5]", false },
    };
    for (cases) |case| {
        const body, const call, const joins = case;
        var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = loading }}, .calls = &calls, .join_says = "waiting on the reload\n" };
        const wire = try runControl(&f, a, body);
        try testing.expectEqual(@as(u8, 0), wire.code);
        try testing.expect(f.wasCalled(call));
        try testing.expectEqual(@as(usize, @intFromBool(joins)), f.joins);
        try testing.expectEqualStrings(if (joins) "waiting on the reload\n" else "", wire.out);
        try testing.expectEqual(@as(usize, 0), f.repairs);
        try testing.expect(!f.engine_started);
    }
}

test "a play-next that a stop cancels while it joins a reload sends nothing, and answers the state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = loading }}, .stop_while_joining = true, .calls = &.{
        .{ .method = "playNext", .results = &.{.{ .ok = playing_full }} },
        .{ .method = "snapshot", .results = &.{.{ .ok = playing_full }} },
    } };
    const wire = try runControl(&f, a, "{\"action\":\"play_next\",\"value\":{\"songs\":[\"1\"]}}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expect(!f.wasCalled("playNext"));
    try testing.expectEqual(@as(usize, 1), wire.data.len);
}

/// `control` as the TUI sends it, with `c`'s reply, which says what it printed as it goes
/// (`Caller.printed`).
fn runControlAs(ph: *fake.PageHost, c: *fake.Caller, body: []const u8) !Wire {
    const a = c.t.reply.arena;
    const req = try std.json.parseFromSliceLeaky(ControlRequest, a, body, .{ .ignore_unknown_fields = true });
    return runEndpoint(a, control(ph.host(), &c.t.reply, req), &c.t);
}

/// What the engine page module prints while a control play waits on a launch in flight.
const starting_line = engine_page.starting_line;

/// Space, play-next and play-later as the TUI sends them: the body, its page call, and how it
/// fails on a new page load.
const control_plays = [_]struct { []const u8, []const u8, ?[]const u8 }{
    // A new page has nothing queued: the TUI queues its music again from its resume point.
    .{ "{\"action\":\"toggle\"}", "toggle", not_running },
    .{ "{\"action\":\"play_next\",\"value\":{\"songs\":[\"1561837008\"]}}", "playNext", null },
    .{ "{\"action\":\"play_later\",\"value\":{\"songs\":[\"1561837008\"]}}", "playLater", null },
};

/// What a control play from `control_plays` that waited for the launch got: its page call
/// reached the launch's page load once it was ready, it made no repair and no launch of its own.
fn expectLandedOnLaunch(rig: *fake.Rig, wire: Wire, method: []const u8, failure: ?[]const u8) !void {
    try testing.expectEqualStrings(starting_line ++ "\n", wire.out);
    try testing.expect(rig.fp.calledOn("1", method));
    if (failure) |message| {
        try testing.expectEqual(@as(u8, 1), wire.code);
        try testing.expectEqualStrings(message, wire.message.?);
    } else {
        try testing.expectEqual(@as(u8, 0), wire.code);
        try testing.expectEqual(playback.Music.starting, rig.fp.held());
    }
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads + rig.fp.checks + rig.fp.probes);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
}

test "Space, play-next and play-later during a launch in flight wait for its page, then make their page call instead of failing as not configured" {
    // Before the page connected, and while its MusicKit configures.
    for ([_]fake.FakePage.Op{ .open, .configure }) |held| for (control_plays) |case| {
        const body, const method, const failure = case;
        var rig: fake.Rig = undefined;
        rig.init(fake.Rig.patientLaunch(fake.Rig.timing));
        defer rig.deinit();
        var ph: fake.PageHost = .{ .rig = &rig };
        // `am play` or the TUI's queue launches the engine and waits for its page.
        rig.fp.hold(held, 1);
        var problem: []const u8 = "";
        var starting = try testing.io.concurrent(engine_page.EnginePage.start, .{ &rig.page, rig.newArena(), &problem });
        defer drop(&starting);
        try rig.fp.arrived(held);

        const c = rig.caller();
        var controlling = try testing.io.concurrent(runControlAs, .{ &ph, c, body });
        defer drop(&controlling);
        try c.printed(starting_line);
        rig.fp.release(held, .answer);
        try expectLandedOnLaunch(&rig, try controlling.await(testing.io), method, failure);
        try testing.expect((try starting.await(testing.io)).ready);
    };
}

test "Space, play-next and play-later during the launch call, before it set the launch's nonce, wait out the call and then the launch's page" {
    for (control_plays) |case| {
        const body, const method, const failure = case;
        var rig: fake.Rig = undefined;
        rig.init(fake.Rig.patientLaunch(fake.Rig.timing));
        defer rig.deinit();
        var ph: fake.PageHost = .{ .rig = &rig };
        // The launch call holds the engine and has set no nonce yet, as while it kills a
        // leftover engine: no launch shows on the channel.
        rig.fp.hold(.open, 1);
        rig.launcher.holdLaunch(.before_nonce);
        var problem: []const u8 = "";
        var starting = try testing.io.concurrent(engine_page.EnginePage.start, .{ &rig.page, rig.newArena(), &problem });
        defer drop(&starting);
        try rig.launcher.arrivedLaunch();

        const c = rig.caller();
        var controlling = try testing.io.concurrent(runControlAs, .{ &ph, c, body });
        defer drop(&controlling);
        // It waits on the engine, which the launch call holds, before it looks for a launch.
        try ph.askedState(1);
        rig.launcher.releaseLaunch();
        try c.printed(starting_line);
        rig.fp.release(.open, .answer);
        try expectLandedOnLaunch(&rig, try controlling.await(testing.io), method, failure);
        try testing.expect((try starting.await(testing.io)).ready);
    }
}

test "Space with no engine has no launch to wait for: it fails at once as engine-not-running, for the TUI to queue its music" {
    var rig: fake.Rig = undefined;
    rig.init(fake.Rig.timing);
    defer rig.deinit();
    var ph: fake.PageHost = .{ .rig = &rig };
    const wire = try runControlAs(&ph, rig.caller(), "{\"action\":\"toggle\"}");
    try testing.expectEqualStrings("", wire.out);
    try testing.expectEqualStrings(not_running, wire.message.?);
    try testing.expectEqual(@as(u32, 0), rig.launcher.launches);
}

const drop = fake.drop;

test "a control call the page never answers is in the daemon's log by method and timeout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .timeouts = &.{"stop"}, .calls = &.{
        .{ .method = "snapshot", .results = &.{.{ .ok = playing_full }} },
    } };
    const wire = try runControl(&f, a, "{\"action\":\"stop\"}");
    try testing.expectEqual(@as(u8, 1), wire.code);
    try testing.expectEqualStrings("the engine page didn't answer stop within 10 s", wire.message.?);
    try testing.expectEqual(@as(usize, 1), f.logged.items.len);
    try testing.expectEqualStrings("the engine page didn't answer stop within 10 s", f.logged.items[0]);
}

test "what the page gave up waiting on is logged; the control still answers its state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{
        .{ .method = "next", .results = &.{.{ .ok = "{\"playbackState\":\"paused\",\"gaveUp\":[\"pause() after 2 s\",\"seekToTime(0) after 2 s\"]}" }} },
    } };
    const wire = try runControl(&f, a, "{\"action\":\"next\"}");
    try testing.expectEqual(@as(u8, 0), wire.code);
    try testing.expect(std.mem.find(u8, wire.data[0], "\"playbackState\":\"paused\"") != null);
    try testing.expectEqual(@as(usize, 2), f.logged.items.len);
    try testing.expectEqualStrings("the engine page's next gave up waiting on pause() after 2 s", f.logged.items[0]);
    try testing.expectEqualStrings("the engine page's next gave up waiting on seekToTime(0) after 2 s", f.logged.items[1]);
}

test "queue-items asks the page for a window of at most 200 and passes its answer on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const window = "{\"position\":3,\"length\":27,\"items\":[{\"index\":0,\"id\":\"1\",\"title\":\"A\",\"autoplay\":false}]}";
    var f: Fake = .{ .arena = a, .states = &.{.{ .engine = chrome, .report = null }}, .calls = &.{.{ .method = "queueWindow", .results = &.{ .{ .ok = window }, .{ .ok = "null" } } }} };
    var t: protocol.TestReply = undefined;
    t.init(a);
    const wire = try runEndpoint(a, queueItems(f.host(), &t.reply, .{ .offset = 0, .limit = 500 }), &t);
    try testing.expect(f.wasCalled("queueWindow [0,200]"));
    try testing.expectEqualStrings(window, wire.data[0]);

    var t2: protocol.TestReply = undefined;
    t2.init(a);
    const empty = try runEndpoint(a, queueItems(f.host(), &t2.reply, .{}), &t2);
    try testing.expectEqualStrings("{\"position\":-1,\"length\":0,\"items\":[]}", empty.data[0]);
}
