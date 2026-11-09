//! `am daemon`: the background process. It runs the engine page's local server, owns the
//! engine's lifecycle (launch on demand, per-launch nonce, idle close, leftover cleanup) and
//! answers the CLI's authenticated `/cli/` requests. Once the engine is closed and nothing used
//! it for the idle limit (a connected TUI keeps a request open), it exits as on `stop`.
//!
//! It runs in the foreground and never forks; the CLI starts it detached when nothing answers
//! (see `daemon/client.zig`). Binding the port is the lock: a second daemon fails to bind and
//! exits quietly.
const std = @import("std");
const apple = @import("apple.zig");
const config = @import("config.zig");
const developer_token = @import("developer_token.zig");
const engine = @import("engine.zig");
const footprint = @import("footprint.zig");
const platform = @import("platform.zig");
const playback = @import("playback.zig");
const settings_mod = @import("settings.zig");
const channel_mod = @import("daemon/channel.zig");
const control = @import("daemon/control.zig");
const server_mod = @import("daemon/server.zig");
const doctor = @import("daemon/doctor.zig");
const endpoints = @import("daemon/endpoints.zig");
const engine_page = @import("daemon/engine_page.zig");
const host_mod = @import("daemon/host.zig");
const protocol = @import("daemon/protocol.zig");
const signin = @import("daemon/signin.zig");
const token_source = @import("token_source.zig");
const Deadline = @import("deadline.zig").Deadline;

const Allocator = std.mem.Allocator;
const Channel = channel_mod.Channel;
const Environ = std.process.Environ;
const Io = std.Io;
const Response = server_mod.Response;

pub const client = @import("daemon/client.zig");

test {
    _ = endpoints;
    _ = doctor;
    _ = protocol;
    _ = signin;
    _ = client;
    _ = host_mod;
    _ = @import("daemon/play.zig");
    _ = @import("daemon/control.zig");
    _ = @import("daemon/player.zig");
    _ = engine_page;
}

/// A hash of the running executable's bytes, as 16 hex digits: binaries from different builds
/// differ. The daemon computes it once at start and sends it with `ping` and `state`; a client
/// computes its own the same way and restarts a daemon whose id differs.
pub fn buildId(io: Io, arena: Allocator) ![]const u8 {
    const path = try std.process.executablePathAlloc(io, arena);
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher: std.hash.Wyhash = .init(0);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => |other| return other,
        };
        hasher.update(buffer[0..n]);
    }
    return arena.print("{x:0>16}", .{hasher.final()});
}

/// Who holds the daemon lock, from the lock file's text (`pid <n>, port <p>`).
pub const Holder = union(enum) {
    /// A daemon for this port: one that is shutting down keeps the lock until its engine exited.
    this_port: []const u8,
    /// Another daemon on this config dir.
    other: []const u8,
    /// No text naming a port: a daemon between taking the lock and writing it, or a CLI's
    /// `lockHeld` probe, which holds it for a moment and writes nothing.
    unknown: []const u8,

    pub fn text(h: Holder) []const u8 {
        return switch (h) {
            inline else => |t| t,
        };
    }
};

/// Reads who holds the lock at `path` (the text lives in `buffer`).
pub fn lockHolder(io: Io, path: []const u8, port: u16, buffer: []u8) Holder {
    const text = config.trimSpace(Io.Dir.cwd().readFile(io, path, buffer) catch "");
    const label = std.mem.find(u8, text, "port ") orelse return .{ .unknown = text };
    const theirs = std.fmt.parseInt(u16, text[label + "port ".len ..], 10) catch return .{ .unknown = text };
    return if (theirs == port) .{ .this_port = text } else .{ .other = text };
}

/// A held lock whose text doesn't name this port is waited for this long: it may be a probe's or
/// a daemon's that hasn't written its text yet.
pub const brief_hold: Io.Duration = .fromSeconds(1);

pub const LockVerdict = enum {
    /// Try again shortly.
    wait,
    /// Another daemon uses this config dir.
    other,
    /// Held longer than any shutdown or probe takes.
    stuck,
};

pub const LockWait = union(enum) {
    free,
    /// Another daemon's: its text.
    other: []const u8,
    /// Held too long: its holder's text.
    stuck: []const u8,
};

/// Waits while `held(ctx, io, path)` says the lock at `path` is held, by `lockVerdict`'s
/// rules (the holder's text lands in `buffer`). `held` may take the lock, as a starting daemon
/// does, or only look, as the CLI does.
pub fn waitOutLock(io: Io, path: []const u8, port: u16, buffer: []u8, ctx: anytype, comptime held: fn (@TypeOf(ctx), Io, []const u8) bool) Io.Cancelable!LockWait {
    const start = Io.Clock.awake.now(io);
    while (held(ctx, io, path)) {
        const who = lockHolder(io, path, port, buffer);
        switch (lockVerdict(who, start.durationTo(Io.Clock.awake.now(io)))) {
            .wait => try io.sleep(.fromMilliseconds(100), .awake),
            .other => return .{ .other = who.text() },
            .stuck => return .{ .stuck = who.text() },
        }
    }
    return .free;
}

/// A starting daemon's side of `waitOutLock`: tries to take the lock.
const TakeLock = struct {
    holder: []const u8,
    file: ?Io.File = null,
    err: ?platform.LockFileError = null,

    fn held(t: *TakeLock, io: Io, path: []const u8) bool {
        t.file = platform.lockFile(io, path, t.holder) catch |e| {
            if (e == error.Locked) return true;
            t.err = e;
            return false;
        };
        return false;
    }
};

/// What to do about a lock held by `holder`, `waited` into the wait.
pub fn lockVerdict(holder: Holder, waited: Io.Duration) LockVerdict {
    return switch (holder) {
        .this_port => if (waited.nanoseconds < lock_wait.nanoseconds) .wait else .stuck,
        .other => if (waited.nanoseconds < brief_hold.nanoseconds) .wait else .other,
        .unknown => if (waited.nanoseconds < brief_hold.nanoseconds) .wait else .stuck,
    };
}

/// How long a starting daemon (and the CLI starting it) waits for one that is still shutting
/// down to free the lock.
pub const lock_wait: Io.Duration = .fromSeconds(8);
/// How often the daemon checks for shutdown requests, a dead engine and the idle timeout.
const tick: Io.Duration = .fromMilliseconds(250);
/// How long `am status` measures CPU use over.
const footprint_window: Io.Duration = .fromSeconds(1);

/// When to close the engine: once nothing has been playing for `limit`. "Nothing playing" is
/// paused, stopped or never started. CLI requests that use the engine count as activity for as
/// long as they run.
pub const IdleTimer = struct {
    limit: Io.Duration,
    last_active: Io.Timestamp,
    /// CLI requests using the engine right now.
    busy: u32 = 0,

    pub fn touch(t: *IdleTimer, now: Io.Timestamp) void {
        if (now.compare(.gt, t.last_active)) t.last_active = now;
    }

    /// A CLI request starts using the engine. Pair with `end`.
    pub fn begin(t: *IdleTimer, now: Io.Timestamp) void {
        t.busy += 1;
        t.touch(now);
    }

    pub fn end(t: *IdleTimer, now: Io.Timestamp) void {
        t.busy -= 1;
        t.touch(now);
    }

    /// Call on every tick; `playing` comes from the engine page's latest report.
    pub fn expired(t: *IdleTimer, now: Io.Timestamp, playing: bool) bool {
        if (playing or t.busy > 0) t.touch(now);
        return t.remaining(now).nanoseconds <= 0;
    }

    pub fn remaining(t: *const IdleTimer, now: Io.Timestamp) Io.Duration {
        const idle = t.last_active.durationTo(now);
        return .{ .nanoseconds = t.limit.nanoseconds - idle.nanoseconds };
    }
};

/// The CLI requests open on the background process (a TUI's `watch` is one for as long as the
/// TUI runs), for exiting once nothing uses it. Thread-safe.
pub const Requests = struct {
    mutex: Io.Mutex = .init,
    /// `busy` counts the open requests; the clock runs from when one last started or ended.
    timer: IdleTimer,
    /// Set once the daemon exits: from then on requests are refused.
    closed: bool = false,
    /// Every open request.
    open: ?*Ticket = null,
    /// Signaled whenever a request ends.
    ended: Io.Condition = .init,

    /// One open request, kept on its handler's stack.
    pub const Ticket = struct {
        /// Set once its client closed the connection (`server.zig` watches for that); null when
        /// that can't be told.
        client_gone: ?*const std.atomic.Value(bool) = null,
        /// It counts even once its client is gone: what it does still happens (`queue`).
        outlives_client: bool = false,
        /// It uses the engine (a pause, a seek): what it asks may not show in the page's state yet.
        uses_engine: bool = false,
        /// The client it names itself as (a TUI session), if it does.
        client_id: ?[]const u8 = null,
        next: ?*Ticket = null,

        /// In use, for `asker`: what it does still happens, or its client is still there. A
        /// request of the asker's own client isn't: that client is quitting and its requests
        /// close with it, whether or not its hang-up can be noticed (`client_gone` null). Its
        /// own queue included: nothing is audible from it yet, and `Daemon.stopIfUnused` stops
        /// it first (#55).
        fn inUseFor(t: *const Ticket, asker: *const Ticket) bool {
            if (t.sameClient(asker)) return false;
            if (t.outlives_client) return true;
            return !t.clientGone();
        }

        fn sameClient(t: *const Ticket, other: *const Ticket) bool {
            const a = t.client_id orelse return false;
            const b = other.client_id orelse return false;
            return std.mem.eql(u8, a, b);
        }

        fn clientGone(t: *const Ticket) bool {
            const gone = t.client_gone orelse return false;
            return gone.load(.acquire);
        }

        /// Its client left (or is the asker, quitting), but what it asked of the engine is still
        /// on its way.
        fn settlingFor(t: *const Ticket, asker: *const Ticket) bool {
            return t.uses_engine and !t.outlives_client and (t.clientGone() or t.sameClient(asker));
        }
    };

    /// A request starts; false, and it must be refused, once closed. Pair a true with `end`.
    pub fn begin(q: *Requests, io: Io, now: Io.Timestamp, t: *Ticket) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed) return false;
        q.timer.begin(now);
        t.next = q.open;
        q.open = t;
        return true;
    }

    pub fn end(q: *Requests, io: Io, now: Io.Timestamp, t: *Ticket) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        q.timer.end(now);
        var link = &q.open;
        while (link.*) |open| : (link = &open.next) if (open == t) {
            link.* = t.next;
            break;
        };
        q.ended.broadcast(io);
    }

    /// For `stop-if-unused`: waits, for at most `timeout`, until no request besides `asker` is
    /// settling (see `Ticket.settlingFor`): a pause pressed just before q lands first.
    pub fn settle(q: *Requests, io: Io, asker: *const Ticket, timeout: Io.Duration) Io.Cancelable!void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        const until: Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = timeout, .clock = .awake }) };
        while (q.settlingLocked(asker)) {
            q.ended.waitTimeout(io, &q.mutex, until) catch |e| switch (e) {
                error.Timeout => return,
                error.Canceled => return error.Canceled,
            };
        }
    }

    fn settlingLocked(q: *const Requests, asker: *const Ticket) bool {
        var it = q.open;
        while (it) |t| : (it = t.next) if (t != asker and t.settlingFor(asker)) return true;
        return false;
    }

    pub fn close(q: *Requests, io: Io) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        q.closed = true;
    }

    /// With no engine running: closes, and returns true, when nothing used the background
    /// process for the idle limit. Nothing played and no request used the engine for that long
    /// (`idle`), no request is open, and none started or ended within the limit either.
    pub fn closeIfUnused(q: *Requests, io: Io, idle: *const IdleTimer, now: Io.Timestamp) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed) return true;
        if (q.timer.busy > 0 or idle.busy > 0 or idle.remaining(now).nanoseconds > 0) return false;
        if (q.timer.remaining(now).nanoseconds > 0) return false;
        q.closed = true;
        return true;
    }

    /// Whether an open request besides `asker` is in use (see `Ticket.inUseFor`).
    pub fn othersInUse(q: *Requests, io: Io, asker: *const Ticket) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        return q.othersInUseLocked(asker);
    }

    fn othersInUseLocked(q: *const Requests, asker: *const Ticket) bool {
        var it = q.open;
        while (it) |t| : (it = t.next) if (t != asker and t.inUseFor(asker)) return true;
        return false;
    }

    /// For `stop-if-unused` (`asker` is its own request): closes, and returns true, when no
    /// other open request is in use (see `Ticket.inUseFor`): the asker's own client's requests
    /// don't count, even while their close is still unnoticed.
    pub fn closeIfAlone(q: *Requests, io: Io, asker: *const Ticket) bool {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);
        if (q.closed) return true;
        if (q.othersInUseLocked(asker)) return false;
        q.closed = true;
        return true;
    }
};

/// What `stop-if-unused` looks at in the engine.
pub const EngineView = struct {
    running: bool,
    signin_window: bool = false,
    /// Its page is connected and MusicKit configured (or failed to).
    ready: bool = false,
    report: ?playback.Report = null,
    report_age_ms: u64 = 0,
    /// The quitting TUI's own play, not audible yet, was stopped just now
    /// (`control.stopStarting`): a page still loading, or a report that still names a song
    /// starting, is on its way to nothing.
    own_play_stopped: bool = false,
};

/// An engine page reports once a second; one silent for this long may be hung mid-song.
const stale_report_ms = 5000;

/// Why the engine still has a use, or null when it has none: music playing (live radio
/// included), a song starting or a queue on its way, a page still loading, a sign-in window
/// open or a sign-in waiting, or a page that stopped reporting (it may be playing). A page
/// loading or a song starting is nobody's once the quitting TUI's own play was stopped
/// (`EngineView.own_play_stopped`).
pub fn engineInUse(e: EngineView, signins_waiting: u32) ?[]const u8 {
    if (signins_waiting > 0) return "a sign-in is waiting";
    if (!e.running) return null;
    if (e.signin_window) return "a sign-in window is open";
    const loading: ?[]const u8 = if (e.own_play_stopped) null else "the engine is loading";
    const r = e.report orelse return loading;
    if (!e.ready) return loading;
    if (e.report_age_ms > stale_report_ms) return "the engine page stopped reporting";
    return switch (r.music()) {
        .playing => "music is playing",
        .starting => if (e.own_play_stopped) null else "a song is starting",
        // Whether anyone listens or is about to, not what a reload would lose: nobody listens to
        // a paused song or stopped live radio, and the TUI saves what it played before it quits,
        // so its next session queues it again.
        .paused, .stopped_live, .none => null,
    };
}

/// The browser binary to launch: the path setting if given, else the first of the platform's
/// candidates that exists. A candidate under an unset environment variable is skipped. Null
/// when none exists.
pub fn findBinary(arena: Allocator, io: Io, override: ?[]const u8, candidates: []const platform.Candidate, environ: *const Environ.Map) Allocator.Error!?[]const u8 {
    if (override) |path| return if (isFile(io, path)) path else null;
    for (candidates) |candidate| {
        if (candidate.under) |variable| {
            const dir = config.getEnv(environ, variable) orelse continue;
            const full = try Io.Dir.path.join(arena, &.{ dir, candidate.path });
            if (isFile(io, full)) return full;
            continue;
        }
        if (Io.Dir.path.isAbsolute(candidate.path)) {
            if (isFile(io, candidate.path)) return candidate.path;
            continue;
        }
        var dirs = std.mem.tokenizeScalar(u8, config.getEnv(environ, "PATH") orelse "", Io.Dir.path.delimiter);
        while (dirs.next()) |dir| {
            const full = try Io.Dir.path.join(arena, &.{ dir, candidate.path });
            if (isFile(io, full)) return full;
        }
    }
    return null;
}

fn isFile(io: Io, path: []const u8) bool {
    if (!Io.Dir.path.isAbsolute(path)) return false;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind != .directory;
}

/// What a browser is launched for.
const Purpose = union(enum) {
    /// The engine page, headless unless `ENGINE_HEADLESS=0`.
    engine,
    /// `am signin --engine E`: a visible window of that engine's profile on the sign-in page.
    signin_window: struct { kind: engine.Kind, url: []const u8 },
};

/// What runs on the engine profile now, as far as a new launch cares.
pub const Occupant = struct {
    signin_window: bool,
    /// What the engine page holds, from its last report (`playback.Report.music`); `.none`
    /// without one.
    music: playback.Music,
};

pub const Conflict = union(enum) {
    none,
    /// Close it and launch.
    replace,
    /// Leave it alone and fail with this.
    refuse: []const u8,
};

/// What a launch for `want` does about what runs on the profile. `other_signins` counts the
/// `am signin` requests waiting, besides the one asking. A sign-in window closes the engine
/// unless its page plays music or has some on its way.
pub fn conflict(want: std.meta.Tag(Purpose), occupant: ?Occupant, other_signins: u32) Conflict {
    const o = occupant orelse return .none;
    return switch (want) {
        .engine => if (!o.signin_window)
            .none
        else if (other_signins > 0)
            .{ .refuse = "sign-in in progress; finish or cancel `am signin` first" }
        else
            .replace,
        .signin_window => if (o.signin_window)
            (if (other_signins > 0) .{ .refuse = "another am signin is in progress" } else .replace)
        else switch (o.music) {
            .playing, .starting => .{ .refuse = "stop playback first: am stop" },
            // A silent page gives way, as the advice promises: `am stop` leaves its song paused
            // at 0:00.
            .paused, .stopped_live, .none => .replace,
        },
    };
}

/// The last of a kind of message, so the same one is logged once, not on every call.
pub const OnceText = struct {
    mutex: Io.Mutex = .init,
    buf: [256]u8 = undefined,
    len: usize = 0,

    /// Whether `text` differs from the last one (at most 256 bytes compared); remembers it.
    pub fn changed(o: *OnceText, io: Io, text: []const u8) bool {
        o.mutex.lockUncancelable(io);
        defer o.mutex.unlock(io);
        const short = text[0..@min(text.len, o.buf.len)];
        if (std.mem.eql(u8, o.buf[0..o.len], short)) return false;
        @memcpy(o.buf[0..short.len], short);
        o.len = short.len;
        return true;
    }
};

test "OnceText: the same message is new once, then again only after another one" {
    var once: OnceText = .{};
    const io = std.testing.io;
    try std.testing.expect(once.changed(io, "the last download failed at 10:00; the next try is after 11:00"));
    try std.testing.expect(!once.changed(io, "the last download failed at 10:00; the next try is after 11:00"));
    try std.testing.expect(once.changed(io, "ConnectionRefused"));
    try std.testing.expect(!once.changed(io, "ConnectionRefused"));
    // Long texts compare by their first 256 bytes.
    const long: [300]u8 = @splat('x');
    try std.testing.expect(once.changed(io, &long));
    try std.testing.expect(!once.changed(io, &long));
}

/// A launched engine.
const Running = struct {
    kind: engine.Kind,
    /// A sign-in window has no engine page: it never claims the channel or reports.
    signin_window: bool,
    identity: platform.EngineIdentity,
    group: platform.ProcessGroup,
    nonce: channel_mod.Nonce,
    /// The channel's launch for it (`Channel.currentLaunch`); 0 for a sign-in window, which has
    /// no engine page.
    generation: u64,
    started: Io.Timestamp,
    /// Allocations of this launch (paths), freed when it ends.
    arena: std.heap.ArenaAllocator,
};

pub const Daemon = struct {
    io: Io,
    gpa: Allocator,
    environ: *const Environ.Map,
    config_dir: []const u8,
    /// Read once, at start: restart the daemon (`am daemon stop`) to apply a change.
    settings: settings_mod.Settings,
    /// `AM_PORT` and `ENGINE`, from `settings.daemonStart`.
    port: u16,
    engine_kind: engine.Kind,
    /// The last "can't download a newer shared token" logged, so the backoff's repeats aren't.
    refresh_warning: OnceText = .{},
    secret: [64]u8,
    channel: Channel,
    server: server_mod.Server,
    stop_requested: std.atomic.Value(bool) = .init(false),

    /// Guards `running`, `idle` and `shutting_down`. Held while launching (which includes
    /// killing leftovers), not while waiting for the page.
    engine_mutex: Io.Mutex = .init,
    running: ?Running = null,
    idle: IdleTimer,
    /// Set when the daemon decided to exit (`stop-if-unused`, the idle exit) and at shutdown
    /// before the engine is stopped: from then on no engine is launched, so none can outlive us.
    shutting_down: bool = false,
    /// An engine or sign-in window is being launched (killing leftovers first, which can take
    /// seconds): `stop-if-unused` keeps the daemon without waiting for the launch.
    launching: std.atomic.Value(bool) = .init(false),
    /// What the sign-in page's tokens got from Apple, for `am signin` to wait on.
    signins: signin.Log,
    /// `am signin` requests waiting now; a sign-in window is theirs while any wait.
    signins_waiting: std.atomic.Value(u32) = .init(0),
    /// Every CLI request, for exiting once nothing uses the daemon.
    requests: Requests,
    /// Bumped by every `am play`: an earlier one's watch ends when it moves on.
    play_claims: std.atomic.Value(u64) = .init(0),
    /// The cancel generation of plays and stops. The engine page belongs to this daemon's
    /// launch (its nonce), so its generations never meet another daemon's.
    plays: host_mod.Plays = .{},
    /// The engine page module: every launch wait and reload of the engine page goes through
    /// it. Set in `run`, once the channel and `plays` have their place.
    page: engine_page.EnginePage = undefined,
    /// `buildId` of this binary, or "unknown".
    build_id: []const u8 = "unknown",

    fn log(d: *const Daemon, comptime fmt: []const u8, args: anytype) void {
        const time: developer_token.UtcTime = .{ .unix = Io.Clock.real.now(d.io).toSeconds() };
        std.debug.print("{f} am daemon: " ++ fmt ++ "\n", .{time} ++ args);
    }

    fn now(d: *const Daemon) Io.Timestamp {
        return Io.Clock.awake.now(d.io);
    }

    // ---- Engine lifecycle ----

    pub const EngineError = error{
        /// Why is in the caller's `problem`.
        EngineFailed,
    } || Allocator.Error || Io.Cancelable;

    /// What leaves the process for the engine page module: launching the browser, the tokens
    /// the daemon hands out, and the daemon's log.
    fn enginePagePort(d: *Daemon) engine_page.Port {
        return .{ .ptr = d, .vtable = &.{ .launch = portLaunch, .developerToken = portDeveloperToken, .userToken = portUserToken, .log = hostLog } };
    }

    /// Launches the engine if none runs (`.launch`), or relaunches the one of that generation
    /// while its page still isn't connected (`.relaunch`), and returns the engine that runs
    /// then. Under `engine_mutex`: a sign-in window gives way unless an `am signin` waits on
    /// it, an engine that exited is launched again, and none launches once the daemon is
    /// shutting down. The engine page module waits for the page, outside the lock: a doctor can
    /// take minutes, a shutdown must not.
    fn portLaunch(ptr: *anyopaque, arena: Allocator, how: engine_page.Launch.How, problem: *[]const u8) host_mod.EngineError!engine_page.Launch {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        try d.engine_mutex.lock(d.io);
        defer d.engine_mutex.unlock(d.io);
        if (d.running) |*r| switch (conflict(.engine, try d.occupantLocked(arena), d.signins_waiting.load(.monotonic))) {
            .refuse => |why| {
                problem.* = why;
                return error.EngineFailed;
            },
            .replace => {
                d.log("closing a sign-in window nobody waits on, to start the engine", .{});
                d.stopEngineLocked();
            },
            // The module asks for a relaunch of a page that never connected, long after its
            // launch: it won't any more. It asked outside this lock, so a page that connected
            // since is left as it is.
            .none => if (!r.group.alive() or switch (how) {
                .launch => false,
                .relaunch => |generation| r.generation == generation and !d.channel.connected(),
            }) {
                d.log("the engine stopped answering; relaunching it", .{});
                d.stopEngineLocked();
            },
        };
        var launched = false;
        if (d.running == null) {
            if (d.shutting_down) {
                problem.* = "the background process is shutting down";
                return error.EngineFailed;
            }
            try d.launchLocked(arena, problem, .engine);
            launched = true;
        }
        const r = &d.running.?;
        return .{
            .generation = r.generation,
            .kind = @tagName(r.kind),
            .pid = r.group.leader(),
            .launched = launched,
            .headless = d.settings.engine_headless,
            .at = r.started,
            .log_path = try d.configPath(arena, engine_log),
        };
    }

    /// The developer token the daemon hands out now, as the engine page reports the one it
    /// has; null when there is none.
    fn portDeveloperToken(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const source = d.developerTokenSource(arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return null,
        };
        return switch (source) {
            .found => |f| try playback.TokenId.of(arena, f.token),
            .problem => null,
        };
    }

    /// The stored Music User Token, as `GET /user-token` hands it to the engine page and the
    /// page reports the one MusicKit holds; null when there is none or it can't be read.
    fn portUserToken(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const token = d.readToken(arena, config.file.music_user_token) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return null,
        } orelse return null;
        return try playback.TokenId.of(arena, token);
    }

    fn occupantLocked(d: *Daemon, arena: Allocator) Allocator.Error!?Occupant {
        const r = if (d.running) |*r| r else return null;
        const report = if (try d.channel.lastReport(arena)) |last| playback.parseReport(arena, last.json) else null;
        return .{ .signin_window = r.signin_window, .music = if (report) |rep| rep.music() else .none };
    }

    fn isReady(arena: Allocator, report: []const u8) bool {
        const fields = std.json.parseFromSliceLeaky(struct {
            configured: bool = false,
            configureError: ?[]const u8 = null,
        }, arena, report, .{ .ignore_unknown_fields = true }) catch return false;
        return fields.configured or fields.configureError != null;
    }

    const engine_log = "engine.log";

    fn launchLocked(d: *Daemon, arena: Allocator, problem: *[]const u8, purpose: Purpose) EngineError!void {
        d.launching.store(true, .release);
        defer d.launching.store(false, .release);
        const kind = switch (purpose) {
            .engine => d.engine_kind,
            .signin_window => |w| w.kind,
        };
        const headless = purpose == .engine and d.settings.engine_headless;
        var launch_arena: std.heap.ArenaAllocator = .init(d.gpa);
        errdefer launch_arena.deinit();
        const la = launch_arena.allocator();

        const spec = kind.spec();
        // `am signin --engine` may use the browser that isn't `ENGINE`.
        const override = d.settings.browserPath(kind);
        const path_setting = settings_mod.browserPathName(kind);
        const binary = try findBinary(la, d.io, override, spec.browser.candidates, d.environ) orelse {
            problem.* = if (override) |path|
                try arena.print("{t} not found at {s} ({t})", .{ kind, path, path_setting })
            else
                try arena.print("{t} not found; install it or set {t}", .{ kind, path_setting });
            return error.EngineFailed;
        };
        const nonce = channel_mod.newNonce(d.io);
        const url = switch (purpose) {
            .engine => try la.print("http://localhost:{d}/?engine={s}", .{ d.port, &nonce }),
            .signin_window => |w| try la.dupe(u8, w.url),
        };
        const plan = try engine.plan(la, .{
            .kind = kind,
            .binary = binary,
            .config_dir = d.config_dir,
            .url = url,
            .headless = headless,
            .widevine_from_google = d.settings.widevine_from_google,
        });
        const profile = plan.identity.profile;

        d.killLeftovers(plan.identity);

        // The profile persists across launches (Widevine module, cached musickit.js).
        if (plan.user_js) |user_js| {
            platform.writePrivateFile(d.io, profile, "user.js", user_js) catch |e| {
                problem.* = try arena.print("can't write {s}/user.js: {t}", .{ profile, e });
                return error.EngineFailed;
            };
        } else {
            platform.createPrivateDir(d.io, profile) catch |e| {
                problem.* = try arena.print("can't create {s}: {t}", .{ profile, e });
                return error.EngineFailed;
            };
        }

        var environ = try d.environ.clone(la);
        for (plan.env) |kv| try environ.put(kv[0], kv[1]);

        const log_path = try d.configPath(la, engine_log);
        const output = platform.createPrivateFile(d.io, log_path) catch null;
        defer if (output) |f| f.close(d.io);

        // A launch with a fresh nonce: only its page may claim the channel.
        d.channel.setNonce(if (purpose == .engine) nonce else null);
        const generation = d.channel.currentLaunch() orelse 0;
        const group = platform.spawnGroup(d.io, .{ .argv = plan.argv, .environ_map = &environ, .output = output }) catch |e| {
            d.channel.setNonce(null);
            problem.* = try arena.print("can't start {s}: {t}", .{ binary, e });
            return error.EngineFailed;
        };
        d.running = .{
            .kind = kind,
            .signin_window = purpose != .engine,
            .identity = plan.identity,
            .group = group,
            .nonce = nonce,
            .generation = generation,
            .started = d.now(),
            .arena = launch_arena,
        };
        d.idle.touch(d.now());
        d.log("{s} started: {t}{s}, pid {d}, profile {s}", .{
            if (purpose == .engine) "engine" else "sign-in window", kind, if (headless) " (headless)" else "", group.leader(), profile,
        });
    }

    /// Engines from earlier runs (the daemon was killed with -9, say) still hold the profile
    /// lock and may still be playing.
    fn killLeftovers(d: *Daemon, identity: platform.EngineIdentity) void {
        const leftovers = platform.findLeftovers(d.gpa, d.io, identity) catch |e| {
            d.log("can't look for leftover engines: {t}", .{e});
            return;
        };
        defer d.gpa.free(leftovers);
        for (leftovers) |target| {
            d.log("killing a leftover engine from an earlier run ({f})", .{target});
            platform.killLeftover(d.io, target);
        }
    }

    /// Closes the engine's whole process tree and keeps its profile.
    fn stopEngineLocked(d: *Daemon) void {
        var r = d.running orelse return;
        d.running = null;
        d.channel.setNonce(null);
        r.group.kill(d.io);
        d.log("engine stopped: {t}, pid {d}", .{ r.kind, r.group.leader() });
        r.arena.deinit();
    }

    /// Every tick: notice a dead engine, and close an idle one. True when, with no engine,
    /// nothing used the daemon for the idle limit either (see `Requests.closeIfUnused`): it
    /// exits, and refuses CLI requests from now on.
    fn superviseEngine(d: *Daemon, arena: Allocator) bool {
        if (!d.engine_mutex.tryLock()) return false;
        defer d.engine_mutex.unlock(d.io);
        const r = if (d.running) |*r| r else {
            if (!d.requests.closeIfUnused(d.io, &d.idle, d.now())) return false;
            // No launch can start any more: none can outlive the exit.
            d.shutting_down = true;
            d.log("nothing used the background process for {d} min: exiting", .{@divFloor(d.idle.limit.toSeconds(), 60)});
            return true;
        };
        if (!r.group.alive()) {
            d.log("{s}", .{if (r.signin_window) "the sign-in window was closed" else "the engine exited on its own"});
            d.stopEngineLocked();
            return false;
        }
        // Only music that plays holds the engine open, as `am status` says
        // (`playback.Music.keepsEngineOpen`).
        const playing = blk: {
            const last = (d.channel.lastReport(arena) catch null) orelse break :blk false;
            const report = playback.parseReport(arena, last.json) orelse break :blk false;
            break :blk report.music().keepsEngineOpen();
        };
        if (d.idle.expired(d.now(), playing)) {
            d.log("nothing played for {d} min: closing the engine", .{@divFloor(d.idle.limit.toSeconds(), 60)});
            d.stopEngineLocked();
        }
        return false;
    }

    /// Brackets a CLI request that uses the engine: the idle close waits until it's done.
    fn beginActivity(d: *Daemon) void {
        d.engine_mutex.lockUncancelable(d.io);
        defer d.engine_mutex.unlock(d.io);
        d.idle.begin(d.now());
    }

    fn endActivity(d: *Daemon) void {
        d.engine_mutex.lockUncancelable(d.io);
        defer d.engine_mutex.unlock(d.io);
        d.idle.end(d.now());
    }

    // ---- Files ----

    fn configPath(d: *const Daemon, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        return Io.Dir.path.join(arena, &.{ d.config_dir, name });
    }

    /// A stored token file (developer token, Music User Token), as `config.storedToken` reads it.
    fn readToken(d: *const Daemon, arena: Allocator, name: []const u8) !?[]const u8 {
        return config.storedToken(try config.readFile(d.io, arena, d.config_dir, name));
    }

    /// The developer token to use (`token_source.zig`), downloading the shared one when it is
    /// due; else why there is none.
    fn developerTokenSource(d: *Daemon, arena: Allocator) !token_source.Result {
        var transport: apple.HttpTransport = .{ .io = d.io, .gpa = d.gpa };
        const result = try token_source.get(arena, d.tokenEnv(&transport));
        switch (result) {
            .found => |f| if (f.refresh_failed) |why| if (d.refresh_warning.changed(d.io, why))
                d.log("can't download a newer shared developer token ({s}); using the stored one", .{why}),
            .problem => {},
        }
        return result;
    }

    /// A request's renewal put a newer shared developer token in place of a refused one. An
    /// engine page on the refused one reloads before its next play (the engine page module).
    fn developerTokenRenewed(d: *const Daemon, renewer: *const token_source.Renewer) void {
        if (renewer.fresh == null) return;
        d.log("Apple refused the shared developer token; a newer one is in use (an engine page on the old one reloads before its next play)", .{});
    }

    /// Where `token_source` finds the tokens; `transport` must outlive its use.
    fn tokenEnv(d: *const Daemon, transport: *apple.HttpTransport) token_source.Env {
        return .fromSettings(d.io, d.config_dir, &d.settings, transport.transport(), Io.Clock.real.now(d.io).toSeconds());
    }

    /// The developer token to use, else why not.
    fn developerToken(d: *Daemon, arena: Allocator) !union(enum) { token: []const u8, problem: []const u8 } {
        return switch (try d.developerTokenSource(arena)) {
            .found => |f| .{ .token = f.token },
            // The env file is read once, at start.
            .problem => |p| .{ .problem = if (p.nothing_set) try arena.print("{s}, then restart the background process (am daemon stop)", .{p.text}) else p.text },
        };
    }

    // ---- Backend for the server ----

    fn backend(d: *Daemon) server_mod.Backend {
        return .{ .ptr = d, .vtable = &.{
            .developerToken = backendDeveloperToken,
            .userToken = backendUserToken,
            .postUserToken = backendPostUserToken,
            .hasCli = backendHasCli,
            .cli = backendCli,
        } };
    }

    fn backendDeveloperToken(ptr: *anyopaque, arena: Allocator) !Response {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return switch (try d.developerToken(arena)) {
            .token => |t| .text(.ok, t),
            .problem => |p| .text(.service_unavailable, p),
        };
    }

    fn backendUserToken(ptr: *anyopaque, arena: Allocator) !Response {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const token = try d.readToken(arena, config.file.music_user_token) orelse return .{ .status = .no_content };
        return .text(.ok, token);
    }

    /// The sign-in page hands over a fresh Music User Token. Keep it only if Apple accepts it.
    /// The outcome also goes to the sign-in log, where `am signin` waits for it.
    fn backendPostUserToken(ptr: *anyopaque, arena: Allocator, body: []const u8) !Response {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const posted = std.json.parseFromSliceLeaky(struct { token: []const u8 }, arena, body, .{ .ignore_unknown_fields = true }) catch
            return .text(.bad_request, "expected {\"token\":...}\n");
        const result = try d.storeUserToken(arena, posted.token);
        try d.signins.record(result);
        return .json(result);
    }

    /// `{ok, status, storefront}`, or `{ok: false, status: 0, error}` when it couldn't be checked.
    fn storeUserToken(d: *Daemon, arena: Allocator, token: []const u8) ![]const u8 {
        // Nothing that could break a header (or a later read of the file) is sent or stored.
        const valid = if (config.storedToken(token)) |t| t.len == token.len else false;
        if (!valid) return jsonAlloc(arena, .{ .ok = false, .status = 0, .@"error" = "the page sent an empty or malformed token" });
        const dev = switch (try d.developerToken(arena)) {
            .token => |t| t,
            .problem => |p| return jsonAlloc(arena, .{ .ok = false, .status = 0, .@"error" = p }),
        };
        const answer = d.checkUserToken(arena, dev, token) catch |e| switch (e) {
            error.Canceled, error.OutOfMemory => |x| return x,
            else => return jsonAlloc(arena, .{ .ok = false, .status = 0, .@"error" = try arena.print("can't reach {s}: {t}", .{ apple.base_url, e }) }),
        };
        if (answer.status == 200) {
            try platform.writePrivateFile(d.io, d.config_dir, config.file.music_user_token, try std.mem.concat(arena, u8, &.{ token, "\n" }));
            d.log("stored a new Music User Token (storefront {s})", .{answer.storefront orelse "?"});
            // Before the result is recorded, so a reload, when there is one, has landed by the time
            // `am signin` reports success. A page that holds music, unless its item is a preview,
            // or that a play is on its way to, is left alone: it is behind on the Music User
            // Token, and the next play reloads it first.
            _ = try d.page.newUserToken(arena);
        } else d.log("Apple rejected a Music User Token from the sign-in page (HTTP {d})", .{answer.status});
        return jsonAlloc(arena, .{ .ok = answer.status == 200, .status = answer.status, .storefront = answer.storefront });
    }

    /// The address of a new sign-in page. Its nonce lets that page fetch the developer token
    /// and post a Music User Token; the previous sign-in page's stops working.
    fn newSigninPage(d: *Daemon, arena: Allocator) Allocator.Error![]const u8 {
        const nonce = channel_mod.newNonce(d.io);
        d.channel.setSigninNonce(nonce);
        return arena.print("http://localhost:{d}/?signin&engine={s}", .{ d.port, &nonce });
    }

    const TokenAnswer = struct { status: u16, storefront: ?[]const u8 };

    /// `GET /v1/me/storefront` with this Music User Token: 200 means valid, 403 sign in again. A
    /// shared developer token Apple refuses is renewed once (`token_source.Renewer`).
    fn checkUserToken(d: *const Daemon, arena: Allocator, dev: []const u8, user: []const u8) !TokenAnswer {
        var transport: apple.HttpTransport = .{ .io = d.io, .gpa = d.gpa };
        var renewer: token_source.Renewer = .{ .env = d.tokenEnv(&transport), .arena = arena };
        const apple_client: apple.Client = .{ .transport = transport.transport(), .developer_token = dev, .user_token = user, .renew = renewer.renew() };
        const response = try apple_client.get(arena, "/v1/me/storefront", .{});
        d.developerTokenRenewed(&renewer);
        if (response.status != 200) return .{ .status = response.status, .storefront = null };
        const parsed = std.json.parseFromSliceLeaky(struct { data: []const struct { id: []const u8 } }, arena, response.body, .{
            .ignore_unknown_fields = true,
        }) catch return .{ .status = response.status, .storefront = null };
        return .{ .status = 200, .storefront = if (parsed.data.len > 0) parsed.data[0].id else null };
    }

    fn backendHasCli(_: *anyopaque, name: []const u8) bool {
        return endpoints.find(name) != null;
    }

    fn backendCli(ptr: *anyopaque, name: []const u8, body: []const u8, reply: *protocol.Reply) protocol.Reply.Error!void {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const endpoint = endpoints.find(name).?;
        var ticket: Requests.Ticket = .{
            .client_gone = reply.client_gone,
            .outlives_client = endpoint.outlives_client,
            .uses_engine = endpoint.uses_engine,
            .client_id = reply.client_id,
        };
        if (!d.requests.begin(d.io, d.now(), &ticket)) {
            // Already on its way out: what a stop asks for. The CLI's wait sees the port close.
            if (std.mem.eql(u8, name, "stop")) return reply.print("already stopping\n", .{});
            if (std.mem.eql(u8, name, "stop-if-unused")) return reply.data("{\"kept\":null}");
            // A failed `ping` makes the CLI start a fresh daemon once this one is gone.
            return reply.fail("the background process is exiting; run the command again", .{});
        }
        defer d.requests.end(d.io, d.now(), &ticket);
        reply.outlives_client = endpoint.outlives_client;
        reply.request = &ticket;
        if (endpoint.uses_engine) d.beginActivity();
        defer if (endpoint.uses_engine) d.endActivity();
        return endpoint.run(d, reply, body);
    }

    /// `stop-if-unused`, asked by the request `asker`: shuts down as `stop` does unless
    /// something else uses the daemon (see `engineInUse` and `Requests.closeIfAlone`, decided
    /// together so nothing slips in between); then the reason, logged, and the daemon stays.
    pub fn stopIfUnused(d: *Daemon, arena: Allocator, asker: *const Requests.Ticket) (Allocator.Error || Io.Cancelable)!?[]const u8 {
        const kept = try d.decideStopIfUnused(arena, asker) orelse return null;
        d.log("kept: {s} (the TUI quit)", .{kept});
        return kept;
    }

    /// The decision, and the stop of the quitting TUI's own play that comes before it.
    fn decideStopIfUnused(d: *Daemon, arena: Allocator, asker: *const Requests.Ticket) (Allocator.Error || Io.Cancelable)!?[]const u8 {
        // The quitting TUI's own connections are closing (they name its client). What it asked
        // of the engine just before (a pause) lands first. Each step is bounded (3 + 2 + 10 + 1 s
        // at most, the engine's launch aside, which a stop waits out), within the 17 s the TUI
        // waits in all.
        if (d.requests.othersInUse(d.io, asker)) return "another client is using it";
        try d.requests.settle(d.io, asker, .fromSeconds(3));
        // The last report can be a second old: ask the page. Once, before the stop below: what
        // the stop changes, a song starting that it stopped, counts as nothing anyway.
        const fresh = try d.freshReport(arena);
        // Nothing else uses the daemon, so a play on its way or a song the page is starting is
        // the quitting TUI's own, not audible yet: stopped, or the song starts with nobody to
        // hear it and nothing on screen to stop it (#55). A stop during the engine's launch
        // waits for the launch (`hostState` takes `engine_mutex`), so none is under way below.
        const own_play_stopped = switch (try control.stopStarting(d.playbackHost(), arena, fresh)) {
            .nothing => false,
            .stopped => blk: {
                d.log("stopped the TUI's own play before it started (the TUI quit)", .{});
                break :blk true;
            },
            .failed => |why| return why,
        };
        if (try d.lockEngineBriefly(.fromSeconds(1))) |why| return why;
        defer d.engine_mutex.unlock(d.io);
        var view = try d.engineViewLocked(arena);
        view.own_play_stopped = own_play_stopped;
        if (view.running and view.ready) if (fresh) |report| {
            view.report = report;
            view.report_age_ms = 0;
        };
        if (engineInUse(view, d.signins_waiting.load(.monotonic))) |why| return why;
        if (!d.requests.closeIfAlone(d.io, asker)) return "another client is using it";
        d.shutting_down = true;
        d.requestStop("nothing else uses it (the TUI quit)");
        return null;
    }

    /// Takes `engine_mutex` without waiting out a launch: null once held, else why not.
    /// `launching` is set only while a launch holds the mutex.
    fn lockEngineBriefly(d: *Daemon, timeout: Io.Duration) Io.Cancelable!?[]const u8 {
        const deadline: Deadline = .after(d.io, timeout);
        while (!d.engine_mutex.tryLock()) {
            if (d.launching.load(.acquire)) return "the engine is starting";
            if (!try deadline.sleep(.fromMilliseconds(5))) return "the engine is busy";
        }
        return null;
    }

    /// The engine page's state now, if it answers within 2 s.
    fn freshReport(d: *Daemon, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.Report {
        const json = try d.playbackHost().snapshot(arena, .fromSeconds(2)) orelse return null;
        return playback.parseReport(arena, json);
    }

    fn engineViewLocked(d: *Daemon, arena: Allocator) Allocator.Error!EngineView {
        const r = if (d.running) |*r| r else return .{ .running = false };
        var view: EngineView = .{ .running = true, .signin_window = r.signin_window };
        if (try d.channel.lastReport(arena)) |last| {
            view.ready = d.channel.connected() and isReady(arena, last.json);
            view.report = playback.parseReport(arena, last.json);
            view.report_age_ms = @intCast(@max(0, last.age.toMilliseconds()));
        }
        return view;
    }

    /// Ends the main loop: the daemon shuts down.
    pub fn requestStop(d: *Daemon, why: []const u8) void {
        d.log("stop requested: {s}", .{why});
        d.stop_requested.store(true, .release);
    }

    // ---- The playback endpoints' view of the daemon ----

    pub fn playbackHost(d: *Daemon) host_mod.Host {
        return .{
            .ptr = d,
            .gpa = d.gpa,
            .vtable = &.{
                .call = hostCall,
                .userTokenStatus = hostUserTokenStatus,
                .developerToken = hostDeveloperToken,
                .build = hostBuild,
                .waitChange = hostWaitChange,
                .state = hostState,
                .footprints = hostFootprints,
                .search = hostSearch,
                .availableMemory = hostAvailableMemory,
                .openSigninWindow = hostOpenSigninWindow,
                .waitSignin = hostWaitSignin,
                .signinPage = hostSigninPage,
                .claimPlayback = hostClaimPlayback,
                .playbackClaim = hostPlaybackClaim,
                .userTokenPath = hostUserTokenPath,
                .log = hostLog,
            },
            .page = d.page.page(),
            .plays = &d.plays,
            .settings_warnings = d.settings.warnings,
        };
    }

    fn hostCall(ptr: *anyopaque, arena: Allocator, method: []const u8, args_json: []const u8, timeout: Io.Duration) host_mod.Host.CallError!Channel.CallResult {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.channel.call(arena, method, args_json, timeout);
    }

    /// A check that fails in any way but a shutdown or running out of memory is `unchecked`,
    /// with the error's name.
    fn hostUserTokenStatus(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.TokenStatus {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.userTokenStatus(arena) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => .{ .unchecked = @errorName(e) },
        };
    }

    fn userTokenStatus(d: *Daemon, arena: Allocator) !host_mod.TokenStatus {
        const user = try d.readToken(arena, config.file.music_user_token) orelse return .missing;
        const dev = switch (try d.developerToken(arena)) {
            .token => |t| t,
            .problem => |p| return .{ .unchecked = p },
        };
        const answer = d.checkUserToken(arena, dev, user) catch |e| switch (e) {
            error.Canceled, error.OutOfMemory => |x| return x,
            else => return .{ .unchecked = try arena.print("can't reach {s}: {t}", .{ apple.base_url, e }) },
        };
        return .{ .checked = .{ .status = answer.status, .storefront = answer.storefront } };
    }

    /// A token source that fails in any way but a shutdown or running out of memory is a
    /// problem, with the error's name.
    fn hostDeveloperToken(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.DeveloperToken {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const source = d.developerTokenSource(arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Canceled => return error.Canceled,
            else => return .{ .problem = @errorName(e) },
        };
        return switch (source) {
            .found => |f| .{ .found = .{
                .line = try arena.print("{f}{s}{s}{s}{s}", .{
                    f,
                    if (f.refresh_failed != null) "; can't download a newer one: " else "",
                    f.refresh_failed orelse "",
                    if (f.own_problem != null) "; your own isn't used: " else "",
                    f.own_problem orelse "",
                }),
            } },
            .problem => |p| .{ .problem = p.text },
        };
    }

    fn hostLog(ptr: *anyopaque, line: []const u8) void {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        d.log("{s}", .{line});
    }

    fn hostBuild(ptr: *anyopaque) []const u8 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.build_id;
    }

    fn hostWaitChange(ptr: *anyopaque, after: ?u64, timeout: Io.Duration) Io.Cancelable!u64 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.channel.waitChange(after, timeout);
    }

    fn hostState(ptr: *anyopaque, arena: Allocator) Allocator.Error!host_mod.State {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        var state: host_mod.State = .{ .engine = null, .report = null };
        {
            d.engine_mutex.lockUncancelable(d.io);
            defer d.engine_mutex.unlock(d.io);
            if (d.running) |*r| state.engine = .{
                .kind = @tagName(r.kind),
                .pid = r.group.leader(),
                .headless = d.settings.engine_headless and !r.signin_window,
                .signin_window = r.signin_window,
                .idle_close_in_s = @max(0, d.idle.remaining(d.now()).toSeconds()),
            };
        }
        if (try d.channel.lastReport(arena)) |last| {
            state.report = last.json;
            state.report_age_ms = @intCast(@max(0, last.age.toMilliseconds()));
        }
        return state;
    }

    /// The daemon and the engine tree, sampled together over `footprint_window`.
    fn hostFootprints(ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!host_mod.Footprints {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        var result: host_mod.Footprints = .{ .daemon_pid = platform.currentPid(), .daemon = .{} };
        var engine_running = false;
        {
            d.engine_mutex.lockUncancelable(d.io);
            defer d.engine_mutex.unlock(d.io);
            if (d.running) |*r| {
                engine_running = true;
                result.engine_pids = platform.processTree(arena, d.io, &r.group) catch |e| blk: {
                    result.engine_error = @errorName(e);
                    break :blk &.{};
                };
            }
        }
        const daemon_pids: []const platform.ProcessId = &.{result.daemon_pid};
        const start: Io.Clock.Timestamp = .now(d.io, .awake);
        const daemon_before = try footprint.sample(arena, d.io, daemon_pids);
        const engine_before = try footprint.sample(arena, d.io, result.engine_pids);
        try d.io.sleep(footprint_window, .awake);
        const elapsed = start.untilNow(d.io).raw;
        result.daemon = footprint.combine(daemon_before, try footprint.sample(arena, d.io, daemon_pids), elapsed);
        if (engine_running and result.engine_error == null)
            result.engine = footprint.combine(engine_before, try footprint.sample(arena, d.io, result.engine_pids), elapsed);
        return result;
    }

    fn hostSearch(ptr: *anyopaque, arena: Allocator, storefront: []const u8, term: []const u8) (Allocator.Error || Io.Cancelable)!host_mod.SearchOutcome {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const dev = switch (d.developerToken(arena) catch |e| return problemOr(arena, e, "can't read the developer token")) {
            .token => |t| t,
            .problem => |p| return .{ .problem = p },
        };
        var transport: apple.HttpTransport = .{ .io = d.io, .gpa = d.gpa };
        var renewer: token_source.Renewer = .{ .env = d.tokenEnv(&transport), .arena = arena };
        const apple_client: apple.Client = .{
            .transport = transport.transport(),
            .developer_token = dev,
            .user_token = d.readToken(arena, config.file.music_user_token) catch |e| return problemOr(arena, e, "can't read the Music User Token"),
            .renew = renewer.renew(),
        };
        const result = apple.searchSongs(apple_client, arena, storefront, term, 1) catch |e|
            return problemOr(arena, e, try arena.print("can't reach {s}", .{apple.base_url}));
        d.developerTokenRenewed(&renewer);
        return .{ .result = result };
    }

    /// `error.OutOfMemory` and `error.Canceled` as themselves; any other error as a problem
    /// saying `what` and the error.
    fn problemOr(arena: Allocator, e: anyerror, what: []const u8) (Allocator.Error || Io.Cancelable)!host_mod.SearchOutcome {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.Canceled) return error.Canceled;
        return .{ .problem = try arena.print("{s}: {t}", .{ what, e }) };
    }

    fn hostAvailableMemory(ptr: *anyopaque) ?u64 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return platform.availableMemory(d.io) catch null;
    }

    /// The running engine shares the profile, so it is closed first.
    fn hostOpenSigninWindow(ptr: *anyopaque, arena: Allocator, kind: engine.Kind, problem: *[]const u8) host_mod.EngineError!host_mod.SigninWindow {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        try d.engine_mutex.lock(d.io);
        defer d.engine_mutex.unlock(d.io);
        if (d.shutting_down) {
            problem.* = "the background process is shutting down";
            return error.EngineFailed;
        }
        // The asking `am signin` counts itself among the waiting.
        const others = d.signins_waiting.load(.monotonic) -| 1;
        switch (conflict(.signin_window, try d.occupantLocked(arena), others)) {
            .refuse => |why| {
                problem.* = why;
                return error.EngineFailed;
            },
            .replace => {
                d.log("closing what runs on the profile for a sign-in window", .{});
                d.stopEngineLocked();
            },
            .none => {},
        }
        const url = try d.newSigninPage(arena);
        try d.launchLocked(arena, problem, .{ .signin_window = .{ .kind = kind, .url = url } });
        return .{ .pid = d.running.?.group.leader(), .url = url };
    }

    fn hostClaimPlayback(ptr: *anyopaque) u64 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.play_claims.fetchAdd(1, .monotonic) + 1;
    }

    fn hostPlaybackClaim(ptr: *anyopaque) u64 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.play_claims.load(.monotonic);
    }

    fn hostSigninPage(ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.newSigninPage(arena);
    }

    fn hostWaitSignin(ptr: *anyopaque, arena: Allocator, after: ?u64, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!host_mod.SigninWait {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        const seen = try d.signins.wait(arena, after, timeout);
        const window_open = blk: {
            d.engine_mutex.lockUncancelable(d.io);
            defer d.engine_mutex.unlock(d.io);
            const r = if (d.running) |*r| r else break :blk false;
            break :blk r.signin_window and r.group.alive();
        };
        return .{ .count = seen.count, .result = seen.result, .window_open = window_open };
    }

    fn hostUserTokenPath(ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8 {
        const d: *Daemon = @ptrCast(@alignCast(ptr));
        return d.configPath(arena, config.file.music_user_token);
    }

    // ---- Startup and shutdown ----

    fn removeSecret(d: *Daemon) void {
        var buffer: [256]u8 = undefined;
        const path = Io.Dir.path.join(d.gpa, &.{ d.config_dir, secret_file }) catch return;
        defer d.gpa.free(path);
        // Only ours: never delete a file that a newer daemon wrote.
        const current = Io.Dir.cwd().readFile(d.io, path, &buffer) catch return;
        if (!std.mem.eql(u8, std.mem.trim(u8, current, " \t\r\n"), &d.secret)) return;
        Io.Dir.cwd().deleteFile(d.io, path) catch {};
    }
};

/// Locked while a daemon uses the config dir (its engine profiles, tokens and secret), whatever
/// its port. Holds that daemon's pid and port.
pub const lock_file = "daemon.lock";
/// Holds the secret CLI requests must carry; mode 600, removed at shutdown.
pub const secret_file = "daemon-secret";
/// The detached daemon's stdout and stderr.
pub const log_file = "daemon.log";

fn jsonAlloc(arena: Allocator, value: anytype) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

pub const RunOptions = struct {
    io: Io,
    gpa: Allocator,
    environ: *const Environ.Map,
    config_dir: []const u8,
    settings: *const settings_mod.Settings,
    /// Leave the terminal's session first (the CLI's auto-start passes `--detach`).
    detach: bool,
    err: *Io.Writer,
};

pub const RunError = error{
    /// Printed to `err`.
    Reported,
};

/// Runs the background process until a shutdown request. Returns normally when something else
/// already holds the port; fails when another daemon uses the config dir.
pub fn run(o: RunOptions) RunError!void {
    if (o.detach) platform.detachFromTerminal();
    const start = switch (o.settings.daemonStart()) {
        .ok => |start| start,
        .bad => |why| {
            o.err.print("error: {s}\n", .{why}) catch {};
            return error.Reported;
        },
    };
    const port = start.port;
    const idle: Io.Duration = .fromSeconds(@as(i64, start.idle_minutes) * 60);

    // One daemon per config dir: a second one, even on another port, would kill the first
    // one's engine as a leftover (same profile).
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const lock_path = std.mem.print(&path_buffer, "{s}{c}{s}", .{ o.config_dir, Io.Dir.path.sep, lock_file }) catch {
        o.err.print("error: config dir path too long: {s}\n", .{o.config_dir}) catch {};
        return error.Reported;
    };
    platform.createPrivateDir(o.io, o.config_dir) catch |e| {
        o.err.print("error: can't create {s}: {t}\n", .{ o.config_dir, e }) catch {};
        return error.Reported;
    };
    var holder_buffer: [64]u8 = undefined;
    const holder = std.mem.print(&holder_buffer, "pid {d}, port {d}\n", .{ platform.currentPid(), port }) catch unreachable;
    // A daemon that just stopped keeps the lock until its engine has exited (up to 7 s).
    var take: TakeLock = .{ .holder = holder };
    var other: [64]u8 = undefined;
    switch (waitOutLock(o.io, lock_path, port, &other, &take, TakeLock.held) catch return error.Reported) {
        .free => {},
        .other, .stuck => |who| {
            o.err.print("error: another am daemon ({s}) uses {s}; not starting\n", .{ who, o.config_dir }) catch {};
            return error.Reported;
        },
    }
    if (take.err) |e| {
        o.err.print("error: can't lock {s}: {t}\n", .{ lock_path, e }) catch {};
        return error.Reported;
    }
    const lock = take.file.?;
    defer lock.close(o.io);
    var build_arena: std.heap.ArenaAllocator = .init(o.gpa);
    defer build_arena.deinit();
    const build_id = buildId(o.io, build_arena.allocator()) catch "unknown";

    var d: Daemon = .{
        .io = o.io,
        .gpa = o.gpa,
        .environ = o.environ,
        .config_dir = o.config_dir,
        .settings = o.settings.*,
        .port = port,
        .engine_kind = start.engine,
        .secret = undefined,
        .channel = .init(o.io, o.gpa),
        .server = undefined,
        .idle = .{ .limit = idle, .last_active = Io.Clock.awake.now(o.io) },
        .signins = .init(o.io, o.gpa),
        .requests = .{ .timer = .{ .limit = idle, .last_active = Io.Clock.awake.now(o.io) } },
        .build_id = build_id,
    };
    defer d.channel.deinit();
    defer d.signins.deinit();
    var secret_bytes: [32]u8 = undefined;
    o.io.random(&secret_bytes);
    d.secret = std.fmt.bytesToHex(secret_bytes, .lower);
    d.server = .{ .io = o.io, .gpa = o.gpa, .channel = &d.channel, .backend = d.backend(), .secret = &d.secret };
    d.page = .init(o.io, &d.channel, &d.plays, d.enginePagePort(), .{});

    // Binding is the lock; only the winner writes the secret.
    d.server.bind(port) catch |e| switch (e) {
        error.PortBusy => {
            d.log("port {d} is taken (another am daemon running?); exiting", .{port});
            return;
        },
        else => {
            o.err.print("error: can't listen on port {d}: {t}\n", .{ port, e }) catch {};
            return error.Reported;
        },
    };
    platform.writePrivateFile(o.io, o.config_dir, secret_file, &d.secret) catch |e| {
        d.server.close();
        o.err.print("error: can't write {s}/{s}: {t}\n", .{ o.config_dir, secret_file, e }) catch {};
        return error.Reported;
    };
    platform.installShutdownHandlers();
    d.server.start() catch |e| {
        d.server.close();
        d.removeSecret();
        o.err.print("error: can't start the server: {t}\n", .{e}) catch {};
        return error.Reported;
    };
    d.log("listening on localhost:{d} (pid {d}, build {s}, engine {t}, idle close after {d} min)", .{
        port, platform.currentPid(), d.build_id, d.engine_kind, start.idle_minutes,
    });
    // `am doctor` reports them too.
    for (d.settings.warnings) |warning| d.log("warning: {s}", .{warning});

    var arena: std.heap.ArenaAllocator = .init(o.gpa);
    defer arena.deinit();
    const reason: []const u8 = while (true) {
        if (platform.shutdownRequested()) |signal| break signal;
        if (d.stop_requested.load(.acquire)) break "requested";
        _ = arena.reset(.retain_capacity);
        if (d.superviseEngine(arena.allocator())) break "unused";
        o.io.sleep(tick, .awake) catch break "cancel";
    };

    // No engine process may outlive the background process: refuse new launches and requests,
    // stop the engine (a launch in progress finishes first), and only then close the port, so
    // that a CLI waiting for it to close knows the engine is gone. The lock goes last.
    d.log("shutting down ({s})", .{reason});
    d.requests.close(o.io);
    {
        d.engine_mutex.lockUncancelable(o.io);
        defer d.engine_mutex.unlock(o.io);
        d.shutting_down = true;
        d.stopEngineLocked();
    }
    d.server.close();
    d.removeSecret();
    d.log("stopped", .{});
}

const testing = std.testing;

fn at(seconds: i64) Io.Timestamp {
    return .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s);
}

test "the build id is 16 hex digits, the same every time for the same binary" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const first = try buildId(testing.io, arena.allocator());
    try testing.expectEqual(@as(usize, 16), first.len);
    for (first) |c| try testing.expect(std.ascii.isHex(c));
    try testing.expectEqualStrings(first, try buildId(testing.io, arena.allocator()));
}

test "the engine closes once nothing has played for the idle limit" {
    var timer: IdleTimer = .{ .limit = .fromSeconds(60), .last_active = at(0) };
    try testing.expect(!timer.expired(at(30), false));
    try testing.expect(!timer.expired(at(59), false));
    try testing.expect(timer.expired(at(60), false));
}

test "playing, and CLI commands, push the idle close back" {
    var timer: IdleTimer = .{ .limit = .fromSeconds(60), .last_active = at(0) };
    // Playing from 0:50 to 3:00: never idle meanwhile.
    try testing.expect(!timer.expired(at(50), true));
    try testing.expect(!timer.expired(at(180), true));
    // Paused at 3:00: closes a minute later.
    try testing.expect(!timer.expired(at(200), false));
    try testing.expectEqual(@as(i64, 40), timer.remaining(at(200)).toSeconds());
    timer.touch(at(230));
    try testing.expect(!timer.expired(at(280), false));
    try testing.expect(timer.expired(at(290), false));
    // An older activity never moves the clock back.
    timer.touch(at(10));
    try testing.expect(timer.expired(at(290), false));
}

test "a CLI request that uses the engine keeps it open for as long as it runs" {
    var timer: IdleTimer = .{ .limit = .fromSeconds(60), .last_active = at(0) };
    timer.begin(at(10));
    // A doctor waiting minutes for Widevine.
    try testing.expect(!timer.expired(at(100), false));
    try testing.expect(!timer.expired(at(300), false));
    timer.end(at(310));
    try testing.expect(!timer.expired(at(369), false));
    try testing.expect(timer.expired(at(370), false));

    // Two at once: open until both are done.
    timer.begin(at(400));
    timer.begin(at(410));
    timer.end(at(420));
    try testing.expect(!timer.expired(at(600), false));
    timer.end(at(600));
    try testing.expect(timer.expired(at(660), false));
}

fn requestsAt(seconds: i64) Requests {
    return .{ .timer = .{ .limit = .fromSeconds(60), .last_active = at(seconds) } };
}

test "with no engine, the daemon exits once nothing used it for the idle limit; a connected TUI keeps it" {
    const io = testing.io;
    var idle: IdleTimer = .{ .limit = .fromSeconds(60), .last_active = at(0) };
    var q = requestsAt(0);
    try testing.expect(!q.closeIfUnused(io, &idle, at(59)));
    // A TUI's watch, open for ten minutes.
    var watch: Requests.Ticket = .{};
    try testing.expect(q.begin(io, at(30), &watch));
    try testing.expect(!q.closeIfUnused(io, &idle, at(600)));
    q.end(io, at(630), &watch);
    try testing.expect(!q.closeIfUnused(io, &idle, at(689)));
    // A request using the engine (a sign-in waiting) holds it as well.
    idle.begin(at(640));
    try testing.expect(!q.closeIfUnused(io, &idle, at(900)));
    idle.end(at(900));
    try testing.expect(!q.closeIfUnused(io, &idle, at(959)));
    try testing.expect(q.closeIfUnused(io, &idle, at(960)));
    // From then on requests are refused; the CLI starts a fresh daemon.
    var late: Requests.Ticket = .{};
    try testing.expect(!q.begin(io, at(961), &late));
}

test "a request that doesn't use the engine pushes the exit back, not the engine's idle close" {
    const io = testing.io;
    var idle: IdleTimer = .{ .limit = .fromSeconds(60), .last_active = at(0) };
    var q = requestsAt(0);
    // am status at 0:50.
    var status: Requests.Ticket = .{};
    try testing.expect(q.begin(io, at(50), &status));
    q.end(io, at(51), &status);
    try testing.expect(idle.expired(at(60), false));
    try testing.expect(!q.closeIfUnused(io, &idle, at(110)));
    try testing.expect(q.closeIfUnused(io, &idle, at(111)));
    // Closed by a stop meanwhile: refused as well.
    var stopped = requestsAt(0);
    stopped.close(io);
    var late: Requests.Ticket = .{};
    try testing.expect(!stopped.begin(io, at(1), &late));
}

test "stop-if-unused: alone means no other request whose client is still there" {
    const io = testing.io;
    var q = requestsAt(0);
    var watch_gone: std.atomic.Value(bool) = .init(false);
    var watch: Requests.Ticket = .{ .client_gone = &watch_gone };
    var other_gone: std.atomic.Value(bool) = .init(false);
    var other: Requests.Ticket = .{ .client_gone = &other_gone };
    var asker: Requests.Ticket = .{ .client_gone = &other_gone };
    try testing.expect(q.begin(io, at(1), &watch));
    try testing.expect(q.begin(io, at(2), &other));
    try testing.expect(q.begin(io, at(3), &asker));
    try testing.expect(q.othersInUse(io, &asker));
    try testing.expect(!q.closeIfAlone(io, &asker));
    // The other TUI quit: its watch is still open, but its client is gone.
    other_gone.store(true, .release);
    q.end(io, at(4), &other);
    try testing.expect(!q.closeIfAlone(io, &asker));
    watch_gone.store(true, .release);
    try testing.expect(!q.othersInUse(io, &asker));
    try testing.expect(q.closeIfAlone(io, &asker));
    var late: Requests.Ticket = .{};
    try testing.expect(!q.begin(io, at(5), &late));
}

test "stop-if-unused: a queue whose client left, and a request that can't tell, still count" {
    const io = testing.io;
    var q = requestsAt(0);
    var gone: std.atomic.Value(bool) = .init(true);
    var queue: Requests.Ticket = .{ .client_gone = &gone, .outlives_client = true };
    var unknown: Requests.Ticket = .{};
    var asker: Requests.Ticket = .{};
    try testing.expect(q.begin(io, at(1), &queue));
    try testing.expect(q.begin(io, at(2), &asker));
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(3), &queue);
    try testing.expect(q.begin(io, at(4), &unknown));
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(5), &unknown);
    try testing.expect(q.closeIfAlone(io, &asker));
}

test "the lock's holder: a daemon for this port is waited for, another's or a silent one briefly" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try Io.Dir.path.join(testing.allocator, &.{ dir, lock_file });
    defer testing.allocator.free(path);
    var text: [64]u8 = undefined;
    try testing.expect(lockHolder(io, path, 47823, &text) == .unknown);
    try tmp.dir.writeFile(io, .{ .sub_path = lock_file, .data = "pid 86147, port 47823\n" });
    try testing.expectEqualStrings("pid 86147, port 47823", lockHolder(io, path, 47823, &text).this_port);
    try testing.expectEqualStrings("pid 86147, port 47823", lockHolder(io, path, 50000, &text).other);
    try tmp.dir.writeFile(io, .{ .sub_path = lock_file, .data = "pid 861" });
    try testing.expect(lockHolder(io, path, 47823, &text) == .unknown);

    const half: Io.Duration = .fromMilliseconds(500);
    try testing.expectEqual(LockVerdict.wait, lockVerdict(.{ .this_port = "" }, .fromSeconds(5)));
    try testing.expectEqual(LockVerdict.stuck, lockVerdict(.{ .this_port = "" }, lock_wait));
    try testing.expectEqual(LockVerdict.wait, lockVerdict(.{ .other = "" }, half));
    try testing.expectEqual(LockVerdict.other, lockVerdict(.{ .other = "" }, brief_hold));
    try testing.expectEqual(LockVerdict.wait, lockVerdict(.{ .unknown = "" }, half));
    try testing.expectEqual(LockVerdict.stuck, lockVerdict(.{ .unknown = "" }, brief_hold));
}

test "stop-if-unused: the quitting TUI's own watch and queue don't count before its close is noticed; another TUI's queue does" {
    const io = testing.io;
    var q = requestsAt(0);
    var not_yet: std.atomic.Value(bool) = .init(false);
    var own_watch: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "0123456789abcdef" };
    var other_watch: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "fedcba9876543210" };
    var own_queue: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "0123456789abcdef", .uses_engine = true, .outlives_client = true };
    var other_queue: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "fedcba9876543210", .uses_engine = true, .outlives_client = true };
    var asker: Requests.Ticket = .{ .client_id = "0123456789abcdef" };
    try testing.expect(q.begin(io, at(1), &own_watch));
    try testing.expect(q.begin(io, at(2), &other_watch));
    try testing.expect(q.begin(io, at(3), &asker));
    // Another TUI still watches.
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(4), &other_watch);
    // A queue the quitting TUI sent a moment before q doesn't count: nothing is audible yet, and
    // `Daemon.stopIfUnused` stops it first (#55). Nor is it waited for.
    try testing.expect(q.begin(io, at(5), &own_queue));
    try testing.expect(!own_queue.settlingFor(&asker));
    try testing.expect(!q.othersInUse(io, &asker));
    // Another TUI's queue is on its way to music that TUI will hear.
    try testing.expect(q.begin(io, at(6), &other_queue));
    try testing.expect(q.othersInUse(io, &asker));
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(7), &other_queue);
    try testing.expect(q.closeIfAlone(io, &asker));
}

test "stop-if-unused: the quitting TUI's own request doesn't count even where its hang-up can't be told; another's does" {
    const io = testing.io;
    var q = requestsAt(0);
    var own: Requests.Ticket = .{ .client_id = "0123456789abcdef" };
    var other: Requests.Ticket = .{ .client_id = "fedcba9876543210" };
    var anonymous: Requests.Ticket = .{};
    var asker: Requests.Ticket = .{ .client_id = "0123456789abcdef" };
    try testing.expect(q.begin(io, at(1), &own));
    try testing.expect(q.begin(io, at(2), &other));
    try testing.expect(q.begin(io, at(3), &anonymous));
    try testing.expect(q.begin(io, at(4), &asker));
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(5), &other);
    // A request that names no client is never the asker's.
    try testing.expect(!q.closeIfAlone(io, &asker));
    q.end(io, at(6), &anonymous);
    try testing.expect(q.closeIfAlone(io, &asker));
}

test "stop-if-unused: a pause the quitting TUI sent is waited for before its close is noticed; another client's isn't" {
    const io = testing.io;
    var not_yet: std.atomic.Value(bool) = .init(false);
    var own_pause: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "0123456789abcdef", .uses_engine = true };
    var other_pause: Requests.Ticket = .{ .client_gone = &not_yet, .client_id = "fedcba9876543210", .uses_engine = true };
    var asker: Requests.Ticket = .{ .client_id = "0123456789abcdef" };
    try testing.expect(own_pause.settlingFor(&asker));
    // Its client is there and keeps the daemon anyway (`inUseFor`): nothing to wait for.
    try testing.expect(!other_pause.settlingFor(&asker));
    // A queue still happens once it's gone, so it's in use rather than settling.
    var own_queue: Requests.Ticket = .{ .client_id = "0123456789abcdef", .uses_engine = true, .outlives_client = true };
    try testing.expect(!own_queue.settlingFor(&asker));

    var q = requestsAt(0);
    try testing.expect(q.begin(io, at(1), &own_pause));
    try testing.expect(q.begin(io, at(2), &asker));
    var ender = try io.concurrent(endLater, .{ &q, &own_pause });
    const start: Io.Clock.Timestamp = .now(io, .awake);
    try q.settle(io, &asker, .fromSeconds(10));
    try ender.await(io);
    // It waited for the pause to end, not for the timeout.
    try testing.expect(asker.next == null);
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
    try testing.expect(q.closeIfAlone(io, &asker));
}

test "stop-if-unused: a pause sent just before quitting lands first, for a bounded time" {
    const io = testing.io;
    var q = requestsAt(0);
    var gone: std.atomic.Value(bool) = .init(true);
    var pause: Requests.Ticket = .{ .client_gone = &gone, .uses_engine = true };
    var asker: Requests.Ticket = .{};
    try testing.expect(q.begin(io, at(1), &pause));
    try testing.expect(q.begin(io, at(2), &asker));
    // It never ends: the wait gives up.
    const start: Io.Clock.Timestamp = .now(io, .awake);
    try q.settle(io, &asker, .fromMilliseconds(100));
    try testing.expect(start.untilNow(io).raw.toMilliseconds() >= 100);
    // It ends meanwhile: the wait ends with it.
    var ender = try io.concurrent(endLater, .{ &q, &pause });
    try q.settle(io, &asker, .fromSeconds(10));
    try ender.await(io);
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
    try testing.expect(q.closeIfAlone(io, &asker));
}

fn endLater(q: *Requests, t: *Requests.Ticket) Io.Cancelable!void {
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    q.end(testing.io, at(3), t);
}

test "the engine keeps the daemon while it plays, loads, signs in, or can't say" {
    const playing: playback.Report = .{ .state = .playing };
    const paused: playback.Report = .{ .state = .paused, .nowPlaying = .{} };
    try testing.expectEqual(null, engineInUse(.{ .running = false }, 0));
    try testing.expectEqualStrings("a sign-in is waiting", engineInUse(.{ .running = false }, 1).?);
    // Its difference from what a reload would lose: nobody listens to a paused song.
    try testing.expectEqual(null, engineInUse(.{ .running = true, .ready = true, .report = paused }, 0));
    try testing.expectEqualStrings("music is playing", engineInUse(.{ .running = true, .ready = true, .report = playing }, 0).?);
    // Live radio reports playing like a song.
    try testing.expectEqualStrings("music is playing", engineInUse(.{ .running = true, .ready = true, .report = .{ .state = .unknown, .isPlaying = true } }, 0).?);
    try testing.expectEqualStrings("a song is starting", engineInUse(.{ .running = true, .ready = true, .report = .{ .state = .loading } }, 0).?);
    // A queue on its way, alone or replacing a paused song.
    try testing.expectEqualStrings("a song is starting", engineInUse(.{ .running = true, .ready = true, .report = .{ .state = .none, .loadPending = true } }, 0).?);
    try testing.expectEqualStrings("a song is starting", engineInUse(.{ .running = true, .ready = true, .report = .{ .state = .paused, .nowPlaying = .{}, .loadPending = true } }, 0).?);
    // Stopped live radio is silent too.
    try testing.expectEqual(null, engineInUse(.{ .running = true, .ready = true, .report = .{ .state = .stopped, .stoppedLive = .{ .id = "ra.1" } } }, 0));
    try testing.expectEqualStrings("the engine is loading", engineInUse(.{ .running = true }, 0).?);
    try testing.expectEqualStrings("the engine is loading", engineInUse(.{ .running = true, .ready = false, .report = paused }, 0).?);
    try testing.expectEqualStrings("a sign-in window is open", engineInUse(.{ .running = true, .signin_window = true }, 0).?);
    try testing.expectEqualStrings("the engine page stopped reporting", engineInUse(.{ .running = true, .ready = true, .report = paused, .report_age_ms = 9000 }, 0).?);
}

test "once the quitting TUI's own play is stopped, a page still loading or a song still starting keeps nothing; music playing or a silent page still does" {
    const stopped: EngineView = .{ .running = true, .own_play_stopped = true };
    try testing.expectEqual(null, engineInUse(stopped, 0));
    var not_ready = stopped;
    not_ready.report = .{ .state = .none };
    try testing.expectEqual(null, engineInUse(not_ready, 0));
    var starting = stopped;
    starting.ready = true;
    starting.report = .{ .state = .loading };
    try testing.expectEqual(null, engineInUse(starting, 0));
    var load_pending = starting;
    load_pending.report = .{ .state = .paused, .nowPlaying = .{}, .loadPending = true };
    try testing.expectEqual(null, engineInUse(load_pending, 0));
    var playing = starting;
    playing.report = .{ .state = .playing };
    try testing.expectEqualStrings("music is playing", engineInUse(playing, 0).?);
    var silent = starting;
    silent.report_age_ms = 9000;
    try testing.expectEqualStrings("the engine page stopped reporting", engineInUse(silent, 0).?);
    var window = stopped;
    window.signin_window = true;
    try testing.expectEqualStrings("a sign-in window is open", engineInUse(window, 0).?);
}

test "the browser comes from its path setting, else the first candidate found, looked up on PATH if it's a name" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "bin2");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin2/firefox", .data = "" });
    const bin1 = try Io.Dir.path.join(a, &.{ root, "bin1" });
    const bin2 = try Io.Dir.path.join(a, &.{ root, "bin2" });
    var both: Environ.Map = .init(a);
    try both.put("PATH", try std.mem.join(a, &.{Io.Dir.path.delimiter}, &.{ bin1, bin2 }));
    var only_bin1: Environ.Map = .init(a);
    try only_bin1.put("PATH", bin1);
    var empty: Environ.Map = .init(a);

    const names: []const platform.Candidate = &.{ .{ .path = "firefox-esr" }, .{ .path = "firefox" } };
    // firefox-esr isn't there; firefox is, in the second PATH entry.
    try testing.expectEqualStrings(try Io.Dir.path.join(a, &.{ bin2, "firefox" }), (try findBinary(a, io, null, names, &both)).?);
    try testing.expectEqual(null, try findBinary(a, io, null, names, &only_bin1));
    try testing.expectEqual(null, try findBinary(a, io, null, names, &empty));
    // An absolute candidate is taken as it is, not looked up.
    const absolute = try Io.Dir.path.join(a, &.{ bin2, "firefox" });
    const nonexistent = try Io.Dir.path.join(a, &.{ root, "nonexistent", "firefox" });
    try testing.expectEqualStrings(absolute, (try findBinary(a, io, null, &.{ .{ .path = nonexistent }, .{ .path = absolute } }, &empty)).?);
    // The setting wins, and must exist.
    try testing.expectEqualStrings(absolute, (try findBinary(a, io, absolute, names, &empty)).?);
    try testing.expectEqual(null, try findBinary(a, io, nonexistent, names, &empty));
    try testing.expectEqual(null, try findBinary(a, io, "relative/chrome", names, &empty));
}

test "a candidate under an environment variable is looked for in the directory it names" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    try tmp.dir.createDirPath(io, "x86/Mozilla Firefox");
    try tmp.dir.writeFile(io, .{ .sub_path = "x86/Mozilla Firefox/firefox.exe", .data = "" });

    const in_dir = try Io.Dir.path.join(a, &.{ "Mozilla Firefox", "firefox.exe" });
    const candidates: []const platform.Candidate = &.{
        .{ .under = "ProgramFiles", .path = in_dir },
        .{ .under = "ProgramFiles(x86)", .path = in_dir },
    };
    var environ: Environ.Map = .init(a);
    try environ.put("ProgramFiles", try Io.Dir.path.join(a, &.{ root, "missing" }));
    try environ.put("ProgramFiles(x86)", try Io.Dir.path.join(a, &.{ root, "x86" }));
    try testing.expectEqualStrings(
        try Io.Dir.path.join(a, &.{ root, "x86", "Mozilla Firefox", "firefox.exe" }),
        (try findBinary(a, io, null, candidates, &environ)).?,
    );
    // An unset (or empty) variable rules its candidate out.
    var empty: Environ.Map = .init(a);
    try empty.put("ProgramFiles", "");
    try testing.expectEqual(null, try findBinary(a, io, null, candidates, &empty));
}

test "launches don't take the profile from a sign-in in progress or from music that plays or is on its way" {
    const window: Occupant = .{ .signin_window = true, .music = .none };

    // Starting the engine: reuse it, whatever its page holds, or take over a sign-in window
    // nobody waits on any more.
    try testing.expectEqual(Conflict.none, conflict(.engine, null, 0));
    for (std.enums.values(playback.Music)) |music|
        try testing.expectEqual(Conflict.none, conflict(.engine, .{ .signin_window = false, .music = music }, 0));
    try testing.expectEqual(Conflict.replace, conflict(.engine, window, 0));
    try testing.expectEqualStrings("sign-in in progress; finish or cancel `am signin` first", conflict(.engine, window, 1).refuse);

    // A sign-in window: never over music that plays or is on its way, nor over another sign-in
    // in progress. A silent page gives way, so the advice works: `am stop` leaves its song
    // paused at 0:00.
    try testing.expectEqual(Conflict.none, conflict(.signin_window, null, 0));
    try testing.expectEqualStrings("stop playback first: am stop", conflict(.signin_window, .{ .signin_window = false, .music = .playing }, 0).refuse);
    try testing.expectEqualStrings("stop playback first: am stop", conflict(.signin_window, .{ .signin_window = false, .music = .starting }, 0).refuse);
    try testing.expectEqual(Conflict.replace, conflict(.signin_window, .{ .signin_window = false, .music = .paused }, 0));
    try testing.expectEqual(Conflict.replace, conflict(.signin_window, .{ .signin_window = false, .music = .stopped_live }, 0));
    try testing.expectEqual(Conflict.replace, conflict(.signin_window, .{ .signin_window = false, .music = .none }, 0));
    try testing.expectEqual(Conflict.replace, conflict(.signin_window, window, 0));
    try testing.expectEqualStrings("another am signin is in progress", conflict(.signin_window, window, 1).refuse);
}
