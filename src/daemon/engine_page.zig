//! The engine page module: it owns the engine page from the engine's launch until MusicKit is
//! fit for the caller (see GLOSSARY.md for the words). It waits for the page after a launch,
//! waits for Widevine, sends every reload of the page and waits for its new page load, asks
//! the page whether Apple refuses its developer token, and marks a page load that is behind on
//! the Music User Token.
//!
//! Callers state an intent and get one outcome. A repair for a play (`am play`, the TUI's queue)
//! repairs whatever the page needs, whatever it holds, because the play replaces it. A repair if
//! idle (`am doctor`) makes the same repairs only while the page holds no music and no play is
//! on its way, and says which ones it left alone. A new Music User Token (the sign-in) reloads a
//! page behind on it that holds no music, or only a preview, with no play on its way, so it
//! reads the new token. A page it leaves alone stays behind, and the next repair for a play
//! reloads it first.
//!
//! One reload runs at a time. A caller that finds one in flight waits for its new page load and
//! decides again on it. A control play (Space, `am resume`, play-next, play-later) joins one
//! without repairing anything, so its page call lands on the new page load. A decision is acted
//! on, and a verdict returned, only while no reload, launch or sign-in has come since its inputs
//! were read, and the reloads of doctor and the sign-in only while no play began since they read
//! `Plays`. That check and the reload's record are one short critical section, so two callers
//! can't both send a reload, and none acts on a page load another one reloaded.
//!
//! Behind is decided on the Music User Token the page's report names (a hash, as it names its
//! developer token): a page load that names another one than the stored one is behind, and one
//! that names the stored one isn't, whenever it began. A page that names none (an older page, a
//! browser that can't hash, MusicKit holding none) is judged by an epoch: the sign-in moves it
//! once it has stored a new token, and each page load is stamped with the epoch read just before
//! the act that started it, its launch call or its reload's record. Such a page load is behind
//! while the epoch is past its stamp, which never takes one that may have read the old token as
//! not behind, at the cost of at most one extra reload. Either way the sign-in moves the epoch,
//! so a decision made on what was read before it is made again.
const std = @import("std");
const channel_mod = @import("channel.zig");
const host_mod = @import("host.zig");
const platform = @import("../platform.zig");
const playback = @import("../playback.zig");
const protocol = @import("protocol.zig");
const Deadline = @import("../deadline.zig").Deadline;

const Allocator = std.mem.Allocator;
const Channel = channel_mod.Channel;
const Io = std.Io;
const Plays = host_mod.Plays;
const Reply = protocol.Reply;
const Report = playback.Report;

pub const StartError = error{
    /// Why is in the caller's `problem`.
    EngineFailed,
} || Allocator.Error || Io.Cancelable;

/// How long each step may take. Production keeps the defaults; tests shorten them.
pub const Timing = struct {
    /// A new engine page gets this long, from the launch, to connect and configure MusicKit.
    launch_wait: Io.Duration = .fromSeconds(90),
    /// A reloaded page gets this long to configure MusicKit.
    reload_wait: Io.Duration = .fromSeconds(60),
    /// The sign-in waits this long for the reload it sent.
    signin_wait: Io.Duration = .fromSeconds(30),
    /// How long Firefox may take to install Widevine on a fresh profile.
    widevine_wait: Io.Duration = .fromSeconds(180),
    /// How often the page is probed for Widevine meanwhile.
    widevine_poll: Io.Duration = .fromSeconds(5),
    /// A look at the page (`snapshot`).
    look: Io.Duration = .fromSeconds(5),
    /// The page's check of its developer token with Apple.
    check: Io.Duration = .fromSeconds(10),
    /// The Widevine probe: Firefox holds it open while it installs the CDM (up to 60 s).
    probe: Io.Duration = .fromSeconds(90),
    /// Sending the reload.
    send: Io.Duration = .fromSeconds(5),
    /// The longest a wait on the page goes without looking again.
    step: Io.Duration = .fromSeconds(1),
};

/// What a caller asks of the page.
pub const Intent = union(enum) {
    /// Repair for a play: `am play`, the TUI's queue.
    for_play: *const Plays.Play,
    /// Repair if idle: `am doctor`. Token repairs only with `user_token_ok`: Apple accepted the
    /// Music User Token with the current developer token.
    if_idle: struct { user_token_ok: bool },
};

pub const Outcome = struct {
    /// The page load the verdict is about. After a reload that didn't come back, or after the
    /// engine stopped, a report that carries why in its `configureError`.
    report: Report,
    verdict: Verdict,
    /// Repair if idle: the repairs the page needs that were left for the next play.
    left_alone: ?LeftAlone = null,
};

/// `not_configured`: why, or null when MusicKit hasn't configured and gave no error (each caller
/// words that case in its own way).
pub const Verdict = union(enum) { ready, not_configured: ?[]const u8, signed_out, cancelled };

/// Why a page load needs a reload.
pub const Repair = enum {
    /// MusicKit configured without DRM support, and Widevine answers now.
    drm,
    /// MusicKit signed the page out, though Apple accepts the Music User Token.
    signed_out,
    /// The page load is behind on the Music User Token: it names another one than the stored
    /// one, or, naming none, it loaded before the last sign-in.
    behind,
    /// Apple refuses the developer token the page configured with.
    token_refused,

    /// The reason in `daemon.log`'s words.
    pub fn format(why: Repair, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(switch (why) {
            .drm => "Widevine had become available",
            .signed_out => "MusicKit had signed it out",
            .behind => "it loaded before the last sign-in",
            .token_refused => "Apple refused its developer token",
        });
    }

    /// What the CLI says right after the reload went out.
    pub fn reloadLine(why: Repair) []const u8 {
        return switch (why) {
            .drm => "Widevine is available; reloading the engine page so MusicKit sees it.",
            .signed_out => "MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens",
            .behind => "the engine page loaded before the last sign-in; reloading it so it reads the new Music User Token",
            .token_refused => "Apple refused the engine page's developer token (HTTP 401); reloading the page so it takes the current one",
        };
    }

    /// The need, in a left-alone note.
    fn need(why: Repair) []const u8 {
        return switch (why) {
            .drm => "Widevine is available, but MusicKit configured without it",
            .signed_out => "MusicKit signed the engine page out, though Apple accepts the Music User Token",
            .behind => "the engine page loaded before the last sign-in",
            .token_refused => "Apple refuses the engine page's developer token",
        };
    }
};

/// The repairs a page needs that a repair if idle left for the next play, and why.
pub const LeftAlone = struct {
    needs: std.EnumSet(Repair),
    because: Because,

    /// The body of the note for one need: "<need>; <because>, so it's left alone: the next play
    /// reloads it".
    pub fn note(l: LeftAlone, why: Repair) Note {
        return .{ .need = why, .because = l.because };
    }

    pub const Note = struct {
        need: Repair,
        because: Because,

        pub fn format(n: Note, w: *Io.Writer) Io.Writer.Error!void {
            try w.print("{s}; {f}, so it's left alone: the next play reloads it", .{ n.need.need(), n.because });
        }
    };
};

/// Why a page was left alone.
pub const Because = union(enum) {
    holds: playback.Music,
    play_on_its_way,
    no_answer,
    /// The sign-in only.
    reloading,
    not_connected,

    pub fn format(b: Because, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(switch (b) {
            .holds => "the page holds music",
            .play_on_its_way => "a play is on its way",
            .no_answer => "the engine page didn't answer",
            .reloading => "the engine page is reloading",
            .not_connected => "the engine page isn't connected yet",
        });
    }
};

/// What the sign-in's new Music User Token did to the page. `reloaded`: the page has the new
/// token: its report names it, or a page load that began after the sign-in reads it, the one its
/// own reload brought or one that another command's reload or launch began (that reload may
/// still be in flight: the sign-in doesn't wait for it). `left_alone`: the page is behind, or
/// may be, and the next play reloads it first if it is.
/// `no_engine`: the next launch reads the new token. `superseded`: a newer sign-in came
/// meanwhile, and that one decides and logs.
pub const NewUserToken = union(enum) { reloaded, not_back, left_alone: Because, no_engine, superseded };

/// The engine and its page, as `start` found them.
pub const Started = struct {
    kind: []const u8,
    pid: platform.ProcessId,
    /// False when the engine was already running.
    started: bool,
    headless: bool,
    /// Whether MusicKit configured (or failed to) before the launch wait ran out.
    ready: bool,
    /// The page's latest report; empty when it sent none.
    report: Report,
};

/// The page's codecs and Widevine, as `drmProbe` answers.
pub const Probe = struct {
    h264: []const u8 = "",
    aac: []const u8 = "",
    mseAac: bool = false,
    widevine: bool = false,
    widevineError: ?[]const u8 = null,
};

/// `start`, `probe`, `repair`, `reloadInFlight` and `joinReload`, for the callers. Adapters:
/// `EnginePage.page`, and the playback fake's canned page.
pub const Page = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        start: *const fn (ptr: *anyopaque, arena: Allocator, problem: *[]const u8) StartError!Started,
        probe: *const fn (ptr: *anyopaque, r: *Reply) Reply.Error!Probe,
        repair: *const fn (ptr: *anyopaque, r: *Reply, intent: Intent) Reply.Error!Outcome,
        reloadInFlight: *const fn (ptr: *anyopaque, arena: Allocator) Allocator.Error!bool,
        joinReload: *const fn (ptr: *anyopaque, r: *Reply, play: ?*const Plays.Play) Reply.Error!void,
    };

    /// Launches the engine if none runs and waits for its page. `error.EngineFailed` with
    /// `problem`. Call it before `repair` in the same request.
    pub fn start(pg: Page, arena: Allocator, problem: *[]const u8) StartError!Started {
        return pg.vtable.start(pg.ptr, arena, problem);
    }

    /// The page's codecs and Widevine, for `am doctor`'s lines, from the page load after any
    /// reload in flight. Prints only the line for waiting on that reload.
    pub fn probe(pg: Page, r: *Reply) Reply.Error!Probe {
        return pg.vtable.probe(pg.ptr, r);
    }

    /// Repairs the page for `intent` and says whether MusicKit is fit for it.
    pub fn repair(pg: Page, r: *Reply, intent: Intent) Reply.Error!Outcome {
        return pg.vtable.repair(pg.ptr, r, intent);
    }

    /// Whether a reload is in flight now. Never waits and never repairs: a stop asks it so it
    /// doesn't wait on the page.
    pub fn reloadInFlight(pg: Page, arena: Allocator) Allocator.Error!bool {
        return pg.vtable.reloadInFlight(pg.ptr, arena);
    }

    /// Joins the reload in flight, if any, without repairing: a control play (Space, `am
    /// resume`, play-next, play-later) makes its page call on the new page load, not in the
    /// reload's gap. Never sends a reload. Prints the line for waiting on the reload (once).
    /// Returns once no reload is in flight, or once a stop cancelled `play`.
    pub fn joinReload(pg: Page, r: *Reply, play: ?*const Plays.Play) Reply.Error!void {
        return pg.vtable.joinReload(pg.ptr, r, play);
    }
};

/// What leaves the process: launching the browser, the tokens the daemon hands out, and the
/// daemon's log. Adapters: the Daemon, and the test rig's launcher.
pub const Port = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Launches the engine if none runs (`.launch`), or relaunches the one of that
        /// generation while its page still isn't connected (`.relaunch`); either way it returns
        /// the engine that runs then.
        launch: *const fn (ptr: *anyopaque, arena: Allocator, how: Launch.How, problem: *[]const u8) host_mod.EngineError!Launch,
        /// The developer token the daemon hands out now; null when there is none.
        developerToken: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId,
        /// The Music User Token stored now, the one a page load reads; null when there is none
        /// or it can't be read.
        userToken: *const fn (ptr: *anyopaque, arena: Allocator) (Allocator.Error || Io.Cancelable)!?playback.TokenId,
        log: *const fn (ptr: *anyopaque, line: []const u8) void,
    };
};

/// An engine launch, as the port's `launch` returns it.
pub const Launch = struct {
    /// The channel's generation for it (`Channel.currentLaunch`).
    generation: u64,
    kind: []const u8,
    pid: platform.ProcessId,
    /// This call launched it; false when it was already running.
    launched: bool,
    headless: bool,
    /// When it was launched, on the awake clock.
    at: Io.Timestamp,
    /// The engine's own log, for the failure texts.
    log_path: []const u8,

    pub const How = union(enum) { launch, relaunch: u64 };
};

pub const EnginePage = struct {
    io: Io,
    channel: *Channel,
    plays: *Plays,
    port: Port,
    timing: Timing,
    /// Guards the reloads below. Held only for loads and stores, never across a channel call, a
    /// port call, a print or a wait, so a stop or a shutdown never waits on it. It is taken
    /// before the `Plays` lock, never after.
    mutex: Io.Mutex = .init,
    /// The newest launch the module has seen. A decision about an older one is stale.
    launch: u64 = 0,
    /// Reloads recorded so far; the newest one's id.
    reloads: u64 = 0,
    /// The reload in flight: there is one at a time.
    in_flight: ?Reload = null,
    /// How the last reload that was in flight ended.
    last_end: ?Ended = null,
    /// The Music User Token epoch: the sign-in moves it once it has stored a new token.
    user_token: u64 = 0,
    /// The epoch the current page load was stamped with: the one read just before the act
    /// that started it, its launch call or its reload's record. A page load whose report names
    /// no Music User Token is behind while `user_token` is past it.
    load_stamp: u64 = 0,

    pub fn init(io: Io, channel: *Channel, plays: *Plays, port: Port, timing: Timing) EnginePage {
        return .{ .io = io, .channel = channel, .plays = plays, .port = port, .timing = timing };
    }

    /// The callers' interface.
    pub fn page(p: *EnginePage) Page {
        return .{ .ptr = p, .vtable = &.{
            .start = pageStart,
            .probe = pageProbe,
            .repair = pageRepair,
            .reloadInFlight = pageReloadInFlight,
            .joinReload = pageJoinReload,
        } };
    }

    fn of(ptr: *anyopaque) *EnginePage {
        return @ptrCast(@alignCast(ptr));
    }

    fn pageStart(ptr: *anyopaque, arena: Allocator, problem: *[]const u8) StartError!Started {
        return of(ptr).start(arena, problem);
    }

    fn pageProbe(ptr: *anyopaque, r: *Reply) Reply.Error!Probe {
        return of(ptr).probe(r);
    }

    fn pageRepair(ptr: *anyopaque, r: *Reply, intent: Intent) Reply.Error!Outcome {
        return of(ptr).repair(r, intent);
    }

    fn pageReloadInFlight(ptr: *anyopaque, arena: Allocator) Allocator.Error!bool {
        return of(ptr).reloadInFlight(arena);
    }

    fn pageJoinReload(ptr: *anyopaque, r: *Reply, play: ?*const Plays.Play) Reply.Error!void {
        return of(ptr).joinReload(r, play);
    }

    /// Launches the engine if none runs, then waits for its page: connected, with MusicKit
    /// configured or failed to, up to the launch wait counted from the launch. A page that
    /// never connected, long after its launch, is relaunched. While a reload is in flight it
    /// returns at once with the latest report: the page is between two page loads, and `repair`
    /// waits for the new one. Prints nothing.
    pub fn start(p: *EnginePage, arena: Allocator, problem: *[]const u8) StartError!Started {
        var asked = p.userTokenEpoch();
        var launch = try p.port.vtable.launch(p.port.ptr, arena, .launch, problem);
        p.recordLaunch(launch, asked);
        // A page with no stream in a reload's gap isn't one that never connected.
        try p.settle(arena);
        if (p.inFlight() != null) {
            const report = try p.lastReport(arena);
            return started(launch, report.configureDone(), report);
        }
        // A page that never connected, long after its launch, won't any more.
        if (!p.channel.connected() and launch.at.durationTo(p.now()).nanoseconds > p.timing.launch_wait.nanoseconds) {
            asked = p.userTokenEpoch();
            launch = try p.port.vtable.launch(p.port.ptr, arena, .{ .relaunch = launch.generation }, problem);
            p.recordLaunch(launch, asked);
        }

        // The launch wait counts from the launch: a warm engine's page is ready, or never will be.
        const deadline: Deadline = .since(p.io, launch.at, p.timing.launch_wait);
        var seen = try p.channel.waitChange(null, .zero);
        while (true) {
            if (try p.channel.lastReport(arena)) |last| if (p.channel.connected()) if (playback.parseReport(arena, last.json)) |report|
                if (report.configureDone()) return started(launch, true, report);
            // Every engine stop moves the channel's launch, and the supervisor stops an engine
            // that exited within a tick.
            if (p.channel.currentLaunch() != launch.generation) {
                problem.* = try arena.print("{s} exited before its page loaded; see {s}", .{ launch.kind, launch.log_path });
                return error.EngineFailed;
            }
            if (deadline.passed()) {
                if (!p.channel.connected()) {
                    problem.* = try arena.print("the engine page didn't connect within {d} s; see {s}", .{ p.timing.launch_wait.toSeconds(), launch.log_path });
                    return error.EngineFailed;
                }
                return started(launch, false, try p.lastReport(arena));
            }
            seen = try p.channel.waitChange(seen, .{ .nanoseconds = @min(deadline.left().nanoseconds, p.timing.step.nanoseconds) });
        }
    }

    fn started(launch: Launch, ready: bool, report: Report) Started {
        return .{ .kind = launch.kind, .pid = launch.pid, .started = launch.launched, .headless = launch.headless, .ready = ready, .report = report };
    }

    /// The page's latest report, or an empty one when it sent none or one am can't read.
    fn lastReport(p: *EnginePage, arena: Allocator) Allocator.Error!Report {
        const last = try p.channel.lastReport(arena) orelse return .{};
        return playback.parseReport(arena, last.json) orelse .{};
    }

    fn now(p: *const EnginePage) Io.Timestamp {
        return Io.Clock.awake.now(p.io);
    }

    /// The page's codecs and Widevine, for `am doctor`'s lines, from the page load after any
    /// reload in flight: it waits that one out first, and says so. A failed probe says why in
    /// `widevineError`.
    pub fn probe(p: *EnginePage, r: *Reply) Reply.Error!Probe {
        try p.joinReload(r, null);
        return p.drmProbe(r.arena);
    }

    /// Whether a reload is in flight now, once one that has landed, run out its deadline or
    /// lost its launch is settled. Never waits.
    pub fn reloadInFlight(p: *EnginePage, arena: Allocator) Allocator.Error!bool {
        try p.settle(arena);
        return p.inFlight() != null;
    }

    /// Joins the reload in flight, and any that follows it, without deciding anything: it
    /// returns once none is in flight, or once a stop cancelled `play`. Says so once.
    pub fn joinReload(p: *EnginePage, r: *Reply, play: ?*const Plays.Play) Reply.Error!void {
        var said = false;
        while (try p.join(r, &said, play)) |waited| if (waited == .cancelled) return;
    }

    /// Repairs the page for `intent` and says whether MusicKit is fit for it. Call `start`
    /// first. Prints the Widevine wait line, the line for waiting on another command's reload
    /// (once), and the reason line right after a reload of its own, and never fails the reply:
    /// callers fail from the outcome, in their own words. It sends at most one reload of its
    /// own, for every reason it found, and never acts on a decision whose inputs went stale.
    pub fn repair(p: *EnginePage, r: *Reply, intent: Intent) Reply.Error!Outcome {
        switch (intent) {
            .for_play => |play| {
                const outcome = try p.repairFor(r, .for_play, play);
                // A play a stop cancelled meanwhile gets `cancelled` in place of any other
                // verdict: nothing was to play, and a problem with the page shows on the next
                // play or in `am doctor`.
                return if (play.cancelled()) .{ .report = outcome.report, .verdict = .cancelled } else outcome;
            },
            .if_idle => |idle| return p.repairFor(r, .{ .if_idle = idle }, null),
        }
    }

    /// The repair, decided by `decide` on fresh inputs until a decision holds: a reload in
    /// flight is waited out first, and a decision whose epoch moved (a reload or a launch since
    /// its inputs were read) is made again. Once the launch it decided on has ended, it returns
    /// not configured, with why: the engine stopped, or the engine stopped during the reload
    /// when the last reload ended with that launch.
    fn repairFor(p: *EnginePage, r: *Reply, kind: Kind, play: ?*const Plays.Play) Reply.Error!Outcome {
        const a = r.arena;
        var said_waiting = false;
        // Set once this call sent a reload of its own: it sends no other, and takes the verdict
        // from the newest page load.
        var reloaded = false;
        // Whether Widevine answers now, once a probe for this call found out.
        var widevine: ?bool = null;
        decide: while (true) {
            if (play) |pl| if (pl.cancelled()) return .{ .report = .{}, .verdict = .cancelled };
            if (try p.join(r, &said_waiting, play)) |waited| switch (waited) {
                .ended => |end| switch (end) {
                    // Decide again on the new page load, or at once on the old one.
                    .loaded, .withdrawn => continue,
                    .not_back, .unreadable, .gone => return p.notBack(a, end),
                },
                .replaced, .cancelled => continue,
                .capped => unreachable,
            };

            // A reload recorded since the wait: its new page load is the one to decide on.
            const under = p.decidable() orelse continue;
            const seen = under.epoch;
            const last = try p.channel.lastReport(a);
            if (last) |l| if (l.generation > seen.launch) {
                p.noteLaunch(l.generation);
                continue;
            };
            // The launch the decision is about ended, and its last report with it: what is left
            // is no page load's report, so there is nothing to decide on.
            if (p.channel.currentLaunch() != seen.launch) return p.engineStopped(a, seen.launch);
            const report: Report = if (last) |l| playback.parseReport(a, l.json) orelse .{} else .{};
            var in: Inputs = .{
                .report = report,
                .connected = p.channel.connected(),
                .widevine = widevine,
                .behind = try p.behind(a, report, under.began_before),
            };
            // Repair if idle: `Plays` as read before its look.
            var hold: ?Plays.Activity = null;
            while (true) {
                const decision: Decision = if (reloaded) .go_on else decide(kind, in);
                switch (decision) {
                    .go_on => {
                        if (!p.checkVerdict(seen)) continue :decide;
                        return .{ .report = in.report, .verdict = verdictOf(in.report) };
                    },
                    .leave_alone => |left| {
                        if (!p.checkVerdict(seen)) continue :decide;
                        return .{ .report = in.report, .verdict = verdictOf(in.report), .left_alone = left };
                    },
                    .probe => {
                        const found = try p.widevineNow(r, seen.launch, play);
                        widevine = found.widevine;
                        // The page may have changed during a wait, or its launch ended: decide
                        // again on it as it is.
                        if (found.decide_again) continue :decide;
                        in.widevine = widevine;
                    },
                    .compare_token => in.token = try p.compareToken(a, in.report),
                    .ask_token => in.token = if (try p.pageTokenRefused(a)) .refused else .not_refused,
                    .look => {
                        // `Plays` before the look: a play that begins, sends its music and ends after
                        // the look still moves `begun`.
                        const activity = p.plays.activity();
                        hold = activity;
                        in.play_on_its_way = activity.on_their_way > 0;
                        in.looked = true;
                        if (try p.look(a)) |looked| {
                            in.report = looked;
                            in.behind = try p.behind(a, looked, under.began_before);
                        } else in.answered = false;
                    },
                    .reload => |reasons| {
                        const reload = switch (p.record(seen, hold, play, in.report.load)) {
                            .reload => |reload| reload,
                            .stale => continue :decide,
                            .cancelled => return .{ .report = in.report, .verdict = .cancelled },
                            .held => return .{ .report = in.report, .verdict = verdictOf(in.report), .left_alone = .{ .needs = reasons, .because = .play_on_its_way } },
                        };
                        if (try p.sendReload(a, reload.id) == .withdrawn) continue :decide;
                        reloaded = true;
                        // How the reload came out, for its log line.
                        var then: []const u8 = "";
                        defer p.logReload(kind, reasons, then);
                        var first = reasons.iterator();
                        try r.print("{s}\n", .{first.next().?.reloadLine()});
                        switch (try p.waitSettled(a, reload, null, play)) {
                            .ended => |end| switch (end) {
                                .loaded => then = try p.thenAfter(a),
                                .withdrawn => {},
                                .not_back, .unreadable, .gone => {
                                    const outcome = try p.notBack(a, end);
                                    then = try a.print("; then: {s}", .{outcome.verdict.not_configured.?});
                                    return outcome;
                                },
                            },
                            .replaced => {},
                            .cancelled => return .{ .report = in.report, .verdict = .cancelled },
                            .capped => unreachable,
                        }
                        continue :decide;
                    },
                }
            }
        }
    }

    /// A reload that didn't give a new page load to decide on: not configured, with why.
    fn notBack(p: *EnginePage, a: Allocator, end: End) Allocator.Error!Outcome {
        const why: []const u8 = switch (end) {
            .not_back => try a.print("the reloaded engine page didn't configure MusicKit within {d} s", .{p.timing.reload_wait.toSeconds()}),
            .unreadable => "the reloaded engine page sent a report am can't read",
            .gone => "the engine stopped during the reload",
            .loaded, .withdrawn => unreachable,
        };
        return notConfigured(why);
    }

    /// The launch a decision was about ended: not configured, with why. When it ended during a
    /// reload, which a caller may have waited on before this call (doctor's `probe`) or settled
    /// at its start, why says so, as it does to the callers that waited on that reload.
    fn engineStopped(p: *EnginePage, a: Allocator, launch: u64) Allocator.Error!Outcome {
        const during_reload = blk: {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            const last = p.last_end orelse break :blk false;
            break :blk last.end == .gone and last.launch == launch;
        };
        if (during_reload) return p.notBack(a, .gone);
        return notConfigured("the engine stopped");
    }

    /// No page load to decide on: an empty report that carries why, and the verdict.
    fn notConfigured(why: []const u8) Outcome {
        return .{ .report = .{ .configureError = why }, .verdict = .{ .not_configured = why } };
    }

    /// What became of a page load that came back from a reload, for the reload's log line: why
    /// MusicKit isn't configured on it, if it isn't.
    fn thenAfter(p: *EnginePage, a: Allocator) Allocator.Error![]const u8 {
        const report = try p.lastReport(a);
        if (report.configured) return "";
        return a.print("; then: {s}", .{report.configureError orelse "MusicKit isn't configured"});
    }

    /// Every reload the module sends is logged, with who asked for it and why.
    fn logReload(p: *EnginePage, kind: Kind, reasons: std.EnumSet(Repair), then: []const u8) void {
        const who = switch (kind) {
            .for_play => "before a play",
            .if_idle => "for am doctor",
            .new_user_token => unreachable,
        };
        p.log("reloaded the engine page {s}: {f}{s}", .{ who, Reasons{ .set = reasons }, then });
    }

    /// The page's report now, or null when it doesn't answer.
    fn look(p: *EnginePage, a: Allocator) (Allocator.Error || Io.Cancelable)!?Report {
        const result = p.channel.call(a, "snapshot", "[]", p.timing.look) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return switch (result) {
            .ok => |json| playback.parseReport(a, json),
            .page_error => null,
        };
    }

    /// What `widevineNow` found. `decide_again`: the page may have changed meanwhile (a wait
    /// ran, or its launch ended), so the caller decides again on it as it is now.
    const Found = struct { widevine: bool, decide_again: bool };

    /// Whether Widevine answers now. MusicKit decides DRM support once, at configure(), and
    /// Firefox downloads Widevine on a fresh profile's first start: when it isn't there yet,
    /// waits up to the Widevine wait, probing the page every poll. The wait sleeps in steps: a
    /// play's stop ends it within one, and so does the end of its launch.
    fn widevineNow(p: *EnginePage, r: *Reply, launch: u64, play: ?*const Plays.Play) Reply.Error!Found {
        const a = r.arena;
        var found = try p.drmProbe(a);
        if (found.widevine) return .{ .widevine = true, .decide_again = false };
        // The launch ended: no browser is left to install Widevine, and nothing to wait for.
        if (p.channel.currentLaunch() != launch) return .{ .widevine = false, .decide_again = true };
        try r.print("Widevine not available yet ({s}); waiting up to {d} s for the browser to install it…\n", .{
            found.widevineError orelse "no error given", p.timing.widevine_wait.toSeconds(),
        });
        const deadline: Deadline = .after(p.io, p.timing.widevine_wait);
        var next: Deadline = .after(p.io, p.timing.widevine_poll);
        while (!found.widevine) {
            if (play) |pl| if (pl.cancelled()) break;
            if (p.channel.currentLaunch() != launch) break;
            if (!try deadline.sleep(.{ .nanoseconds = @max(0, @min(p.timing.step.nanoseconds, next.left().nanoseconds)) })) break;
            if (next.passed()) {
                found = try p.drmProbe(a);
                next = .after(p.io, p.timing.widevine_poll);
            }
        }
        return .{ .widevine = found.widevine, .decide_again = true };
    }

    fn drmProbe(p: *EnginePage, a: Allocator) (Allocator.Error || Io.Cancelable)!Probe {
        const result = p.channel.call(a, "drmProbe", "[]", p.timing.probe) catch |e| return .{ .widevineError = switch (e) {
            error.NoEnginePage => "no engine page is connected",
            error.Disconnected => "the engine page disconnected before answering",
            error.Timeout => try a.print("the engine page didn't answer within {d} s", .{p.timing.probe.toSeconds()}),
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
        } };
        return switch (result) {
            .ok => |json| std.json.parseFromSliceLeaky(Probe, a, json, .{ .ignore_unknown_fields = true }) catch .{ .widevineError = "unexpected drmProbe result" },
            .page_error => |message| .{ .widevineError = try a.print("page: {s}", .{message}) },
        };
    }

    /// The page's developer token against the one the daemon hands out now. MusicKit takes its
    /// developer token once, at configure(), and learns that Apple refuses it only by using it:
    /// a refused one signs the page out at its next account check, without an event. The
    /// caller has just had Apple accept the Music User Token with the current one, so only
    /// another token can be refused.
    fn compareToken(p: *EnginePage, a: Allocator, report: Report) (Allocator.Error || Io.Cancelable)!Token {
        const current = try p.port.vtable.developerToken(p.port.ptr, a) orelse return .current;
        if (report.developerToken) |token| if (token.eql(current)) return .current;
        return .other;
    }

    /// Whether Apple refuses the page's developer token, as the page's own check says. A page
    /// that can't answer counts as not refused.
    fn pageTokenRefused(p: *EnginePage, a: Allocator) (Allocator.Error || Io.Cancelable)!bool {
        const result = p.channel.call(a, "checkDeveloperToken", "[]", p.timing.check) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        const json = switch (result) {
            .ok => |json| json,
            .page_error => return false,
        };
        const answer = std.json.parseFromSliceLeaky(struct { refused: bool = false }, a, json, .{ .ignore_unknown_fields = true }) catch return false;
        return answer.refused;
    }

    /// A line for the daemon's log, cut at 512 bytes.
    fn log(p: *EnginePage, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        w.print(fmt, args) catch {};
        p.port.vtable.log(p.port.ptr, w.buffered());
    }

    fn verdictOf(report: Report) Verdict {
        if (!report.configured) return .{ .not_configured = report.configureError };
        if (!report.isAuthorized) return .signed_out;
        return .ready;
    }

    // ---- One reload at a time ----

    /// A reload of the engine page, from its record until it lands, runs out its deadline or
    /// ends with its launch.
    const Reload = struct {
        id: u64,
        /// The launch it was sent to.
        launch: u64,
        /// The page load it was sent to.
        from: LoadId,
        /// Its record time plus the reload wait: one deadline for its owner and every joiner.
        deadline: Io.Timestamp,
        /// The Music User Token epoch at its record, for its new page load.
        stamp: u64,
    };

    /// A page load's id, kept without an allocation under the mutex. app.js's are 8 characters;
    /// a longer one is told by its first 16.
    const LoadId = struct {
        buf: [16]u8 = undefined,
        len: u8 = 0,

        fn of(load: ?[]const u8) LoadId {
            var id: LoadId = .{};
            const bytes = load orelse return id;
            id.len = @intCast(@min(bytes.len, id.buf.len));
            @memcpy(id.buf[0..id.len], bytes[0..id.len]);
            return id;
        }

        fn eql(id: LoadId, load: []const u8) bool {
            const n = @min(load.len, id.buf.len);
            return n == id.len and std.mem.eql(u8, id.buf[0..n], load[0..n]);
        }
    };

    /// How a reload ended.
    const End = enum {
        /// Its new page load reported, with MusicKit configured or failed to.
        loaded,
        /// No new page load did by its deadline.
        not_back,
        /// The new page load sent a report am can't read.
        unreadable,
        /// Its launch ended: the engine stopped or was relaunched.
        gone,
        /// It never went out: no engine page was connected to send it to.
        withdrawn,
    };

    const Ended = struct {
        id: u64,
        end: End,
        /// The launch the reload was sent to.
        launch: u64,
    };

    /// What a decision about the page was made under. It is acted on only while this holds: no
    /// launch, no reload and no sign-in since.
    const Epoch = struct { launch: u64, reloads: u64, user_token: u64 };

    fn epoch(p: *EnginePage) Epoch {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.epochLocked();
    }

    fn epochLocked(p: *const EnginePage) Epoch {
        return .{ .launch = p.launch, .reloads = p.reloads, .user_token = p.user_token };
    }

    /// A launch the module saw under a report it read. Nobody here knows when it was launched,
    /// so its first page load counts as behind after any sign-in.
    fn noteLaunch(p: *EnginePage, generation: u64) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        p.newLaunchLocked(generation, 0);
    }

    /// A launch the port's `launch` returned, to a caller that read the Music User Token epoch
    /// `asked` just before that call. Only the call that launched the engine stamps its first
    /// page load with it. Any other call returned an engine already running, which a sign-in
    /// may have come after: it stamps 0, behind after any sign-in.
    fn recordLaunch(p: *EnginePage, launch: Launch, asked: u64) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        p.newLaunchLocked(launch.generation, if (launch.launched) asked else 0);
    }

    /// The first record of a launch stamps its first page load, and a later one changes
    /// nothing. The first stamp is never too high: the call that launched the engine stamps the
    /// epoch it read before that call, and any other call stamps 0. A later record mustn't
    /// change it either, since a reload may have landed since, whose new page load has a stamp
    /// of its own. An older launch never replaces a newer one.
    fn newLaunchLocked(p: *EnginePage, generation: u64, stamp: u64) void {
        if (generation <= p.launch) return;
        p.launch = generation;
        p.load_stamp = stamp;
    }

    /// The Music User Token epoch now, for a launch call about to start a page load.
    fn userTokenEpoch(p: *EnginePage) u64 {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.user_token;
    }

    /// What a decision about the page is made under.
    const Decidable = struct {
        epoch: Epoch,
        /// The current page load began before the last sign-in stored a new Music User Token:
        /// behind, when its report names no Music User Token (`behindOn`).
        began_before: bool,
    };

    /// The epoch, and whether the current page load began before the last sign-in, read
    /// together; null while a reload is in flight, since its new page load is the one to decide
    /// on.
    fn decidable(p: *EnginePage) ?Decidable {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.in_flight != null) return null;
        return .{ .epoch = p.epochLocked(), .began_before = p.user_token > p.load_stamp };
    }

    /// Whether the page load that sent `report` is behind on the Music User Token (`behindOn`),
    /// `began_before` as `decidable` read it. Call it after `decidable`: the sign-in writes the
    /// token before it moves the epoch, so a decision on the token stored before is made again.
    fn behind(p: *EnginePage, a: Allocator, report: Report, began_before: bool) (Allocator.Error || Io.Cancelable)!bool {
        return behindOn(report.musicUserToken, try p.port.vtable.userToken(p.port.ptr, a), began_before);
    }

    /// Whether the page load to come reads the Music User Token of the sign-in that moved the
    /// epoch to `bumped`: the one a reload in flight brings, or else the current one, began
    /// after that sign-in.
    fn readsUserToken(p: *EnginePage, bumped: u64) bool {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.in_flight) |reload| return reload.stamp >= bumped;
        return p.load_stamp >= bumped;
    }

    fn inFlight(p: *EnginePage) ?Reload {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.in_flight;
    }

    /// Whether a verdict decided under `seen` still holds: no reload or launch since, none in
    /// flight, and its launch hasn't ended. The channel is read first, outside the mutex.
    fn checkVerdict(p: *EnginePage, seen: Epoch) bool {
        if (p.channel.currentLaunch() != seen.launch) return false;
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        return p.in_flight == null and std.meta.eql(seen, p.epochLocked());
    }

    const Recorded = union(enum) {
        reload: Reload,
        /// A reload or a launch since `seen`, or a reload in flight: decide again.
        stale,
        /// Repair if idle: a play was on its way at the read of `Plays`, or one began since.
        held,
        /// A stop cancelled the play.
        cancelled,
    };

    /// Records a reload of the page load `from`, decided under `seen`: the one critical section
    /// that makes reloads one at a time, so two callers can't both send one. A play's cancel is
    /// checked in it, and so is `hold`, the `Plays` a repair if idle read before its look.
    fn record(p: *EnginePage, seen: Epoch, hold: ?Plays.Activity, play: ?*const Plays.Play, from: ?[]const u8) Recorded {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (play) |pl| if (pl.cancelled()) return .cancelled;
        if (p.in_flight != null or !std.meta.eql(seen, p.epochLocked())) return .stale;
        if (hold) |h| if (h.on_their_way > 0 or p.plays.activity().begun != h.begun) return .held;
        p.reloads += 1;
        const reload: Reload = .{ .id = p.reloads, .launch = seen.launch, .from = .of(from), .deadline = p.now().addDuration(p.timing.reload_wait), .stamp = p.user_token };
        p.in_flight = reload;
        return .{ .reload = reload };
    }

    /// Ends the reload `id` as `end`, unless another caller ended it first. A new page load it
    /// brought takes its stamp; one that may not have come keeps the old load's, so a page load
    /// is never wrongly taken as not behind.
    fn settleAs(p: *EnginePage, id: u64, end: End) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        const reload = p.in_flight orelse return;
        if (reload.id != id) return;
        p.in_flight = null;
        p.last_end = .{ .id = id, .end = end, .launch = reload.launch };
        switch (end) {
            .loaded, .unreadable => if (reload.launch == p.launch) {
                p.load_stamp = reload.stamp;
            },
            .not_back, .gone, .withdrawn => {},
        }
    }

    /// The reload `id` never went out: its joiners decide again at once.
    fn withdraw(p: *EnginePage, id: u64) void {
        p.settleAs(id, .withdrawn);
    }

    /// Sends the recorded reload `id` (5 s). A send that finds no engine page withdraws it. Any
    /// other failure leaves it in flight, since the command may be in the outbox: it lands, runs
    /// out its deadline, or ends with its launch.
    fn sendReload(p: *EnginePage, a: Allocator, id: u64) (Allocator.Error || Io.Cancelable)!enum { sent, withdrawn } {
        _ = p.channel.call(a, "reload", "[]", p.timing.send) catch |e| switch (e) {
            error.NoEnginePage => {
                p.withdraw(id);
                return .withdrawn;
            },
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.Timeout, error.Disconnected => {},
        };
        return .sent;
    }

    /// Settles the reload in flight if it has landed, run out its deadline or lost its launch.
    /// Whoever sees that first settles it for everyone, so an owner that went away strands
    /// nobody.
    fn settle(p: *EnginePage, a: Allocator) Allocator.Error!void {
        const reload = p.inFlight() orelse return;
        if (try p.observe(a, reload)) |end| p.settleAs(reload.id, end);
    }

    /// How `reload` has ended as the page shows it now, or null while it is still in flight: a
    /// report of another page load of its launch, from a connected page, once MusicKit
    /// configured or failed to.
    fn observe(p: *EnginePage, a: Allocator, reload: Reload) Allocator.Error!?End {
        if (p.channel.currentLaunch() != reload.launch) return .gone;
        if (try p.channel.lastReport(a)) |last| if (last.generation == reload.launch and p.channel.connected()) {
            // Read leniently first, so a report am can't read is told from one that never came.
            const fields = std.json.parseFromSliceLeaky(struct {
                load: ?[]const u8 = null,
                configured: bool = false,
                configureError: ?[]const u8 = null,
            }, a, last.json, .{ .ignore_unknown_fields = true }) catch null;
            if (fields) |f| if (f.load) |load| if (!reload.from.eql(load) and (Report{ .configured = f.configured, .configureError = f.configureError }).configureDone())
                return if (playback.parseReport(a, last.json) != null) .loaded else .unreadable;
        };
        if (p.now().nanoseconds >= reload.deadline.nanoseconds) return .not_back;
        return null;
    }

    const Waited = union(enum) {
        ended: End,
        /// It is neither in flight nor the last to end: another reload came and went since.
        replaced,
        /// A stop cancelled the play meanwhile.
        cancelled,
        /// The caller's own cap ran out first; the reload stays in flight for the others.
        capped,
    };

    /// Waits for `reload` to end, on the page, never on another caller: in steps of at most
    /// `timing.step`, each checking the reload's own deadline, its launch and the play's cancel.
    fn waitSettled(p: *EnginePage, a: Allocator, reload: Reload, cap: ?Io.Duration, play: ?*const Plays.Play) (Allocator.Error || Io.Cancelable)!Waited {
        const capped: ?Deadline = if (cap) |c| .after(p.io, c) else null;
        const deadline: Deadline = .since(p.io, reload.deadline, .zero);
        var seen = try p.channel.waitChange(null, .zero);
        while (true) {
            {
                p.mutex.lockUncancelable(p.io);
                defer p.mutex.unlock(p.io);
                const ours = if (p.in_flight) |f| f.id == reload.id else false;
                if (!ours) {
                    if (p.last_end) |e| if (e.id == reload.id) return .{ .ended = e.end };
                    return .replaced;
                }
            }
            if (play) |pl| if (pl.cancelled()) return .cancelled;
            if (try p.observe(a, reload)) |end| {
                p.settleAs(reload.id, end);
                continue;
            }
            var left = deadline.left();
            if (capped) |c| {
                if (c.passed()) return .capped;
                left = .{ .nanoseconds = @min(left.nanoseconds, c.left().nanoseconds) };
            }
            seen = try p.channel.waitChange(seen, .{ .nanoseconds = @max(0, @min(left.nanoseconds, p.timing.step.nanoseconds)) });
        }
    }

    /// Waits out the reload in flight, if any, saying so once per call; null when none is.
    fn join(p: *EnginePage, r: *Reply, said: *bool, play: ?*const Plays.Play) Reply.Error!?Waited {
        try p.settle(r.arena);
        const reload = p.inFlight() orelse return null;
        if (!said.*) {
            try r.print("{s}\n", .{waiting_line});
            said.* = true;
        }
        return try p.waitSettled(r.arena, reload, null, play);
    }

    /// The sign-in stored a new Music User Token. A page behind on it (`behindOn`) that holds no
    /// music, or only a preview, with no play on its way, reloads now so it reads the new token,
    /// and the sign-in waits for that reload. It decides on `Plays`, then a fresh look.
    ///
    /// A page it leaves alone stays behind, and the next repair for a play reloads it first: one
    /// that holds music, has a play on its way or begun since `Plays` was read, or didn't answer.
    /// It also leaves alone a page that is reloading or isn't connected yet. That page load may
    /// read the new token, and the next repair for a play decides on its report.
    ///
    /// A page that has the new token already is left as it is: its report names it, or, naming
    /// none, another command's reload or launch began it after the sign-in.
    ///
    /// Call it after the token file is written. Prints nothing; logs what it did. Never
    /// launches, and never waits for a launch or for another command's reload.
    pub fn newUserToken(p: *EnginePage, arena: Allocator) (Allocator.Error || Io.Cancelable)!NewUserToken {
        // Every page load from before this that names no Music User Token is behind now, and a
        // decision made before it is made again.
        const bumped = blk: {
            p.mutex.lockUncancelable(p.io);
            defer p.mutex.unlock(p.io);
            p.user_token += 1;
            break :blk p.user_token;
        };
        while (true) {
            try p.settle(arena);
            const under = p.decidable() orelse {
                // A newer sign-in decides, and logs, in this one's place.
                if (p.userTokenEpoch() != bumped) return .superseded;
                // A reload recorded since the bump brings a page load that reads the new token;
                // one already in flight at it may have read the old one.
                if (p.readsUserToken(bumped)) return .reloaded;
                return p.leftBehind(.reloading);
            };
            const seen = under.epoch;
            if (seen.user_token != bumped) return .superseded;
            // A page load that has the new token already is left as it is: it names it, or,
            // naming none, another command's reload or launch began it after the bump.
            if (!try p.behind(arena, try p.lastReport(arena), under.began_before)) return .reloaded;
            // The channel alone tells no engine from a page that isn't connected yet, so the
            // sign-in never waits on a launch.
            if (p.channel.currentLaunch() == null) return .no_engine;
            if (!p.channel.connected()) return p.leftBehind(.not_connected);
            // `Plays` before the look: a play that begins, sends its music and ends after the
            // look still moves `begun`.
            const activity = p.plays.activity();
            const looked = try p.look(arena);
            // The look names the token the page has now, which its last report may not have yet:
            // the page's own sign-in hashes the token, then posts it.
            if (looked) |l| if (!try p.behind(arena, l, under.began_before))
                return if (p.userTokenEpoch() != bumped) .superseded else .reloaded;
            const in: Inputs = .{ .report = looked orelse .{}, .answered = looked != null, .play_on_its_way = activity.on_their_way > 0 };
            switch (decide(.new_user_token, in)) {
                // A newer sign-in that came during the look decides, and logs, in this one's place.
                .leave_alone => |left| return if (p.userTokenEpoch() != bumped) .superseded else p.leftBehind(left.because),
                .reload => {},
                .go_on, .probe, .compare_token, .ask_token, .look => unreachable,
            }
            const reload = switch (p.record(seen, activity, null, in.report.load)) {
                .reload => |reload| reload,
                .stale => {
                    if (p.userTokenEpoch() != bumped) return .superseded;
                    // A reload or a launch since: decide again on the page load it brought,
                    // which is behind only if it began before the bump.
                    continue;
                },
                // A play began since `Plays` was read.
                .held => return p.leftBehind(.play_on_its_way),
                .cancelled => unreachable,
            };
            // Logged once the reload went out: a send that found no page withdrew it.
            if (try p.sendReload(arena, reload.id) == .withdrawn) continue;
            p.log("reloading the engine page so it reads the new Music User Token", .{});
            switch (try p.waitSettled(arena, reload, p.timing.signin_wait, null)) {
                // A later reload came and went since: the page reloaded after the token was written.
                .ended => |end| switch (end) {
                    .loaded, .unreadable => return .reloaded,
                    .gone, .withdrawn => return .not_back,
                    .not_back => {},
                },
                .replaced => return .reloaded,
                .capped => {},
                .cancelled => unreachable,
            }
            p.log("the engine page didn't configure MusicKit within {d} s of the reload", .{p.timing.signin_wait.toSeconds()});
            return .not_back;
        }
    }

    /// The sign-in left the page alone, so the page is behind on the Music User Token, or may
    /// be: the log says why, and that the next play reloads it.
    fn leftBehind(p: *EnginePage, because: Because) NewUserToken {
        const then = "so it reads the new Music User Token";
        const unless = "unless it has the new Music User Token";
        switch (because) {
            .holds => |music| p.log("the engine page holds {f}; the next play reloads it first, " ++ then, .{music}),
            .play_on_its_way => p.log("a play is on its way to the engine page, so it's left alone: the next play reloads it first, " ++ then, .{}),
            .reloading => p.log("the engine page is reloading; the next play reloads it again " ++ unless, .{}),
            .no_answer => p.log("the engine page didn't answer; the next play reloads it first, " ++ then, .{}),
            .not_connected => p.log("the engine page isn't connected yet; the next play reloads it first " ++ unless, .{}),
        }
        return .{ .left_alone = because };
    }
};

/// What a caller waiting on another command's reload prints, once per call.
const waiting_line = "waiting for the engine page to finish a reload another command started";

/// Reasons for one reload, in `daemon.log`'s words, joined with ", ".
const Reasons = struct {
    set: std.EnumSet(Repair),

    pub fn format(rs: Reasons, w: *Io.Writer) Io.Writer.Error!void {
        var it = rs.set.iterator();
        var first = true;
        while (it.next()) |why| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{f}", .{why});
        }
    }
};

/// Who asks: the repair rule differs for each.
const Kind = union(enum) {
    for_play,
    /// Repair if idle, as `Intent` has it: the token repairs only with `user_token_ok`.
    if_idle: @FieldType(Intent, "if_idle"),
    new_user_token,
};

/// What the repair rule decides on.
const Inputs = struct {
    /// The page load decided on: the last report, or a look's.
    report: Report,
    /// An engine page holds an event stream.
    connected: bool = true,
    /// Whether Widevine answers now; null until a probe for this decision found out.
    widevine: ?bool = null,
    /// The page load is behind on the Music User Token (`behindOn`).
    behind: bool = false,
    token: Token = .unchecked,
    /// Repair if idle: `report` is a fresh look's, with `Plays` read before it. The sign-in
    /// always decides on one.
    looked: bool = false,
    /// The look got an answer. Without one, a repair if idle's `report` is the last report.
    answered: bool = true,
    /// A play was on its way when `Plays` was read.
    play_on_its_way: bool = false,
};

/// The page's developer token, as far as the repair has found out.
const Token = enum {
    /// Not compared yet with the one the daemon hands out.
    unchecked,
    /// The one the daemon hands out, or there is none to compare with.
    current,
    /// Another one, and the page wasn't asked yet whether Apple refuses it.
    other,
    refused,
    /// The page says Apple accepts it, or couldn't answer.
    not_refused,
};

/// What the repair rule answers.
const Decision = union(enum) {
    /// No reload: the verdict comes from the report.
    go_on,
    /// Probe the page for Widevine, and wait for it if it isn't there yet.
    probe,
    /// Compare the page's developer token with the one the daemon hands out.
    compare_token,
    /// Ask the page whether Apple refuses its developer token.
    ask_token,
    /// Read `Plays`, then take a fresh look at the page.
    look,
    /// One reload, for every reason found.
    reload: std.EnumSet(Repair),
    /// No reload: the needs are left for the next play.
    leave_alone: LeftAlone,
};

/// The repair rule: what a caller does next about the page, from what it found so far.
///
/// A repair for a play reloads for whatever the page needs, whatever it holds: Widevine there
/// now but not when MusicKit configured, a page MusicKit signed out, a page load behind on the
/// Music User Token, a developer token Apple refuses (asked only when no other reason already
/// needs a reload). A page MusicKit didn't configure is left to its error. A repair if idle
/// finds the same needs, the token ones only with `user_token_ok`, and reloads only a page
/// whose fresh look answered, holding no music, with no play on its way. The sign-in, which
/// always looks, reloads a page that answered, holding no music or only a preview, with no
/// play on its way: that is what the reload is for (the page read no Music User Token, or one
/// Apple no longer accepts).
fn decide(kind: Kind, in: Inputs) Decision {
    const r = in.report;
    const tokens = switch (kind) {
        .for_play => true,
        .if_idle => |idle| idle.user_token_ok,
        .new_user_token => {
            if (leftBecause(in, .preview_reloads)) |b| return .{ .leave_alone = .{ .needs = .initOne(.behind), .because = b } };
            return .{ .reload = .initOne(.behind) };
        },
    };
    if (kind == .for_play and (!r.configured or !in.connected)) return .go_on;
    if (r.browserSupportsVideoDrm != true and in.widevine == null) return .probe;
    var needs: std.EnumSet(Repair) = .empty;
    if (r.configured and r.browserSupportsVideoDrm != true and in.widevine == true) needs.insert(.drm);
    if (tokens and r.configured) {
        if (!r.isAuthorized) needs.insert(.signed_out);
        if (in.behind) needs.insert(.behind);
        if (in.token == .refused) needs.insert(.token_refused);
    }
    const maybe_refused = tokens and r.configured and needs.count() == 0 and (in.token == .unchecked or in.token == .other);
    if (maybe_refused and in.token == .unchecked) return .compare_token;
    if (kind == .for_play) {
        if (needs.count() > 0) return .{ .reload = needs };
        return if (maybe_refused) .ask_token else .go_on;
    }
    if (needs.count() == 0 and !maybe_refused) return .go_on;
    if (!in.looked) return .look;
    if (leftBecause(in, .preview_holds)) |b| return if (needs.count() == 0) .go_on else .{ .leave_alone = .{ .needs = needs, .because = b } };
    if (maybe_refused) return .ask_token;
    return .{ .reload = needs };
}

/// Behind on the Music User Token: the page load names one MusicKit holds (`held`, from its
/// report) other than the stored one. When either is unknown (an older page, a browser that
/// can't hash, MusicKit holding none, no token stored), by the epoch: `began_before`, the page
/// load began before the last sign-in stored a new one.
fn behindOn(held: ?playback.TokenId, stored: ?playback.TokenId, began_before: bool) bool {
    const h = held orelse return began_before;
    const s = stored orelse return began_before;
    if (h.hash == null or s.hash == null) return began_before;
    return !h.eql(s);
}

/// Why a repair if idle or the sign-in leaves the page alone, from its fresh look and `Plays`;
/// null when it may reload the page. Only the sign-in reloads a page that holds a preview
/// (`decide` says why).
fn leftBecause(in: Inputs, preview: enum { preview_holds, preview_reloads }) ?Because {
    const r = in.report;
    if (!in.answered) return .no_answer;
    if (r.holdsMusic() and !(preview == .preview_reloads and playback.isPreview(r.nowPlaying))) return .{ .holds = r.music() };
    if (in.play_on_its_way) return .play_on_its_way;
    return null;
}

const testing = std.testing;
const fake = @import("fake_page.zig");
const Rig = fake.Rig;
const Caller = fake.Caller;

/// For tests whose callers run at once: no wait that isn't under test runs out, so only the
/// fake page's gates and the callers' printed lines order them.
const patient: Timing = blk: {
    var t = Rig.timing;
    t.reload_wait = .fromSeconds(30);
    t.signin_wait = .fromSeconds(30);
    t.widevine_wait = .fromSeconds(30);
    t.look = .fromSeconds(30);
    t.check = .fromSeconds(30);
    t.probe = .fromSeconds(30);
    break :blk t;
};

test "start launches the engine once and waits for its page; the next start finds it running" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    const a = rig.newArena();
    var problem: []const u8 = "";
    const first = try rig.page.start(a, &problem);
    try testing.expect(first.started);
    try testing.expect(first.ready);
    try testing.expect(first.report.configured);
    try testing.expectEqualStrings("1", first.report.load.?);

    const again = try rig.page.start(a, &problem);
    try testing.expect(!again.started);
    try testing.expect(again.ready);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
}

/// Ends a caller that a test started on its own task, whatever it came to: for the paths where
/// the test failed before it awaited the caller.
fn drop(future: anytype) void {
    if (future.cancel(testing.io)) |_| {} else |_| {}
}

test "start fails with the launch's own problem, and says so when the engine exits before its page loaded" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    const a = rig.newArena();
    var problem: []const u8 = "";
    rig.launcher.refuse = "firefox not found; install it or set FIREFOX_PATH";
    try testing.expectError(error.EngineFailed, rig.page.start(a, &problem));
    try testing.expectEqualStrings("firefox not found; install it or set FIREFOX_PATH", problem);
    rig.launcher.refuse = null;

    // The engine stops before its page connected.
    rig.fp.hold(.open, 1);
    var starting = try testing.io.concurrent(EnginePage.start, .{ &rig.page, a, &problem });
    defer drop(&starting);
    try rig.fp.arrived(.open);
    rig.launcher.stop();
    try testing.expectError(error.EngineFailed, starting.await(testing.io));
    try testing.expectEqualStrings("firefox exited before its page loaded; see /home/u/.config/am/engine.log", problem);
}

test "a page that never connects fails start at the launch wait, and the next start relaunches it" {
    var timing = Rig.timing;
    timing.launch_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    const a = rig.newArena();
    var problem: []const u8 = "";
    rig.fp.hold(.open, 1);
    try testing.expectError(error.EngineFailed, rig.page.start(a, &problem));
    try testing.expectEqualStrings("the engine page didn't connect within 1 s; see /home/u/.config/am/engine.log", problem);

    const again = try rig.page.start(a, &problem);
    try testing.expect(again.started);
    try testing.expect(again.ready);
    try testing.expectEqualStrings("2", again.report.load.?);
    try testing.expectEqual(@as(u32, 2), rig.launcher.launches);
    try testing.expectEqualStrings("the engine stopped answering; relaunching it", rig.launcher.logged.items[0]);
}

test "start returns a page whose MusicKit hasn't configured by the launch wait as not ready, with its report" {
    var timing = Rig.timing;
    timing.launch_wait = .fromMilliseconds(100);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.next = .never;
    var problem: []const u8 = "";
    const started = try rig.page.start(rig.newArena(), &problem);
    try testing.expect(started.started);
    try testing.expect(!started.ready);
    try testing.expect(!started.report.configured);
    try testing.expectEqualStrings("Firefox/140", started.report.userAgent.?);
    // A warm engine whose page is connected isn't relaunched for it, nor asked to be.
    const again = try rig.page.start(rig.newArena(), &problem);
    try testing.expect(!again.started);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    try testing.expectEqual(@as(u32, 0), rig.launcher.relaunch_asks);
}

fn expectNotConfigured(why: ?[]const u8, verdict: Verdict) !void {
    switch (verdict) {
        .not_configured => |got| if (why) |want| try testing.expectEqualStrings(want, got orelse "(null)") else try testing.expectEqual(null, got),
        else => {
            std.debug.print("verdict: {t}\n", .{verdict});
            return error.TestUnexpectedResult;
        },
    }
}

test "a repair for a play leaves a page on the current developer token alone: nothing asked, no reload" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings("", ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("1", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 0), rig.fp.checks);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
}

/// Launches the engine and waits for its first page load.
fn launched(rig: *Rig) !void {
    var problem: []const u8 = "";
    const started = try rig.page.start(rig.newArena(), &problem);
    try testing.expect(started.ready);
}

test "a repair for a play asks a page on another developer token whether Apple refuses it, and reloads it only then" {
    // Accepted: an own token signed meanwhile, the page still on the shared one, keeps working.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.developer = fake.older_token;
        try launched(&rig);
        rig.fp.world.developer = fake.current_token;
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 1), rig.fp.checks);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    }
    // Refused, though still signed in (a key revoked mid-song): reloaded, and the play goes on
    // with the new page load.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.developer = fake.older_token;
        try launched(&rig);
        rig.fp.world.developer = fake.current_token;
        rig.fp.world.refused = &.{fake.older_token};
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("Apple refused the engine page's developer token (HTTP 401); reloading the page so it takes the current one\n", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.checks);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqualStrings("reloaded the engine page before a play: Apple refused its developer token", rig.launcher.logged.items[0]);
    }
}

test "a page that can't answer whether Apple refuses its developer token isn't reloaded; one that doesn't name its token is asked" {
    {
        var timing = Rig.timing;
        timing.check = .fromMilliseconds(50);
        var rig: Rig = undefined;
        rig.init(timing);
        defer rig.deinit();
        rig.fp.world.developer = fake.older_token;
        try launched(&rig);
        rig.fp.world.developer = fake.current_token;
        rig.fp.world.refused = &.{fake.older_token};
        rig.fp.hold(.check, 1);
        rig.fp.release(.check, .silent);
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 1), rig.fp.checks);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    }
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.developer = "";
        try launched(&rig);
        rig.fp.world.developer = fake.current_token;
        var play = rig.plays.begin();
        defer play.end();
        _ = try rig.play(&play);
        try testing.expectEqual(@as(u32, 1), rig.fp.checks);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    }
}

test "a repair for a play reloads a page MusicKit signed out at once; a new page load still signed out is signed out" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    rig.fp.world.signs_out = true;
    try launched(&rig);
    rig.fp.world.signs_out = false;
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings("MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens\n", ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 0), rig.fp.checks);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqualStrings("reloaded the engine page before a play: MusicKit had signed it out", rig.launcher.logged.items[0]);

    // Signed out again on its new load: one reload, and the play is told.
    var still: Rig = undefined;
    still.init(Rig.timing);
    defer still.deinit();
    still.fp.world.signs_out = true;
    try launched(&still);
    var again = still.plays.begin();
    defer again.end();
    const signed_out = try still.play(&again);
    try testing.expectEqual(Verdict.signed_out, signed_out.outcome.verdict);
    try testing.expectEqualStrings("2", signed_out.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), still.fp.reloads);
}

test "a reload for a play that doesn't come back, or whose report am can't read, leaves a page that isn't configured, with why" {
    const cases = [_]struct { fake.FakePage.World.Next, []const u8 }{
        .{ .never, "the reloaded engine page didn't configure MusicKit within 1 s" },
        .{ .unreadable, "the reloaded engine page sent a report am can't read" },
    };
    for (cases) |case| {
        const next, const why = case;
        var timing = Rig.timing;
        timing.reload_wait = .fromSeconds(1);
        var rig: Rig = undefined;
        rig.init(timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        try launched(&rig);
        rig.fp.world.signs_out = false;
        rig.fp.world.next = next;
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try expectNotConfigured(why, ran.outcome.verdict);
        try testing.expectEqual(null, ran.outcome.report.load);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        const logged = try std.mem.concat(rig.newArena(), u8, &.{ "reloaded the engine page before a play: MusicKit had signed it out; then: ", why });
        try testing.expectEqualStrings(logged, rig.launcher.logged.items[0]);
    }
}

test "a repair for a play leaves a page whose MusicKit didn't configure to its error: nothing asked, no reload" {
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.next = .fails;
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try expectNotConfigured("developer token endpoint: HTTP 503", ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads + rig.fp.probes);
    }
    // Not configured by the launch wait, with no error: each caller words that itself.
    {
        var timing = Rig.timing;
        timing.launch_wait = .fromMilliseconds(100);
        var rig: Rig = undefined;
        rig.init(timing);
        defer rig.deinit();
        rig.fp.world.next = .never;
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try expectNotConfigured(null, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads + rig.fp.probes);
    }
}

test "a play a stop cancelled gets cancelled in place of any other verdict, and its page no token repair" {
    for ([_]fake.FakePage.World.Next{ .configures, .fails }) |next| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        rig.fp.world.next = next;
        try launched(&rig);
        var play = rig.plays.begin();
        defer play.end();
        rig.plays.cancel(rig.plays.beginStop());
        const ran = try rig.play(&play);
        try testing.expectEqual(Verdict.cancelled, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads);
    }
}

test "a play on a page MusicKit configured without DRM waits for the browser to install Widevine, then reloads it once" {
    var timing = Rig.timing;
    timing.widevine_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    // Firefox installs the CDM by the third probe.
    rig.fp.world.widevine_after = 3;
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings(
        \\Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 1 s for the browser to install it…
        \\Widevine is available; reloading the engine page so MusicKit sees it.
        \\
    , ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(true, ran.outcome.report.browserSupportsVideoDrm);
    try testing.expectEqual(@as(u32, 3), rig.fp.probes);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqualStrings("reloaded the engine page before a play: Widevine had become available", rig.launcher.logged.items[0]);
}

test "a play's Widevine reload that doesn't come back fails the play as not configured, with why" {
    var timing = Rig.timing;
    timing.reload_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    rig.fp.world.widevine = true;
    rig.fp.world.next = .never;
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings("Widevine is available; reloading the engine page so MusicKit sees it.\n", ran.out);
    try expectNotConfigured("the reloaded engine page didn't configure MusicKit within 1 s", ran.outcome.verdict);
    try testing.expectEqualStrings("reloaded the engine page before a play: Widevine had become available; then: the reloaded engine page didn't configure MusicKit within 1 s", rig.launcher.logged.items[0]);
}

test "probe answers the page's codecs and Widevine, and says why when the page can't" {
    var timing = Rig.timing;
    timing.probe = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    var t: protocol.TestReply = undefined;
    t.init(rig.newArena());

    try testing.expectEqualStrings("no engine page is connected", (try rig.page.probe(&t.reply)).widevineError.?);

    try launched(&rig);
    const found = try rig.page.probe(&t.reply);
    try testing.expectEqualStrings("probably", found.h264);
    try testing.expectEqualStrings("probably", found.aac);
    try testing.expect(found.mseAac);
    try testing.expect(found.widevine);
    try testing.expectEqual(null, found.widevineError);

    rig.fp.hold(.probe, 1);
    rig.fp.release(.probe, .silent);
    try testing.expectEqualStrings("the engine page didn't answer within 1 s", (try rig.page.probe(&t.reply)).widevineError.?);

    // The engine stops while the page is probed.
    rig.fp.hold(.probe, 1);
    var probing = try testing.io.concurrent(EnginePage.probe, .{ &rig.page, &t.reply });
    defer drop(&probing);
    try rig.fp.arrived(.probe);
    rig.launcher.stop();
    try testing.expectEqualStrings("the engine page disconnected before answering", (try probing.await(testing.io)).widevineError.?);
    // Nothing printed: doctor prints its own lines.
    try testing.expectEqualStrings("", (try t.finish({})).out);
}

test "a repair if idle reloads a page MusicKit signed out once Apple accepts the Music User Token, and reports the new page load" {
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        try launched(&rig);
        rig.fp.world.signs_out = false;
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("MusicKit signed the engine page out, though Apple accepts the Music User Token; reloading the page so it takes the current tokens\n", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(null, ran.outcome.left_alone);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: MusicKit had signed it out", rig.launcher.logged.items[0]);
    }
    // Without a valid Music User Token, the sign-out is the token's: no reload.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        try launched(&rig);
        const ran = try rig.doctor(false);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.signed_out, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads);
    }
    // An idle page on a developer token Apple refuses: asked, then reloaded.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.developer = fake.older_token;
        try launched(&rig);
        rig.fp.world.developer = fake.current_token;
        rig.fp.world.refused = &.{fake.older_token};
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("Apple refused the engine page's developer token (HTTP 401); reloading the page so it takes the current one\n", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 1), rig.fp.checks);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: Apple refused its developer token", rig.launcher.logged.items[0]);
    }
    // Its reload not coming back: not configured, with why.
    {
        var timing = Rig.timing;
        timing.reload_wait = .fromSeconds(1);
        var rig: Rig = undefined;
        rig.init(timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        try launched(&rig);
        rig.fp.world.next = .never;
        const ran = try rig.doctor(true);
        try expectNotConfigured("the reloaded engine page didn't configure MusicKit within 1 s", ran.outcome.verdict);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: MusicKit had signed it out; then: the reloaded engine page didn't configure MusicKit within 1 s", rig.launcher.logged.items[0]);
    }
}

/// The note doctor prints for `need`, which the repair if idle left alone.
fn noteText(rig: *Rig, left: LeftAlone, need: Repair) ![]const u8 {
    var note: Io.Writer.Allocating = .init(rig.newArena());
    try note.writer.print("{f}", .{left.note(need)});
    return note.written();
}

test "a repair if idle leaves a page that holds music alone, with the need it found" {
    for ([_]playback.Music{ .playing, .starting, .paused, .stopped_live }) |music| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.signs_out = true;
        try launched(&rig);
        rig.fp.world.signs_out = false;
        rig.fp.set(music, false);
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.signed_out, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads);
        const left = ran.outcome.left_alone.?;
        try testing.expectEqual(std.EnumSet(Repair).initOne(.signed_out), left.needs);
        try testing.expectEqual(Because{ .holds = music }, left.because);
        try testing.expectEqual(music, rig.fp.held());
        var note: Io.Writer.Allocating = .init(rig.newArena());
        try note.writer.print("{f}", .{left.note(.signed_out)});
        try testing.expectEqualStrings("MusicKit signed the engine page out, though Apple accepts the Music User Token; the page holds music, so it's left alone: the next play reloads it", note.written());
    }
}

test "a repair if idle decides on the page as it is now: a queue that started after the report it read is left alone" {
    var timing = Rig.timing;
    timing.widevine_wait = .fromMilliseconds(100);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    rig.fp.world.signs_out = true;
    try launched(&rig);
    rig.fp.world.signs_out = false;
    // The repair read the page's report, idle, and probes it for Widevine meanwhile.
    rig.fp.hold(.probe, 1);
    var doctor = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctor);
    try rig.fp.arrived(.probe);
    try rig.controlPlay();
    rig.fp.release(.probe, .answer);
    const ran = try doctor.await(testing.io);
    try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.reloads);
    try testing.expectEqual(Because{ .holds = .starting }, ran.outcome.left_alone.?.because);
    try testing.expect(rig.fp.calledOn("1", "playNext"));
}

test "a repair if idle whose look gets no answer leaves the page alone, and says so" {
    var timing = Rig.timing;
    timing.look = .fromMilliseconds(50);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.snapshot, 1);
    rig.fp.release(.snapshot, .silent);
    const ran = try rig.doctor(true);
    try testing.expectEqualStrings("", ran.out);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqual(Verdict.signed_out, ran.outcome.verdict);
    const left = ran.outcome.left_alone.?;
    try testing.expectEqual(std.EnumSet(Repair).initOne(.signed_out), left.needs);
    try testing.expectEqualStrings("MusicKit signed the engine page out, though Apple accepts the Music User Token; the engine page didn't answer, so it's left alone: the next play reloads it", try noteText(&rig, left, .signed_out));
}

test "doctor's Widevine reload holds against music: a page holding a paused song is left alone with a note; an idle one is reloaded once" {
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.widevine = false;
        try launched(&rig);
        rig.fp.world.widevine = true;
        rig.fp.set(.paused, false);
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqual(false, ran.outcome.report.browserSupportsVideoDrm);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqual(.paused, rig.fp.held());
        const left = ran.outcome.left_alone.?;
        try testing.expectEqual(std.EnumSet(Repair).initOne(.drm), left.needs);
        try testing.expectEqualStrings("Widevine is available, but MusicKit configured without it; the page holds music, so it's left alone: the next play reloads it", try noteText(&rig, left, .drm));
    }
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.widevine = false;
        try launched(&rig);
        rig.fp.world.widevine = true;
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("Widevine is available; reloading the engine page so MusicKit sees it.\n", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(true, ran.outcome.report.browserSupportsVideoDrm);
        try testing.expectEqual(null, ran.outcome.left_alone);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: Widevine had become available", rig.launcher.logged.items[0]);
    }
}

test "a repair if idle waits for Widevine whether or not MusicKit configured" {
    var timing = Rig.timing;
    timing.widevine_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    rig.fp.world.widevine_after = 2;
    rig.fp.world.next = .fails;
    try launched(&rig);
    const ran = try rig.doctor(false);
    try testing.expectEqualStrings("Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 1 s for the browser to install it…\n", ran.out);
    try expectNotConfigured("developer token endpoint: HTTP 503", ran.outcome.verdict);
    try testing.expectEqual(@as(u32, 2), rig.fp.probes);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
}

/// Waits until the page's latest report shows it holding `music`.
fn reported(rig: *Rig, music: playback.Music) !void {
    const deadline: Deadline = .after(testing.io, .fromSeconds(2));
    var seen = try rig.channel.waitChange(null, .zero);
    while (!deadline.passed()) {
        if (try rig.channel.lastReport(rig.newArena())) |last| if (playback.parseReport(rig.newArena(), last.json)) |report|
            if (report.music() == music) return;
        seen = try rig.channel.waitChange(seen, deadline.left());
    }
    return error.NeverReported;
}

/// Waits until the latest report names the Music User Token that the `n`th sign-in stored.
fn namesUserToken(rig: *Rig, n: u64) !void {
    const want = fake.userTokenHash(n);
    const deadline: Deadline = .after(testing.io, .fromSeconds(2));
    var seen = try rig.channel.waitChange(null, .zero);
    while (!deadline.passed()) {
        if (try rig.channel.lastReport(rig.newArena())) |last| if (playback.parseReport(rig.newArena(), last.json)) |report|
            if (report.musicUserToken) |held| if (held.eql(.{ .hash = &want })) return;
        seen = try rig.channel.waitChange(seen, deadline.left());
    }
    return error.NeverReported;
}

test "the sign-in reloads a page on the older Music User Token that holds no music, or only a preview, and waits for its new page load, whether or not the page names the token" {
    const cases = [_]struct { playback.Music, bool }{ .{ .none, false }, .{ .playing, true }, .{ .paused, true }, .{ .starting, true } };
    for (names_any) |names| for (cases) |case| {
        const music, const preview = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.names_user_token = names;
        try launched(&rig);
        rig.fp.set(music, preview);
        try reported(&rig, music);
        try testing.expectEqual(NewUserToken.reloaded, try rig.signin());
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqualStrings("2", rig.fp.current());
        try testing.expectEqualStrings("reloading the engine page so it reads the new Music User Token", rig.launcher.logged.items[0]);
        try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);
    };
}

test "the sign-in leaves a page that holds music alone, and logs what it holds" {
    const cases = [_]struct { playback.Music, []const u8 }{
        .{ .paused, "the engine page holds a paused song; the next play reloads it first, so it reads the new Music User Token" },
        .{ .playing, "the engine page holds music that plays; the next play reloads it first, so it reads the new Music User Token" },
        .{ .starting, "the engine page holds a song on its way; the next play reloads it first, so it reads the new Music User Token" },
        .{ .stopped_live, "the engine page holds stopped live radio; the next play reloads it first, so it reads the new Music User Token" },
    };
    for (cases) |case| {
        const music, const line = case;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.set(music, false);
        try reported(&rig, music);
        try testing.expectEqual(NewUserToken{ .left_alone = .{ .holds = music } }, try rig.signin());
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqualStrings(line, rig.launcher.logged.items[0]);
    }
}

test "the sign-in's reload that doesn't come back within its wait is logged" {
    var timing = Rig.timing;
    timing.signin_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    try launched(&rig);
    rig.fp.world.next = .never;
    try testing.expectEqual(NewUserToken.not_back, try rig.signin());
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqualStrings("reloading the engine page so it reads the new Music User Token", rig.launcher.logged.items[0]);
    try testing.expectEqualStrings("the engine page didn't configure MusicKit within 1 s of the reload", rig.launcher.logged.items[1]);
}

test "the sign-in reloads nothing with no engine, nor with an engine page that isn't connected yet, and says so only while an engine runs" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    try testing.expectEqual(NewUserToken.no_engine, try rig.signin());
    try testing.expectEqual(@as(usize, 0), rig.launcher.logged.items.len);

    rig.fp.hold(.open, 1);
    var problem: []const u8 = "";
    var starting = try testing.io.concurrent(EnginePage.start, .{ &rig.page, rig.newArena(), &problem });
    defer drop(&starting);
    try rig.fp.arrived(.open);
    try testing.expectEqual(NewUserToken{ .left_alone = .not_connected }, try rig.signin());
    rig.fp.release(.open, .answer);
    _ = try starting.await(testing.io);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqualStrings("the engine page isn't connected yet; the next play reloads it first unless it has the new Music User Token", rig.launcher.logged.items[0]);
    try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);
}

test "the sign-in leaves alone a page whose music may play in full, and reloads one with a preview or nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const full =
        \\"nowPlaying":{"id":"1561837008","title":"Shy Away","playbackType":"encryptedFull"}
    ;
    const preview =
        \\"nowPlaying":{"id":"1561837008","title":"Shy Away","playbackType":"preview"}
    ;
    const untyped =
        \\"nowPlaying":{"id":"1561837008","title":"Shy Away","playbackType":null}
    ;
    // Every row but two starts as a configured, signed-in page; those two spell out how they differ.
    const signed_in =
        \\{"configured":true,"isAuthorized":true,
    ;
    // Reports as the page sends them, read through the parser. Null: the page reloads.
    const rows = [_]struct { []const u8, ?playback.Music }{
        // Left alone: a paused song, also on a page MusicKit signed out (the next play's token
        // repair reloads that one), one `am stop` rewound to 0:00, and one left in place after it
        // ended.
        .{ signed_in ++ "\"playbackState\":\"paused\",\"currentPlaybackTime\":62,\"isPlaying\":false,\"loadPending\":false," ++ full ++ "}", .paused },
        .{ "{\"configured\":true,\"isAuthorized\":false,\"playbackState\":\"paused\",\"currentPlaybackTime\":62,\"isPlaying\":false,\"loadPending\":false," ++ full ++ "}", .paused },
        .{ signed_in ++ "\"playbackState\":\"paused\",\"currentPlaybackTime\":0,\"isPlaying\":false,\"loadPending\":false," ++ full ++ "}", .paused },
        .{ signed_in ++ "\"playbackState\":\"ended\",\"isPlaying\":false,\"loadPending\":false," ++ full ++ "}", .paused },
        // Left alone: a song starting, with or without an item yet, and a queue on its way.
        .{ signed_in ++ "\"playbackState\":\"loading\",\"isPlaying\":false,\"loadPending\":false,\"nowPlaying\":null}", .starting },
        .{ signed_in ++ "\"playbackState\":\"waiting\",\"isPlaying\":false,\"loadPending\":false," ++ full ++ "}", .starting },
        .{ signed_in ++ "\"playbackState\":\"none\",\"isPlaying\":false,\"loadPending\":true,\"nowPlaying\":null}", .starting },
        .{ signed_in ++ "\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false,\"nowPlaying\":null,\"stoppedLive\":{\"id\":\"ra.978194965\",\"name\":\"Apple Music 1\"}}", .stopped_live },
        // Left alone: music that plays, a full track, an item whose playback type isn't named yet,
        // live radio before MusicKit names the item, and under a state MusicKit doesn't name.
        .{ signed_in ++ "\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false," ++ full ++ "}", .playing },
        .{ signed_in ++ "\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false," ++ untyped ++ "}", .playing },
        .{ signed_in ++ "\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false,\"nowPlaying\":null}", .playing },
        .{ signed_in ++ "\"playbackState\":\"11\",\"isPlaying\":true,\"loadPending\":false,\"nowPlaying\":null}", .playing },
        // Reloaded: a preview, playing, paused or starting, also with a queue on its way (it would
        // play as a preview too, on the same token).
        .{ signed_in ++ "\"playbackState\":\"playing\",\"isPlaying\":true,\"loadPending\":false," ++ preview ++ "}", null },
        .{ signed_in ++ "\"playbackState\":\"paused\",\"isPlaying\":false,\"loadPending\":false," ++ preview ++ "}", null },
        .{ signed_in ++ "\"playbackState\":\"loading\",\"isPlaying\":false,\"loadPending\":false," ++ preview ++ "}", null },
        .{ signed_in ++ "\"playbackState\":\"paused\",\"isPlaying\":false,\"loadPending\":true," ++ preview ++ "}", null },
        // Reloaded: nothing held, and a page whose MusicKit isn't configured.
        .{ signed_in ++ "\"playbackState\":\"stopped\",\"isPlaying\":false,\"loadPending\":false,\"nowPlaying\":null,\"stoppedLive\":null}", null },
        .{ "{\"configured\":false,\"isAuthorized\":false,\"playbackState\":null,\"loadPending\":false,\"nowPlaying\":null}", null },
    };
    comptime std.debug.assert(rows.len == 18);
    for (rows) |row| {
        const json, const left_alone = row;
        const report = playback.parseReport(arena.allocator(), json) orelse return error.TestBadReport;
        const got: ?playback.Music = switch (decide(.new_user_token, .{ .report = report })) {
            .leave_alone => |left| left.because.holds,
            .reload => null,
            else => return error.TestUnexpectedResult,
        };
        testing.expectEqual(left_alone, got) catch |e| {
            std.debug.print("row: {s}\n", .{json});
            return e;
        };
    }
}

/// A page MusicKit signed out, launched and reported: the next repair for a play reloads it.
fn signedOut(rig: *Rig) !void {
    rig.fp.world.signs_out = true;
    try launched(rig);
    rig.fp.world.signs_out = false;
}

test "a play that comes while another play's reload is in flight waits for it: one reload, the waiting line, no relaunch, no 'didn't load' failure" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    // The first play reloads the page; MusicKit waits on its new page load.
    rig.fp.hold(.configure, 1);
    var first = rig.plays.begin();
    defer first.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &first });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);

    var second = rig.plays.begin();
    defer second.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &second });
    defer drop(&waiting);
    try waiter.printed(waiting_line);
    rig.fp.release(.configure, .answer);

    const reloaded = try reloading.await(testing.io);
    const joined = try waiting.await(testing.io);
    try testing.expectEqual(Verdict.ready, reloaded.outcome.verdict);
    try testing.expectEqualStrings("2", reloaded.outcome.report.load.?);
    try testing.expectEqualStrings(waiting_line ++ "\n", joined.out);
    try testing.expectEqual(Verdict.ready, joined.outcome.verdict);
    try testing.expectEqualStrings("2", joined.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
}

test "a control play that begins during another play's reload joins it, sends no reload of its own, and lands on the new page load" {
    for ([_][]const u8{ "playNext", "playLater", "play" }) |method| {
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        try signedOut(&rig);
        rig.fp.hold(.configure, 1);
        var first = rig.plays.begin();
        defer first.end();
        var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &first });
        defer drop(&reloading);
        try rig.fp.arrived(.configure);

        const control = rig.caller();
        var inserting = try testing.io.concurrent(Caller.controlPlay, .{ control, method });
        defer drop(&inserting);
        try control.printed(waiting_line);
        rig.fp.release(.configure, .answer);

        _ = try reloading.await(testing.io);
        try inserting.await(testing.io);
        try testing.expectEqualStrings(waiting_line ++ "\n", try control.out());
        try testing.expect(rig.fp.calledOn("2", method));
        try testing.expect(!rig.fp.calledOn("1", method));
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    }
}

test "a control play with no reload in flight goes straight to the page: it never reloads one that needs it" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    // MusicKit signed the page out: a repair for a play would reload it.
    try signedOut(&rig);
    const control = rig.caller();
    try control.controlPlay("playNext");
    try testing.expectEqualStrings("", try control.out());
    try testing.expect(rig.fp.calledOn("1", "playNext"));
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqual(@as(u32, 0), rig.fp.checks + rig.fp.probes);
}

test "reloadInFlight answers at once: no before a reload, yes while it is in flight, no once its new page load landed" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    const page = rig.page.page();
    try testing.expect(!try page.reloadInFlight(rig.newArena()));
    rig.fp.hold(.configure, 1);
    var p = rig.plays.begin();
    defer p.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &p });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);
    try testing.expect(try page.reloadInFlight(rig.newArena()));
    rig.fp.release(.configure, .answer);
    _ = try reloading.await(testing.io);
    try testing.expect(!try page.reloadInFlight(rig.newArena()));
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a control play that a stop cancels while it joins a reload stops waiting, and sends nothing" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var first = rig.plays.begin();
    defer first.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &first });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);

    var p = rig.plays.begin();
    defer p.end();
    const control = rig.caller();
    var joining = try testing.io.concurrent(Page.joinReload, .{ rig.page.page(), &control.t.reply, &p });
    defer drop(&joining);
    try control.printed(waiting_line);
    rig.plays.cancel(rig.plays.beginStop());
    // It returns while the reload is still held in flight.
    try joining.await(testing.io);
    try testing.expect(try rig.page.page().reloadInFlight(rig.newArena()));
    try testing.expect(!p.send());
    rig.fp.release(.configure, .answer);
    _ = try reloading.await(testing.io);
}

/// What the CLI shows right after a reload the module sent for `why`.
fn reasonLine(comptime why: Repair) []const u8 {
    return comptime why.reloadLine() ++ "\n";
}

/// Waits until the latest report is the page load `load`'s, with MusicKit configured or failed
/// to.
fn loadDone(rig: *Rig, load: []const u8) !void {
    const deadline: Deadline = .after(testing.io, .fromSeconds(2));
    var seen = try rig.channel.waitChange(null, .zero);
    while (!deadline.passed()) {
        if (try rig.channel.lastReport(rig.newArena())) |last| if (playback.parseReport(rig.newArena(), last.json)) |report|
            if (report.configureDone() and std.mem.eql(u8, report.load orelse "", load)) return;
        seen = try rig.channel.waitChange(seen, deadline.left());
    }
    return error.NeverLanded;
}

/// A stop that succeeds elsewhere: every play begun before it is cancelled.
fn stop(rig: *Rig) void {
    rig.plays.cancel(rig.plays.beginStop());
}

/// For a stop that must end a wait within a step, not at its deadline (`patient`: 30 s).
fn expectSoon(since: Io.Timestamp) !void {
    const took = since.durationTo(Io.Clock.awake.now(testing.io));
    if (took.toSeconds() >= 10) {
        std.debug.print("took {d} s\n", .{took.toSeconds()});
        return error.TestTookTooLong;
    }
}

test "doctor's look that comes back after a play reloaded the page and sent its queue: doctor reloads nothing, and the queue stays" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    // Doctor read `Plays` while nothing was on its way, and looks at page load 1; that waits.
    rig.fp.hold(.snapshot, 1);
    var doctor = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctor);
    try rig.fp.arrived(.snapshot);
    // Meanwhile a play reloads the page and sends its queue to page load 2.
    {
        var play = rig.plays.begin();
        defer play.end();
        const played = try rig.play(&play);
        try testing.expectEqualStrings("2", played.outcome.report.load.?);
        try rig.sendMusic(&play, "playQueue");
    }
    // The look answers as page load 1 was: signed out, holding nothing.
    rig.fp.release(.snapshot, .answer);
    const ran = try doctor.await(testing.io);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(.starting, rig.fp.held());
    try testing.expectEqualStrings("2", rig.fp.current());
    try testing.expectEqualStrings("", ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
}

test "two plays on a page whose developer token Apple refuses: one reload, and the play whose check was stranded goes on with the new load" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.developer = fake.older_token;
    try launched(&rig);
    rig.fp.world.developer = fake.current_token;
    // The first play asks page load 1 about its developer token before Apple refuses it; the
    // answer waits.
    rig.fp.hold(.check, 1);
    var stranded = rig.plays.begin();
    defer stranded.end();
    var first = try testing.io.concurrent(Rig.play, .{ &rig, &stranded });
    defer drop(&first);
    try rig.fp.arrived(.check);
    // Apple refuses it now: the second play's check says so, and it reloads the page.
    rig.fp.world.refused = &.{fake.older_token};
    var second = rig.plays.begin();
    defer second.end();
    const reloaded = try rig.play(&second);
    try testing.expectEqualStrings(reasonLine(.token_refused), reloaded.out);
    try testing.expectEqualStrings("2", reloaded.outcome.report.load.?);
    // The stranded check fails as disconnected once the server notices page load 1's stream is
    // dead, though page load 2's is open; a check that can't answer counts as not refused.
    try rig.fp.streamClosed("1");
    const ran = try first.await(testing.io);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u32, 2), rig.fp.checks);
}

test "doctor leaves a signed-out page alone while a play is on its way; that play then reloads it once" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    try signedOut(&rig);
    var play = rig.plays.begin();
    defer play.end();
    const doctored = try rig.doctor(true);
    try testing.expectEqualStrings("", doctored.out);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqual(Verdict.signed_out, doctored.outcome.verdict);
    const left = doctored.outcome.left_alone.?;
    try testing.expectEqual(std.EnumSet(Repair).initOne(.signed_out), left.needs);
    try testing.expectEqualStrings("MusicKit signed the engine page out, though Apple accepts the Music User Token; a play is on its way, so it's left alone: the next play reloads it", try noteText(&rig, left, .signed_out));

    const played = try rig.play(&play);
    try testing.expectEqualStrings(reasonLine(.signed_out), played.out);
    try testing.expectEqual(Verdict.ready, played.outcome.verdict);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "doctor waiting for Widevine while a play reloads for it reloads nothing after its wait" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    // Firefox has installed the CDM by doctor's second probe, whose answer waits.
    rig.fp.world.widevine_after = 2;
    rig.fp.hold(.probe, 2);
    var doctor = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctor);
    try rig.fp.arrived(.probe);
    // A play probes too, reloads for Widevine and sends its song to page load 2.
    {
        var play = rig.plays.begin();
        defer play.end();
        const played = try rig.play(&play);
        try testing.expectEqualStrings(reasonLine(.drm), played.out);
        try testing.expectEqualStrings("2", played.outcome.report.load.?);
        try rig.sendMusic(&play, "playQueue");
    }
    // Doctor's probe answers as page load 1 was when asked: Widevine is there.
    rig.fp.release(.probe, .answer);
    const ran = try doctor.await(testing.io);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(.starting, rig.fp.held());
    try testing.expectEqualStrings("Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 30 s for the browser to install it…\n", ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
}

test "a stop during a play's reload ends the play as cancelled within a step; the next play finds the new load" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var play = rig.plays.begin();
    defer play.end();
    const player = rig.caller();
    var playing = try testing.io.concurrent(Caller.play, .{ player, &play });
    defer drop(&playing);
    try player.printed(Repair.signed_out.reloadLine());
    const stopped_at = Io.Clock.awake.now(testing.io);
    stop(&rig);
    const stopped = try playing.await(testing.io);
    try testing.expectEqual(Verdict.cancelled, stopped.outcome.verdict);
    try expectSoon(stopped_at);

    // The reload carries on: the next play waits for its new page load.
    var next = rig.plays.begin();
    defer next.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &next });
    defer drop(&waiting);
    try waiter.printed(waiting_line);
    rig.fp.release(.configure, .answer);
    const ran = try waiting.await(testing.io);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a stop during a play's Widevine wait ends the play as cancelled within a step" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    var play = rig.plays.begin();
    defer play.end();
    const player = rig.caller();
    var playing = try testing.io.concurrent(Caller.play, .{ player, &play });
    defer drop(&playing);
    try player.printed("waiting up to 30 s for the browser to install it…");
    const stopped_at = Io.Clock.awake.now(testing.io);
    stop(&rig);
    const stopped = try playing.await(testing.io);
    try testing.expectEqual(Verdict.cancelled, stopped.outcome.verdict);
    try expectSoon(stopped_at);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
}

test "a reload that doesn't come back fails everyone waiting at the same deadline, counted from its record; the next repair can reload again" {
    var timing = patient;
    timing.reload_wait = .fromSeconds(2);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);
    var joiner = rig.plays.begin();
    defer joiner.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &joiner });
    defer drop(&waiting);
    try waiter.printed(waiting_line);

    const why = "the reloaded engine page didn't configure MusicKit within 2 s";
    try expectNotConfigured(why, (try reloading.await(testing.io)).outcome.verdict);
    const joined = try waiting.await(testing.io);
    try expectNotConfigured(why, joined.outcome.verdict);
    try testing.expectEqualStrings(waiting_line ++ "\n", joined.out);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);

    // Its page load configures at last, signed out: the next play reloads it again.
    rig.fp.world.signs_out = true;
    rig.fp.release(.configure, .answer);
    try loadDone(&rig, "2");
    rig.fp.world.signs_out = false;
    var next = rig.plays.begin();
    defer next.end();
    const ran = try rig.play(&next);
    try testing.expectEqualStrings(reasonLine(.signed_out), ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("3", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 2), rig.fp.reloads);
}

test "an engine stop during a reload ends every wait at once" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);
    var joiner = rig.plays.begin();
    defer joiner.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &joiner });
    defer drop(&waiting);
    try waiter.printed(waiting_line);

    rig.launcher.stop();
    try expectNotConfigured("the engine stopped during the reload", (try reloading.await(testing.io)).outcome.verdict);
    try expectNotConfigured("the engine stopped during the reload", (try waiting.await(testing.io)).outcome.verdict);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "an engine that stops during a play's Widevine wait ends the play at once: not configured, the engine stopped" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    var play = rig.plays.begin();
    defer play.end();
    const player = rig.caller();
    var playing = try testing.io.concurrent(Caller.play, .{ player, &play });
    defer drop(&playing);
    try player.printed("waiting up to 30 s for the browser to install it…");
    const stopped_at = Io.Clock.awake.now(testing.io);
    rig.launcher.stop();
    const ran = try playing.await(testing.io);
    try expectNotConfigured("the engine stopped", ran.outcome.verdict);
    try expectSoon(stopped_at);
    try testing.expectEqualStrings("Widevine not available yet (NotSupportedError: Key system configuration is not supported); waiting up to 30 s for the browser to install it…\n", ran.out);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
}

test "an engine that stops while a play probes the page for Widevine: no Widevine wait, and the play ends as not configured" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    rig.fp.hold(.probe, 1);
    var play = rig.plays.begin();
    defer play.end();
    var playing = try testing.io.concurrent(Rig.play, .{ &rig, &play });
    defer drop(&playing);
    try rig.fp.arrived(.probe);
    rig.launcher.stop();
    const ran = try playing.await(testing.io);
    try expectNotConfigured("the engine stopped", ran.outcome.verdict);
    try testing.expectEqualStrings("", ran.out);
}

test "an engine that stops while a play asks the page about its developer token: not configured, not ready on the old report" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.developer = fake.older_token;
    try launched(&rig);
    rig.fp.world.developer = fake.current_token;
    rig.fp.hold(.check, 1);
    var play = rig.plays.begin();
    defer play.end();
    var playing = try testing.io.concurrent(Rig.play, .{ &rig, &play });
    defer drop(&playing);
    try rig.fp.arrived(.check);
    rig.launcher.stop();
    const ran = try playing.await(testing.io);
    try expectNotConfigured("the engine stopped", ran.outcome.verdict);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
}

test "an engine stop during a reload doctor's probe waits on: doctor says the engine stopped during the reload, and waits for no Widevine" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);
    // Doctor starts, and its probe waits on the play's reload: `am doctor` probes before it
    // repairs.
    const doctor = rig.caller();
    var doctoring = try testing.io.concurrent(Caller.doctorWithProbe, .{ doctor, true });
    defer drop(&doctoring);
    try doctor.printed(waiting_line);
    const stopped_at = Io.Clock.awake.now(testing.io);
    rig.launcher.stop();
    try expectNotConfigured("the engine stopped during the reload", (try reloading.await(testing.io)).outcome.verdict);
    const ran = try doctoring.await(testing.io);
    try expectNotConfigured("the engine stopped during the reload", ran.outcome.verdict);
    try expectSoon(stopped_at);
    try testing.expectEqualStrings(waiting_line ++ "\n", ran.out);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "the play that sent a reload is cancelled while it waits: a play waiting on the same reload still gets the new load" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);
    // A stop cancels the play that sent the reload; a play begun after it joins the reload.
    stop(&rig);
    try testing.expectEqual(Verdict.cancelled, (try reloading.await(testing.io)).outcome.verdict);
    var joiner = rig.plays.begin();
    defer joiner.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &joiner });
    defer drop(&waiting);
    try waiter.printed(waiting_line);
    rig.fp.release(.configure, .answer);

    const joined = try waiting.await(testing.io);
    try testing.expectEqual(Verdict.ready, joined.outcome.verdict);
    try testing.expectEqualStrings("2", joined.outcome.report.load.?);
    try testing.expectEqualStrings(waiting_line ++ "\n", joined.out);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a page with no stream between a reload's old and new load isn't relaunched" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    // The new page load's stream waits, and the server notices page load 1's dead stream first.
    rig.fp.hold(.open, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.open);
    try rig.fp.streamClosed("1");
    try testing.expect(!rig.channel.connected());
    // The launch is older than the launch wait, so a page that never connected would be
    // relaunched.
    rig.page.timing.launch_wait = .zero;

    var problem: []const u8 = "";
    const found = try rig.page.start(rig.newArena(), &problem);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    try testing.expect(!found.started);
    var joiner = rig.plays.begin();
    defer joiner.end();
    const waiter = rig.caller();
    var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &joiner });
    defer drop(&waiting);
    try waiter.printed(waiting_line);
    rig.fp.release(.open, .answer);

    try testing.expectEqualStrings("2", (try reloading.await(testing.io)).outcome.report.load.?);
    const joined = try waiting.await(testing.io);
    try testing.expectEqual(Verdict.ready, joined.outcome.verdict);
    try testing.expectEqualStrings("2", joined.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a control play that begins, sends and ends while doctor's developer-token check is held: doctor reloads nothing" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.developer = fake.older_token;
    try launched(&rig);
    rig.fp.world.developer = fake.current_token;
    rig.fp.world.refused = &.{fake.older_token};
    // Doctor read `Plays` while nothing was on its way, looked at the idle page, and asks it
    // about its developer token; the answer waits.
    rig.fp.hold(.check, 1);
    var doctor = try testing.io.concurrent(Rig.doctor, .{ &rig, true });
    defer drop(&doctor);
    try rig.fp.arrived(.check);
    // Meanwhile a control play starts a queue on page load 1.
    try rig.controlPlay();
    rig.fp.release(.check, .answer);
    const ran = try doctor.await(testing.io);
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqual(.starting, rig.fp.held());
    try testing.expect(rig.fp.calledOn("1", "playNext"));
    try testing.expectEqualStrings("", ran.out);
    const left = ran.outcome.left_alone.?;
    try testing.expectEqual(std.EnumSet(Repair).initOne(.token_refused), left.needs);
    try testing.expectEqualStrings("Apple refuses the engine page's developer token; a play is on its way, so it's left alone: the next play reloads it", try noteText(&rig, left, .token_refused));
}

test "one reload covers every reason a play found and says the first; a new page load still signed out is signed out" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    rig.fp.world.signs_out = true;
    try launched(&rig);
    rig.fp.world.widevine = true;
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings(reasonLine(.drm), ran.out);
    try testing.expectEqual(Verdict.signed_out, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqualStrings("reloaded the engine page before a play: Widevine had become available, MusicKit had signed it out", rig.launcher.logged.items[0]);
}

test "doctor's Widevine reload that doesn't come back leaves the page not configured, with why, and no note" {
    var timing = Rig.timing;
    timing.reload_wait = .fromSeconds(1);
    var rig: Rig = undefined;
    rig.init(timing);
    defer rig.deinit();
    rig.fp.world.widevine = false;
    try launched(&rig);
    rig.fp.world.widevine = true;
    rig.fp.world.next = .never;
    const ran = try rig.doctor(true);
    try testing.expectEqualStrings(reasonLine(.drm), ran.out);
    try expectNotConfigured("the reloaded engine page didn't configure MusicKit within 1 s", ran.outcome.verdict);
    try testing.expectEqualStrings("reloaded the engine page for am doctor: Widevine had become available; then: the reloaded engine page didn't configure MusicKit within 1 s", rig.launcher.logged.items[0]);
}

test "doctor during a play's reload waits for it, says so, and reports the new page load; so does its probe" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try signedOut(&rig);
    rig.fp.hold(.configure, 1);
    var owner = rig.plays.begin();
    defer owner.end();
    var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
    defer drop(&reloading);
    try rig.fp.arrived(.configure);

    const prober = rig.caller();
    var probing = try testing.io.concurrent(Caller.probe, .{prober});
    defer drop(&probing);
    try prober.printed(waiting_line);
    const doctor = rig.caller();
    var doctoring = try testing.io.concurrent(Caller.doctor, .{ doctor, true });
    defer drop(&doctoring);
    try doctor.printed(waiting_line);
    rig.fp.release(.configure, .answer);

    try testing.expect((try probing.await(testing.io)).widevine);
    try testing.expectEqualStrings(waiting_line ++ "\n", try prober.out());
    try testing.expect(rig.fp.calledOn("2", "drmProbe"));
    const ran = try doctoring.await(testing.io);
    try testing.expectEqualStrings(waiting_line ++ "\n", ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    _ = try reloading.await(testing.io);
}

test "the sign-in leaves a page that is reloading alone, and a play during the sign-in's own reload waits for it" {
    {
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        try signedOut(&rig);
        rig.fp.hold(.configure, 1);
        var owner = rig.plays.begin();
        defer owner.end();
        var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &owner });
        defer drop(&reloading);
        try rig.fp.arrived(.configure);
        try testing.expectEqual(NewUserToken{ .left_alone = .reloading }, try rig.signin());
        rig.fp.release(.configure, .answer);
        _ = try reloading.await(testing.io);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    }
    {
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.hold(.configure, 1);
        var signing_in = try testing.io.concurrent(Rig.signin, .{&rig});
        defer drop(&signing_in);
        try rig.fp.arrived(.configure);
        var play = rig.plays.begin();
        defer play.end();
        const waiter = rig.caller();
        var waiting = try testing.io.concurrent(Caller.play, .{ waiter, &play });
        defer drop(&waiting);
        try waiter.printed(waiting_line);
        rig.fp.release(.configure, .answer);
        try testing.expectEqual(NewUserToken.reloaded, try signing_in.await(testing.io));
        const ran = try waiting.await(testing.io);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    }
}

test "a joiner of a reload withdrawn before it went out decides again at once, with no 60 s failure" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    const p = &rig.page;
    // An engine whose page hasn't opened its stream yet: a reload finds no page to go to.
    rig.fp.hold(.open, 1);
    var problem: []const u8 = "";
    const launch = try p.port.vtable.launch(p.port.ptr, rig.newArena(), .launch, &problem);
    p.noteLaunch(launch.generation);
    try rig.fp.arrived(.open);

    const reload = p.record(p.epoch(), null, null, "1").reload;
    var joining = try testing.io.concurrent(EnginePage.waitSettled, .{ p, rig.newArena(), reload, null, null });
    defer drop(&joining);
    const sent = try p.sendReload(rig.newArena(), reload.id);
    try testing.expectEqual(EnginePage.Waited{ .ended = .withdrawn }, try joining.await(testing.io));
    try testing.expectEqual(.withdrawn, sent);
    // Nothing is in flight: the next reload can be recorded.
    try testing.expect(p.record(p.epoch(), null, null, "1") == .reload);
    rig.fp.release(.open, .answer);
}

test "the repair rule: what a play, doctor and the sign-in do next about the page, and what they leave alone" {
    const ready: Report = .{ .configured = true, .isAuthorized = true, .browserSupportsVideoDrm = true };
    const signed_out: Report = .{ .configured = true, .isAuthorized = false, .browserSupportsVideoDrm = true };
    const no_drm: Report = .{ .configured = true, .isAuthorized = true, .browserSupportsVideoDrm = false };
    const no_drm_signed_out: Report = .{ .configured = true, .isAuthorized = false, .browserSupportsVideoDrm = false };
    const unconfigured: Report = .{ .configureError = "developer token endpoint: HTTP 503" };
    const song: playback.NowPlaying = .{ .id = "1561837008", .playbackType = "encryptedFull" };
    var paused_signed_out = signed_out;
    paused_signed_out.state = .paused;
    paused_signed_out.nowPlaying = song;
    var paused_no_drm = no_drm;
    paused_no_drm.state = .paused;
    paused_no_drm.nowPlaying = song;
    var paused_ready = ready;
    paused_ready.state = .paused;
    paused_ready.nowPlaying = song;
    var paused_preview = paused_ready;
    paused_preview.nowPlaying = .{ .id = "1561837008", .playbackType = "preview" };
    var playing_signed_out = signed_out;
    playing_signed_out.state = .playing;
    playing_signed_out.isPlaying = true;
    playing_signed_out.nowPlaying = song;
    var starting_signed_out = signed_out;
    starting_signed_out.state = .none;
    starting_signed_out.loadPending = true;
    var stopped_live_signed_out = signed_out;
    stopped_live_signed_out.state = .stopped;
    stopped_live_signed_out.stoppedLive = .{ .id = "ra.978194965", .name = "Apple Music 1" };
    var paused_preview_signed_out = paused_signed_out;
    paused_preview_signed_out.nowPlaying = paused_preview.nowPlaying;

    const idle: Kind = .{ .if_idle = .{ .user_token_ok = true } };
    const idle_without_user_token: Kind = .{ .if_idle = .{ .user_token_ok = false } };
    const Row = struct { []const u8, Kind, Inputs, Decision };
    const rows = [_]Row{
        // A repair for a play: whatever the page needs, whatever it holds.
        .{ "play: a configured page's token is compared first", .for_play, .{ .report = ready }, .compare_token },
        .{ "play: a page on the current token goes on", .for_play, .{ .report = ready, .token = .current }, .go_on },
        .{ "play: a page on another token is asked", .for_play, .{ .report = ready, .token = .other }, .ask_token },
        .{ "play: a refused token reloads", .for_play, .{ .report = ready, .token = .refused }, .{ .reload = .initOne(.token_refused) } },
        .{ "play: a token not refused goes on", .for_play, .{ .report = ready, .token = .not_refused }, .go_on },
        .{ "play: a page MusicKit signed out reloads, with no token asked", .for_play, .{ .report = signed_out }, .{ .reload = .initOne(.signed_out) } },
        .{ "play: a signed-out page that holds a paused song reloads", .for_play, .{ .report = paused_signed_out, .play_on_its_way = true }, .{ .reload = .initOne(.signed_out) } },
        .{ "play: an unconfigured page is left to its error", .for_play, .{ .report = unconfigured }, .go_on },
        .{ "play: a page with no stream is decided on as it is", .for_play, .{ .report = signed_out, .connected = false }, .go_on },
        .{ "play: no DRM: probe first", .for_play, .{ .report = no_drm_signed_out }, .probe },
        .{ "play: one reload for Widevine and the sign-out", .for_play, .{ .report = no_drm_signed_out, .widevine = true }, .{ .reload = .initMany(&.{ .drm, .signed_out }) } },
        .{ "play: no Widevine yet: the tokens alone", .for_play, .{ .report = no_drm, .widevine = false, .token = .current }, .go_on },
        // A repair if idle: the same needs, held against music, plays on their way and silence.
        .{ "doctor: a page on the current token is asked nothing, and not looked at", idle, .{ .report = ready, .token = .current }, .go_on },
        .{ "doctor: a configured page's token is compared first", idle, .{ .report = ready }, .compare_token },
        .{ "doctor: another token: look before asking", idle, .{ .report = ready, .token = .other }, .look },
        .{ "doctor: another token on an idle page is asked", idle, .{ .report = ready, .token = .other, .looked = true }, .ask_token },
        .{ "doctor: a refused token on an idle page reloads", idle, .{ .report = ready, .token = .refused, .looked = true }, .{ .reload = .initOne(.token_refused) } },
        .{ "doctor: another token on a page with music isn't asked", idle, .{ .report = paused_ready, .token = .other, .looked = true }, .go_on },
        .{ "doctor: another token with a play on its way isn't asked", idle, .{ .report = ready, .token = .other, .looked = true, .play_on_its_way = true }, .go_on },
        .{ "doctor: a need: look first", idle, .{ .report = signed_out }, .look },
        .{ "doctor: an idle signed-out page reloads", idle, .{ .report = signed_out, .looked = true }, .{ .reload = .initOne(.signed_out) } },
        .{ "doctor: a signed-out page that holds a paused song is left alone", idle, .{ .report = paused_signed_out, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .paused } } } },
        .{ "doctor: a signed-out page whose music plays is left alone", idle, .{ .report = playing_signed_out, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .playing } } } },
        .{ "doctor: a signed-out page with a queue on its way is left alone", idle, .{ .report = starting_signed_out, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .starting } } } },
        .{ "doctor: a signed-out page with stopped live radio is left alone", idle, .{ .report = stopped_live_signed_out, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .stopped_live } } } },
        .{ "doctor: a signed-out page that holds a paused preview is left alone, unlike the sign-in", idle, .{ .report = paused_preview_signed_out, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .{ .holds = .paused } } } },
        .{ "doctor: a play on its way leaves the page alone", idle, .{ .report = signed_out, .looked = true, .play_on_its_way = true }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .play_on_its_way } } },
        .{ "doctor: a look with no answer leaves the page alone", idle, .{ .report = signed_out, .looked = true, .answered = false }, .{ .leave_alone = .{ .needs = .initOne(.signed_out), .because = .no_answer } } },
        .{ "doctor: no DRM: probe, configured or not", idle, .{ .report = unconfigured }, .probe },
        .{ "doctor: Widevine there now on an unconfigured page: nothing to reload", idle, .{ .report = unconfigured, .widevine = true }, .go_on },
        .{ "doctor: Widevine on a page that holds a paused song is left alone", idle, .{ .report = paused_no_drm, .widevine = true, .token = .current, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.drm), .because = .{ .holds = .paused } } } },
        .{ "doctor: one reload for Widevine and the sign-out", idle, .{ .report = no_drm_signed_out, .widevine = true, .looked = true }, .{ .reload = .initMany(&.{ .drm, .signed_out }) } },
        // Without a Music User Token Apple accepts, a sign-out is the token's: no token repair.
        .{ "doctor without a valid Music User Token: a signed-out page goes on", idle_without_user_token, .{ .report = signed_out }, .go_on },
        .{ "doctor without a valid Music User Token: Widevine alone", idle_without_user_token, .{ .report = no_drm_signed_out, .widevine = true, .looked = true }, .{ .reload = .initOne(.drm) } },
        // A page load from before the last sign-in: a token reason.
        .{ "play: a page behind on the Music User Token reloads, with no token asked", .for_play, .{ .report = ready, .behind = true }, .{ .reload = .initOne(.behind) } },
        .{ "play: a page behind that holds a paused song reloads", .for_play, .{ .report = paused_ready, .behind = true }, .{ .reload = .initOne(.behind) } },
        .{ "play: one reload for Widevine, the sign-out and behind", .for_play, .{ .report = no_drm_signed_out, .widevine = true, .behind = true }, .{ .reload = .initMany(&.{ .drm, .signed_out, .behind }) } },
        .{ "play: an unconfigured page behind is left to its error", .for_play, .{ .report = unconfigured, .behind = true }, .go_on },
        .{ "doctor: behind: look first", idle, .{ .report = ready, .behind = true }, .look },
        .{ "doctor: an idle page behind reloads", idle, .{ .report = ready, .behind = true, .looked = true }, .{ .reload = .initOne(.behind) } },
        .{ "doctor: a page behind that holds a paused song is left alone", idle, .{ .report = paused_ready, .behind = true, .looked = true }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .{ .holds = .paused } } } },
        .{ "doctor: a page behind with a play on its way is left alone", idle, .{ .report = ready, .behind = true, .looked = true, .play_on_its_way = true }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .play_on_its_way } } },
        .{ "doctor without a valid Music User Token: behind isn't repaired", idle_without_user_token, .{ .report = ready, .behind = true }, .go_on },
        // The sign-in decides on a fresh look and on `Plays`; what it leaves alone is behind.
        .{ "sign-in: an idle page reloads", .new_user_token, .{ .report = ready }, .{ .reload = .initOne(.behind) } },
        .{ "sign-in: a look with no answer leaves the page alone", .new_user_token, .{ .report = .{}, .answered = false }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .no_answer } } },
        .{ "sign-in: a paused song is left alone", .new_user_token, .{ .report = paused_ready }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .{ .holds = .paused } } } },
        .{ "sign-in: a paused song with a play on its way: it holds music", .new_user_token, .{ .report = paused_ready, .play_on_its_way = true }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .{ .holds = .paused } } } },
        .{ "sign-in: an idle page with a play on its way is left alone", .new_user_token, .{ .report = ready, .play_on_its_way = true }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .play_on_its_way } } },
        .{ "sign-in: a preview with a play on its way is left alone", .new_user_token, .{ .report = paused_preview, .play_on_its_way = true }, .{ .leave_alone = .{ .needs = .initOne(.behind), .because = .play_on_its_way } } },
    };
    for (rows) |row| {
        const name, const kind, const in, const want = row;
        testing.expectEqual(want, decide(kind, in)) catch |e| {
            std.debug.print("row: {s}\n", .{name});
            return e;
        };
    }
}

// ---- Behind on the Music User Token ----

/// Every way a page names its Music User Token, or doesn't.
const names_any = [_]fake.FakePage.World.NamesUserToken{ .hashed, .unnamed, .absent };

test "a page load on the older Music User Token, whether or not it names it: a sign-in leaves it alone while it holds a paused song; the next play reloads it first, and the play after that doesn't" {
    for (names_any) |names| {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.names_user_token = names;
        try launched(&rig);
        rig.fp.set(.paused, false);
        try reported(&rig, .paused);
        try testing.expectEqual(NewUserToken{ .left_alone = .{ .holds = .paused } }, try rig.signin());
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqual(.paused, rig.fp.held());
        try testing.expectEqual(@as(u64, 0), rig.fp.userToken());

        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings(reasonLine(.behind), ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
        try testing.expectEqualStrings("the engine page holds a paused song; the next play reloads it first, so it reads the new Music User Token", rig.launcher.logged.items[0]);
        try testing.expectEqualStrings("reloaded the engine page before a play: it loaded before the last sign-in", rig.launcher.logged.items[1]);

        var next = rig.plays.begin();
        defer next.end();
        const again = try rig.play(&next);
        try testing.expectEqualStrings("", again.out);
        try testing.expectEqualStrings("2", again.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    }
}

test "a sign-in while a play is on its way leaves the page alone; that play reloads it first" {
    var rig: Rig = undefined;
    rig.init(Rig.timing);
    defer rig.deinit();
    try launched(&rig);
    var play = rig.plays.begin();
    defer play.end();
    try testing.expectEqual(NewUserToken{ .left_alone = .play_on_its_way }, try rig.signin());
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqualStrings("a play is on its way to the engine page, so it's left alone: the next play reloads it first, so it reads the new Music User Token", rig.launcher.logged.items[0]);

    const ran = try rig.play(&play);
    try testing.expectEqualStrings(reasonLine(.behind), ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
}

test "a control play that begins, sends and ends while the sign-in's look is held: the sign-in leaves the page alone, and the next play reloads it" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try launched(&rig);
    // The sign-in read `Plays` while nothing was on its way, and looks at the idle page load 1;
    // the answer waits.
    rig.fp.hold(.snapshot, 1);
    var signing_in = try testing.io.concurrent(Rig.signin, .{&rig});
    defer drop(&signing_in);
    try rig.fp.arrived(.snapshot);
    // Meanwhile a control play starts a queue on page load 1.
    try rig.controlPlay();
    rig.fp.release(.snapshot, .answer);
    try testing.expectEqual(NewUserToken{ .left_alone = .play_on_its_way }, try signing_in.await(testing.io));
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqual(.starting, rig.fp.held());
    try testing.expect(rig.fp.calledOn("1", "playNext"));
    try testing.expectEqualStrings("a play is on its way to the engine page, so it's left alone: the next play reloads it first, so it reads the new Music User Token", rig.launcher.logged.items[0]);

    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings(reasonLine(.behind), ran.out);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a sign-in during a play's own reload leaves it; that play plays on the new load, and the next play reloads it once more only when it doesn't name the new Music User Token" {
    for (names_any) |names| {
        const named = names == .hashed;
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        rig.fp.world.names_user_token = names;
        try signedOut(&rig);
        // The play reloads the page; MusicKit waits on its new page load.
        rig.fp.hold(.configure, 1);
        var first = rig.plays.begin();
        defer first.end();
        var reloading = try testing.io.concurrent(Rig.play, .{ &rig, &first });
        defer drop(&reloading);
        try rig.fp.arrived(.configure);
        try testing.expectEqual(NewUserToken{ .left_alone = .reloading }, try rig.signin());
        rig.fp.release(.configure, .answer);
        const ran = try reloading.await(testing.io);
        try testing.expectEqualStrings(reasonLine(.signed_out), ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);

        // Page load 2 began before the sign-in and read the new token: a page that says so isn't
        // reloaded again, and one that doesn't is.
        var next = rig.plays.begin();
        defer next.end();
        const again = try rig.play(&next);
        try testing.expectEqualStrings(if (named) "" else reasonLine(.behind), again.out);
        try testing.expectEqual(Verdict.ready, again.outcome.verdict);
        try testing.expectEqualStrings(if (named) "2" else "3", again.outcome.report.load.?);
        try testing.expectEqual(@as(u32, if (named) 1 else 2), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
        try testing.expectEqualStrings("the engine page is reloading; the next play reloads it again unless it has the new Music User Token", rig.launcher.logged.items[0]);
    }
}

test "doctor reloads a page behind on the Music User Token that holds no music, and leaves one that holds music alone with a note" {
    // The sign-in's look gets no answer: the idle page is left behind, and doctor reloads it.
    {
        var timing = Rig.timing;
        timing.look = .fromMilliseconds(50);
        var rig: Rig = undefined;
        rig.init(timing);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.hold(.snapshot, 1);
        rig.fp.release(.snapshot, .silent);
        try testing.expectEqual(NewUserToken{ .left_alone = .no_answer }, try rig.signin());
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings(reasonLine(.behind), ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(null, ran.outcome.left_alone);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
        try testing.expectEqualStrings("the engine page didn't answer; the next play reloads it first, so it reads the new Music User Token", rig.launcher.logged.items[0]);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: it loaded before the last sign-in", rig.launcher.logged.items[1]);
    }
    // A page that holds a paused song is left alone, with a note.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.set(.paused, false);
        try reported(&rig, .paused);
        try testing.expectEqual(NewUserToken{ .left_alone = .{ .holds = .paused } }, try rig.signin());
        const ran = try rig.doctor(true);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqual(.paused, rig.fp.held());
        const left = ran.outcome.left_alone.?;
        try testing.expectEqual(std.EnumSet(Repair).initOne(.behind), left.needs);
        try testing.expectEqualStrings("the engine page loaded before the last sign-in; the page holds music, so it's left alone: the next play reloads it", try noteText(&rig, left, .behind));
    }
}

test "a sign-in that lands while a play's developer-token check is held: the play reloads the page as behind" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    rig.fp.world.developer = fake.older_token;
    try launched(&rig);
    rig.fp.world.developer = fake.current_token;
    // The play asks page load 1 about its developer token; the answer waits.
    rig.fp.hold(.check, 1);
    var play = rig.plays.begin();
    defer play.end();
    var playing = try testing.io.concurrent(Rig.play, .{ &rig, &play });
    defer drop(&playing);
    try rig.fp.arrived(.check);
    // The sign-in lands: the play is on its way, so it leaves the page alone.
    try testing.expectEqual(NewUserToken{ .left_alone = .play_on_its_way }, try rig.signin());
    // Apple accepts the page's token.
    rig.fp.release(.check, .answer);
    const ran = try playing.await(testing.io);
    try testing.expectEqualStrings(reasonLine(.behind), ran.out);
    try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
    try testing.expectEqualStrings("2", ran.outcome.report.load.?);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u32, 1), rig.fp.checks);
    try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
    try testing.expectEqualStrings("reloaded the engine page before a play: it loaded before the last sign-in", rig.launcher.logged.items[1]);
}

test "a sign-in that a newer one overtook leaves the page to it: the newer one reloads and logs, the older one says nothing" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try launched(&rig);
    // The first sign-in looks at the idle page load 1; the answer waits.
    rig.fp.hold(.snapshot, 1);
    var older = try testing.io.concurrent(Rig.signin, .{&rig});
    defer drop(&older);
    try rig.fp.arrived(.snapshot);
    // A second sign-in stores a newer token, and reloads the page for it.
    try testing.expectEqual(NewUserToken.reloaded, try rig.signin());
    rig.fp.release(.snapshot, .answer);
    try testing.expectEqual(NewUserToken.superseded, try older.await(testing.io));
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    try testing.expectEqual(@as(u64, 2), rig.fp.userToken());
    try testing.expectEqualStrings("reloading the engine page so it reads the new Music User Token", rig.launcher.logged.items[0]);
    try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);

    // The page load the newer sign-in reloaded isn't behind.
    var play = rig.plays.begin();
    defer play.end();
    const ran = try rig.play(&play);
    try testing.expectEqualStrings("", ran.out);
    try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
}

test "a sign-in that a newer one overtook while it looked at a page holding a paused song says nothing: the newer one logs what it left alone" {
    var rig: Rig = undefined;
    rig.init(patient);
    defer rig.deinit();
    try launched(&rig);
    rig.fp.set(.paused, false);
    try reported(&rig, .paused);
    // The first sign-in looks at page load 1; the answer waits.
    rig.fp.hold(.snapshot, 1);
    var older = try testing.io.concurrent(Rig.signin, .{&rig});
    defer drop(&older);
    try rig.fp.arrived(.snapshot);
    try testing.expectEqual(NewUserToken{ .left_alone = .{ .holds = .paused } }, try rig.signin());
    rig.fp.release(.snapshot, .answer);
    try testing.expectEqual(NewUserToken.superseded, try older.await(testing.io));
    try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
    try testing.expectEqualStrings("the engine page holds a paused song; the next play reloads it first, so it reads the new Music User Token", rig.launcher.logged.items[0]);
    try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);
}

test "a sign-in whose look comes back after doctor reloaded the page for it promises no other reload: the new page load reads its token" {
    // Doctor's reload has landed.
    {
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        try launched(&rig);
        // The sign-in looks at the idle page load 1; the answer waits.
        rig.fp.hold(.snapshot, 1);
        var signing_in = try testing.io.concurrent(Rig.signin, .{&rig});
        defer drop(&signing_in);
        try rig.fp.arrived(.snapshot);
        // Meanwhile doctor finds page load 1 behind, and reloads it.
        const doctored = try rig.doctor(true);
        try testing.expectEqualStrings(reasonLine(.behind), doctored.out);
        try testing.expectEqualStrings("2", doctored.outcome.report.load.?);
        rig.fp.release(.snapshot, .answer);
        try testing.expectEqual(NewUserToken.reloaded, try signing_in.await(testing.io));
        try testing.expectEqualStrings("reloaded the engine page for am doctor: it loaded before the last sign-in", rig.launcher.logged.items[0]);
        try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);

        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
    }
    // Doctor's reload is in flight.
    {
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.hold(.snapshot, 1);
        var signing_in = try testing.io.concurrent(Rig.signin, .{&rig});
        defer drop(&signing_in);
        try rig.fp.arrived(.snapshot);
        rig.fp.hold(.configure, 1);
        const doctor = rig.caller();
        var doctoring = try testing.io.concurrent(Caller.doctor, .{ doctor, true });
        defer drop(&doctoring);
        try doctor.printed(Repair.behind.reloadLine());
        rig.fp.release(.snapshot, .answer);
        try testing.expectEqual(NewUserToken.reloaded, try signing_in.await(testing.io));
        rig.fp.release(.configure, .answer);
        try testing.expectEqualStrings("2", (try doctoring.await(testing.io)).outcome.report.load.?);
        try testing.expectEqualStrings("reloaded the engine page for am doctor: it loaded before the last sign-in", rig.launcher.logged.items[0]);
        try testing.expectEqual(@as(usize, 1), rig.launcher.logged.items.len);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
    }
}

test "two plays that launch at once around a sign-in: a new page load that doesn't name the new Music User Token counts as behind and is reloaded once, and one that names it isn't" {
    for (names_any) |names| {
        const named = names == .hashed;
        var rig: Rig = undefined;
        rig.init(patient);
        defer rig.deinit();
        rig.fp.world.names_user_token = names;
        // The first play launches the engine: the launch's nonce is set and the page opens, but
        // its stream waits, and the play has yet to record the launch.
        rig.fp.hold(.open, 1);
        rig.launcher.holdLaunch();
        var first = rig.plays.begin();
        defer first.end();
        var launching = try testing.io.concurrent(Rig.play, .{ &rig, &first });
        defer drop(&launching);
        try rig.launcher.arrivedLaunch();
        // The sign-in lands while the page isn't connected yet; the page reads the new token
        // as it connects.
        try testing.expectEqual(NewUserToken{ .left_alone = .not_connected }, try rig.signin());
        rig.fp.release(.open, .answer);
        // The second play's launch call finds the engine running: it records the launch first,
        // and repairs the page.
        var second = rig.plays.begin();
        defer second.end();
        const ran = try rig.play(&second);
        try testing.expectEqualStrings(if (named) "" else reasonLine(.behind), ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings(if (named) "1" else "2", ran.outcome.report.load.?);
        // The first play records its launch at last, and finds the same page load.
        rig.launcher.releaseLaunch();
        const late = try launching.await(testing.io);
        try testing.expectEqualStrings("", late.out);
        try testing.expectEqual(Verdict.ready, late.outcome.verdict);
        try testing.expectEqualStrings(if (named) "1" else "2", late.outcome.report.load.?);
        try testing.expectEqual(@as(u32, if (named) 0 else 1), rig.fp.reloads);
        try testing.expectEqual(@as(u32, 1), rig.launcher.launches);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
        try testing.expectEqualStrings("the engine page isn't connected yet; the next play reloads it first unless it has the new Music User Token", rig.launcher.logged.items[0]);
    }
}

test "the page's own sign-in: a page that names the new Music User Token is reloaded neither by the sign-in nor by the next play, and one that names none is reloaded once, by the sign-in" {
    for (names_any) |names| {
        const named = names == .hashed;
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        rig.fp.world.names_user_token = names;
        try launched(&rig);
        try testing.expectEqual(NewUserToken.reloaded, try rig.signinOnPage());
        const reloads: u32 = if (named) 0 else 1;
        try testing.expectEqual(reloads, rig.fp.reloads);
        try testing.expectEqual(@as(usize, reloads), rig.launcher.logged.items.len);
        // The page reports once it has hashed the new token (app.js `hashUserToken`).
        if (named) try namesUserToken(&rig, 1);
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(Verdict.ready, ran.outcome.verdict);
        try testing.expectEqualStrings(if (named) "1" else "2", ran.outcome.report.load.?);
        try testing.expectEqual(reloads, rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
    }
}

test "behind on the Music User Token: the one the page names against the stored one, else whether it began before the last sign-in" {
    const stored: playback.TokenId = .{ .hash = "0000000000000001" };
    const older: playback.TokenId = .{ .hash = "0000000000000000" };
    const unhashed: playback.TokenId = .{};
    // Name, the token the page names, the stored one, whether it began before the last sign-in, behind.
    const rows = [_]struct { []const u8, ?playback.TokenId, ?playback.TokenId, bool, bool }{
        .{ "names the stored one, began before", stored, stored, true, false },
        .{ "names the stored one, began after", stored, stored, false, false },
        .{ "names another, began before", older, stored, true, true },
        .{ "names another, began after", older, stored, false, true },
        .{ "names none (an older page, a browser that can't hash, or MusicKit holds none), began before", null, stored, true, true },
        .{ "names none, began after", null, stored, false, false },
        .{ "names a null hash, began before", unhashed, stored, true, true },
        .{ "names a null hash, began after", unhashed, stored, false, false },
        .{ "no token stored, began before", older, null, true, true },
        .{ "no token stored, began after", older, null, false, false },
    };
    for (rows) |row| {
        const name, const held, const current, const began_before, const want = row;
        testing.expectEqual(want, behindOn(held, current, began_before)) catch |e| {
            std.debug.print("row: {s}\n", .{name});
            return e;
        };
    }
}

test "a page the sign-in reloaded, or one launched after it, isn't behind" {
    // Reloaded by the sign-in.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        try launched(&rig);
        try testing.expectEqual(NewUserToken.reloaded, try rig.signin());
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 1), rig.fp.reloads);
    }
    // Launched after a sign-in with no engine.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        try testing.expectEqual(NewUserToken.no_engine, try rig.signin());
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqual(@as(u64, 1), rig.fp.userToken());
    }
    // Launched again after the sign-in left the last engine's page alone.
    {
        var rig: Rig = undefined;
        rig.init(Rig.timing);
        defer rig.deinit();
        try launched(&rig);
        rig.fp.set(.paused, false);
        try reported(&rig, .paused);
        try testing.expectEqual(NewUserToken{ .left_alone = .{ .holds = .paused } }, try rig.signin());
        rig.launcher.stop();
        var play = rig.plays.begin();
        defer play.end();
        const ran = try rig.play(&play);
        try testing.expectEqualStrings("", ran.out);
        try testing.expectEqualStrings("2", ran.outcome.report.load.?);
        try testing.expectEqual(@as(u32, 0), rig.fp.reloads);
        try testing.expectEqual(@as(u32, 2), rig.launcher.launches);
    }
}
