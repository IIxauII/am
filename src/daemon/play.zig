//! The `play` endpoint: play a song in the engine. Without `--seconds`/`--full` it returns once
//! MusicKit plays, and the music keeps playing in the engine. With them it watches the track and
//! prints the full-track verdict. The CLI dropping the request (Ctrl-C) ends the watch only.
const std = @import("std");
const engine_page = @import("engine_page.zig");
const host_mod = @import("host.zig");
const platform = @import("../platform.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const CallResult = @import("channel.zig").Channel.CallResult;
const Host = host_mod.Host;
const Play = host_mod.Plays.Play;
const Io = std.Io;
const Reply = protocol.Reply;

/// What `am play` sends.
pub const Request = struct {
    /// A catalog song id, or a search term whose first hit plays.
    target: []const u8,
    /// `--seconds N`
    seconds: ?u32 = null,
    /// `--full`
    full: bool = false,
    /// The CLI prints to a terminal: redraw one progress line in place.
    live: bool = false,

    pub fn mode(req: Request) playback.Mode {
        if (req.full) return .full;
        if (req.seconds) |n| return .{ .seconds = n };
        return .until_playing;
    }
};

pub const Options = struct {
    poll: Io.Duration = .fromSeconds(1),
    engineAudio: *const @TypeOf(platform.engineAudio) = platform.engineAudio,
};

/// The engine needs about 0.4-0.55 GiB; starting it into memory pressure risks the OOM killer
/// picking the user's own browser instead.
pub const low_memory_bytes = 700 * 1024 * 1024;

/// Before a cold engine start (none running, or a sign-in window it replaces), warns when memory
/// is short. `doctor` runs it too.
pub fn warnIfLowMemory(host: Host, r: *Reply) Reply.Error!void {
    const state = host.state(r.arena) catch return;
    if (state.engine) |e| if (!e.signin_window) return;
    const available = host.availableMemory() orelse return;
    if (available < low_memory_bytes)
        try r.print("warning: only {d} MiB of memory available; the engine needs about 400-550 MiB\n", .{available / (1024 * 1024)});
}

/// An engine that is ready to play, after `prepare`.
pub const Prepared = struct {
    started: engine_page.Started,
    /// The page's report once MusicKit configured (and saw DRM, if it can).
    ready: playback.Report,
    /// From the Music User Token check.
    storefront: []const u8,
};

pub const PrepareOptions = struct {
    /// Say "starting the engine…" before a cold start.
    announce_start: bool = false,
};

/// Everything before playback: the Music User Token check, the memory warning, the engine
/// start, DRM and MusicKit's authorization. Fails with the same messages `am play` prints.
/// Null when a stop cancelled `play` meanwhile: checked after the token check (no engine
/// launch for it) and after the engine start, before any readiness failure (`startEngine`).
pub fn prepare(host: Host, r: *Reply, play: *const Play, options: PrepareOptions) Reply.Error!?Prepared {
    const storefront = try checkUserToken(host, r);
    if (play.cancelled()) return null;
    var prepared = try startEngine(host, r, play, options) orelse return null;
    if (play.cancelled()) return null;
    prepared.storefront = storefront;
    return prepared;
}

pub fn run(host: Host, io: Io, r: *Reply, request: Request, options: Options) Reply.Error!void {
    const a = r.arena;
    var play = host.plays.begin();
    defer play.end();
    const storefront = try checkUserToken(host, r);
    const song_id = try resolve(host, r, storefront, request.target);
    // A stop before the song started is what the user asked for: said, and not an error.
    if (play.cancelled()) return r.print("{s}\n", .{stopped_before_start});
    const prepared = try startEngine(host, r, &play, .{}) orelse return r.print("{s}\n", .{stopped_before_start});
    const started = prepared.started;
    const ready = prepared.ready;

    const watching: Watching = .{
        .started_at = .now(io, .awake),
        .claim = host.claimPlayback(),
        .engine_pid = started.pid,
        .load = ready.load,
        .play = &play,
    };
    if (!play.send()) return r.print("{s}\n", .{stopped_before_start});
    // The page checks the generation at each step (app.js `load`).
    const args = try std.json.Stringify.valueAlloc(a, .{ song_id, play.generation }, .{});
    const result = try pageCall(host, r, "play", args, .fromSeconds(60));
    play.end();
    switch (result) {
        .ok => {},
        .page_error => |message| if (std.mem.eql(u8, message, stopped_before_start))
            return r.print("{s}\n", .{stopped_before_start})
        else
            return r.fail("the engine page couldn't start playback: {s}", .{message}),
    }

    const mode = request.mode();
    var watch: playback.Watch = .{ .mode = mode };
    var audio: playback.Audio = .not_sampled;
    var footprint_line: ?[]const u8 = null;
    var sampled = false;
    var tick: u32 = 0;
    while (true) : (tick += 1) {
        try io.sleep(options.poll, .awake);
        const more = watch.observe(try sample(host, io, a, watching));
        if (mode != .until_playing) if (watch.last) |last| {
            var line: Io.Writer.Allocating = .init(a);
            try playback.writeProgress(&line.writer, last, watch.now_playing);
            if (request.live) {
                try r.print("\r{s}\x1b[K", .{line.written()});
            } else if (tick % 10 == 0) try r.print("{s}\n", .{line.written()});
            if (more and !sampled and last.state == .playing and (last.currentPlaybackTime orelse 0) > sample_after_seconds) {
                // While audio flows. Takes about a second (the CPU window).
                sampled = true;
                const f = host.footprints(a) catch null;
                if (f) |fp| {
                    footprint_line = if (fp.engine) |e|
                        try a.print("engine footprint: {f}", .{e})
                    else
                        try a.print("engine footprint: can't measure: {s}", .{fp.engine_error orelse "the engine isn't running"});
                    audio = .{ .sampled = try options.engineAudio(a, io, fp.engine_pids) };
                }
            }
        };
        if (!more) break;
    }

    if (request.live and mode != .until_playing) try r.print("\n", .{});
    if (watch.end == .stopped) return r.print("{s}\n", .{stopped_before_start});
    // Without a verdict: what was seen belongs to another play, or to an engine that's gone.
    if (watch.failure) |f| switch (f) {
        .replaced, .engine_restarted => return r.fail("{f}", .{f}),
        else => {},
    };

    if (mode == .until_playing) {
        if (watch.failure) |f| return r.fail("{f}", .{f});
        const np = watch.now_playing orelse return r.fail("playback ended before MusicKit named the song", .{});
        var line: Io.Writer.Allocating = .init(a);
        try playback.writeNowPlaying(&line.writer, watch.last.?, np);
        try r.print("{s}\n", .{line.written()});
        if (playback.isPreview(np)) return r.fail(preview_message, .{});
        return;
    }

    if (watch.end == .limit_reached) _ = host.call(a, "pause", "[]", .fromSeconds(5)) catch {};
    try r.print("\n", .{});
    const ok = try playback.writeVerdict(r, &watch, .{ .drm = ready.browserSupportsVideoDrm, .audio = audio, .footprint = footprint_line });
    if (!ok) return r.fail("the track didn't play in full (see the checks above)", .{});
}

/// A play a stop cancelled before it started (`Plays`): the engine page's error for it (app.js
/// `load`), and what `am play` prints. Not a failure.
pub const stopped_before_start = "stopped before it started";

/// Why playback that started fails anyway.
pub const preview_message = "MusicKit is playing the 30 s preview, not the full track; see `am doctor`";

/// The verify mode samples the footprint and audio once playback has run this long.
const sample_after_seconds = 10;

/// Checks that Apple accepts the Music User Token, and returns its storefront: MusicKit counts
/// any stored string as authorized and would silently play previews.
pub fn checkUserToken(host: Host, r: *Reply) Reply.Error![]const u8 {
    return switch (try host.userTokenStatus(r.arena)) {
        .missing => r.fail("no Music User Token stored: run `am signin` first", .{}),
        .unchecked => |why| r.fail("can't check the Music User Token: {s}", .{why}),
        // 401 is about the developer token; 403 about the Music User Token.
        .checked => |c| if (c.status == 401)
            r.fail("Apple refused the developer token (GET /v1/me/storefront → 401): check it with `am token`", .{})
        else if (c.status != 200)
            r.fail("Apple refused the stored Music User Token (GET /v1/me/storefront → {d}): run `am signin`", .{c.status})
        else
            c.storefront orelse "us",
    };
}

/// Warns about low memory, starts the engine (or finds it running) and has the engine page
/// module repair the page for `play` (`engine_page.zig`): MusicKit configured, DRM, authorized.
/// Null when a stop cancelled `play` meanwhile, in place of a readiness failure: nothing was to
/// play, and the problem shows on the next play or in `am doctor`.
fn startEngine(host: Host, r: *Reply, play: *const Play, options: PrepareOptions) Reply.Error!?Prepared {
    const a = r.arena;
    try warnIfLowMemory(host, r);
    if (options.announce_start) {
        const state = try host.state(a);
        const cold = if (state.engine) |e| e.signin_window else true;
        if (cold) try r.print("starting the engine…\n", .{});
    }
    var problem: []const u8 = "";
    const started = host.page.start(a, &problem) catch |e| switch (e) {
        error.EngineFailed => return r.fail("the engine didn't start: {s}", .{problem}),
        error.Canceled => return error.Canceled,
        else => return r.fail("the engine didn't start: {t}", .{e}),
    };
    try r.print("engine: {s}{s}, pid {d}{s}\n", .{
        started.kind, if (started.headless) " (headless)" else "", started.pid, if (started.started) "" else " (already running)",
    });
    const outcome = try host.page.repair(r, .{ .for_play = play });
    switch (outcome.verdict) {
        .cancelled => return null,
        .not_configured => |why| return r.fail("MusicKit isn't configured in the engine page: {s}", .{why orelse "it didn't load within 90 s"}),
        // Apple accepted the Music User Token, so signing in again won't help.
        .signed_out => return r.fail("MusicKit is not authorized in the engine page, though Apple accepts the Music User Token: try again, or restart the engine (am daemon stop)", .{}),
        .ready => {},
    }
    // Warnings only for a play that goes on, after what the repair said.
    const ready = outcome.report;
    if (ready.browserSupportsVideoDrm != true) try r.print("warning: MusicKit found no usable DRM; expect a 30 s preview\n", .{});
    if (ready.subscriptionActive == false) try r.print("warning: no active Apple Music subscription ({s}); expect a preview\n", .{ready.meError orelse "per /v1/me/account"});
    return .{ .started = started, .ready = ready, .storefront = "" };
}

/// The song id to play: `target` itself, or the first hit of a search for it.
fn resolve(host: Host, r: *Reply, storefront: []const u8, target: []const u8) Reply.Error![]const u8 {
    const a = r.arena;
    if (isSongId(target)) return target;

    const result = switch (try host.search(a, storefront, target)) {
        .result => |result| result,
        .problem => |why| return r.fail("search failed: {s}", .{why}),
    };
    const songs = switch (result) {
        .failed => |response| return r.fail("search failed: HTTP {d} {s}", .{ response.status, response.excerpt(300) }),
        .songs => |songs| songs,
    };
    if (songs.len == 0) return r.fail("no song found for \"{s}\" [{s}]", .{ target, storefront });
    const hit = songs[0];
    try r.print("search \"{s}\" → {s}: {s} — {s} ({f})\n", .{
        target, hit.id, hit.name, hit.artist, playback.Time{ .seconds = if (hit.duration_ms) |ms| @as(f64, @floatFromInt(ms)) / 1000 else null },
    });
    return hit.id;
}

fn isSongId(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// A page call whose transport problems end the endpoint (`failPageCall`).
pub fn pageCall(host: Host, r: *Reply, method: []const u8, args_json: []const u8, timeout: Io.Duration) Reply.Error!CallResult {
    return host.call(r.arena, method, args_json, timeout) catch |e| failPageCall(r, e, method, timeout);
}

/// Ends the endpoint over a page call that got no answer (no page, a page gone or silent): what
/// `am play`, `am pause`, `am resume`, `am stop` and the TUI's `queue` and stop say for it.
pub fn failPageCall(r: *Reply, e: Host.CallError, method: []const u8, timeout: Io.Duration) Reply.Error {
    return switch (e) {
        error.NoEnginePage => r.fail("no engine page is connected", .{}),
        error.Disconnected => r.fail("the engine page disconnected before answering {s}", .{method}),
        error.Timeout => r.fail("the engine page didn't answer {s} within {d} s", .{ method, timeout.toSeconds() }),
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// What a watch compares each look at the engine against.
pub const Watching = struct {
    started_at: Io.Clock.Timestamp,
    claim: u64,
    engine_pid: platform.ProcessId,
    /// The page load that got `play`.
    load: ?[]const u8,
    /// The play, for whether a stop since cancelled it: the page may have answered just before
    /// the stop, with the music not started yet.
    play: ?*const Play = null,

    fn stopped(w: Watching) bool {
        return if (w.play) |p| p.cancelled() else false;
    }
};

/// Watches until MusicKit plays and names the playback type, or the watch fails. `first` is a
/// snapshot the page just returned, looked at before the first poll.
pub fn untilPlaying(host: Host, io: Io, arena: Allocator, watching: Watching, first: ?playback.Report, poll: Io.Duration) Reply.Error!playback.Watch {
    var watch: playback.Watch = .{ .mode = .until_playing };
    if (first) |report| if (!watch.observe(.{ .report = report, .elapsed_ms = 0, .replaced = host.playbackClaim() != watching.claim, .stopped = watching.stopped() })) return watch;
    while (true) {
        try io.sleep(poll, .awake);
        if (!watch.observe(try sample(host, io, arena, watching))) return watch;
    }
}

/// The latest report, how old it is, and whether the engine (the same one) still runs.
fn sample(host: Host, io: Io, arena: Allocator, w: Watching) Reply.Error!playback.Sample {
    const elapsed_ms: u64 = @intCast(@max(0, w.started_at.untilNow(io).raw.toMilliseconds()));
    const state = try host.state(arena);
    const report = playback.parseReport(arena, state.report);
    const reloaded = if (report) |rep| if (rep.load) |now| if (w.load) |then| !std.mem.eql(u8, now, then) else false else false else false;
    return .{
        .report = report,
        .report_age_ms = state.report_age_ms,
        .engine_running = if (state.engine) |e| !e.signin_window else false,
        .engine_restarted = reloaded or if (state.engine) |e| e.pid != w.engine_pid else false,
        .replaced = host.playbackClaim() != w.claim,
        .stopped = w.stopped(),
        .elapsed_ms = elapsed_ms,
    };
}

const testing = std.testing;
const Fake = host_mod.Fake;

const ready_report =
    \\{"configured":true,"musicKitVersion":"3.2526.0","browserSupportsVideoDrm":true,"isAuthorized":true,"storefrontId":"gb","subscriptionActive":true,
    \\"developerToken":{"kid":"KEY","exp":1793604800,"hash":"c0ffee00c0ffee00"}}
;
/// The first report of the page load after a reload.
const reloaded_report =
    \\{"configured":true,"browserSupportsVideoDrm":true,"isAuthorized":true,"storefrontId":"gb","subscriptionActive":true,"load":"new",
    \\"developerToken":{"kid":"KEY","exp":1793604800,"hash":"c0ffee00c0ffee00"}}
;
const chrome: host_mod.EngineState = .{ .kind = "chrome", .pid = 4242, .headless = true, .signin_window = false, .idle_close_in_s = 300 };

fn at(comptime report: []const u8) host_mod.State {
    return .{ .engine = chrome, .report = report, .report_age_ms = 400 };
}

const loading = at("{\"isAuthorized\":true,\"playbackState\":\"loading\",\"currentPlaybackTime\":0,\"nowPlaying\":null}");
const playing = at(
    \\{"isAuthorized":true,"playbackState":"playing","currentPlaybackTime":0.3,"currentPlaybackDuration":175,
    \\"nowPlaying":{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"encryptedFull"}}
);
const playing_preview = at(
    \\{"isAuthorized":true,"playbackState":"playing","currentPlaybackTime":0.3,"currentPlaybackDuration":30,
    \\"nowPlaying":{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"preview"}}
);
const played_ok: CallResult = .{ .ok = "{\"playbackState\":\"loading\"}" };

/// The engine page module finds the page ready, as `ready_report` says.
fn fake(arena: Allocator, states: []const host_mod.State, calls: []const Fake.Call) Fake {
    var f: Fake = .{ .arena = arena, .states = states, .calls = calls };
    f.outcomes = canned(arena, &.{.{ .report = parsed(arena, ready_report), .verdict = .ready }});
    return f;
}

fn parsed(arena: Allocator, json: []const u8) playback.Report {
    return playback.parseReport(arena, json) orelse @panic("not a report");
}

/// What the canned engine page's `repair` answers, in turn.
fn canned(arena: Allocator, outcomes: []const engine_page.Outcome) []const engine_page.Outcome {
    return arena.dupe(engine_page.Outcome, outcomes) catch @panic("out of memory");
}

fn runPlay(f: *Fake, arena: Allocator, request: Request) !protocol.TestReply.Printed {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    return t.finish(run(f.host(), testing.io, &t.reply, request, .{ .poll = .fromMilliseconds(1), .engineAudio = noAudioCheck }));
}

fn noAudioCheck(_: Allocator, _: Io, _: []const platform.ProcessId) Allocator.Error!platform.EngineAudio {
    return .{ .unsupported = "not checked here" };
}

test "without flags, play returns once MusicKit plays the full track, and leaves it playing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // The first state is the cold-start check; then loading twice, then playing.
    var f = fake(arena.allocator(), &.{ at(ready_report), loading, loading, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(
        \\engine: chrome (headless), pid 4242 (already running)
        \\▶ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]
        \\
    , printed.out);
    // With its generation, for the page to check against the stops since.
    try testing.expect(f.wasCalled("play [\"1561837008\",0]"));
    // Nothing paused or stopped it: the music keeps playing in the engine.
    try testing.expect(!f.wasCalled("pause"));
    try testing.expect(!f.wasCalled("stop"));
}

test "a stop before the song starts, during the token check, while the engine starts or in the page, ends play with that said, not an error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var checking = fake(arena.allocator(), &.{ at(ready_report), playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    checking.stop_while_checking_token = true;
    const before_engine = try runPlay(&checking, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), before_engine.code);
    try testing.expectEqualStrings("stopped before it started\n", before_engine.out);
    // No engine launch for a play that won't start.
    try testing.expect(!checking.engine_started);

    var starting = fake(arena.allocator(), &.{ at(ready_report), playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    starting.stop_while_starting = true;
    const before_page = try runPlay(&starting, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), before_page.code);
    try testing.expect(std.mem.endsWith(u8, before_page.out, "stopped before it started\n"));
    try testing.expect(!starting.wasCalled("play"));
    try testing.expectEqual(@as(usize, 0), starting.plays.onTheirWay());

    var in_page = fake(arena.allocator(), &.{ at(ready_report), playing }, &.{.{ .method = "play", .results = &.{.{ .page_error = "stopped before it started" }} }});
    const printed = try runPlay(&in_page, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expect(std.mem.endsWith(u8, printed.out, "stopped before it started\n"));
    try testing.expectEqualStrings("", printed.err);
}

test "a play a stop cancelled during the engine start or the page's repair ends as stopped, not as an engine that isn't ready; one not cancelled still fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const signed_out: playback.Report = .{ .configured = true, .browserSupportsVideoDrm = true, .isAuthorized = false };
    // What the engine page module found, and the error a play that wasn't stopped gives for it.
    const unready = [_]struct { engine_page.Outcome, []const u8 }{
        .{ .{ .report = .{ .configureError = "developer token endpoint: HTTP 500" }, .verdict = .{ .not_configured = "developer token endpoint: HTTP 500" } }, "error: MusicKit isn't configured in the engine page: developer token endpoint: HTTP 500\n" },
        // MusicKit hadn't configured by the launch wait, and gave no error.
        .{ .{ .report = .{}, .verdict = .{ .not_configured = null } }, "error: MusicKit isn't configured in the engine page: it didn't load within 90 s\n" },
        .{ .{ .report = signed_out, .verdict = .signed_out }, "error: MusicKit is not authorized in the engine page, though Apple accepts the Music User Token: try again, or restart the engine (am daemon stop)\n" },
        .{ .{ .report = .{}, .verdict = .{ .not_configured = "the reloaded engine page didn't configure MusicKit within 60 s" } }, "error: MusicKit isn't configured in the engine page: the reloaded engine page didn't configure MusicKit within 60 s\n" },
    };
    for (unready) |case| {
        const outcome, const failure = case;
        for ([_]enum { starting, repairing }{ .starting, .repairing }) |when| {
            var stopped = fake(a, &.{ at(ready_report), playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
            stopped.outcomes = canned(a, &.{outcome});
            switch (when) {
                .starting => stopped.stop_while_starting = true,
                .repairing => stopped.stop_while_repairing = true,
            }
            const printed = try runPlay(&stopped, a, .{ .target = "1561837008" });
            try testing.expectEqual(@as(u8, 0), printed.code);
            try testing.expectEqualStrings("", printed.err);
            try testing.expectEqualStrings("engine: chrome (headless), pid 4242 (already running)\nstopped before it started\n", printed.out);
            try testing.expect(!stopped.wasCalled("play"));
        }

        var not_stopped = fake(a, &.{ at(ready_report), playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
        not_stopped.outcomes = canned(a, &.{outcome});
        const failed = try runPlay(&not_stopped, a, .{ .target = "1561837008" });
        try testing.expectEqual(@as(u8, 1), failed.code);
        try testing.expectEqualStrings(failure, failed.err);
        try testing.expect(!not_stopped.wasCalled("play"));
    }
}

test "a stop just after the page answered, before the music started, ends play as stopped at its next look, not 30 s later as never started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{ at(ready_report), loading }, &.{.{ .method = "play", .results = &.{played_ok} }});
    // The memory check is the first look; the watch's first is the second.
    f.stop_at_state = 1;
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings("engine: chrome (headless), pid 4242 (already running)\nstopped before it started\n", printed.out);
    try testing.expectEqual(@as(usize, 2), f.state_hits);
}

test "without flags, a preview is printed and fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{playing_preview}, &.{.{ .method = "play", .results = &.{played_ok} }});
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expect(std.mem.endsWith(u8, printed.out, "▶ Shy Away — Twenty One Pilots  0:00 / 0:30  [preview]\n"));
    try testing.expectEqualStrings("error: MusicKit is playing the 30 s preview, not the full track; see `am doctor`\n", printed.err);
}

test "a page that stops reporting fails the watch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var stale = at(
        \\{"isAuthorized":true,"playbackState":"playing","currentPlaybackTime":12,"nowPlaying":{"title":"Shy Away","playbackType":"encryptedFull"}}
    );
    stale.report_age_ms = 25_000;
    var f = fake(arena.allocator(), &.{ loading, loading, stale }, &.{.{ .method = "play", .results = &.{played_ok} }});
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008", .full = true });
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expect(std.mem.find(u8, printed.out, "✘ the engine page stopped reporting for 25 s\n") != null);
}

test "an engine page that can't play, or isn't signed in, fails before watching" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{loading}, &.{.{ .method = "play", .results = &.{.{ .page_error = "MEDIA_KEY | 190121 | WIDEVINE_CDM_EXPIRED" }} }});
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqualStrings("error: the engine page couldn't start playback: MEDIA_KEY | 190121 | WIDEVINE_CDM_EXPIRED\n", printed.err);

    // Signed out, also after the engine page module's reload: Apple accepted the Music User
    // Token, so the message doesn't send the user to `am signin`.
    var unauthorized = fake(arena.allocator(), &.{loading}, &.{});
    unauthorized.outcomes = canned(arena.allocator(), &.{.{ .report = .{ .configured = true, .browserSupportsVideoDrm = true, .isAuthorized = false, .load = "2" }, .verdict = .signed_out }});
    const u = try runPlay(&unauthorized, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqualStrings("error: MusicKit is not authorized in the engine page, though Apple accepts the Music User Token: try again, or restart the engine (am daemon stop)\n", u.err);
    try testing.expect(!unauthorized.wasCalled("play"));

    // A reload that doesn't come back: not configured, nothing played.
    var gone = fake(arena.allocator(), &.{loading}, &.{});
    gone.outcomes = canned(arena.allocator(), &.{.{ .report = .{}, .verdict = .{ .not_configured = "the reloaded engine page didn't configure MusicKit within 60 s" } }});
    const g = try runPlay(&gone, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqualStrings("error: MusicKit isn't configured in the engine page: the reloaded engine page didn't configure MusicKit within 60 s\n", g.err);
    try testing.expect(!gone.wasCalled("play"));
}

test "a play prints what the page's repair says between the engine line and the song" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake(a, &.{ at(ready_report), loading, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    f.says = "MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens\n";
    f.outcomes = canned(a, &.{.{ .report = parsed(a, reloaded_report), .verdict = .ready }});
    const printed = try runPlay(&f, a, .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(
        \\engine: chrome (headless), pid 4242 (already running)
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\▶ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]
        \\
    , printed.out);
    try testing.expectEqual(@as(usize, 1), f.repairs);
    try testing.expect(f.wasCalled("play [\"1561837008\",0]"));
}

test "the DRM warning comes after what the page's repair said, and only for a play that goes on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Widevine never came, and the page was reloaded for its sign-out: the new load has no DRM
    // either, and plays.
    var f = fake(a, &.{ at(ready_report), loading, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    f.says =
        \\Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 180 s for the browser to install it…
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\
    ;
    f.outcomes = canned(a, &.{.{ .report = .{ .configured = true, .browserSupportsVideoDrm = false, .isAuthorized = true }, .verdict = .ready }});
    const printed = try runPlay(&f, a, .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(
        \\engine: chrome (headless), pid 4242 (already running)
        \\Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 180 s for the browser to install it…
        \\MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens
        \\warning: MusicKit found no usable DRM; expect a 30 s preview
        \\▶ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]
        \\
    , printed.out);

    // Still signed out: the play fails, with no warning about a preview it won't play.
    var signed_out = fake(a, &.{ at(ready_report), loading, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    signed_out.outcomes = canned(a, &.{.{ .report = .{ .configured = true, .browserSupportsVideoDrm = false }, .verdict = .signed_out }});
    const failed = try runPlay(&signed_out, a, .{ .target = "1561837008" });
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expectEqualStrings("engine: chrome (headless), pid 4242 (already running)\n", failed.out);
    try testing.expectEqualStrings("error: MusicKit is not authorized in the engine page, though Apple accepts the Music User Token: try again, or restart the engine (am daemon stop)\n", failed.err);
}

test "--seconds N watches, samples the footprint, pauses after N seconds and prints the verdict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const at11 = at(
        \\{"isAuthorized":true,"playbackState":"playing","currentPlaybackTime":11,"currentPlaybackDuration":175,
        \\"nowPlaying":{"title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"encryptedFull"},
        \\"mediaElement":{"blobSrc":true,"mediaKeys":true}}
    );
    var f = fake(arena.allocator(), &.{ loading, loading, at11 }, &.{
        .{ .method = "play", .results = &.{played_ok} },
        .{ .method = "pause", .results = &.{.{ .ok = "null" }} },
    });
    f.footprint = .{
        .daemon_pid = 1,
        .daemon = .{},
        .engine_pids = &.{ 4242, 4243 },
        .engine = .{ .processes = 2, .memory_bytes = 450 * 1024 * 1024, .memory = .phys_footprint, .cpu_percent = 12.5 },
    };
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008", .seconds = 1 });
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expect(f.wasCalled("pause"));
    try testing.expect(std.mem.endsWith(u8, printed.out,
        \\
        \\✔ MusicKit sees DRM support
        \\✔ playbackType = encryptedFull (encryptedFull = full track; preview = 30 s clip)
        \\✔ media element: MSE blob src true, MediaKeys attached true
        \\? playback reached 0:11 of 2:55 (previews stop at 0:30, sometimes 1:30); stopped watching before a preview would have ended
        \\? engine audio stream: not checked here
        \\engine footprint: 2 processes, 450 MiB phys_footprint, CPU 12.5% of one core
        \\
    ));
}

test "without a stored Music User Token, or one Apple refuses, play fails before starting the engine" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { host_mod.TokenStatus, []const u8 }{
        .{ .missing, "error: no Music User Token stored: run `am signin` first\n" },
        .{ .{ .unchecked = "developer token missing: run am token --key-stdin" }, "error: can't check the Music User Token: developer token missing: run am token --key-stdin\n" },
        .{ .{ .checked = .{ .status = 403, .storefront = null } }, "error: Apple refused the stored Music User Token (GET /v1/me/storefront → 403): run `am signin`\n" },
        .{ .{ .checked = .{ .status = 401, .storefront = null } }, "error: Apple refused the developer token (GET /v1/me/storefront → 401): check it with `am token`\n" },
    };
    for (cases) |case| {
        var f = fake(arena.allocator(), &.{loading}, &.{.{ .method = "play", .results = &.{played_ok} }});
        f.token = case[0];
        const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
        try testing.expectEqual(@as(u8, 1), printed.code);
        try testing.expectEqualStrings(case[1], printed.err);
        try testing.expect(!f.engine_started);
    }
}

test "a term plays its first hit; no hit fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{playing}, &.{.{ .method = "play", .results = &.{played_ok} }});
    f.search_result = .{ .result = .{ .songs = &.{.{ .id = "1561837008", .name = "Shy Away", .artist = "Twenty One Pilots", .album = "Scaled and Icy", .duration_ms = 175000, .storefront = "gb" }} } };
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "shy away" });
    try testing.expect(std.mem.startsWith(u8, printed.out, "search \"shy away\" → 1561837008: Shy Away — Twenty One Pilots (2:55)\n"));
    try testing.expect(f.wasCalled("play [\"1561837008\",0]"));

    var none = fake(arena.allocator(), &.{playing}, &.{});
    none.token = .{ .checked = .{ .status = 200, .storefront = "gb" } };
    const n = try runPlay(&none, arena.allocator(), .{ .target = "zzzz" });
    try testing.expectEqualStrings("error: no song found for \"zzzz\" [gb]\n", n.err);

    // Apple accepted the token but named no storefront: the search falls back to us.
    var unnamed = fake(arena.allocator(), &.{playing}, &.{});
    unnamed.token = .{ .checked = .{ .status = 200, .storefront = null } };
    const u = try runPlay(&unnamed, arena.allocator(), .{ .target = "zzzz" });
    try testing.expectEqualStrings("error: no song found for \"zzzz\" [us]\n", u.err);
}

test "a cold start into low memory warns first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{ .{ .engine = null, .report = null }, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    f.available = 512 * 1024 * 1024;
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expect(std.mem.startsWith(u8, printed.out, "warning: only 512 MiB of memory available; the engine needs about 400-550 MiB\nengine: chrome"));
}

test "a second play takes over: the first watcher says so, with nobody's verdict" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f = fake(arena.allocator(), &.{ loading, playing }, &.{.{ .method = "play", .results = &.{played_ok} }});
    // From the third look at the engine on, another `am play` holds it.
    f.claim_taken_at_state = 2;
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008", .full = true });
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("error: replaced by another am play\n", printed.err);
    try testing.expect(std.mem.find(u8, printed.out, "playbackType =") == null);
    try testing.expect(!f.wasCalled("pause"));
}

test "an engine relaunch while watching fails at once, not as never started 30 s later" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var relaunched = loading;
    relaunched.engine.?.pid = 5151;
    var f = fake(arena.allocator(), &.{ loading, loading, relaunched }, &.{.{ .method = "play", .results = &.{played_ok} }});
    const start: Io.Clock.Timestamp = .now(testing.io, .awake);
    const printed = try runPlay(&f, arena.allocator(), .{ .target = "1561837008" });
    try testing.expectEqualStrings("error: the engine restarted during playback (another command, or a crash, started it again)\n", printed.err);
    try testing.expect(start.untilNow(testing.io).raw.toSeconds() < 5);
}
