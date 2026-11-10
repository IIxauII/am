//! For the engine page module's tests and the playback endpoints' (`PageHost`): a stateful fake
//! engine page that plays `poc/web/app.js` and the server's side of the channel at once. It
//! calls the channel as the server does for a browser (`openStream`, `nextEvent`, `postReport`,
//! `postResult`, `closeStream`), so the channel's own behaviour stays under test: a stream opened
//! later starts past earlier commands, and a dead stream counts as connected until it is
//! noticed. When a launch ends, its loads go on from any gate that holds them, so their streams
//! close at once, as the server's do.
//!
//! It answers `snapshot`, `checkDeveloperToken`, `drmProbe`, `reload`, the four play calls,
//! `pause`, `resume` and `stop` as app.js does, errors in app.js's `errText` form; any other
//! method gets app.js's error for an unknown one. What MusicKit itself does (a pause that never
//! settles, a seek that doesn't land, a step it rejects) is the test's `World`.
//!
//! Each page load is a task, and each command a handler of its own, as app.js runs every event
//! stream message's handler at once. A test forces an interleaving with gates: `hold` makes the
//! nth op from now wait, `arrived` waits until it does, and `release` lets it answer as the page
//! was when it was asked, or never. Where a caller waits on no page call a gate could hold, such
//! as a play waiting on another's reload, `Caller.printed` waits until it has printed a line.
const std = @import("std");
const channel_mod = @import("channel.zig");
const engine_kind = @import("../engine.zig");
const engine_page = @import("engine_page.zig");
const host_mod = @import("host.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");
const Deadline = @import("../deadline.zig").Deadline;

const Allocator = std.mem.Allocator;
const Channel = channel_mod.Channel;
const Io = std.Io;
const Nonce = channel_mod.Nonce;
const Plays = host_mod.Plays;

/// How often a load reports while nothing happens: app.js's 1 s timer, compressed.
const report_every: Io.Duration = .fromMilliseconds(20);

pub const FakePage = struct {
    io: Io,
    gpa: Allocator,
    channel: *Channel,
    /// Guards everything below. Never held across a channel call.
    mutex: Io.Mutex = .init,
    /// Broadcast on every change to the loads and the gates.
    changed: Io.Condition = .init,
    /// Held by a report from its snapshot to its post; taken before `mutex`.
    reporting: Io.Mutex = .init,
    /// The load tasks and the command handlers.
    tasks: Io.Group = .init,
    /// The loads' ids and what was called.
    arena: std.heap.ArenaAllocator,
    /// What the next load configures with; tests change it between steps.
    world: World = .{},
    /// "1", "2", … in order; the last is current.
    loads: std.ArrayList(Load) = .empty,
    reloads: u32 = 0,
    checks: u32 = 0,
    probes: u32 = 0,
    called: std.ArrayList(Called) = .empty,
    /// Play calls and resumes the page is running (app.js `loads`), until they answer.
    play_calls: std.ArrayList(PlayCall) = .empty,
    next_play_call: u64 = 0,
    gates: std.EnumArray(Op, Gate) = .initFill(.{}),
    /// The nonce of the launch whose browser runs; null once it is gone.
    live: ?Nonce = null,
    /// Set at `deinit`: every gate lets its op through without an answer.
    closing: bool = false,

    pub const World = struct {
        /// The developer token's hash a new load configures with, and the one the daemon hands
        /// out (the launcher's `developerToken`).
        developer: []const u8 = current_token,
        /// Hashes Apple refuses: a load configured on one comes up signed out, and its check
        /// says refused.
        refused: []const []const u8 = &.{},
        /// The next load comes up signed out anyway.
        signs_out: bool = false,
        /// Firefox has its Widevine CDM: a load configures with DRM support, and a probe finds it.
        widevine: bool = true,
        /// While `widevine` is false: the CDM is installed by this probe (0: never).
        widevine_after: u32 = 0,
        /// The Music User Token stored on disk, counted by sign-ins: a load reads it when
        /// MusicKit configures.
        user_token: u64 = 0,
        /// How a new load's reports name the Music User Token MusicKit holds.
        names_user_token: NamesUserToken = .hashed,
        next: Next = .configures,
        configure_error: []const u8 = "developer token endpoint: HTTP 503",
        /// What MusicKit's `pause()` does to music that plays (for `pause` and `stop`).
        pause: Pause = .settles,
        /// A stop's `seekToTime(0)` lands; else the page gives up on it after 2 s, and the
        /// song stays paused where it was.
        seek_lands: bool = true,
        /// A `play()` still pending in MusicKit starts the music again right after the page
        /// answered a `pause`. (After a `stop` the page silences a late play() of a load it
        /// cancelled.)
        late_play: bool = false,
        /// What a `resume` of stopped live radio does: the station plays, named, at once; or
        /// its stream still loads, with no item named yet.
        live_restart: LiveRestart = .plays,
        /// MusicKit rejects a method's step: the call fails with the message.
        rejects: []const Reject = &.{},

        /// How the next load's MusicKit configures: it does, never, with a report that
        /// `parseReport` can't read, or it fails with `configure_error`.
        pub const Next = enum { configures, never, unreadable, fails };

        /// It settles and the music pauses; it settles and the music plays on; it never settles.
        pub const Pause = enum { settles, keeps_playing, never_settles };

        pub const LiveRestart = enum { plays, loads };

        /// `message` in app.js's `errText` form, as the call's error carries it.
        pub const Reject = struct { method: []const u8, message: []const u8 };

        /// By its hash, as app.js does; with a null, as app.js on a browser that can't hash;
        /// or not at all, as an older page.
        pub const NamesUserToken = enum { hashed, unnamed, absent };
    };

    pub const Load = struct {
        id: []const u8,
        nonce: Nonce,
        phase: Phase = .configuring,
        /// It has opened its stream, tried to, or waits at a held `.open`.
        reached_open: bool = false,
        /// The load a reload started in its place.
        successor: ?usize = null,
        /// The server has closed its event stream.
        stream_closed: bool = false,
        configured: bool = false,
        configure_error: ?[]const u8 = null,
        /// Its reports carry a field `parseReport` can't read.
        unreadable: bool = false,
        authorized: bool = false,
        drm: ?bool = null,
        developer: []const u8 = "",
        /// The Music User Token MusicKit holds: the one it read when it configured, or the
        /// page's own sign-in's.
        user_token: u64 = 0,
        names_user_token: World.NamesUserToken = .hashed,
        /// It has opened its event stream.
        connected: bool = false,
        music: playback.Music = .none,
        /// What it holds is a 30 s preview.
        preview: bool = false,
        /// A song, or a live radio station.
        item: Item = .song,
        /// Where the item is, in seconds. The fake's clock stands still.
        position: f64 = 0,
        /// MusicKit names the item; not yet while a live station restarts.
        named: bool = true,
        /// MusicKit names its playback state; live radio can play under a state it sends as a
        /// number.
        state_named: bool = true,
        /// The station's name; null when it stopped before MusicKit had one.
        station_name: ?[]const u8 = "Apple Music 1",
        /// Its play calls a stop could still cancel (app.js `loadPending`).
        calls_pending: u32 = 0,
        /// A resume is restarting its stopped live radio: the station is out of `stoppedLive`.
        restarting: bool = false,
        /// app.js `cancelledBelow`: plays older than the last stop are cancelled.
        cancelled_below: u64 = 0,

        pub const Item = enum { song, station };

        pub const Phase = enum {
            configuring,
            /// MusicKit configured, or failed to.
            done,
            /// A reload took it down: it answers and reports nothing any more.
            unloaded,
        };
    };

    pub const Called = struct { load: []const u8, method: []const u8 };

    const PlayCall = struct {
        id: u64,
        index: usize,
        gen: u64,
        cancelled: bool = false,
        /// A live restart that carries on past its call's answer: a stop's cancel wakes it,
        /// and it ends at once. Any other is a call held at its gate.
        ends_on_cancel: bool = false,
    };

    /// What a gate can hold.
    pub const Op = enum {
        /// A load opening its event stream: silent, it never connects.
        open,
        /// A load's MusicKit configuring: silent, it never configures.
        configure,
        /// The answers to `snapshot`, `checkDeveloperToken` and `drmProbe`.
        snapshot,
        check,
        probe,
        /// The answer to `reload`; the page reloads either way.
        reload,
        /// The reloaded load going down.
        unload,
        /// The server noticing that a reloaded load's stream is dead.
        notice,
        /// The answer to `play`, `playQueue`, `playNext` and `playLater`.
        play_queue,
        /// The answers to `pause`, `resume` and `stop`, decided once released.
        pause,
        @"resume",
        stop,
    };
    pub const Release = enum { answer, silent };

    const Gate = struct {
        /// The `armed`th op since `hold` waits; 0: none.
        armed: u32 = 0,
        seen: u32 = 0,
        waiting: bool = false,
        released: ?Release = null,
    };

    pub fn init(io: Io, gpa: Allocator, channel: *Channel) FakePage {
        return .{ .io = io, .gpa = gpa, .channel = channel, .arena = .init(gpa) };
    }

    /// Lets every held op go without an answer and ends every load and handler.
    pub fn deinit(fp: *FakePage) void {
        fp.mutex.lockUncancelable(fp.io);
        fp.closing = true;
        fp.changed.broadcast(fp.io);
        fp.mutex.unlock(fp.io);
        fp.tasks.cancel(fp.io);
        fp.loads.deinit(fp.gpa);
        fp.called.deinit(fp.gpa);
        fp.play_calls.deinit(fp.gpa);
        fp.arena.deinit();
    }

    /// A new load task on `nonce`, as a launched browser opens the engine page.
    pub fn launch(fp: *FakePage, nonce: Nonce) (Allocator.Error || Io.ConcurrentError)!void {
        const index = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            fp.live = nonce;
            break :blk try fp.addLoadLocked(nonce);
        };
        try fp.tasks.concurrent(fp.io, runLoad, .{ fp, index });
    }

    fn addLoadLocked(fp: *FakePage, nonce: Nonce) Allocator.Error!usize {
        const id = try fp.arena.allocator().print("{d}", .{fp.loads.items.len + 1});
        try fp.loads.append(fp.gpa, .{ .id = id, .nonce = nonce });
        fp.changed.broadcast(fp.io);
        return fp.loads.items.len - 1;
    }

    /// The `nth` `op` from now waits until `release`.
    pub fn hold(fp: *FakePage, op: Op, nth: u32) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.gates.set(op, .{ .armed = nth });
    }

    /// Waits until the held `op` waits; fails after 2 s.
    pub fn arrived(fp: *FakePage, op: Op) !void {
        const deadline: Deadline = .after(fp.io, .fromSeconds(2));
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        while (!fp.gates.get(op).waiting) {
            fp.changed.waitTimeout(fp.io, &fp.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return error.NeverArrived,
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// Lets the held `op` answer as the page was when it was asked, or never.
    pub fn release(fp: *FakePage, op: Op, how: Release) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.gates.getPtr(op).released = how;
        fp.changed.broadcast(fp.io);
    }

    /// What MusicKit holds on the current load: a song, at 0:00.
    pub fn set(fp: *FakePage, music: playback.Music, preview: bool) void {
        fp.setHolding(.{ .music = music, .preview = preview });
    }

    /// What MusicKit holds, in full.
    pub const Holding = struct {
        music: playback.Music,
        item: Load.Item = .song,
        preview: bool = false,
        position: f64 = 0,
        named: bool = true,
        state_named: bool = true,
        station_name: ?[]const u8 = "Apple Music 1",
    };

    /// What MusicKit holds on the current load. `starting` is MusicKit loading the item: a
    /// queue the page is still loading is a play call held at its gate.
    pub fn setHolding(fp: *FakePage, h: Holding) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        const load = &fp.loads.items[fp.loads.items.len - 1];
        load.music = h.music;
        load.item = h.item;
        load.preview = h.preview;
        load.position = h.position;
        load.named = h.named;
        load.state_named = h.state_named;
        load.station_name = h.station_name;
    }

    /// The current load posts its report now, as its timer would, so the channel's last
    /// report is what it holds.
    pub fn reportNow(fp: *FakePage) Io.Cancelable!void {
        const index = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            break :blk fp.loads.items.len - 1;
        };
        try fp.report(index);
    }

    /// Waits until the current load has opened its event stream; fails after 2 s.
    pub fn connected(fp: *FakePage) !void {
        const deadline: Deadline = .after(fp.io, .fromSeconds(2));
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        while (fp.loads.items.len == 0 or !fp.loads.items[fp.loads.items.len - 1].connected) {
            fp.changed.waitTimeout(fp.io, &fp.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return error.NeverConnected,
                error.Canceled => return error.Canceled,
            };
        }
    }

    pub fn held(fp: *FakePage) playback.Music {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.loads.items[fp.loads.items.len - 1].music;
    }

    /// The current load's id.
    pub fn current(fp: *FakePage) []const u8 {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.loads.items[fp.loads.items.len - 1].id;
    }

    /// The Music User Token the current load read: the sign-ins stored before it configured.
    pub fn userToken(fp: *FakePage) u64 {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.loads.items[fp.loads.items.len - 1].user_token;
    }

    /// A sign-in writes a new Music User Token to disk.
    pub fn storeUserToken(fp: *FakePage) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.world.user_token += 1;
    }

    /// The page's own sign-in (app.js `signIn`): MusicKit on the current load takes a new Music
    /// User Token, and the page posts it, which writes it to disk.
    pub fn signinOnPage(fp: *FakePage) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.world.user_token += 1;
        fp.loads.items[fp.loads.items.len - 1].user_token = fp.world.user_token;
    }

    /// Waits until the server has closed the event stream of the page load `load`; fails after
    /// 2 s.
    pub fn streamClosed(fp: *FakePage, load: []const u8) !void {
        const deadline: Deadline = .after(fp.io, .fromSeconds(2));
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        while (!fp.streamClosedLocked(load)) {
            fp.changed.waitTimeout(fp.io, &fp.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return error.StillOpen,
                error.Canceled => return error.Canceled,
            };
        }
    }

    fn streamClosedLocked(fp: *const FakePage, load: []const u8) bool {
        for (fp.loads.items) |l| if (std.mem.eql(u8, l.id, load)) return l.stream_closed;
        return false;
    }

    /// Whether `method` reached the page load `load`.
    pub fn calledOn(fp: *FakePage, load: []const u8, method: []const u8) bool {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        for (fp.called.items) |c| if (std.mem.eql(u8, c.load, load) and std.mem.eql(u8, c.method, method)) return true;
        return false;
    }

    /// How many page calls reached any page load so far.
    pub fn callCount(fp: *FakePage) usize {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.called.items.len;
    }

    /// Waits at `op`'s gate when this is the held one, and says how it was released. A held
    /// `.open` counts as reached for the load `index`. A load whose launch ended goes on at once,
    /// silent: its browser is gone.
    fn pass(fp: *FakePage, op: Op, index: usize) Io.Cancelable!Release {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        const gate = fp.gates.getPtr(op);
        if (gate.armed == 0) return .answer;
        gate.seen += 1;
        if (gate.seen != gate.armed) return .answer;
        gate.waiting = true;
        if (op == .open) fp.loads.items[index].reached_open = true;
        fp.changed.broadcast(fp.io);
        defer gate.waiting = false;
        while (gate.released == null and !fp.closing and !fp.goneLocked(index)) try fp.changed.wait(fp.io, &fp.mutex);
        return gate.released orelse .silent;
    }

    /// Whether the launch of the load `index` has ended.
    fn goneLocked(fp: *const FakePage, index: usize) bool {
        const live = fp.live orelse return true;
        return !std.mem.eql(u8, &live, &fp.loads.items[index].nonce);
    }

    /// The browser of the current launch is gone. Its loads go on from any gate that holds
    /// them, so each stream sees the launch end and closes, as the server's stream handler does
    /// at its next wait.
    fn browserGone(fp: *FakePage) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.live = null;
        fp.changed.broadcast(fp.io);
    }

    /// One page load, from its event stream to its end: a reload, or the end of its launch.
    fn runLoad(fp: *FakePage, index: usize) Io.Cancelable!void {
        const nonce = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            break :blk fp.loads.items[index].nonce;
        };
        const opens = try fp.pass(.open, index);
        var stream = if (opens == .answer) fp.channel.openStream(&nonce) else null;
        fp.reach(index, stream != null);
        // A page whose launch is over unloads itself (app.js `claimed`).
        var open = stream != null;
        defer if (open) fp.closeStream(index, stream.?);
        if (!open) return;
        try fp.report(index);
        if (try fp.pass(.configure, index) == .answer) fp.configure(index);
        try fp.report(index);

        var arena: std.heap.ArenaAllocator = .init(fp.gpa);
        defer arena.deinit();
        // Ends at `deinit` by itself: a cancelation can be lost to an allocation that unwinds a
        // stack trace for the testing allocator, and swallows the cancelation with its read.
        while (!fp.isClosing()) {
            if (fp.phase(index) == .unloaded) {
                // The server notices a dead stream only at its next write: until then the old
                // load still counts as connected, by default until the new load opened its stream.
                try fp.waitReached(index);
                _ = try fp.pass(.notice, index);
                open = false;
                fp.closeStream(index, stream.?);
                return;
            }
            _ = arena.reset(.retain_capacity);
            const event = fp.channel.nextEvent(arena.allocator(), &stream.?, report_every) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                error.OutOfMemory => continue,
            };
            switch (event) {
                .command => |json| {
                    if (fp.phase(index) == .unloaded) continue;
                    const command = fp.gpa.dupe(u8, json) catch continue;
                    fp.tasks.concurrent(fp.io, handle, .{ fp, index, command }) catch fp.gpa.free(command);
                },
                .ping => try fp.report(index),
                .closed => return,
            }
        }
    }

    /// The server closes the load `index`'s event stream.
    fn closeStream(fp: *FakePage, index: usize, stream: Channel.Stream) void {
        fp.channel.closeStream(stream);
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.loads.items[index].stream_closed = true;
        fp.loads.items[index].connected = false;
        fp.changed.broadcast(fp.io);
    }

    fn reach(fp: *FakePage, index: usize, opened: bool) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fp.loads.items[index].reached_open = true;
        fp.loads.items[index].connected = opened;
        fp.changed.broadcast(fp.io);
    }

    /// Until the load that replaced `index` reached its open.
    fn waitReached(fp: *FakePage, index: usize) Io.Cancelable!void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        while (!fp.closing) {
            const next = fp.loads.items[index].successor orelse unreachable;
            if (fp.loads.items[next].reached_open) return;
            try fp.changed.wait(fp.io, &fp.mutex);
        }
    }

    fn isClosing(fp: *FakePage) bool {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.closing;
    }

    fn phase(fp: *FakePage, index: usize) Load.Phase {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return fp.loads.items[index].phase;
    }

    /// MusicKit configures from the world as it is now.
    fn configure(fp: *FakePage, index: usize) void {
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        const w = fp.world;
        const load = &fp.loads.items[index];
        if (load.phase == .unloaded) return;
        switch (w.next) {
            .never => return,
            .fails => load.configure_error = w.configure_error,
            .configures, .unreadable => {
                load.configured = true;
                load.developer = w.developer;
                load.user_token = w.user_token;
                load.names_user_token = w.names_user_token;
                load.drm = w.widevine;
                load.authorized = !w.signs_out and !refused(w, w.developer);
                load.unreadable = w.next == .unreadable;
            },
        }
        load.phase = .done;
    }

    fn refused(w: World, developer: []const u8) bool {
        for (w.refused) |hash| if (std.mem.eql(u8, hash, developer)) return true;
        return false;
    }

    /// Posts the load's report, as app.js's timer does; an unloaded load sends none. One at a
    /// time, from its snapshot to its post: a report posted after `reportNow` was taken after it.
    fn report(fp: *FakePage, index: usize) Io.Cancelable!void {
        fp.reporting.lockUncancelable(fp.io);
        defer fp.reporting.unlock(fp.io);
        var arena: std.heap.ArenaAllocator = .init(fp.gpa);
        defer arena.deinit();
        const body = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            const load = fp.loads.items[index];
            if (load.phase == .unloaded) return;
            break :blk snapshotOf(arena.allocator(), load) catch return;
        };
        _ = fp.channel.postReport(body) catch {};
    }

    /// The load's `snapshot()`, in the shape app.js sends and `parseReport` reads.
    fn snapshotOf(a: Allocator, load: Load) Allocator.Error![]const u8 {
        var out: Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        writeSnapshot(w, load) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeSnapshot(w: *Io.Writer, load: Load) Io.Writer.Error!void {
        try w.print("{{\"engine\":\"{s}\",\"load\":\"{s}\",\"userAgent\":\"Firefox/140\",\"webdriver\":false", .{ &load.nonce, load.id });
        try w.print(",\"configured\":{},\"configureError\":{f}", .{ load.configured, std.json.fmt(load.configure_error, .{}) });
        if (!load.configured) {
            return w.writeAll(",\"musicKitVersion\":null,\"developerToken\":null,\"musicUserToken\":null,\"browserSupportsVideoDrm\":null,\"isAuthorized\":false,\"storefrontId\":null,\"subscriptionActive\":null,\"playbackState\":null,\"nowPlaying\":null,\"loadPending\":false,\"stoppedLive\":null}");
        }
        try w.writeAll(",\"musicKitVersion\":\"3.2526.0\"");
        if (load.developer.len > 0)
            try w.print(",\"developerToken\":{{\"kid\":\"KEY\",\"exp\":1793604800,\"hash\":\"{s}\"}}", .{load.developer})
        else
            try w.writeAll(",\"developerToken\":null");
        switch (load.names_user_token) {
            .hashed => try w.print(",\"musicUserToken\":{{\"kid\":null,\"exp\":null,\"hash\":\"{s}\"}}", .{&userTokenHash(load.user_token)}),
            .unnamed => try w.writeAll(",\"musicUserToken\":null"),
            .absent => {},
        }
        try w.print(",\"browserSupportsVideoDrm\":{f}", .{std.json.fmt(load.drm, .{})});
        if (load.unreadable)
            try w.writeAll(",\"isAuthorized\":\"yes\"")
        else
            try w.print(",\"isAuthorized\":{}", .{load.authorized});
        if (load.authorized)
            try w.writeAll(",\"storefrontId\":\"gb\",\"subscriptionActive\":true")
        else
            try w.writeAll(",\"storefrontId\":null,\"subscriptionActive\":null");
        const station = load.item == .station;
        const state = switch (load.music) {
            .none => "none",
            .playing => if (load.state_named) "playing" else "11",
            .starting => "loading",
            .paused => "paused",
            .stopped_live => "stopped",
        };
        const item: ?[]const u8 = switch (load.music) {
            .none, .stopped_live => null,
            .playing, .paused, .starting => if (!load.named) null else if (station) item_station else if (load.preview) item_preview else item_full,
        };
        try w.print(",\"playbackState\":\"{s}\",\"isPlaying\":{},\"loadPending\":{}", .{ state, load.music == .playing, load.calls_pending > 0 });
        try w.print(",\"currentPlaybackTime\":{d}", .{load.position});
        if (item != null and !station)
            try w.print(",\"currentPlaybackDuration\":{d}", .{@as(u32, if (load.preview) 30 else 175)})
        else
            try w.writeAll(",\"currentPlaybackDuration\":null");
        try w.print(",\"nowPlaying\":{s}", .{item orelse "null"});
        if (load.music == .stopped_live and !load.restarting)
            try w.print(",\"stoppedLive\":{{\"id\":\"ra.978194965\",\"name\":{f}}}", .{std.json.fmt(load.station_name, .{})})
        else
            try w.writeAll(",\"stoppedLive\":null");
        try w.writeAll("}");
    }

    const item_full =
        \\{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"encryptedFull"}
    ;
    const item_preview =
        \\{"id":"1561837008","title":"Shy Away","artist":"Twenty One Pilots","catalogDurationSec":175.08,"playbackType":"preview"}
    ;
    const item_station =
        \\{"id":"ra.978194965","title":"Apple Music 1","artist":"Apple Music","playbackType":"encryptedFull","isLive":true}
    ;

    /// Runs one command as app.js does, on the load whose stream it came over.
    fn handle(fp: *FakePage, index: usize, command: []u8) Io.Cancelable!void {
        defer fp.gpa.free(command);
        var arena: std.heap.ArenaAllocator = .init(fp.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSliceLeaky(struct { id: u64, method: []const u8, args: std.json.Value }, a, command, .{}) catch return;
        const is_reload = std.mem.eql(u8, parsed.method, "reload");
        const answer = fp.run(a, index, parsed.method, generationOf(parsed.args)) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return,
        };
        if (answer) |fields| {
            const body = std.fmt.allocPrint(a, "{{\"id\":{d},{s}}}", .{ parsed.id, fields }) catch return;
            _ = fp.channel.postResult(body) catch {};
        }
        // app.js answers, then reloads 100 ms later; a reload whose answer was lost still reloads.
        if (is_reload and fp.phase(index) != .unloaded) fp.reload(index) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return,
        };
    }

    /// A play call's or a stop's generation: its last argument, when that is an integer.
    fn generationOf(args: std.json.Value) ?u64 {
        const items = switch (args) {
            .array => |list| list.items,
            else => return null,
        };
        if (items.len == 0) return null;
        return switch (items[items.len - 1]) {
            .integer => |n| if (n >= 0) @intCast(n) else null,
            else => null,
        };
    }

    /// The answer's fields (`"ok":…`), or null for none.
    fn run(fp: *FakePage, a: Allocator, index: usize, method: []const u8, gen: ?u64) (Allocator.Error || Io.Cancelable)!?[]const u8 {
        const op: Op = if (std.mem.eql(u8, method, "snapshot"))
            .snapshot
        else if (std.mem.eql(u8, method, "checkDeveloperToken"))
            .check
        else if (std.mem.eql(u8, method, "drmProbe"))
            .probe
        else if (std.mem.eql(u8, method, "reload"))
            .reload
        else if (std.mem.eql(u8, method, "play") or std.mem.eql(u8, method, "playQueue") or std.mem.eql(u8, method, "playNext") or std.mem.eql(u8, method, "playLater"))
            .play_queue
        else if (std.mem.eql(u8, method, "pause"))
            .pause
        else if (std.mem.eql(u8, method, "resume"))
            .@"resume"
        else if (std.mem.eql(u8, method, "stop"))
            .stop
        else
            return try a.print("\"ok\":false,\"error\":\"TypeError | am[method] is not a function: {s}\"", .{method});

        // A play call or a resume runs in app.js `load` from the moment it is asked until it
        // answers: a stop meanwhile cancels it.
        var play_call: ?u64 = null;
        // What the page answers is decided as it is when asked.
        const asked: ?[]const u8 = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            const load = &fp.loads.items[index];
            if (load.phase == .unloaded) return null;
            try fp.called.append(fp.gpa, .{ .load = load.id, .method = try fp.arena.allocator().dupe(u8, method) });
            if (op == .play_queue or op == .@"resume") {
                fp.next_play_call += 1;
                play_call = fp.next_play_call;
                try fp.play_calls.append(fp.gpa, .{ .id = fp.next_play_call, .index = index, .gen = gen orelse load.cancelled_below });
                load.calls_pending += 1;
                // app.js takes the stopped station first: the page names none while it restarts.
                if (op == .@"resume" and load.music == .stopped_live) load.restarting = true;
            }
            break :blk switch (op) {
                .snapshot => try a.print("\"ok\":true,\"value\":{s}", .{try snapshotOf(a, load.*)}),
                .check => check: {
                    fp.checks += 1;
                    if (!load.configured) break :check not_configured;
                    break :check if (refused(fp.world, load.developer))
                        "\"ok\":true,\"value\":{\"refused\":true,\"error\":\"MKError | UNAUTHORIZED_ERROR | 401\"}"
                    else
                        "\"ok\":true,\"value\":{\"refused\":false}";
                },
                .probe => probe: {
                    fp.probes += 1;
                    if (!fp.world.widevine and fp.world.widevine_after > 0 and fp.probes >= fp.world.widevine_after) fp.world.widevine = true;
                    break :probe if (fp.world.widevine)
                        "\"ok\":true,\"value\":{\"h264\":\"probably\",\"aac\":\"probably\",\"mseAac\":true,\"widevine\":true}"
                    else
                        "\"ok\":true,\"value\":{\"h264\":\"probably\",\"aac\":\"probably\",\"mseAac\":true,\"widevine\":false,\"widevineError\":\"NotSupportedError: Key system configuration is not supported\"}";
                },
                .reload => reload: {
                    fp.reloads += 1;
                    break :reload "\"ok\":true,\"value\":null";
                },
                .play_queue, .pause, .@"resume", .stop => null,
                .open, .configure, .unload, .notice => unreachable,
            };
        };

        const released = try fp.pass(op, index);
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        // A play call that ended: answered, or never.
        const cancelled = if (play_call) |id| fp.endPlayCallLocked(id) else false;
        const load = &fp.loads.items[index];
        load.restarting = false;
        if (released == .silent) return null;
        const call_gen = gen orelse load.cancelled_below;
        return switch (op) {
            .play_queue => {
                if (try requireMusicFor(load, call_gen)) |err| return err;
                if (cancelled or call_gen < load.cancelled_below) return stopped_before_start;
                if (rejected(fp.world, method)) |why| return try pageError(a, why);
                // Queued, and MusicKit still loads the song after its play() resolved.
                load.music = .starting;
                load.item = .song;
                load.preview = false;
                load.named = true;
                load.position = 0;
                return try answerOf(a, load.*, &.{}, null);
            },
            .@"resume" => try fp.resumeLocked(a, index, call_gen, cancelled),
            .pause => try fp.pauseLocked(a, load),
            .stop => try fp.stopLocked(a, index, gen),
            else => asked,
        };
    }

    /// app.js `requireMusicFor`: on a page whose MusicKit isn't configured, a play older than a
    /// stop that reached it was stopped before it started; any other gets `requireMusic`'s error.
    fn requireMusicFor(load: *const Load, gen: u64) Allocator.Error!?[]const u8 {
        if (load.configured) return null;
        return if (gen < load.cancelled_below) stopped_before_start else not_configured;
    }

    /// Ends the play call `id`: whether a stop cancelled it meanwhile.
    fn endPlayCallLocked(fp: *FakePage, id: u64) bool {
        for (fp.play_calls.items, 0..) |c, i| if (c.id == id) {
            _ = fp.play_calls.swapRemove(i);
            if (!c.cancelled) fp.loads.items[c.index].calls_pending -= 1;
            return c.cancelled;
        };
        return false;
    }

    /// app.js `resume`: stopped live radio is queued again, anything else plays on. It runs in
    /// `load` with its generation either way.
    fn resumeLocked(fp: *FakePage, a: Allocator, index: usize, gen: u64, cancelled: bool) Allocator.Error![]const u8 {
        const load = &fp.loads.items[index];
        if (try requireMusicFor(load, gen)) |err| return err;
        // Cancelled, the station stays the one to restart.
        if (cancelled or gen < load.cancelled_below) return stopped_before_start;
        if (rejected(fp.world, "resume")) |why| {
            // The restart had taken the station: MusicKit dropped it, and the queue failed.
            if (load.music == .stopped_live) load.music = .none;
            return pageError(a, why);
        }
        var gave_up: GaveUp = .{};
        switch (load.music) {
            .stopped_live => {
                load.item = .station;
                load.position = 0;
                switch (fp.world.live_restart) {
                    .plays => {
                        load.music = .playing;
                        load.named = true;
                    },
                    // Past its bound the restart carries on as a load: a stop still cancels it.
                    .loads => {
                        load.music = .starting;
                        load.named = false;
                        gave_up.add("setQueue({station}) and play() after 5 s");
                        fp.next_play_call += 1;
                        try fp.play_calls.append(fp.gpa, .{ .id = fp.next_play_call, .index = index, .gen = gen, .ends_on_cancel = true });
                        load.calls_pending += 1;
                    },
                }
            },
            .paused, .starting => load.music = .playing,
            .playing, .none => {},
        }
        return answerOf(a, load.*, gave_up.slice(), null);
    }

    /// app.js `pause`: live radio can't pause, it stops.
    fn pauseLocked(fp: *FakePage, a: Allocator, load: *Load) Allocator.Error![]const u8 {
        if (!load.configured) return not_configured;
        if (rejected(fp.world, "pause")) |why| return pageError(a, why);
        var gave_up: GaveUp = .{};
        if (isLive(load.*)) {
            stopLive(load);
        } else if (try fp.pauseNowLocked(a, load, &gave_up)) |err| return err;
        const answer = try answerOf(a, load.*, gave_up.slice(), null);
        if (fp.world.late_play) load.music = .playing;
        return answer;
    }

    /// app.js `stop`: silent, rewound, and every older play call cancelled. A page whose
    /// MusicKit isn't configured has started nothing, and only raises its cancel floor.
    fn stopLocked(fp: *FakePage, a: Allocator, index: usize, gen: ?u64) Allocator.Error![]const u8 {
        const load = &fp.loads.items[index];
        if (!load.configured) {
            if (gen) |stop_gen| load.cancelled_below = @max(load.cancelled_below, stop_gen);
            return answerOf(a, load.*, &.{}, 0);
        }
        if (rejected(fp.world, "stop")) |why| return pageError(a, why);
        var gave_up: GaveUp = .{};
        if (isLive(load.*)) {
            stopLive(load);
        } else {
            if (try fp.pauseNowLocked(a, load, &gave_up)) |err| return err;
            if (hasItem(load.*) and load.position != 0) {
                if (fp.world.seek_lands) load.position = 0 else gave_up.add("seekToTime(0) after 2 s");
            }
        }
        var count: u32 = 0;
        var still_held = false;
        if (gen) |stop_gen| if (stop_gen > load.cancelled_below) {
            var i: usize = 0;
            while (i < fp.play_calls.items.len) {
                const c = &fp.play_calls.items[i];
                if (c.index != index or c.gen >= stop_gen or c.cancelled) {
                    i += 1;
                    continue;
                }
                load.calls_pending -= 1;
                count += 1;
                if (c.ends_on_cancel) {
                    // Woken, it ends at once; the station stays the one to restart.
                    _ = fp.play_calls.swapRemove(i);
                    if (load.music == .starting and load.item == .station) load.music = .stopped_live;
                    continue;
                }
                // Held at its gate, it doesn't end within the stop's wait for it.
                c.cancelled = true;
                still_held = true;
                i += 1;
            }
            load.cancelled_below = stop_gen;
        };
        if (still_held) gave_up.add("the cancelled loads after 2 s");
        return answerOf(a, load.*, gave_up.slice(), count);
    }

    /// MusicKit names an item: a song, or a station.
    fn hasItem(load: Load) bool {
        return load.named and switch (load.music) {
            .playing, .paused, .starting => true,
            .none, .stopped_live => false,
        };
    }

    /// MusicKit holds a named live station (app.js `isLive`).
    fn isLive(load: Load) bool {
        return load.item == .station and hasItem(load);
    }

    /// app.js `stopLive`: MusicKit drops the station, and a resume restarts it.
    fn stopLive(load: *Load) void {
        load.music = .stopped_live;
        load.position = 0;
    }

    /// app.js `pauseNow` and `requireSilent`: MusicKit's `pause()` on music that plays or loads,
    /// and an error when the music still plays after it. A song that loads stops loading;
    /// with no item named, nothing is left.
    fn pauseNowLocked(fp: *FakePage, a: Allocator, load: *Load, gave_up: *GaveUp) Allocator.Error!?[]const u8 {
        if (load.music != .playing and load.music != .starting) return null;
        switch (fp.world.pause) {
            .settles => load.music = if (load.named) .paused else .none,
            .keeps_playing => {},
            .never_settles => gave_up.add("pause() after 2 s"),
        }
        if (load.music != .playing) return null;
        return try pageError(a, if (gave_up.len > 0)
            try std.fmt.allocPrint(a, "Error | gave up waiting on {s}; MusicKit still plays", .{gave_up.items[0]})
        else
            "Error | MusicKit still plays after pause()");
    }

    /// What a call gave up waiting on (app.js `settle`), for its answer's `gaveUp`.
    const GaveUp = struct {
        items: [2][]const u8 = undefined,
        len: usize = 0,

        fn add(g: *GaveUp, what: []const u8) void {
            g.items[g.len] = what;
            g.len += 1;
        }

        fn slice(g: *const GaveUp) []const []const u8 {
            return g.items[0..g.len];
        }
    };

    /// app.js `answer`: the snapshot, with what it gave up on and the play calls a stop
    /// cancelled.
    fn answerOf(a: Allocator, load: Load, gave_up: []const []const u8, cancelled: ?u32) Allocator.Error![]const u8 {
        const snap = try snapshotOf(a, load);
        var out: Io.Writer.Allocating = .init(a);
        writeAnswer(&out.writer, snap, gave_up, cancelled) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeAnswer(w: *Io.Writer, snap: []const u8, gave_up: []const []const u8, cancelled: ?u32) Io.Writer.Error!void {
        try w.print("\"ok\":true,\"value\":{s}", .{snap[0 .. snap.len - 1]});
        if (gave_up.len > 0) try w.print(",\"gaveUp\":{f}", .{std.json.fmt(gave_up, .{})});
        if (cancelled) |n| try w.print(",\"cancelled\":{d}", .{n});
        try w.writeAll("}");
    }

    fn rejected(w: World, method: []const u8) ?[]const u8 {
        for (w.rejects) |r| if (std.mem.eql(u8, r.method, method)) return r.message;
        return null;
    }

    fn pageError(a: Allocator, message: []const u8) Allocator.Error![]const u8 {
        return a.print("\"ok\":false,\"error\":{f}", .{std.json.fmt(message, .{})});
    }

    /// app.js `requireMusic` on a page whose MusicKit isn't configured.
    const not_configured = "\"ok\":false,\"error\":\"Error | MusicKit is not configured yet\"";
    /// app.js `STOPPED_BEFORE_START`, thrown as a plain object: its `errText` is the message.
    const stopped_before_start = "\"ok\":false,\"error\":\"stopped before it started\"";

    /// The page goes down and a new load starts on the same nonce. A second reload sent to the
    /// same load finds it gone.
    fn reload(fp: *FakePage, index: usize) (Allocator.Error || Io.Cancelable)!void {
        _ = try fp.pass(.unload, index);
        const next = blk: {
            fp.mutex.lockUncancelable(fp.io);
            defer fp.mutex.unlock(fp.io);
            if (fp.loads.items[index].phase == .unloaded) return;
            const nonce = fp.loads.items[index].nonce;
            fp.loads.items[index].phase = .unloaded;
            const next = try fp.addLoadLocked(nonce);
            fp.loads.items[index].successor = next;
            break :blk next;
        };
        fp.tasks.concurrent(fp.io, runLoad, .{ fp, next }) catch {};
    }
};

/// The developer token's hash a load configures with unless a test says otherwise, and the one
/// the launcher hands out.
pub const current_token = "c0ffee00c0ffee00";
/// An older developer token's hash.
pub const older_token = "01d01d0001d01d00";

/// The hash of the Music User Token the `n`th sign-in stored; 0: the one stored before.
pub fn userTokenHash(n: u64) [16]u8 {
    var hash: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hash, "{x:0>16}", .{n}) catch unreachable;
    return hash;
}

/// The port's test adapter: launches the fake page, as the Daemon launches the browser.
pub const FakeLauncher = struct {
    fp: *FakePage,
    /// As the Daemon's `engine_mutex`: held across a launch.
    mutex: Io.Mutex = .init,
    live: ?Live = null,
    launches: u32 = 0,
    /// The relaunches the module asked for, whether or not one happened.
    relaunch_asks: u32 = 0,
    /// Every line for the daemon's log; guarded by the fake page's mutex.
    logged: std.ArrayList([]const u8) = .empty,
    /// Every launch fails with this problem while it is set (`setRefuse`).
    refuse: ?[]const u8 = null,
    /// The next launch that starts the engine, held where its caller has the launch and
    /// hasn't recorded it yet; guarded by the fake page's mutex.
    held: Hold = .off,

    const Hold = enum { off, armed, waiting, released };

    const Live = struct { generation: u64, at: Io.Timestamp, pid: @import("../platform.zig").ProcessId };

    pub const log_path = "/home/u/.config/am/engine.log";

    pub fn port(fl: *FakeLauncher) engine_page.Port {
        return .{ .ptr = fl, .vtable = &.{ .launch = launch, .developerToken = developerToken, .userToken = userToken, .log = log } };
    }

    pub fn deinit(fl: *FakeLauncher) void {
        fl.logged.deinit(fl.fp.gpa);
    }

    /// How many launches started an engine so far; fine while a caller may still launch.
    pub fn launchCount(fl: *FakeLauncher) u32 {
        const io = fl.fp.io;
        fl.mutex.lockUncancelable(io);
        defer fl.mutex.unlock(io);
        return fl.launches;
    }

    /// Launches fail with `why` from now on, or no longer (null); fine while a caller may
    /// still launch.
    pub fn setRefuse(fl: *FakeLauncher, why: ?[]const u8) void {
        const io = fl.fp.io;
        fl.mutex.lockUncancelable(io);
        defer fl.mutex.unlock(io);
        fl.refuse = why;
    }

    fn of(ptr: *anyopaque) *FakeLauncher {
        return @ptrCast(@alignCast(ptr));
    }

    /// The next launch that starts the engine sets the launch's nonce and opens the page, then
    /// waits until `releaseLaunch` before it returns, with the launcher's mutex free: as a
    /// caller that has the launch from the Daemon and hasn't recorded it yet. A launch call
    /// meanwhile finds the engine running.
    pub fn holdLaunch(fl: *FakeLauncher) void {
        const fp = fl.fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fl.held = .armed;
    }

    /// Waits until the held launch waits; fails after 2 s.
    pub fn arrivedLaunch(fl: *FakeLauncher) !void {
        const fp = fl.fp;
        const deadline: Deadline = .after(fp.io, .fromSeconds(2));
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        while (fl.held != .waiting) {
            fp.changed.waitTimeout(fp.io, &fp.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return error.NeverArrived,
                error.Canceled => return error.Canceled,
            };
        }
    }

    pub fn releaseLaunch(fl: *FakeLauncher) void {
        const fp = fl.fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        fl.held = .released;
        fp.changed.broadcast(fp.io);
    }

    fn launch(ptr: *anyopaque, arena: Allocator, how: engine_page.Launch.How, problem: *[]const u8) host_mod.EngineError!engine_page.Launch {
        const fl = of(ptr);
        const got = try fl.launchLocked(arena, how, problem);
        if (got.launched) try fl.passHold();
        return got;
    }

    /// Waits at the launch hold when it is armed.
    fn passHold(fl: *FakeLauncher) Io.Cancelable!void {
        const fp = fl.fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        if (fl.held != .armed) return;
        fl.held = .waiting;
        fp.changed.broadcast(fp.io);
        while (fl.held == .waiting and !fp.closing) try fp.changed.wait(fp.io, &fp.mutex);
        fl.held = .off;
    }

    fn launchLocked(fl: *FakeLauncher, _: Allocator, how: engine_page.Launch.How, problem: *[]const u8) host_mod.EngineError!engine_page.Launch {
        const io = fl.fp.io;
        try fl.mutex.lock(io);
        defer fl.mutex.unlock(io);
        if (how == .relaunch) fl.relaunch_asks += 1;
        if (fl.refuse) |why| {
            problem.* = why;
            return error.EngineFailed;
        }
        if (fl.live) |live| if (fl.fp.channel.currentLaunch() == live.generation) {
            switch (how) {
                .launch => return fl.launched(live, false),
                .relaunch => |g| {
                    // As the Daemon: only the launch named, and only while its page isn't
                    // connected.
                    if (g != live.generation or fl.fp.channel.connected()) return fl.launched(live, false);
                    fl.logLine("the engine stopped answering; relaunching it");
                    fl.fp.channel.setNonce(null);
                    fl.fp.browserGone();
                },
            }
        };
        const nonce = channel_mod.newNonce(io);
        fl.fp.channel.setNonce(nonce);
        fl.launches += 1;
        const live: Live = .{ .generation = fl.fp.channel.currentLaunch().?, .at = Io.Clock.awake.now(io), .pid = 4242 + @as(i32, @intCast(fl.launches)) };
        fl.live = live;
        fl.fp.launch(nonce) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ConcurrencyUnavailable => {
                problem.* = "no thread for the engine page";
                return error.EngineFailed;
            },
        };
        return fl.launched(live, true);
    }

    fn launched(_: *FakeLauncher, live: Live, now: bool) engine_page.Launch {
        return .{ .generation = live.generation, .kind = "firefox", .pid = live.pid, .launched = now, .headless = true, .at = live.at, .log_path = log_path };
    }

    fn developerToken(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId {
        const fp = of(ptr).fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return .{ .hash = try arena.dupe(u8, fp.world.developer) };
    }

    fn userToken(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId {
        const fp = of(ptr).fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        return .{ .hash = try arena.dupe(u8, &userTokenHash(fp.world.user_token)) };
    }

    fn log(ptr: *anyopaque, line: []const u8) void {
        of(ptr).logLine(line);
    }

    fn logLine(fl: *FakeLauncher, line: []const u8) void {
        const fp = fl.fp;
        fp.mutex.lockUncancelable(fp.io);
        defer fp.mutex.unlock(fp.io);
        const copy = fp.arena.allocator().dupe(u8, line) catch return;
        fl.logged.append(fp.gpa, copy) catch {};
    }

    /// The engine stops, as the Daemon's engine stop and the supervisor end it.
    pub fn stop(fl: *FakeLauncher) void {
        const io = fl.fp.io;
        fl.mutex.lockUncancelable(io);
        defer fl.mutex.unlock(io);
        fl.live = null;
        fl.fp.channel.setNonce(null);
        fl.fp.browserGone();
    }
};

/// A real channel and `Plays`, the fake page and launcher, and the engine page module over them.
pub const Rig = struct {
    io: Io,
    gpa: Allocator,
    channel: Channel,
    plays: Plays = .{},
    fp: FakePage,
    launcher: FakeLauncher,
    page: engine_page.EnginePage,
    /// Each caller's arena, each its own, and the callers; guarded by `arenas_mutex`.
    arenas_mutex: Io.Mutex = .init,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    callers: std.ArrayList(*Caller) = .empty,

    /// Every wait shortened; a test about a deadline shortens that one further.
    pub const timing: engine_page.Timing = .{
        .launch_wait = .fromSeconds(2),
        .reload_wait = .fromSeconds(2),
        .signin_wait = .fromSeconds(1),
        .widevine_wait = .fromMilliseconds(500),
        .widevine_poll = .fromMilliseconds(20),
        .look = .fromMilliseconds(500),
        .check = .fromMilliseconds(500),
        .probe = .fromMilliseconds(500),
        .send = .fromMilliseconds(500),
        .step = .fromMilliseconds(20),
    };

    pub fn init(r: *Rig, t: engine_page.Timing) void {
        const io = std.testing.io;
        const gpa = std.testing.allocator;
        r.* = .{ .io = io, .gpa = gpa, .channel = .init(io, gpa), .fp = undefined, .launcher = undefined, .page = undefined };
        r.fp = .init(io, gpa, &r.channel);
        r.launcher = .{ .fp = &r.fp };
        r.page = .init(io, &r.channel, &r.plays, r.launcher.port(), t);
    }

    pub fn deinit(r: *Rig) void {
        r.fp.deinit();
        r.launcher.deinit();
        r.channel.deinit();
        for (r.callers.items) |c| {
            c.seen.deinit(r.gpa);
            r.gpa.destroy(c);
        }
        r.callers.deinit(r.gpa);
        for (r.arenas.items) |arena| {
            arena.deinit();
            r.gpa.destroy(arena);
        }
        r.arenas.deinit(r.gpa);
    }

    /// A new arena for one caller.
    pub fn newArena(r: *Rig) Allocator {
        r.arenas_mutex.lockUncancelable(r.io);
        defer r.arenas_mutex.unlock(r.io);
        const arena = r.gpa.create(std.heap.ArenaAllocator) catch @panic("out of memory");
        arena.* = .init(r.gpa);
        r.arenas.append(r.gpa, arena) catch @panic("out of memory");
        return arena.allocator();
    }

    /// What a caller printed, as the CLI shows it, and what it got.
    pub const Ran = struct { out: []const u8, outcome: engine_page.Outcome };

    /// A new caller, with a reply and an arena of its own.
    pub fn caller(r: *Rig) *Caller {
        const a = r.newArena();
        r.arenas_mutex.lockUncancelable(r.io);
        defer r.arenas_mutex.unlock(r.io);
        const c = r.gpa.create(Caller) catch @panic("out of memory");
        c.* = .{ .rig = r, .t = undefined };
        c.t.init(a);
        c.t.reply.flushFn = Caller.flushed;
        c.t.reply.flush_ctx = c;
        r.callers.append(r.gpa, c) catch @panic("out of memory");
        return c;
    }

    /// `start` and a repair for `p`, as `am play` and the TUI's queue make them.
    pub fn play(r: *Rig, p: *const Plays.Play) !Ran {
        return r.caller().play(p);
    }

    /// `start` and a repair if idle, as `am doctor` makes them.
    pub fn doctor(r: *Rig, user_token_ok: bool) !Ran {
        return r.caller().doctor(user_token_ok);
    }

    /// The sign-in: it writes the new Music User Token, then tells the module, as the Daemon's
    /// `storeUserToken` does.
    pub fn signin(r: *Rig) !engine_page.NewUserToken {
        r.fp.storeUserToken();
        return r.page.newUserToken(r.newArena());
    }

    /// The engine page's own sign-in: MusicKit on the page takes the new token and the page
    /// posts it, and the Daemon stores it and tells the module, as for `signin`.
    pub fn signinOnPage(r: *Rig) !engine_page.NewUserToken {
        r.fp.signinOnPage();
        return r.page.newUserToken(r.newArena());
    }

    /// A play that makes no repair (Space, play-next, play-later), as `Caller.controlPlay`, with
    /// the page's `playNext`.
    pub fn controlPlay(r: *Rig) !void {
        return r.caller().controlPlay("playNext");
    }

    /// `p`'s page call: `play`, `playQueue`, `playNext` or `playLater`, with one song.
    pub fn sendMusic(r: *Rig, p: *Plays.Play, method: []const u8) !void {
        if (!p.send()) return error.TestUnexpectedResult;
        const a = r.newArena();
        const args = try a.print("[{{\"songs\":[\"1561837008\"]}},{d}]", .{p.generation});
        _ = try r.channel.call(a, method, args, .fromSeconds(2));
    }
};

/// One caller of the engine page module, for a test that runs callers at once: its reply tells
/// the test what it has printed so far, so the test can wait for a line (`printed`) where the
/// caller waits on no page call a gate could hold, such as a play waiting on another's reload.
pub const Caller = struct {
    rig: *Rig,
    t: protocol.TestReply,
    /// Guards `seen`.
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    /// The wire as of the caller's last print, copied at each flush: the caller writes the wire
    /// itself, while the test reads this.
    seen: std.ArrayList(u8) = .empty,

    /// `start` and a repair for `p`, as `am play` and the TUI's queue make them.
    pub fn play(c: *Caller, p: *const Plays.Play) !Rig.Ran {
        return c.ran(.{ .for_play = p }, false);
    }

    /// `start` and a repair if idle, as `am doctor` makes them.
    pub fn doctor(c: *Caller, user_token_ok: bool) !Rig.Ran {
        return c.ran(.{ .if_idle = .{ .user_token_ok = user_token_ok } }, false);
    }

    /// `start`, `probe` and a repair if idle, in the order `am doctor` makes them all.
    pub fn doctorWithProbe(c: *Caller, user_token_ok: bool) !Rig.Ran {
        return c.ran(.{ .if_idle = .{ .user_token_ok = user_token_ok } }, true);
    }

    /// A play that makes no repair (Space, `am resume`, play-next, play-later): begins, joins a
    /// reload in flight, sends `method` over the channel, and ends once the page answered.
    pub fn controlPlay(c: *Caller, method: []const u8) !void {
        var p = c.rig.plays.begin();
        defer p.end();
        try c.rig.page.page().joinReload(&c.t.reply, &p);
        try c.rig.sendMusic(&p, method);
    }

    /// `probe`, as `am doctor` asks for its codecs and Widevine lines.
    pub fn probe(c: *Caller) !engine_page.Probe {
        return c.rig.page.page().probe(&c.t.reply);
    }

    /// What it printed so far, once it has returned.
    pub fn out(c: *Caller) ![]const u8 {
        return (try c.t.finish({})).out;
    }

    fn ran(c: *Caller, intent: engine_page.Intent, probing: bool) !Rig.Ran {
        const page = c.rig.page.page();
        var problem: []const u8 = "";
        _ = try page.start(c.t.reply.arena, &problem);
        if (probing) _ = try page.probe(&c.t.reply);
        const outcome = try page.repair(&c.t.reply, intent);
        const printed_out = try c.t.finish({});
        return .{ .out = printed_out.out, .outcome = outcome };
    }

    /// Waits until the caller has printed `line`; fails after 2 s.
    pub fn printed(c: *Caller, line: []const u8) !void {
        const io = c.rig.io;
        // The wire holds each print as `{"out":<JSON string>}`.
        var buf: [1024]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try w.print("{f}", .{std.json.fmt(line, .{})});
        const want = w.buffered()[1 .. w.buffered().len - 1];
        const deadline: Deadline = .after(io, .fromSeconds(2));
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        while (std.mem.find(u8, c.seen.items, want) == null) {
            c.changed.waitTimeout(io, &c.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return error.NeverPrinted,
                error.Canceled => return error.Canceled,
            };
        }
    }

    /// The reply's flush: runs on the caller's task after each line.
    fn flushed(ctx: *anyopaque) Io.Writer.Error!void {
        const c: *Caller = @ptrCast(@alignCast(ctx));
        const io = c.rig.io;
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.seen.clearRetainingCapacity();
        c.seen.appendSlice(c.rig.gpa, c.t.wire.written()) catch return error.WriteFailed;
        c.changed.broadcast(io);
    }
};

/// For the playback endpoints' tests: the endpoints' `Host` over a `Rig`. Page calls go over the
/// rig's real channel to the fake page, `state` is the rig's engine and the channel's last
/// report, and `page` and `plays` are the rig's: what `Daemon.playbackHost` does over the real
/// ones. What isn't the engine page's (the token check, a search, footprints, memory, the
/// claims) is canned here.
pub const PageHost = struct {
    rig: *Rig,
    token: host_mod.TokenStatus = .{ .checked = .{ .status = 200, .storefront = "gb" } },
    search_result: host_mod.SearchOutcome = .{ .result = .{ .songs = &.{} } },
    footprint: host_mod.Footprints = .{ .daemon_pid = 1, .daemon = .{} },
    available: ?u64 = 8 << 30,
    /// A sign-in window is open on the profile: an engine runs, with no engine page.
    signin_window: bool = false,
    /// What the engine's idle close says while one runs.
    idle_close_in_s: i64 = 300,
    /// The keep-engine requests holding the engine while one runs, as `Requests.keepers` counts
    /// them; a sign-in window has none.
    keep_engine_requests: u32 = 0,
    /// The daemon's clock is this far ahead of the page's last report: as if the page had
    /// stopped reporting that long ago.
    report_older_by_ms: u64 = 0,
    /// Runs once, before the `nth` page call of its method goes out.
    before_call: ?BeforeCall = null,
    claims: u64 = 0,
    /// Guards `before_call`, `claims`, `called` and `logged`: callers run at once.
    mutex: Io.Mutex = .init,
    /// `method args` of every page call the endpoints made, whether it reached a page or not.
    called: std.ArrayList([]const u8) = .empty,
    /// Every line for the daemon's log.
    logged: std.ArrayList([]const u8) = .empty,
    arena: ?Allocator = null,

    pub const BeforeCall = struct { method: []const u8, nth: u32 = 1, run: *const fn (*PageHost) anyerror!void };

    /// A page call waits this many times less than it asks for, as every wait in the rig is
    /// shortened: a call the page never answers within 10 s fails after 1 s.
    const call_time_scale = 10;

    pub fn host(ph: *PageHost) host_mod.Host {
        return .{
            .ptr = ph,
            .gpa = ph.rig.gpa,
            .plays = &ph.rig.plays,
            .page = ph.rig.page.page(),
            .vtable = &.{
                .call = call,
                .userTokenStatus = userTokenStatus,
                .developerToken = developerToken,
                .state = state,
                .footprints = footprints,
                .search = search,
                .availableMemory = availableMemory,
                .openSigninWindow = openSigninWindow,
                .waitSignin = waitSignin,
                .userTokenPath = userTokenPath,
                .signinPage = signinPage,
                .claimPlayback = claimPlayback,
                .playbackClaim = playbackClaim,
                .build = build,
                .waitChange = waitChange,
                .settingsWarningsNow = settingsWarningsNow,
                .log = log,
            },
        };
    }

    /// The engine starts and its page is ready to play, as a play's `start` finds it.
    pub fn warm(ph: *PageHost) !void {
        var problem: []const u8 = "";
        const started = try ph.rig.page.start(ph.rig.newArena(), &problem);
        if (!started.ready) return error.NotReady;
    }

    /// The engine launches, and nothing waits for its page.
    pub fn launch(ph: *PageHost) !void {
        var problem: []const u8 = "";
        _ = try ph.rig.launcher.port().vtable.launch(&ph.rig.launcher, ph.rig.newArena(), .launch, &problem);
    }

    /// Whether the endpoints made a page call starting with `method_and_args`.
    pub fn wasCalled(ph: *PageHost, method_and_args: []const u8) bool {
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        for (ph.called.items) |c| if (std.mem.startsWith(u8, c, method_and_args)) return true;
        return false;
    }

    /// The daemon's log so far; read it once its callers have returned.
    pub fn logLines(ph: *PageHost) []const []const u8 {
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        return ph.logged.items;
    }

    /// Whether the daemon's log has `line` so far; fine while callers still run.
    pub fn hasLogged(ph: *PageHost, line: []const u8) bool {
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        for (ph.logged.items) |l| if (std.mem.eql(u8, l, line)) return true;
        return false;
    }

    fn of(ptr: *anyopaque) *PageHost {
        return @ptrCast(@alignCast(ptr));
    }

    fn record(ph: *PageHost, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) void {
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        if (ph.arena == null) ph.arena = ph.rig.newArena();
        const a = ph.arena.?;
        list.append(a, a.print(fmt, args) catch return) catch {};
    }

    fn call(ptr: *anyopaque, arena: Allocator, method: []const u8, args_json: []const u8, timeout: Io.Duration) host_mod.Host.CallError!channel_mod.Channel.CallResult {
        const ph = of(ptr);
        ph.record(&ph.called, "{s} {s}", .{ method, args_json });
        if (ph.takeHook(method)) |run| run(ph) catch @panic("the hook before a page call failed");
        return ph.rig.channel.call(arena, method, args_json, .{ .nanoseconds = @divTrunc(timeout.nanoseconds, call_time_scale) });
    }

    /// The hook to run before this page call of `method`, if it is the one.
    fn takeHook(ph: *PageHost, method: []const u8) ?*const fn (*PageHost) anyerror!void {
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        const b = &(ph.before_call orelse return null);
        if (!std.mem.eql(u8, b.method, method)) return null;
        b.nth -= 1;
        if (b.nth > 0) return null;
        defer ph.before_call = null;
        return b.run;
    }

    /// As `Daemon.hostState`.
    fn state(ptr: *anyopaque, arena: Allocator) Allocator.Error!host_mod.State {
        const ph = of(ptr);
        const rig = ph.rig;
        var s: host_mod.State = .{ .engine = null, .report = null };
        if (ph.signin_window) {
            s.engine = .{ .kind = "firefox", .pid = 77, .headless = false, .signin_window = true, .idle_close_in_s = ph.idle_close_in_s };
        } else {
            rig.launcher.mutex.lockUncancelable(rig.io);
            defer rig.launcher.mutex.unlock(rig.io);
            if (rig.launcher.live) |live| if (rig.channel.currentLaunch() == live.generation) {
                s.engine = .{ .kind = "firefox", .pid = live.pid, .headless = true, .signin_window = false, .idle_close_in_s = ph.idle_close_in_s, .keep_engine_requests = ph.keep_engine_requests };
            };
        }
        if (try rig.channel.lastReport(arena)) |last| {
            s.report = last.json;
            s.report_age_ms = @as(u64, @intCast(@max(0, last.age.toMilliseconds()))) + ph.report_older_by_ms;
        }
        return s;
    }

    fn userTokenStatus(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.TokenStatus {
        return of(ptr).token;
    }
    fn developerToken(_: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.DeveloperToken {
        return .{ .found = .{ .line = "shared, kid=KEY iss=TEAM expires 2027-04-01 00:00 UTC" } };
    }
    fn footprints(ptr: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.Footprints {
        return of(ptr).footprint;
    }
    fn search(ptr: *anyopaque, _: Allocator, _: []const u8, _: []const u8) (Allocator.Error || Io.Cancelable)!host_mod.SearchOutcome {
        return of(ptr).search_result;
    }
    fn availableMemory(ptr: *anyopaque) ?u64 {
        return of(ptr).available;
    }
    /// Sign-in isn't the playback endpoints'.
    fn openSigninWindow(_: *anyopaque, _: Allocator, _: engine_kind.Kind, problem: *[]const u8) host_mod.EngineError!host_mod.SigninWindow {
        problem.* = "no sign-in window in these tests";
        return error.EngineFailed;
    }
    fn waitSignin(_: *anyopaque, _: Allocator, _: ?u64, _: Io.Duration) (Allocator.Error || Io.Cancelable)!host_mod.SigninWait {
        return .{ .count = 0, .result = null, .window_open = false };
    }
    fn userTokenPath(_: *anyopaque, _: Allocator) Allocator.Error![]const u8 {
        return "/home/u/.config/am/music-user-token";
    }
    fn settingsWarningsNow(_: *anyopaque, _: Allocator) (Allocator.Error || Io.Cancelable)!?[]const []const u8 {
        return &.{};
    }
    fn signinPage(_: *anyopaque, _: Allocator) Allocator.Error![]const u8 {
        return "http://localhost:47823/?signin&engine=5555";
    }
    fn claimPlayback(ptr: *anyopaque) u64 {
        const ph = of(ptr);
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        ph.claims += 1;
        return ph.claims;
    }
    fn playbackClaim(ptr: *anyopaque) u64 {
        const ph = of(ptr);
        ph.mutex.lockUncancelable(ph.rig.io);
        defer ph.mutex.unlock(ph.rig.io);
        return ph.claims;
    }
    fn build(_: *anyopaque) []const u8 {
        return "0123456789abcdef";
    }
    fn waitChange(ptr: *anyopaque, after: ?u64, timeout: Io.Duration) Io.Cancelable!u64 {
        return of(ptr).rig.channel.waitChange(after, timeout);
    }
    fn log(ptr: *anyopaque, line: []const u8) void {
        const ph = of(ptr);
        ph.record(&ph.logged, "{s}", .{line});
    }
};
