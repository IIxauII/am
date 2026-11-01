//! What `am play` and `am status` make of the engine page's reports: the now-playing line, the
//! watch over a track (when it has started, ended or gone wrong) and the full-track verdict;
//! and what the page holds (`Music`), the one rule `am stop`, `am pause`, `am status`, the
//! engine page module (`daemon/engine_page.zig`: `am doctor`'s repair if idle and the sign-in)
//! and the daemon's exit, sign-in window and idle close ask. No I/O: the commands feed it
//! reports and print what it says.
const std = @import("std");
const platform = @import("platform.zig");
const protocol = @import("daemon/protocol.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reply = protocol.Reply;

/// The engine page's report (`snapshot()` in `poc/web/app.js`), as far as `am` reads it.
pub const Report = struct {
    /// Per page load: a reload keeps the launch's nonce but gets a new one.
    load: ?[]const u8 = null,
    configured: bool = false,
    configureError: ?[]const u8 = null,
    /// The developer token MusicKit was configured with; null from an older page.
    developerToken: ?TokenId = null,
    /// The Music User Token MusicKit holds now; null when it holds none, when the browser
    /// can't hash it, and from an older page.
    musicUserToken: ?TokenId = null,
    musicKitVersion: ?[]const u8 = null,
    browserSupportsVideoDrm: ?bool = null,
    isAuthorized: bool = false,
    storefrontId: ?[]const u8 = null,
    subscriptionActive: ?bool = null,
    meError: ?[]const u8 = null,
    userAgent: ?[]const u8 = null,
    webdriver: ?bool = null,
    /// MusicKit's name for it, as sent; `state` is the same, parsed.
    playbackState: ?[]const u8 = null,
    /// Not in the page's JSON: `parseReport` fills it from `playbackState`.
    state: PlaybackState = .unknown,
    currentPlaybackTime: ?f64 = null,
    currentPlaybackDuration: ?f64 = null,
    nowPlaying: ?NowPlaying = null,
    mediaElement: ?MediaElement = null,
    lastEvents: []const Event = &.{},
    /// A queue is loading in the page (API reads, setQueue, play()); a stop cancels it.
    loadPending: bool = false,
    /// Live radio that `stop` or `pause` stopped: MusicKit has dropped the item, and the page's
    /// `resume` queues the station again. Null when there is none, or from an older page.
    stoppedLive: ?StoppedLive = null,

    // For the TUI. Every field is optional: an older engine page sends none of them.

    /// The queue position of `nowPlaying`; -1 when there is none.
    nowPlayingIndex: ?i64 = null,
    isPlaying: ?bool = null,
    /// 0 to 1.
    volume: ?f64 = null,
    /// `off` or `songs`.
    shuffle: ?[]const u8 = null,
    /// `none`, `one` or `all`.
    repeat: ?[]const u8 = null,
    autoplay: ?bool = null,
    queue: ?Queue = null,
    capabilities: ?Capabilities = null,
    /// The song on live radio, from its timed metadata.
    liveInfo: ?LiveInfo = null,

    /// What the page holds (`Music`). The first rule that matches decides: MusicKit's state
    /// when it plays or is about to, then `isPlaying` under any other state (live radio whose
    /// state MusicKit doesn't name), then a queue on its way, an item, stopped live radio. An
    /// older page that sends no `isPlaying`, `loadPending` or `stoppedLive` is judged by its
    /// state and item.
    pub fn music(r: Report) Music {
        switch (r.state) {
            .playing => return .playing,
            .loading, .seeking, .waiting, .stalled => return .starting,
            .none, .paused, .stopped, .ended, .completed, .unknown => {},
        }
        if (r.isPlaying == true) return .playing;
        if (r.loadPending) return .starting;
        if (r.nowPlaying != null) return .paused;
        if (r.stoppedLive != null) return .stopped_live;
        return .none;
    }

    /// MusicKit has configured, or failed to: the page load is as far as it gets by itself.
    pub fn configureDone(r: Report) bool {
        return r.configured or r.configureError != null;
    }

    /// What a reload of the engine page would lose: anything it holds. The engine page module
    /// asks this before `am doctor`'s repair if idle and the sign-in's reload.
    pub fn holdsMusic(r: Report) bool {
        return switch (r.music()) {
            .none => false,
            .playing, .starting, .paused, .stopped_live => true,
        };
    }
};

/// What the engine page holds, as far as a reload, a stop or pause, the daemon's exit, a sign-in
/// window or the engine's idle close cares (`Report.music`). Each of them reaches it through a
/// switch with no default branch, its own or that of `Report.holdsMusic`, `keepsEngineOpen` or
/// `plays`, so a class added here makes every one of them decide what it means.
pub const Music = enum {
    /// Nothing a reload would lose: no item, no queue on its way, no stopped station.
    none,
    /// MusicKit plays: its state says so, or `isPlaying` does under another state.
    playing,
    /// About to play: MusicKit loads, seeks, waits or stalls, or a queue is on its way (also
    /// one that replaces a paused song).
    starting,
    /// An item is loaded and silent: paused, rewound to 0:00 by `am stop`, or left in place
    /// after it ended.
    paused,
    /// Live radio that `stop` or `pause` stopped: MusicKit dropped it, and `resume` queues it
    /// again.
    stopped_live,

    /// The class in plain words, for `daemon.log`.
    pub fn format(m: Music, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(switch (m) {
            .none => "nothing",
            .playing => "music that plays",
            .starting => "a song on its way",
            .paused => "a paused song",
            .stopped_live => "stopped live radio",
        });
    }

    /// Whether the engine's idle close counts it as something playing, and `am status` says the
    /// engine stays open: only music that plays. A song on its way that outlives the request
    /// that sent it still gets the whole idle limit to start, counted from when that request
    /// ended; a queue that never starts must not hold the engine open for good.
    pub fn keepsEngineOpen(m: Music) bool {
        return switch (m) {
            .playing => true,
            .starting, .paused, .stopped_live, .none => false,
        };
    }

    /// Whether it is heard: what a pause or stop the page answered must not leave by the next
    /// look (`am pause`, `am stop`). Music on its way isn't heard yet, so it doesn't fail them.
    pub fn plays(m: Music) bool {
        return switch (m) {
            .playing => true,
            .starting, .paused, .stopped_live, .none => false,
        };
    }
};

/// Which developer token (app.js `tokenId`): the first 8 bytes of its SHA-256 in hex. The engine
/// page reports its own this way, never the token (with its `kid` and `exp`, for people reading
/// the report); null when the browser couldn't hash it.
pub const TokenId = struct {
    hash: ?[]const u8 = null,

    /// The hash of `token`, in `arena`.
    pub fn of(arena: Allocator, token: []const u8) Allocator.Error!TokenId {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
        return .{ .hash = try arena.dupe(u8, &std.fmt.bytesToHex(digest[0..8].*, .lower)) };
    }

    /// The same token: the hash says it. Without one, never.
    pub fn eql(a: TokenId, b: TokenId) bool {
        const x = a.hash orelse return false;
        const y = b.hash orelse return false;
        return x.len > 0 and std.mem.eql(u8, x, y);
    }
};

pub const NowPlaying = struct {
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    catalogDurationSec: ?f64 = null,
    /// `encryptedFull` proves a full track; `preview` is MusicKit's silent 30 s fallback.
    playbackType: ?[]const u8 = null,
    /// The catalog id of a library item (favorites and ratings need it).
    catalogId: ?[]const u8 = null,
    album: ?[]const u8 = null,
    /// A template with `{w}` and `{h}`, or a plain URL.
    artworkUrl: ?[]const u8 = null,
    isLive: bool = false,
    /// The album, playlist or station it plays from.
    container: ?Container = null,
};

pub const StoppedLive = struct {
    id: []const u8,
    /// The station's name when it was stopped, if MusicKit had one.
    name: ?[]const u8 = null,
};

pub const Container = struct {
    type: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const Queue = struct {
    position: i64 = -1,
    length: u32 = 0,
    /// Up to 20 items after the current one.
    upcoming: []const QueueItem = &.{},
};

pub const QueueItem = struct {
    index: u32 = 0,
    id: ?[]const u8 = null,
    /// The catalog id of a library item, as in `NowPlaying`.
    catalogId: ?[]const u8 = null,
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
    durationSec: ?f64 = null,
    artworkUrl: ?[]const u8 = null,
    /// Added by autoplay rather than by the user.
    autoplay: bool = false,
};

/// What MusicKit allows for the current item (live radio allows little).
pub const Capabilities = struct {
    pause: bool = true,
    seek: bool = true,
    skipNext: bool = true,
    skipPrevious: bool = true,
    shuffle: bool = true,
    repeat: bool = true,
    editQueue: bool = true,
};

pub const LiveInfo = struct {
    title: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    album: ?[]const u8 = null,
};

pub const MediaElement = struct {
    blobSrc: bool = false,
    mediaKeys: bool = false,
};

pub const Event = struct {
    t: ?[]const u8 = null,
    type: []const u8 = "",
    detail: ?std.json.Value = null,
};

/// `MusicKit.PlaybackStates`, plus `unknown` for none or a name we don't know.
pub const PlaybackState = enum { none, loading, playing, paused, stopped, ended, seeking, waiting, stalled, completed, unknown };

/// Null when there is no report or `json` isn't one.
pub fn parseReport(arena: Allocator, json: ?[]const u8) ?Report {
    var report = std.json.parseFromSliceLeaky(Report, arena, json orelse return null, .{ .ignore_unknown_fields = true }) catch return null;
    report.state = std.meta.stringToEnum(PlaybackState, report.playbackState orelse "") orelse .unknown;
    return report;
}

/// A report older than this during playback means the engine page is stuck or gone.
pub const stale_after_ms = 20_000;
/// How long MusicKit gets to start playing after `play`.
pub const start_timeout_ms = 30_000;

pub fn isPreview(np: ?NowPlaying) bool {
    const n = np orelse return false;
    return std.mem.eql(u8, n.playbackType orelse "", "preview");
}

pub fn isFullTrack(np: ?NowPlaying) bool {
    const n = np orelse return false;
    return std.mem.eql(u8, n.playbackType orelse "", "encryptedFull");
}

/// `m:ss`, or `–:––` when unknown.
pub const Time = struct {
    seconds: ?f64,

    pub fn format(t: Time, w: *Io.Writer) Io.Writer.Error!void {
        const s = t.seconds orelse return w.writeAll("–:––");
        if (!std.math.isFinite(s) or s < 0) return w.writeAll("–:––");
        const whole: u64 = @intFromFloat(@floor(s));
        try w.print("{d}:{d:0>2}", .{ whole / 60, whole % 60 });
    }
};

fn duration(report: Report, np: ?NowPlaying) ?f64 {
    if (report.currentPlaybackDuration) |d| if (d > 0) return d;
    return if (np) |n| n.catalogDurationSec else null;
}

/// `▶ title — artist  0:42 / 2:55  [encryptedFull]`; `np` is the last item seen while loaded.
pub fn writeNowPlaying(w: *Io.Writer, report: Report, np: NowPlaying) Io.Writer.Error!void {
    const symbol = switch (report.state) {
        .playing => "▶",
        .paused => "⏸",
        else => "■",
    };
    try w.print("{s} {s} — {s}  {f} / {f}  [{s}]", .{
        symbol,
        np.title orelse "?",
        np.artist orelse "?",
        Time{ .seconds = report.currentPlaybackTime },
        Time{ .seconds = duration(report, np) },
        np.playbackType orelse "?",
    });
}

/// The live line while watching: `playing   0:42 / 2:55  title — artist [encryptedFull]`.
pub fn writeProgress(w: *Io.Writer, report: Report, np: ?NowPlaying) Io.Writer.Error!void {
    try w.print("{s:<9} {f} / {f}  {s} — {s} [{s}]", .{
        report.playbackState orelse "?",
        Time{ .seconds = report.currentPlaybackTime },
        Time{ .seconds = duration(report, np) },
        if (np) |n| n.title orelse "" else "",
        if (np) |n| n.artist orelse "" else "",
        if (np) |n| n.playbackType orelse "?" else "?",
    });
}

pub const Mode = union(enum) {
    /// `am play` without flags: until MusicKit plays and names the playback type.
    until_playing,
    /// `--seconds N`: verify for N seconds, then pause.
    seconds: u32,
    /// `--full`: verify until the track ends.
    full,
};

/// One look at the engine, about once a second.
pub const Sample = struct {
    /// The latest report, if the page has sent one since its launch.
    report: ?Report,
    report_age_ms: u64 = 0,
    engine_running: bool = true,
    /// Another engine launch, or a reload of the page, since `play`.
    engine_restarted: bool = false,
    /// Another `am play` took over the engine.
    replaced: bool = false,
    /// A stop that began after the play succeeded (`Plays` in daemon/host.zig).
    stopped: bool = false,
    /// Since `play` was sent.
    elapsed_ms: u64,
};

pub const Failure = union(enum) {
    engine_gone,
    engine_restarted,
    replaced,
    /// No report for this many seconds.
    stale: u64,
    not_started,
    /// `--full`: still going a minute after the track should have ended.
    overtime,

    pub fn format(f: Failure, w: *Io.Writer) Io.Writer.Error!void {
        switch (f) {
            .engine_gone => try w.writeAll("the engine stopped during playback"),
            .engine_restarted => try w.writeAll("the engine restarted during playback (another command, or a crash, started it again)"),
            .replaced => try w.writeAll("replaced by another am play"),
            .stale => |s| try w.print("the engine page stopped reporting for {d} s", .{s}),
            .not_started => try w.print("playback didn't start within {d} s", .{start_timeout_ms / 1000}),
            .overtime => try w.writeAll("playback took over a minute longer than the track"),
        }
    }
};

pub const End = enum {
    /// `until_playing`: MusicKit is playing and named the playback type.
    started,
    /// Ended, completed or stopped.
    track_ended,
    /// `--seconds N` ran out.
    limit_reached,
    /// A stop came before playback got anywhere: the play stopped before it started.
    stopped,
};

/// Watches a track from `play` on. Feed it samples until `observe` returns false.
pub const Watch = struct {
    mode: Mode,
    /// The furthest playback got, in seconds.
    max_time: f64 = 0,
    /// MusicKit clears `nowPlayingItem` and the media element's source before it reports `ended`,
    /// so the verdict uses the last values seen while the track was loaded.
    now_playing: ?NowPlaying = null,
    media: ?MediaElement = null,
    last: ?Report = null,
    failure: ?Failure = null,
    end: ?End = null,

    /// Whether to keep watching.
    pub fn observe(w: *Watch, s: Sample) bool {
        if (s.replaced) return w.fail(.replaced);
        if (!s.engine_running) return w.fail(.engine_gone);
        if (s.engine_restarted) return w.fail(.engine_restarted);
        const report = s.report orelse {
            if (s.stopped and w.max_time == 0) return w.finish(.stopped);
            if (s.elapsed_ms > start_timeout_ms) return w.fail(.not_started);
            return true;
        };
        w.last = report;
        if (s.report_age_ms > stale_after_ms) return w.fail(.{ .stale = s.report_age_ms / 1000 });
        w.max_time = @max(w.max_time, report.currentPlaybackTime orelse 0);
        // Judged on this sample too: one past 0 s, or playing, did start.
        if (s.stopped and w.max_time == 0 and report.state != .playing) return w.finish(.stopped);
        if (report.nowPlaying) |np| w.now_playing = np;
        if (report.mediaElement) |m| if (m.blobSrc) {
            w.media = m;
        };

        const playing = report.state == .playing;
        switch (w.mode) {
            .until_playing => if (playing and w.now_playing != null and w.now_playing.?.playbackType != null) return w.finish(.started),
            .seconds => |limit| if (s.elapsed_ms >= @as(u64, limit) * 1000) return w.finish(.limit_reached),
            .full => if (w.now_playing) |np| if (np.catalogDurationSec) |d| {
                if (@as(f64, @floatFromInt(s.elapsed_ms)) / 1000 > d + 60) return w.fail(.overtime);
            },
        }
        switch (report.state) {
            .ended, .completed, .stopped => if (w.max_time > 0) return w.finish(.track_ended),
            else => {},
        }
        // Without flags, anything short of `started` by now is a failure.
        if (s.elapsed_ms > start_timeout_ms and (w.mode == .until_playing or w.max_time == 0)) return w.fail(.not_started);
        return true;
    }

    fn fail(w: *Watch, failure: Failure) bool {
        w.failure = failure;
        return false;
    }

    fn finish(w: *Watch, end: End) bool {
        w.end = end;
        return false;
    }

    /// `am play` without flags succeeds when playback started and isn't a preview.
    pub fn startedOk(w: *const Watch) bool {
        return w.failure == null and w.end == .started and !isPreview(w.now_playing);
    }
};

/// What `--seconds` / `--full` print at the end besides the watch itself.
pub const VerdictExtras = struct {
    /// `browserSupportsVideoDrm` once the engine was ready.
    drm: ?bool,
    audio: Audio,
    /// A ready-made `engine footprint: …` line, if one was sampled.
    footprint: ?[]const u8 = null,
};

/// The engine's audio streams (`platform.engineAudio`), or why there are none to show.
pub const Audio = union(enum) {
    /// Playback never reached the point where streams are sampled.
    not_sampled,
    sampled: platform.EngineAudio,
};

/// Prints the POC's checks and returns whether the track played in full.
pub fn writeVerdict(r: *Reply, watch: *const Watch, extras: VerdictExtras) Reply.Error!bool {
    var ok = true;
    if (watch.failure) |f| {
        try r.print("✘ {f}\n", .{f});
        ok = false;
    }
    if (watch.last) |last| if (!last.isAuthorized) {
        try r.print("✘ MusicKit lost its authorization during play (Apple rejected the Music User Token)\n", .{});
        ok = false;
    };
    try r.check(extras.drm, "MusicKit sees DRM support", .{});

    const np = watch.now_playing;
    const full = isFullTrack(np);
    if (!full) ok = false;
    try r.check(full, "playbackType = {s} (encryptedFull = full track; preview = 30 s clip)", .{
        if (np) |n| n.playbackType orelse "unknown" else "unknown",
    });

    const media = watch.media;
    try r.check(if (media) |m| m.blobSrc and m.mediaKeys else false, "media element: MSE blob src {}, MediaKeys attached {}", .{
        if (media) |m| m.blobSrc else false, if (media) |m| m.mediaKeys else false,
    });

    const stopped_early = watch.end == .limit_reached;
    const reached: ?bool = if (watch.max_time > 95) true else if (watch.max_time > 31 or stopped_early) null else false;
    if (reached == false) ok = false;
    try r.check(reached, "playback reached {f} of {f} (previews stop at 0:30, sometimes 1:30){s}", .{
        Time{ .seconds = watch.max_time },
        Time{ .seconds = if (np) |n| n.catalogDurationSec else null },
        if (stopped_early and watch.max_time <= 31) "; stopped watching before a preview would have ended" else "",
    });

    switch (extras.audio) {
        .not_sampled => try r.check(null, "engine audio stream: not sampled (playback never reached 0:10)", .{}),
        .sampled => |audio| switch (audio) {
            .unsupported => |why| try r.check(null, "engine audio stream: {s}", .{why}),
            .failed => |why| try r.check(null, "engine audio stream: can't list the streams: {s}", .{why}),
            .streams => |streams| {
                var audible = false;
                for (streams) |s| audible = audible or (!s.corked and !s.mute);
                try r.check(audible, "engine audio stream: {f}", .{std.json.fmt(streams, .{})});
            },
        },
    }

    var events: Io.Writer.Allocating = .init(r.arena);
    if (watch.last) |last| for (last.lastEvents) |e| {
        if (!isNotable(e.type)) continue;
        try events.writer.print("{s} {s} {f}", .{ if (events.written().len == 0) "events:" else ",", e.type, std.json.fmt(e.detail, .{}) });
    };
    if (events.written().len > 0) try r.print("{s}\n", .{events.written()});
    if (extras.footprint) |line| try r.print("{s}\n", .{line});
    return ok;
}

/// Events worth showing after a failed play: errors, DRM and authorization trouble.
fn isNotable(event_type: []const u8) bool {
    for ([_][]const u8{ "rror", "drmUnsupported", "uthorization" }) |needle| if (std.mem.find(u8, event_type, needle) != null) return true;
    return false;
}

const testing = std.testing;

/// A recorded report sequence: (seconds since play, report age in ms, report JSON).
const Recorded = struct { at_s: u64, age_ms: u64 = 300, json: []const u8 };

fn replay(arena: Allocator, mode: Mode, recorded: []const Recorded) !Watch {
    var watch: Watch = .{ .mode = mode };
    for (recorded) |r| {
        const report = parseReport(arena, r.json) orelse return error.TestBadReport;
        if (!watch.observe(.{ .report = report, .report_age_ms = r.age_ms, .elapsed_ms = r.at_s * 1000 })) return watch;
    }
    return error.TestStillWatching;
}

fn verdictText(arena: Allocator, watch: *const Watch, extras: VerdictExtras) !struct { []const u8, bool } {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    const ok = try writeVerdict(&t.reply, watch, extras);
    return .{ (try t.finish({})).out, ok };
}

const shy_away =
    \\"nowPlaying":{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"encryptedFull"}
;
const shy_away_preview =
    \\"nowPlaying":{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"preview"}
;
const mse =
    \\"mediaElement":{"blobSrc":true,"mediaKeys":true,"paused":false}
;
const no_drm_events =
    \\"lastEvents":[{"t":"10:00:01.000","type":"play","detail":"1561837008"}]
;

test "TokenId: the first 8 bytes of the token's SHA-256 in hex, as the engine page reports it; only the hash counts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    // app.test.mjs reports the same hash for the same string.
    const id = try TokenId.of(arena.allocator(), "not a token");
    try std.testing.expectEqualStrings("7038d017c27b8ab3", id.hash.?);
    try std.testing.expect(id.eql(.{ .hash = "7038d017c27b8ab3" }));
    try std.testing.expect(!id.eql(.{ .hash = "7038d017c27b8ab4" }));
    // No hash (an older page, or a browser that couldn't hash): never the same.
    try std.testing.expect(!(TokenId{}).eql(.{}));
    try std.testing.expect(!id.eql(.{}));
    const report = parseReport(arena.allocator(), "{\"developerToken\":{\"kid\":\"KEY\",\"exp\":1793604800,\"hash\":\"7038d017c27b8ab3\"}}").?;
    try std.testing.expect(report.developerToken.?.eql(id));
    // The page's null hash and claims still parse: the rest of the report isn't lost.
    const unhashed = parseReport(arena.allocator(), "{\"configured\":true,\"developerToken\":{\"kid\":null,\"exp\":null,\"hash\":null}}").?;
    try std.testing.expect(unhashed.configured);
    try std.testing.expectEqual(null, unhashed.developerToken.?.hash);
}

test "the report names the Music User Token MusicKit holds by its hash, as it does the developer token" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const report = parseReport(a, "{\"configured\":true,\"musicUserToken\":{\"kid\":null,\"exp\":null,\"hash\":\"7038d017c27b8ab3\"}}").?;
    try std.testing.expect(report.musicUserToken.?.eql(try TokenId.of(a, "not a token")));
    // A null hash still parses. The page names none (null) when MusicKit holds none or the
    // browser can't hash, and an older page doesn't say.
    const unhashed = parseReport(a, "{\"configured\":true,\"musicUserToken\":{\"kid\":null,\"exp\":null,\"hash\":null}}").?;
    try std.testing.expectEqual(null, unhashed.musicUserToken.?.hash);
    try std.testing.expectEqual(null, parseReport(a, "{\"configured\":true,\"musicUserToken\":null}").?.musicUserToken);
    try std.testing.expectEqual(null, parseReport(a, "{\"configured\":true}").?.musicUserToken);
}

test "a full track: encryptedFull, MSE with MediaKeys, past 1:35, then ended" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const watch = try replay(a, .full, &.{
        .{ .at_s = 1, .json = "{\"isAuthorized\":true,\"playbackState\":\"loading\",\"currentPlaybackTime\":0,\"nowPlaying\":null,\"mediaElement\":null}" },
        .{ .at_s = 2, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":0.4,\"currentPlaybackDuration\":175," ++ shy_away ++ "," ++ mse ++ "}" },
        .{ .at_s = 100, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":98.2,\"currentPlaybackDuration\":175," ++ shy_away ++ "," ++ mse ++ "}" },
        .{ .at_s = 177, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":174.9,\"currentPlaybackDuration\":175," ++ shy_away ++ "," ++ mse ++ "," ++ no_drm_events ++ "}" },
        .{ .at_s = 178, .json = "{\"isAuthorized\":true,\"playbackState\":\"ended\",\"currentPlaybackTime\":175,\"currentPlaybackDuration\":175," ++ shy_away ++ "," ++ mse ++ "}" },
    });
    try testing.expectEqual(End.track_ended, watch.end.?);
    const text, const ok = try verdictText(a, &watch, .{ .drm = true, .audio = .{ .sampled = .{ .unsupported = "not checked on macOS (PipeWire is Linux only)" } }, .footprint = "engine footprint: 8 processes, 432 MiB PSS, CPU 17.0% of one core" });
    try testing.expect(ok);
    try testing.expectEqualStrings(
        \\✔ MusicKit sees DRM support
        \\✔ playbackType = encryptedFull (encryptedFull = full track; preview = 30 s clip)
        \\✔ media element: MSE blob src true, MediaKeys attached true
        \\✔ playback reached 2:55 of 2:55 (previews stop at 0:30, sometimes 1:30)
        \\? engine audio stream: not checked on macOS (PipeWire is Linux only)
        \\engine footprint: 8 processes, 432 MiB PSS, CPU 17.0% of one core
        \\
    , text);
}

test "MusicKit clears the item and the media source before it reports ended: the verdict keeps the last ones seen" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const watch = try replay(a, .full, &.{
        .{ .at_s = 2, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":1," ++ shy_away ++ "," ++ mse ++ "}" },
        .{ .at_s = 176, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":174.6," ++ shy_away ++ "," ++ mse ++ "}" },
        // The track is over: no item, the src is gone, the clock is back at 0, then 'ended'.
        .{ .at_s = 177, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":0,\"nowPlaying\":null,\"mediaElement\":{\"blobSrc\":false,\"mediaKeys\":false}}" },
        .{ .at_s = 177, .json = "{\"isAuthorized\":true,\"playbackState\":\"ended\",\"currentPlaybackTime\":0,\"nowPlaying\":null,\"mediaElement\":{\"blobSrc\":false,\"mediaKeys\":false}}" },
    });
    try testing.expectEqual(End.track_ended, watch.end.?);
    try testing.expectEqualStrings("encryptedFull", watch.now_playing.?.playbackType.?);
    const text, const ok = try verdictText(a, &watch, .{ .drm = true, .audio = .not_sampled });
    try testing.expect(ok);
    try testing.expect(std.mem.find(u8, text, "✔ playbackType = encryptedFull") != null);
    try testing.expect(std.mem.find(u8, text, "✔ media element: MSE blob src true, MediaKeys attached true") != null);
    try testing.expect(std.mem.find(u8, text, "✔ playback reached 2:54 of 2:55") != null);
}

test "a preview: playbackType preview and it stops at 0:30" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const events =
        \\"lastEvents":[{"t":"10:00:00.100","type":"drmUnsupported"},{"t":"10:00:00.200","type":"play","detail":"1561837008"},{"t":"10:00:00.300","type":"mkError","detail":"license request failed"}]
    ;
    const watch = try replay(a, .full, &.{
        .{ .at_s = 2, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":1,\"currentPlaybackDuration\":30," ++ shy_away_preview ++ ",\"mediaElement\":{\"blobSrc\":false,\"mediaKeys\":false}}" },
        .{ .at_s = 31, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":29.9,\"currentPlaybackDuration\":30," ++ shy_away_preview ++ ",\"mediaElement\":{\"blobSrc\":false,\"mediaKeys\":false}}" },
        .{ .at_s = 32, .json = "{\"isAuthorized\":true,\"playbackState\":\"completed\",\"currentPlaybackTime\":0,\"nowPlaying\":null,\"mediaElement\":null," ++ events ++ "}" },
    });
    try testing.expectEqual(End.track_ended, watch.end.?);
    const text, const ok = try verdictText(a, &watch, .{ .drm = false, .audio = .not_sampled });
    try testing.expect(!ok);
    try testing.expectEqualStrings(
        \\✘ MusicKit sees DRM support
        \\✘ playbackType = preview (encryptedFull = full track; preview = 30 s clip)
        \\✘ media element: MSE blob src false, MediaKeys attached false
        \\✘ playback reached 0:29 of 2:55 (previews stop at 0:30, sometimes 1:30)
        \\? engine audio stream: not sampled (playback never reached 0:10)
        \\events: drmUnsupported null, mkError "license request failed"
        \\
    , text);
}

test "never started: still loading 30 s after play" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loading = "{\"isAuthorized\":true,\"playbackState\":\"loading\",\"currentPlaybackTime\":0,\"nowPlaying\":null}";
    for ([_]Mode{ .full, .{ .seconds = 100 }, .until_playing }) |mode| {
        const watch = try replay(a, mode, &.{
            .{ .at_s = 1, .json = loading },
            .{ .at_s = 15, .json = loading },
            .{ .at_s = 30, .json = loading },
            .{ .at_s = 31, .json = loading },
        });
        try testing.expectEqual(Failure.not_started, watch.failure.?);
        try testing.expect(!watch.startedOk());
    }
    var watch = try replay(a, .full, &.{ .{ .at_s = 1, .json = loading }, .{ .at_s = 31, .json = loading } });
    const text, const ok = try verdictText(a, &watch, .{ .drm = true, .audio = .not_sampled });
    try testing.expect(!ok);
    try testing.expect(std.mem.startsWith(u8, text, "✘ playback didn't start within 30 s\n"));
    try testing.expect(std.mem.find(u8, text, "✘ playbackType = unknown") != null);
}

test "stale reports: no report for over 20 s fails the watch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const playing = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":40," ++ shy_away ++ "}";
    const watch = try replay(a, .full, &.{
        .{ .at_s = 41, .json = playing },
        .{ .at_s = 55, .age_ms = 14_000, .json = playing },
        .{ .at_s = 62, .age_ms = 21_000, .json = playing },
    });
    try testing.expectEqual(Failure{ .stale = 21 }, watch.failure.?);
    const text, const ok = try verdictText(a, &watch, .{ .drm = true, .audio = .not_sampled });
    try testing.expect(!ok);
    try testing.expect(std.mem.startsWith(u8, text, "✘ the engine page stopped reporting for 21 s\n"));
}

test "the engine going away fails the watch" {
    var watch: Watch = .{ .mode = .full };
    try testing.expect(watch.observe(.{ .report = .{ .state = .playing, .currentPlaybackTime = 3 }, .elapsed_ms = 4000 }));
    try testing.expect(!watch.observe(.{ .report = null, .engine_running = false, .elapsed_ms = 5000 }));
    try testing.expectEqual(Failure.engine_gone, watch.failure.?);
}

test "--seconds N stops watching after N seconds; a short watch can't tell a full track from a preview by time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = struct {
        fn json(comptime t: []const u8) []const u8 {
            return "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":" ++ t ++ "," ++ shy_away ++ "," ++ mse ++ "}";
        }
    };
    const watch = try replay(a, .{ .seconds = 20 }, &.{
        .{ .at_s = 2, .json = at.json("1") },
        .{ .at_s = 10, .json = at.json("9") },
        .{ .at_s = 20, .json = at.json("19") },
    });
    try testing.expectEqual(End.limit_reached, watch.end.?);
    const text, const ok = try verdictText(a, &watch, .{ .drm = true, .audio = .not_sampled });
    try testing.expect(ok);
    try testing.expect(std.mem.find(u8, text, "? playback reached 0:19 of 2:55 (previews stop at 0:30, sometimes 1:30); stopped watching before a preview would have ended\n") != null);
}

test "without flags, the watch ends once MusicKit plays and names the playback type" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try replay(a, .until_playing, &.{
        .{ .at_s = 1, .json = "{\"isAuthorized\":true,\"playbackState\":\"loading\",\"currentPlaybackTime\":0}" },
        // Playing, but the item isn't there yet.
        .{ .at_s = 2, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":0}" },
        .{ .at_s = 3, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":0,\"currentPlaybackDuration\":175," ++ shy_away ++ "}" },
    });
    try testing.expectEqual(End.started, full.end.?);
    try testing.expect(full.startedOk());

    const preview = try replay(a, .until_playing, &.{
        .{ .at_s = 2, .json = "{\"isAuthorized\":true,\"playbackState\":\"playing\",\"currentPlaybackTime\":0.2," ++ shy_away_preview ++ "}" },
    });
    try testing.expectEqual(End.started, preview.end.?);
    try testing.expect(!preview.startedOk());
}

test "the now-playing line: ▶ title — artist  position / duration  [playbackType]" {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const np: NowPlaying = .{ .title = "Shy Away", .artist = "Twenty One Pilots", .catalogDurationSec = 175.08, .playbackType = "encryptedFull" };
    try writeNowPlaying(&w, .{ .state = .playing, .currentPlaybackTime = 0 }, np);
    try w.writeAll("\n");
    try writeNowPlaying(&w, .{ .state = .paused, .currentPlaybackTime = 62.9, .currentPlaybackDuration = 175 }, np);
    try w.writeAll("\n");
    try writeNowPlaying(&w, .{ .state = .stopped }, .{ .title = "X" });
    try testing.expectEqualStrings(
        \\▶ Shy Away — Twenty One Pilots  0:00 / 2:55  [encryptedFull]
        \\⏸ Shy Away — Twenty One Pilots  1:02 / 2:55  [encryptedFull]
        \\■ X — ?  –:–– / –:––  [?]
    , w.buffered());
}

test "the progress line pads the state and tolerates a missing item" {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeProgress(&w, .{ .playbackState = "playing", .currentPlaybackTime = 125.5, .currentPlaybackDuration = 175 }, .{ .title = "Shy Away", .artist = "Twenty One Pilots", .playbackType = "encryptedFull" });
    try w.writeAll("|");
    try writeProgress(&w, .{ .playbackState = "loading" }, null);
    try testing.expectEqualStrings("playing   2:05 / 2:55  Shy Away — Twenty One Pilots [encryptedFull]|loading   –:–– / –:––   —  [?]", w.buffered());
}

test "a stop before playback got anywhere ends the watch as stopped; one after it played doesn't" {
    var loading: Watch = .{ .mode = .until_playing };
    try testing.expect(loading.observe(.{ .report = .{ .state = .loading }, .elapsed_ms = 500 }));
    try testing.expect(!loading.observe(.{ .report = .{ .state = .paused }, .stopped = true, .elapsed_ms = 1500 }));
    try testing.expectEqual(End.stopped, loading.end.?);
    try testing.expectEqual(null, loading.failure);

    var played: Watch = .{ .mode = .full };
    try testing.expect(played.observe(.{ .report = .{ .state = .playing, .currentPlaybackTime = 3 }, .elapsed_ms = 4000 }));
    try testing.expect(played.observe(.{ .report = .{ .state = .paused, .currentPlaybackTime = 0 }, .stopped = true, .elapsed_ms = 5000 }));

    // The first sample that shows it past 0 s counts, even with the stop already in.
    var late: Watch = .{ .mode = .full };
    try testing.expect(late.observe(.{ .report = .{ .state = .paused, .currentPlaybackTime = 1.5 }, .stopped = true, .elapsed_ms = 2000 }));
    try testing.expectEqual(null, late.end);
}

test "a report names stopped live radio when the page sends it; an older page's report parses without it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const old = parseReport(arena.allocator(), "{\"playbackState\":\"stopped\",\"nowPlaying\":null}") orelse return error.TestBadReport;
    try testing.expectEqual(null, old.stoppedLive);
    const none = parseReport(arena.allocator(), "{\"playbackState\":\"stopped\",\"nowPlaying\":null,\"stoppedLive\":null}") orelse return error.TestBadReport;
    try testing.expectEqual(null, none.stoppedLive);
    const live = parseReport(arena.allocator(), "{\"playbackState\":\"stopped\",\"nowPlaying\":null,\"stoppedLive\":{\"id\":\"ra.978194965\",\"name\":\"Apple Music 1\"}}") orelse return error.TestBadReport;
    try testing.expectEqualStrings("ra.978194965", live.stoppedLive.?.id);
    try testing.expectEqualStrings("Apple Music 1", live.stoppedLive.?.name.?);
}

test "what the engine page holds: one class per page state, and a reload loses all but none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const live_item =
        \\"nowPlaying":{"id":"ra.978194965","title":"Apple Music 1","artist":"Apple Music","playbackType":"encryptedFull","isLive":true}
    ;
    const station =
        \\"stoppedLive":{"id":"ra.978194965","name":"Apple Music 1"}
    ;
    // Each row is a report as the page sends it: `state` comes from `playbackState`, as in
    // production. A state MusicKit doesn't name is sent as its number (app.js `enumName`).
    const rows = [_]struct { []const u8, Music, bool }{
        // The state wins over `isPlaying`.
        .{ "{\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .playing, true },
        .{ "{\"playbackState\":\"playing\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .playing, true },
        // Paused mid-way, rewound to 0:00 by `am stop`, a preview, or left in place after it ended.
        .{ "{\"playbackState\":\"paused\",\"currentPlaybackTime\":62,\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        .{ "{\"playbackState\":\"paused\",\"currentPlaybackTime\":0,\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        .{ "{\"playbackState\":\"paused\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away_preview ++ "}", .paused, true },
        .{ "{\"playbackState\":\"ended\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        .{ "{\"playbackState\":\"completed\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        // MusicKit loads, seeks, waits or stalls, before it names the item or with one.
        .{ "{\"playbackState\":\"loading\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"seeking\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"waiting\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"stalled\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"waiting\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .starting, true },
        // A queue on its way, alone or replacing a paused song.
        .{ "{\"playbackState\":\"none\",\"isPlaying\":false,\"loadPending\":true,\"stoppedLive\":null,\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"paused\",\"isPlaying\":false,\"loadPending\":true,\"stoppedLive\":null," ++ shy_away ++ "}", .starting, true },
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false," ++ station ++ ",\"nowPlaying\":null}", .stopped_live, true },
        // Stopped live radio comes last: a queue on its way over it (`am play` or the TUI's
        // queue, before its load clears the station), its item still named, or music that plays
        // (a stop that gave up) decides first.
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":true," ++ station ++ ",\"nowPlaying\":null}", .starting, true },
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false," ++ station ++ "," ++ live_item ++ "}", .paused, true },
        .{ "{\"playbackState\":\"11\",\"isPlaying\":true,\"loadPending\":false," ++ station ++ "," ++ live_item ++ "}", .playing, true },
        // A state MusicKit doesn't name: `isPlaying` decides, then the item.
        .{ "{\"playbackState\":\"11\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .playing, true },
        .{ "{\"playbackState\":\"11\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null," ++ live_item ++ "}", .playing, true },
        .{ "{\"playbackState\":\"11\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        .{ "{\"playbackState\":\"11\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .paused, true },
        // `isPlaying` under a state that says otherwise.
        .{ "{\"playbackState\":\"paused\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away ++ "}", .playing, true },
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .playing, true },
        // A preview playing, and music playing before MusicKit names the item (live radio restarting).
        .{ "{\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null," ++ shy_away_preview ++ "}", .playing, true },
        .{ "{\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .playing, true },
        // Nothing: no item, no queue on its way, no stopped station.
        .{ "{\"playbackState\":\"ended\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        .{ "{\"playbackState\":\"completed\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        .{ "{\"playbackState\":\"none\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        .{ "{\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        // MusicKit isn't configured: the page has no player yet.
        .{ "{\"configured\":false,\"playbackState\":null,\"loadPending\":false,\"stoppedLive\":null,\"nowPlaying\":null}", .none, false },
        // An older page sends no `isPlaying`, `loadPending` or `stoppedLive`: its state and item decide.
        .{ "{\"playbackState\":\"paused\"," ++ shy_away ++ "}", .paused, true },
        .{ "{\"playbackState\":\"stopped\",\"nowPlaying\":null}", .none, false },
    };
    for (rows) |row| {
        const json, const music, const holds = row;
        const report = parseReport(arena.allocator(), json) orelse return error.TestBadReport;
        testing.expectEqual(music, report.music()) catch |e| {
            std.debug.print("row: {s}\n", .{json});
            return e;
        };
        try testing.expectEqual(holds, report.holdsMusic());
    }

    // As `daemon.log` prints them.
    try testing.expectFmt("nothing", "{f}", .{Music.none});
    try testing.expectFmt("music that plays", "{f}", .{Music.playing});
    try testing.expectFmt("a song on its way", "{f}", .{Music.starting});
    try testing.expectFmt("a paused song", "{f}", .{Music.paused});
    try testing.expectFmt("stopped live radio", "{f}", .{Music.stopped_live});
}

test "another play, or an engine restart, ends the watch at once with its own message" {
    var replaced: Watch = .{ .mode = .full };
    try testing.expect(replaced.observe(.{ .report = .{ .state = .playing, .currentPlaybackTime = 3 }, .elapsed_ms = 4000 }));
    try testing.expect(!replaced.observe(.{ .report = .{ .state = .playing, .currentPlaybackTime = 4 }, .replaced = true, .elapsed_ms = 5000 }));
    try testing.expectEqual(Failure.replaced, replaced.failure.?);

    // Well before the 30 s start timeout.
    var restarted: Watch = .{ .mode = .until_playing };
    try testing.expect(restarted.observe(.{ .report = .{ .state = .loading }, .elapsed_ms = 1000 }));
    try testing.expect(!restarted.observe(.{ .report = .{ .state = .loading }, .engine_restarted = true, .elapsed_ms = 2000 }));
    try testing.expectEqual(Failure.engine_restarted, restarted.failure.?);

    var buf: [200]u8 = undefined;
    try testing.expectEqualStrings("replaced by another am play", try std.fmt.bufPrint(&buf, "{f}", .{@as(Failure, .replaced)}));
    try testing.expectEqualStrings("the engine restarted during playback (another command, or a crash, started it again)", try std.fmt.bufPrint(&buf, "{f}", .{@as(Failure, .engine_restarted)}));
}
