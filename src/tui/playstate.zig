//! What the player bar knows: the background process's `State` lines (from `watch` and from
//! every command's reply), the playback position between reports, and the queue request that
//! brings the music back when the engine was closed in between.
const std = @import("std");
const playback = @import("../playback.zig");
const player = @import("../daemon/player.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const QueueRequest = player.QueueRequest;

pub const Engine = struct {
    kind: []const u8 = "",
    pid: ?i64 = null,
    headless: bool = true,
    signin_window: bool = false,
    idle_close_in_s: ?i64 = null,
};

/// One `State`, parsed, with the memory it lives in.
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    build: ?[]const u8 = null,
    engine: ?Engine = null,
    report: ?playback.Report = null,
    report_age_ms: u64 = 0,
    /// When it arrived (awake clock, nanoseconds).
    received_ns: i96 = 0,

    pub fn destroy(s: *Snapshot) void {
        var arena = s.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(s);
    }

    pub fn nowPlaying(s: *const Snapshot) ?playback.NowPlaying {
        const r = s.report orelse return null;
        return r.nowPlaying;
    }

    pub fn isPlaying(s: *const Snapshot) bool {
        const r = s.report orelse return false;
        if (r.isPlaying) |p| return p;
        return r.state == .playing;
    }

    /// Seconds into the item at `now_ns`: the report's time, moved on by the time since it was
    /// taken while playing, within the duration.
    pub fn position(s: *const Snapshot, now_ns: i96) ?f64 {
        const r = s.report orelse return null;
        const t = r.currentPlaybackTime orelse return null;
        if (!s.isPlaying() or r.state != .playing) return t;
        const since_ms: f64 = @as(f64, @floatFromInt(s.report_age_ms)) + @as(f64, @floatFromInt(@max(0, now_ns - s.received_ns))) / 1e6;
        const moved = t + since_ms / 1000;
        if (s.duration()) |d| if (d > 0) return @min(moved, d);
        return moved;
    }

    pub fn duration(s: *const Snapshot) ?f64 {
        const r = s.report orelse return null;
        if (r.currentPlaybackDuration) |d| if (d > 0) return d;
        if (r.nowPlaying) |np| return np.catalogDurationSec;
        return null;
    }

    pub fn volume(s: *const Snapshot) ?f64 {
        const r = s.report orelse return null;
        return r.volume;
    }

    pub fn shuffleOn(s: *const Snapshot) bool {
        const r = s.report orelse return false;
        return std.mem.eql(u8, r.shuffle orelse "off", "songs");
    }

    pub fn repeatMode(s: *const Snapshot) player.Repeat {
        const r = s.report orelse return .none;
        return std.meta.stringToEnum(player.Repeat, r.repeat orelse "none") orelse .none;
    }

    pub fn capabilities(s: *const Snapshot) playback.Capabilities {
        const r = s.report orelse return .{};
        return r.capabilities orelse .{};
    }
};

/// Parses a `State` line into a new snapshot (allocated with `gpa`, which must be thread-safe).
pub fn parse(gpa: Allocator, json: []const u8, received_ns: i96) error{ OutOfMemory, BadState }!*Snapshot {
    const s = try gpa.create(Snapshot);
    s.* = .{ .arena = .init(gpa), .received_ns = received_ns };
    errdefer s.destroy();
    const a = s.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(struct {
        build: ?[]const u8 = null,
        engine: ?Engine = null,
        report: ?playback.Report = null,
        report_age_ms: u64 = 0,
    }, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadState,
    };
    s.build = parsed.build;
    s.engine = parsed.engine;
    s.report = parsed.report;
    s.report_age_ms = parsed.report_age_ms;
    if (s.report) |*r| r.state = std.meta.stringToEnum(playback.PlaybackState, r.playbackState orelse "") orelse .unknown;
    return s;
}

pub fn repeatNext(r: player.Repeat) player.Repeat {
    return switch (r) {
        .none => .all,
        .all => .one,
        .one => .none,
    };
}

/// Where the music was, kept from the last report that had something playing: an engine that
/// closed (or a background process that restarted) reports nothing. Saved in the state file,
/// so the music can come back where it was after the TUI restarts too.
pub const Resume = struct {
    id_buf: [128]u8 = undefined,
    id_len: usize = 0,
    catalog_buf: [128]u8 = undefined,
    catalog_len: usize = 0,
    /// The id of the container the engine says the item plays from (empty: none).
    container_buf: [128]u8 = undefined,
    container_len: usize = 0,
    /// Seconds into the item when the report came.
    time: ?f64 = null,
    live: bool = false,
    shuffle: bool = false,
    repeat: player.Repeat = .none,
    /// The app put the item into Up Next itself (e, E), so it isn't part of the queue request.
    inserted: bool = false,

    pub fn id(r: *const Resume) []const u8 {
        return r.id_buf[0..r.id_len];
    }

    pub fn catalogId(r: *const Resume) []const u8 {
        return r.catalog_buf[0..r.catalog_len];
    }

    pub fn containerId(r: *const Resume) []const u8 {
        return r.container_buf[0..r.container_len];
    }

    /// From a report with something playing; null otherwise.
    pub fn of(s: *const Snapshot, now_ns: i96) ?Resume {
        const np = s.nowPlaying() orelse return null;
        const item_id = np.id orelse return null;
        var r: Resume = .{ .time = s.position(now_ns), .live = np.isLive, .shuffle = s.shuffleOn(), .repeat = s.repeatMode() };
        if (!r.setIds(item_id, np.catalogId orelse "", if (np.container) |c| c.id orelse "" else "")) return null;
        return r;
    }

    fn setIds(r: *Resume, item_id: []const u8, catalog: []const u8, container: []const u8) bool {
        if (item_id.len == 0 or item_id.len > r.id_buf.len or catalog.len > r.catalog_buf.len or container.len > r.container_buf.len) return false;
        @memcpy(r.id_buf[0..item_id.len], item_id);
        r.id_len = item_id.len;
        @memcpy(r.catalog_buf[0..catalog.len], catalog);
        r.catalog_len = catalog.len;
        @memcpy(r.container_buf[0..container.len], container);
        r.container_len = container.len;
        return true;
    }

    /// Whether the item is part of what `last` queued. An item autoplay added reports another
    /// container (or none), and one the app inserted isn't in the request at all: queueing
    /// `last` with its id as `startId` would start at track 1 instead.
    pub fn belongsTo(r: *const Resume, last: QueueRequest) bool {
        if (r.inserted) return false;
        if (last.songs) |ids| {
            for (ids) |x| if (std.mem.eql(u8, x, r.id()) or (r.catalog_len > 0 and std.mem.eql(u8, x, r.catalogId()))) return true;
            return false;
        }
        if (last.container) |c| return std.mem.eql(u8, c.id, r.containerId());
        return true;
    }

    /// The form in the state file.
    pub const Saved = struct {
        id: []const u8,
        catalogId: ?[]const u8 = null,
        containerId: ?[]const u8 = null,
        time: ?f64 = null,
        live: bool = false,
        shuffle: bool = false,
        repeat: player.Repeat = .none,
        inserted: bool = false,
    };

    pub fn saved(r: *const Resume) Saved {
        return .{
            .id = r.id(),
            .catalogId = if (r.catalog_len > 0) r.catalogId() else null,
            .containerId = if (r.container_len > 0) r.containerId() else null,
            .time = r.time,
            .live = r.live,
            .shuffle = r.shuffle,
            .repeat = r.repeat,
            .inserted = r.inserted,
        };
    }

    pub fn fromSaved(v: Saved) ?Resume {
        var r: Resume = .{ .time = v.time, .live = v.live, .shuffle = v.shuffle, .repeat = v.repeat, .inserted = v.inserted };
        if (!r.setIds(v.id, v.catalogId orelse "", v.containerId orelse "")) return null;
        return r;
    }
};

/// The request that plays `last` again where it was: at the item that was playing, at its
/// position, with the volume and modes the player had. `startId` replaces `startIndex`: the
/// queue position differs from the track list's index when MusicKit drops unplayable tracks or
/// shuffle is on. An item that isn't part of `last` (autoplay, e/E) is queued on its own.
/// Without a known item, `last` starts over. Strings are copied into `arena`.
pub fn requeue(arena: Allocator, last: QueueRequest, seen: ?*const Resume, volume: f64) Allocator.Error!QueueRequest {
    var req = last;
    req.volume = volume;
    const r = seen orelse return req;
    // Live radio has no position; a station queue plays on from wherever it is.
    if (r.live or req.station != null or req.stationFor != null) return req;
    const start = try arena.dupe(u8, r.id());
    if (!r.belongsTo(last)) {
        req = .{ .songs = try arena.dupe([]const u8, &.{start}), .volume = volume };
    }
    req.startId = start;
    req.startIndex = null;
    if (r.time) |t| req.startTime = if (t > 1) t else null;
    req.shuffle = r.shuffle;
    req.repeat = r.repeat;
    return req;
}

pub fn requestJson(arena: Allocator, req: QueueRequest) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, req, .{ .emit_null_optional_fields = false });
}

pub fn parseRequest(arena: Allocator, json: []const u8) ?QueueRequest {
    return std.json.parseFromSliceLeaky(QueueRequest, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// The engine page's verdict on the item: a full track, MusicKit's 30 s preview, or not known.
pub const Verdict = enum { full, preview, unknown };

pub fn verdict(np: playback.NowPlaying) Verdict {
    const t = np.playbackType orelse return .unknown;
    if (std.mem.eql(u8, t, "preview")) return .preview;
    if (std.mem.eql(u8, t, "encryptedFull") or std.mem.eql(u8, t, "unencryptedFull")) return .full;
    return .unknown;
}

const testing = std.testing;

const playing_state =
    \\{"build":"0123456789abcdef","engine":{"kind":"firefox","pid":42,"headless":true,"signin_window":false,"idle_close_in_s":300},
    \\ "report":{"playbackState":"playing","isPlaying":true,"currentPlaybackTime":42.5,"currentPlaybackDuration":175,
    \\  "volume":0.1,"shuffle":"songs","repeat":"all","nowPlayingIndex":3,
    \\  "nowPlaying":{"id":"i.abc","catalogId":"1561837008","title":"Shy Away","artist":"twenty one pilots","album":"Scaled and Icy",
    \\   "playbackType":"encryptedFull","artworkUrl":"https://x/{w}x{h}bb.jpg","container":{"type":"library-albums","id":"l.1","name":"Scaled and Icy"}},
    \\  "queue":{"position":3,"length":11,"upcoming":[{"index":4,"id":"i.def","title":"The Outside","durationSec":216}]},
    \\  "capabilities":{"pause":true,"seek":true,"skipNext":true,"skipPrevious":true,"shuffle":true,"repeat":true,"editQueue":true},
    \\  "unknownField":1},
    \\ "report_age_ms":500}
;

test "a State line parses into the bar's state, and the position moves on while playing" {
    const s = try parse(testing.allocator, playing_state, 1_000_000_000);
    defer s.destroy();
    try testing.expectEqualStrings("firefox", s.engine.?.kind);
    try testing.expect(s.isPlaying());
    try testing.expectEqualStrings("Shy Away", s.nowPlaying().?.title.?);
    try testing.expectEqual(Verdict.full, verdict(s.nowPlaying().?));
    try testing.expect(s.shuffleOn());
    try testing.expectEqual(player.Repeat.all, s.repeatMode());
    try testing.expectEqual(@as(?f64, 175), s.duration());
    // Taken 0.5 s before it arrived, read 1 s after: 1.5 s on.
    try testing.expectApproxEqAbs(@as(f64, 44.0), s.position(2_000_000_000).?, 1e-9);
    // Never past the end.
    try testing.expectEqual(@as(f64, 175), s.position(1_000_000_000_000).?);
    try testing.expectEqual(@as(u32, 11), s.report.?.queue.?.length);
}

test "paused: the position stays; an empty state has nothing" {
    const s = try parse(testing.allocator,
        \\{"build":"x","engine":null,"report":{"playbackState":"paused","isPlaying":false,"currentPlaybackTime":10},"report_age_ms":9000}
    , 0);
    defer s.destroy();
    try testing.expectEqual(@as(f64, 10), s.position(5_000_000_000).?);
    try testing.expect(!s.isPlaying());
    const e = try parse(testing.allocator, "{\"build\":\"x\",\"engine\":null,\"report\":null,\"report_age_ms\":0}", 0);
    defer e.destroy();
    try testing.expect(e.nowPlaying() == null and e.position(0) == null);
    try testing.expectError(error.BadState, parse(testing.allocator, "not json", 0));
}

test "requeue after the engine closed: the playing item, its time, the volume and modes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try parse(testing.allocator, playing_state, 0);
    defer s.destroy();
    const last: QueueRequest = .{ .container = .{ .type = .@"library-albums", .id = "l.1", .name = "Scaled and Icy" }, .startIndex = 0 };
    const seen = Resume.of(s, 0).?;
    const req = try requeue(a, last, &seen, 0.1);
    try testing.expectEqualStrings(
        \\{"container":{"type":"library-albums","id":"l.1","name":"Scaled and Icy"},"startId":"i.abc","startTime":43,"shuffle":true,"repeat":"all","volume":0.1}
    , try requestJson(a, req));

    // Nothing seen: the request as it was, with the volume.
    try testing.expectEqualStrings(
        \\{"songs":["1","2"],"startId":"2","volume":0.05}
    , try requestJson(a, try requeue(a, .{ .songs = &.{ "1", "2" }, .startId = "2" }, null, 0.05)));

    // A station plays on; no position.
    const station = try requeue(a, .{ .station = "ra.978194965" }, &seen, 0.1);
    try testing.expect(station.startTime == null and station.startId == null);

    // Nothing playing in a report: no resume point (the last one is kept by the caller).
    const empty = try parse(testing.allocator, "{\"build\":\"x\",\"engine\":null,\"report\":null,\"report_age_ms\":0}", 0);
    defer empty.destroy();
    try testing.expect(Resume.of(empty, 0) == null);

    // Round trip.
    const back = parseRequest(a, try requestJson(a, req)).?;
    try testing.expectEqualStrings("i.abc", back.startId.?);
    try testing.expectEqual(player.ContainerType.@"library-albums", back.container.?.type);
}

test "requeue: an item from autoplay or e/E is queued on its own, not from the container's top" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const album: QueueRequest = .{ .container = .{ .type = .@"library-albums", .id = "l.1", .name = "Scaled and Icy" } };
    // Autoplay: the engine names another container (a station) or none.
    const s = try parse(testing.allocator, playing_state, 0);
    defer s.destroy();
    var seen = Resume.of(s, 0).?;
    try testing.expect(seen.belongsTo(album));
    seen.container_len = 0;
    try testing.expect(!seen.belongsTo(album));
    try testing.expectEqualStrings(
        \\{"songs":["i.abc"],"startId":"i.abc","startTime":43,"shuffle":true,"repeat":"all","volume":0.1}
    , try requestJson(a, try requeue(a, album, &seen, 0.1)));
    // Inserted with E: in the container's context, but not one of its tracks.
    seen = Resume.of(s, 0).?;
    seen.inserted = true;
    try testing.expect((try requeue(a, album, &seen, 0.1)).container == null);
    // A song list: by id or catalog id.
    seen.inserted = false;
    try testing.expect(seen.belongsTo(.{ .songs = &.{ "x", "1561837008" } }));
    try testing.expect(!seen.belongsTo(.{ .songs = &.{ "x", "y" } }));

    // The state file's form round-trips.
    const json = try std.json.Stringify.valueAlloc(a, seen.saved(), .{});
    const back = Resume.fromSaved(try std.json.parseFromSliceLeaky(Resume.Saved, a, json, .{})).?;
    try testing.expectEqualStrings("i.abc", back.id());
    try testing.expectEqualStrings("1561837008", back.catalogId());
    try testing.expectEqualStrings("l.1", back.containerId());
    try testing.expectEqual(player.Repeat.all, back.repeat);
}

test "repeat cycles off → all → one" {
    try testing.expectEqual(player.Repeat.all, repeatNext(.none));
    try testing.expectEqual(player.Repeat.one, repeatNext(.all));
    try testing.expectEqual(player.Repeat.none, repeatNext(.one));
}
