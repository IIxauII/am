//! The CLI's side of the channel to the background process: localhost HTTP on the daemon's port,
//! authenticated with the secret from `<config dir>/daemon-secret` in an `X-AM-Secret` header.
const std = @import("std");
const config = @import("../config.zig");
const daemon = @import("../daemon.zig");
const guard = @import("guard.zig");
const platform = @import("../platform.zig");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");
const Channel = @import("channel.zig").Channel;
const deadline_mod = @import("../deadline.zig");
const Deadline = deadline_mod.Deadline;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// How long the CLI waits for a daemon it started to answer.
const start_timeout: Io.Duration = .fromSeconds(5);
/// How long `stopAndWait` gives the daemon to close the engine and exit: the engine gets up to 7 s.
pub const stop_timeout: Io.Duration = .fromSeconds(15);

pub const Client = struct {
    io: Io,
    gpa: Allocator,
    port: u16,
    secret: []const u8,
    /// The daemon's config dir, for waiting until a stopping daemon releases its lock; empty
    /// waits for the port only.
    config_dir: []const u8 = "",
    /// Sent with every request (`guard.client_header`) when set: which TUI session it is.
    client_id: []const u8 = "",

    pub const RunError = error{
        /// Nothing listens on the port.
        NotRunning,
        /// Something answered other than with our protocol, e.g. 403 for a stale secret.
        Refused,
    } || protocol.ReadError || std.http.Client.RequestError || std.http.Client.Request.ReceiveHeadError || Io.Writer.Error || Io.Cancelable;

    /// Runs the endpoint `name` (see `daemon/endpoints.zig`) with the JSON `body`, printing
    /// what it says to `out` and its error to `err` as it arrives. Returns its exit code.
    pub fn run(c: *const Client, arena: Allocator, name: []const u8, body: []const u8, out: *Io.Writer, err: *Io.Writer) RunError!u8 {
        var http: std.http.Client = .{ .allocator = c.gpa, .io = c.io };
        defer http.deinit();
        var request = try c.send(arena, &http, name, body);
        defer request.deinit();
        var response = request.receiveHead(&.{}) catch |e| return canceledOr(&request, e);
        if (response.head.status != .ok) return error.Refused;
        var transfer: [64 * 1024]u8 = undefined;
        return protocol.readReply(arena, response.reader(&transfer), out, err) catch |e| canceledOr(&request, e);
    }

    /// Runs the endpoint `name` with the JSON `body` for a program rather than a terminal: each
    /// `out` and `data` line goes to `sink` as it arrives. Memory per line is reused, so a
    /// stream may run for hours; only the final message lands in `arena`.
    pub fn call(c: *const Client, arena: Allocator, name: []const u8, body: []const u8, sink: ?Sink) RunError!Outcome {
        var http: std.http.Client = .{ .allocator = c.gpa, .io = c.io };
        defer http.deinit();
        var request = try c.send(arena, &http, name, body);
        defer request.deinit();
        var response = request.receiveHead(&.{}) catch |e| return canceledOr(&request, e);
        if (response.head.status != .ok) return error.Refused;
        // One more byte than a line for its newline.
        const transfer = try c.gpa.alloc(u8, max_line + 1);
        defer c.gpa.free(transfer);
        return readLines(arena, c.gpa, response.reader(transfer), sink) catch |e| canceledOr(&request, e);
    }

    fn send(c: *const Client, arena: Allocator, http: *std.http.Client, name: []const u8, body: []const u8) RunError!std.http.Client.Request {
        const url = try arena.print("http://127.0.0.1:{d}/cli/{s}", .{ c.port, name });
        const headers = [_]std.http.Header{
            .{ .name = guard.secret_header, .value = c.secret },
            .{ .name = guard.client_header, .value = c.client_id },
        };
        var request = http.request(.POST, std.Uri.parse(url) catch unreachable, .{
            .keep_alive = false,
            .extra_headers = headers[0..if (c.client_id.len > 0) 2 else 1],
        }) catch |e| return switch (e) {
            error.ConnectionRefused => error.NotRunning,
            else => e,
        };
        errdefer request.deinit();
        request.sendBodyComplete(try arena.dupe(u8, body)) catch |e| return canceledOr(&request, e);
        return request;
    }

    /// The socket turns this task's cancelation into `ReadFailed` or `WriteFailed`, and the
    /// cancel request is used up by then. Reported as `error.Canceled` instead, so that a
    /// caller (the TUI's watch loop) stops rather than reconnecting.
    fn canceledOr(request: *const std.http.Client.Request, e: RunError) RunError {
        const conn = request.connection orelse return e;
        switch (e) {
            error.ReadFailed => if (conn.stream_reader.err) |cause| if (cause == error.Canceled) return error.Canceled,
            error.WriteFailed => if (conn.stream_writer.err) |cause| if (cause == error.Canceled) return error.Canceled,
            else => {},
        }
        return e;
    }

    /// Whether the daemon answers `ping` with this secret.
    pub fn ping(c: *const Client, arena: Allocator) bool {
        var discard: Io.Writer.Discarding = .init(&.{});
        const code = c.run(arena, "ping", "{}", &discard.writer, &discard.writer) catch return false;
        return code == 0;
    }

    pub const Stopped = enum {
        /// Nothing answers on the port any more and the lock is released: the daemon closed
        /// its engine before its port, so that is gone too.
        stopped,
        /// `stop` answered with an error (already written to `err`).
        refused,
        /// It still answers (or holds the lock) after the timeout, or never answered `stop`.
        still_running,
    };

    /// Asks the daemon to shut down (what `stop` says goes to `out` and `err`), then waits until
    /// it is gone (see `Stopped.stopped`), for at most `timeout` (see `stop_timeout`) from the
    /// start: a daemon that takes the request but never answers it (stopped with ^Z, hung)
    /// doesn't hold the caller longer than a second past that. `out`, `err` and `arena` are used
    /// from another thread meanwhile.
    pub fn stopAndWait(c: *const Client, arena: Allocator, out: *Io.Writer, err: *Io.Writer, timeout: Io.Duration) RunError!Stopped {
        const deadline: Deadline = .after(c.io, timeout);
        // Normally `stopUntil` ends at the deadline itself; this catches a request that never returns.
        const late: Io.Duration = .{ .nanoseconds = timeout.nanoseconds + std.time.ns_per_s };
        const result = (try deadline_mod.withTimeout(c.io, late, stopUntil, .{ c, arena, out, err, deadline })) orelse return .still_running;
        return result;
    }

    fn stopUntil(c: *const Client, arena: Allocator, out: *Io.Writer, err: *Io.Writer, deadline: Deadline) RunError!Stopped {
        const code = c.run(arena, "stop", "{}", out, err) catch |e| {
            if (e == error.Canceled or e == error.Refused) return e;
            // Nothing listens, or the connection dropped mid-answer (the daemon on its way out):
            // the wait tells.
            return c.waitGone(arena, deadline);
        };
        if (code != 0) {
            // A request cut off by the shutdown answers with an error too: give the port a
            // moment to close before calling it a refusal.
            const soon: Deadline = .after(c.io, .fromSeconds(1));
            const brief = if (soon.left().nanoseconds < deadline.left().nanoseconds) soon else deadline;
            return if (try c.waitGone(arena, brief) == .stopped) .stopped else .refused;
        }
        return c.waitGone(arena, deadline);
    }

    /// Waits until nothing answers on the port, then until the lock is released.
    fn waitGone(c: *const Client, arena: Allocator, deadline: Deadline) RunError!Stopped {
        while (true) {
            var discard: Io.Writer.Discarding = .init(&.{});
            _ = c.run(arena, "ping", "{}", &discard.writer, &discard.writer) catch |e| switch (e) {
                error.NotRunning => break,
                error.Canceled => return error.Canceled,
                else => {},
            };
            if (!try deadline.sleep(.fromMilliseconds(100))) return .still_running;
        }
        return if (try waitForLock(c.io, c.config_dir, deadline)) .stopped else .still_running;
    }

    /// What `stopIfUnused` did.
    pub const IfUnused = union(enum) {
        /// Something else uses the daemon: why (in the arena).
        kept: []const u8,
        /// Nothing did: it was asked to stop, and did, or not within the timeout.
        stopping: Stopped,
    };

    /// The TUI's q: asks the daemon to stop unless anything else uses it (the `stop-if-unused`
    /// endpoint decides; this TUI's other connections are closed by then), then waits as
    /// `stopAndWait` does, the wait for at most `timeout`. The request itself isn't bounded.
    /// An error says nothing about the daemon: keep it.
    pub fn stopIfUnused(c: *const Client, arena: Allocator, timeout: Io.Duration) RunError!IfUnused {
        const deadline: Deadline = .after(c.io, timeout);
        var kept: KeptSink = .{ .arena = arena };
        const outcome = c.call(arena, "stop-if-unused", "{}", .{ .ctx = &kept, .onLine = KeptSink.onLine }) catch |e| switch (e) {
            error.NotRunning => return .{ .stopping = try c.waitGone(arena, deadline) },
            else => return e,
        };
        if (outcome.code != 0) return .{ .kept = outcome.message orelse "it answered with an error" };
        if (!kept.answered) return .{ .kept = "it didn't say" };
        if (kept.why) |why| return .{ .kept = why };
        return .{ .stopping = try c.waitGone(arena, deadline) };
    }

    pub const BuildError = RunError || error{
        /// `ping` answered with an error: that says nothing about the daemon's build.
        PingFailed,
    };

    /// The running daemon's build id (`daemon.buildId`), from its `ping`; null from a daemon
    /// that predates build ids (its `ping` succeeds without one). A different one than this
    /// binary's means a stale daemon.
    pub fn build(c: *const Client, arena: Allocator) BuildError!?[]const u8 {
        var found: BuildSink = .{ .arena = arena };
        const outcome = try c.call(arena, "ping", "{}", .{ .ctx = &found, .onLine = BuildSink.onLine });
        if (outcome.code != 0) return error.PingFailed;
        return found.build;
    }
};

/// A line of a reply, as `Client.call` hands it on.
pub const Line = union(enum) {
    /// Text meant for a terminal.
    out: []const u8,
    /// Raw JSON text.
    data: []const u8,
};

pub const Sink = struct {
    ctx: *anyopaque,
    /// Slices are valid only during the call.
    onLine: *const fn (ctx: *anyopaque, line: Line) void,
};

pub const Outcome = struct {
    code: u8,
    /// The endpoint's failure message, allocated in the call's arena.
    message: ?[]const u8,
};

/// The longest reply line `Client.call` accepts.
pub const max_line = 1 << 20;

/// `Client.call`'s reading: every line is parsed in a scratch arena reset per line.
fn readLines(arena: Allocator, gpa: Allocator, in: *Io.Reader, sink: ?Sink) protocol.ReadError!Outcome {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    while (try in.takeDelimiter('\n')) |line| {
        _ = scratch.reset(.retain_capacity);
        switch (try protocol.parseLine(scratch.allocator(), line)) {
            .skip => {},
            .out => |text| if (sink) |s| s.onLine(s.ctx, .{ .out = text }),
            .data => |json| if (sink) |s| s.onLine(s.ctx, .{ .data = json }),
            .exit => |e| return .{ .code = e.code, .message = if (e.message) |m| try arena.dupe(u8, m) else null },
        }
    }
    return error.Truncated;
}

/// The `stop-if-unused` answer: `{"kept":"<why>"}`, or `{"kept":null}` when it stops.
const KeptSink = struct {
    arena: Allocator,
    answered: bool = false,
    why: ?[]const u8 = null,

    fn onLine(ctx: *anyopaque, line: Line) void {
        const s: *KeptSink = @ptrCast(@alignCast(ctx));
        const json = switch (line) {
            .data => |j| j,
            .out => return,
        };
        // Only a line with `kept` answers: null to stop, a string why not.
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, s.arena, json, .{ .allocate = .alloc_always }) catch return;
        if (parsed != .object) return;
        const kept = parsed.object.get("kept") orelse return;
        switch (kept) {
            .null => s.why = null,
            .string => |why| s.why = why,
            else => return,
        }
        s.answered = true;
    }
};

/// Waits until no daemon holds the lock in `config_dir` (true), or `deadline` passes (false).
/// A daemon that stopped answering keeps it until its engine has exited. An empty dir, or a
/// lock that can't be checked, counts as free.
pub fn waitForLock(io: Io, config_dir: []const u8, deadline: Deadline) Io.Cancelable!bool {
    if (config_dir.len == 0) return true;
    var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = lockPath(&buffer, config_dir) orelse return true;
    while (platform.lockHeld(io, path)) {
        if (!try deadline.sleep(.fromMilliseconds(100))) return false;
    }
    return true;
}

/// The CLI's side of `daemon.waitOutLock`: only looks.
fn probeLock(_: void, io: Io, path: []const u8) bool {
    return platform.lockHeld(io, path);
}

fn lockPath(buffer: []u8, config_dir: []const u8) ?[]const u8 {
    return std.mem.print(buffer, "{s}{c}{s}", .{ config_dir, Io.Dir.path.sep, daemon.lock_file }) catch null;
}

const BuildSink = struct {
    arena: Allocator,
    build: ?[]const u8 = null,

    fn onLine(ctx: *anyopaque, line: Line) void {
        const s: *BuildSink = @ptrCast(@alignCast(ctx));
        const json = switch (line) {
            .data => |j| j,
            .out => return,
        };
        // Copied: `json` is gone once the call returns.
        const parsed = std.json.parseFromSliceLeaky(struct { build: ?[]const u8 = null }, s.arena, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return;
        if (parsed.build) |b| s.build = b;
    }
};

pub const Options = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    config_dir: []const u8,
    port: u16,
    /// Start `am daemon` if nothing answers. False for `am daemon stop`.
    start: bool,
    /// Told when a daemon is being started.
    err: *Io.Writer,
    /// `Client.client_id` of every client it makes, the probe `ping` of `connect` included.
    client_id: []const u8 = "",

    /// A client for the daemon these options name, with `secret`.
    pub fn client(o: *const Options, secret: []const u8) Client {
        return .{ .io = o.io, .gpa = o.gpa, .port = o.port, .secret = secret, .config_dir = o.config_dir, .client_id = o.client_id };
    }
};

pub const ConnectError = error{
    /// No daemon answers and `start` was false.
    NotRunning,
    /// Printed to `err`.
    Reported,
} || Allocator.Error || Io.Cancelable;

/// A client for the running daemon, starting one first if needed (and allowed).
pub fn connect(o: Options) ConnectError!Client {
    if (try tryConnect(o)) |c| return c;
    if (!o.start) return error.NotRunning;

    const exe = std.process.executablePathAlloc(o.io, o.arena) catch |e| {
        o.err.print("error: can't find the am binary to start the background process: {t}\n", .{e}) catch {};
        return error.Reported;
    };
    const log_path = try Io.Dir.path.join(o.arena, &.{ o.config_dir, daemon.log_file });
    platform.createPrivateDir(o.io, o.config_dir) catch {};
    // A daemon for this port that is still stopping (closing its engine) holds the lock: wait
    // for it, as `start_timeout` counts from the start. One for another port is another
    // daemon on this config dir: say so (see `daemon.lockVerdict`).
    var path_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    if (lockPath(&path_buffer, o.config_dir)) |lock_path| {
        var holder_buffer: [64]u8 = undefined;
        switch (try daemon.waitOutLock(o.io, lock_path, o.port, &holder_buffer, {}, probeLock)) {
            .free => {},
            .other => |who| {
                o.err.print("error: another am daemon ({s}) uses {s}; not starting one for port {d}\n", .{ who, o.config_dir, o.port }) catch {};
                return error.Reported;
            },
            .stuck => |who| {
                o.err.print("error: am daemon ({s}) holds {s} but doesn't answer on port {d}; end it\n", .{ who, lock_path, o.port }) catch {};
                return error.Reported;
            },
        }
    }
    platform.spawnDetached(o.io, &.{ exe, "daemon", "--detach" }, log_path) catch |e| {
        o.err.print("error: can't start the background process: {t}\n", .{e}) catch {};
        return error.Reported;
    };

    // When two CLIs race, both daemons try to bind; the loser exits and both CLIs end up here
    // talking to the winner.
    const deadline: Deadline = .after(o.io, start_timeout);
    while (try deadline.sleep(.fromMilliseconds(100))) {
        if (try tryConnect(o)) |c| return c;
    }
    o.err.print("error: the background process didn't answer on port {d} within {d} s; see {s}\n", .{
        o.port, start_timeout.toSeconds(), log_path,
    }) catch {};
    return error.Reported;
}

/// A client if a daemon answers `/cli/ping` with the secret currently on disk.
fn tryConnect(o: Options) Allocator.Error!?Client {
    const secret = try readSecret(o) orelse return null;
    const c = o.client(secret);
    // Refused: a daemon from before the secret was rewritten, or something else on the port.
    return if (c.ping(o.arena)) c else null;
}

fn readSecret(o: Options) Allocator.Error!?[]const u8 {
    const text = config.readFile(o.io, o.arena, o.config_dir, daemon.secret_file) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    } orelse return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

const testing = std.testing;

const Recorder = struct {
    arena: Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn onLine(ctx: *anyopaque, line: Line) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const text = switch (line) {
            .out => |t| r.arena.print("out {s}", .{t}),
            .data => |j| r.arena.print("data {s}", .{j}),
        } catch return;
        r.lines.append(r.arena, text) catch {};
    }
};

test "call hands each out and data line to the sink and returns the exit code and message" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var recorder: Recorder = .{ .arena = arena.allocator() };
    var in: Io.Reader = .fixed(
        \\{"out":"starting the engine…\n"}
        \\
        \\{"data":{"build":"0011","report":null}}
        \\{"exit":1,"error":"engine-not-running"}
        \\{"out":"never read"}
        \\
    );
    const outcome = try readLines(arena.allocator(), testing.allocator, &in, .{ .ctx = &recorder, .onLine = Recorder.onLine });
    try testing.expectEqual(@as(u8, 1), outcome.code);
    try testing.expectEqualStrings("engine-not-running", outcome.message.?);
    try testing.expectEqual(@as(usize, 2), recorder.lines.items.len);
    try testing.expectEqualStrings("out starting the engine…\n", recorder.lines.items[0]);
    try testing.expectEqualStrings("data {\"build\":\"0011\",\"report\":null}", recorder.lines.items[1]);

    var truncated: Io.Reader = .fixed("{\"data\":{}}\n");
    try testing.expectError(error.Truncated, readLines(arena.allocator(), testing.allocator, &truncated, null));
}

/// A daemon backend: `ping` sends a long data line and a build id (or, per `ping`, no id or an
/// error); `slow` says one line, then waits as `watch` does; `stop` answers (or, per `stop`,
/// never does) and keeps the daemon running.
const LongPing = struct {
    ping: enum { build, no_build, fails } = .build,
    stop: enum { answers, hangs } = .answers,
    /// What `stop-if-unused` answers.
    unused: ?[]const u8 = null,
    /// `slow` saw its client hang up.
    saw_gone: std.atomic.Value(bool) = .init(false),

    const big_len = 300 * 1024;

    fn backend(p: *LongPing) server_mod.Backend {
        return .{ .ptr = p, .vtable = &.{
            .developerToken = noToken,
            .userToken = noToken,
            .postUserToken = noPost,
            .hasCli = hasCli,
            .cli = cli,
        } };
    }
    fn noToken(_: *anyopaque, _: Allocator) !server_mod.Response {
        return .{ .status = .no_content };
    }
    fn noPost(_: *anyopaque, _: Allocator, _: []const u8) !server_mod.Response {
        return .{ .status = .no_content };
    }
    fn hasCli(_: *anyopaque, name: []const u8) bool {
        for ([_][]const u8{ "ping", "slow", "stop", "stop-if-unused" }) |n| if (std.mem.eql(u8, name, n)) return true;
        return false;
    }
    fn cli(ptr: *anyopaque, name: []const u8, _: []const u8, r: *protocol.Reply) protocol.Reply.Error!void {
        const p: *LongPing = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, name, "slow")) {
            try r.print("waiting\n", .{});
            for (0..6000) |_| {
                if (r.client_gone) |gone| if (gone.load(.acquire)) {
                    p.saw_gone.store(true, .release);
                    return;
                };
                try testing.io.sleep(.fromMilliseconds(10), .awake);
            }
            return;
        }
        if (std.mem.eql(u8, name, "stop-if-unused")) {
            const why = p.unused orelse return r.data("{\"kept\":null}");
            return r.data(try r.arena.print("{{\"kept\":{f}}}", .{std.json.fmt(why, .{})}));
        }
        if (std.mem.eql(u8, name, "stop")) return switch (p.stop) {
            .answers => r.print("stopping\n", .{}),
            .hangs => testing.io.sleep(.fromSeconds(60), .awake),
        };
        switch (p.ping) {
            .build => {},
            .no_build => return r.print("pong\n", .{}),
            .fails => return r.fail("busy", .{}),
        }
        try r.print("pong\n", .{});
        const big = try r.arena.alloc(u8, big_len);
        @memset(big, 'x');
        big[0] = '"';
        big[big.len - 1] = '"';
        try r.data(big);
        try r.data("{\"build\":\"0011223344556677\"}");
    }
};

const Counter = struct {
    out: usize = 0,
    longest_data: usize = 0,

    fn onLine(ctx: *anyopaque, line: Line) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        switch (line) {
            .out => c.out += 1,
            .data => |j| c.longest_data = @max(c.longest_data, j.len),
        }
    }
};

test "call and build over HTTP: lines longer than the CLI's buffer, and a build id that outlives the call" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{};
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };
    var counter: Counter = .{};
    const outcome = try c.call(arena.allocator(), "ping", "{}", .{ .ctx = &counter, .onLine = Counter.onLine });
    try testing.expectEqual(@as(u8, 0), outcome.code);
    try testing.expectEqual(@as(usize, 1), counter.out);
    try testing.expectEqual(@as(usize, LongPing.big_len), counter.longest_data);

    // The id is read from a buffer that is gone once `build` returns.
    try testing.expectEqualStrings("0011223344556677", (try c.build(arena.allocator())).?);
}

test "build: null from a ping without a build id, an error from a ping that fails" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{ .ping = .no_build };
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };
    try testing.expectEqual(@as(?[]const u8, null), try c.build(arena.allocator()));
    ping.ping = .fails;
    try testing.expectError(error.PingFailed, c.build(arena.allocator()));
}

const Waiter = struct {
    started: std.atomic.Value(bool) = .init(false),

    fn onLine(ctx: *anyopaque, _: Line) void {
        const w: *Waiter = @ptrCast(@alignCast(ctx));
        w.started.store(true, .release);
    }
};

fn callSlow(c: *const Client, waiter: *Waiter) Client.RunError!Outcome {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    return c.call(arena.allocator(), "slow", "{}", .{ .ctx = waiter, .onLine = Waiter.onLine });
}

test "a call canceled while it waits for the next line fails with Canceled, not ReadFailed" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{};
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();

    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };
    var waiter: Waiter = .{};
    var future = try testing.io.concurrent(callSlow, .{ &c, &waiter });
    // Cancel once the stream is open and the client is reading it.
    const deadline: Deadline = .after(testing.io, .fromSeconds(10));
    while (!waiter.started.load(.acquire)) {
        if (!try deadline.sleep(.fromMilliseconds(10))) break;
    }
    try testing.expect(waiter.started.load(.acquire));
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectError(error.Canceled, future.cancel(testing.io));
    // The daemon notices the client hung up without writing to it.
    const noticed: Deadline = .after(testing.io, .fromSeconds(5));
    while (!ping.saw_gone.load(.acquire)) {
        if (!try noticed.sleep(.fromMilliseconds(10))) break;
    }
    try testing.expect(ping.saw_gone.load(.acquire));
}

fn stopSoon(c: *const Client, timeout: Io.Duration) Client.RunError!Client.Stopped {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var discard: Io.Writer.Discarding = .init(&.{});
    return c.stopAndWait(arena.allocator(), &discard.writer, &discard.writer, timeout);
}

test "stopAndWait: stopped once nothing answers, still running when it keeps answering" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{};
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };

    try testing.expectEqual(Client.Stopped.still_running, try stopSoon(&c, .fromMilliseconds(250)));

    var future = try testing.io.concurrent(stopSoon, .{ &c, Io.Duration.fromSeconds(10) });
    try testing.io.sleep(.fromMilliseconds(250), .awake);
    server.close();
    try testing.expectEqual(Client.Stopped.stopped, try future.await(testing.io));
}

test "stopAndWait: a daemon that never answers stop counts as still running, a second after the timeout" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{ .stop = .hangs };
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };

    const start: Io.Clock.Timestamp = .now(testing.io, .awake);
    try testing.expectEqual(Client.Stopped.still_running, try stopSoon(&c, .fromMilliseconds(250)));
    const took = start.untilNow(testing.io).raw.toMilliseconds();
    try testing.expect(took >= 1250 and took < 5000);
}

test "stopAndWait: a stop whose connection drops as the daemon goes counts as stopping" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{ .stop = .hangs };
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };

    var future = try testing.io.concurrent(stopSoon, .{ &c, Io.Duration.fromSeconds(10) });
    try testing.io.sleep(.fromMilliseconds(250), .awake);
    server.close();
    try testing.expectEqual(Client.Stopped.stopped, try future.await(testing.io));
}

fn ifUnused(c: *const Client, arena: Allocator, timeout: Io.Duration) Client.RunError!Client.IfUnused {
    return c.stopIfUnused(arena, timeout);
}

test "stopIfUnused: kept with the reason, or stopping and waiting for the port to close" {
    var channel: Channel = .init(testing.io, testing.allocator);
    defer channel.deinit();
    var ping: LongPing = .{ .unused = "music is playing" };
    const secret = "s3cr3t-s3cr3t-s3cr3t-s3cr3t-s3cr3t";
    var server: server_mod.Server = .{ .io = testing.io, .gpa = testing.allocator, .channel = &channel, .backend = ping.backend(), .secret = secret };
    try server.bind(0);
    try server.start();
    defer server.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Client = .{ .io = testing.io, .gpa = testing.allocator, .port = server.port, .secret = secret };

    try testing.expectEqualStrings("music is playing", (try ifUnused(&c, a, .fromMilliseconds(250))).kept);
    ping.unused = null;
    try testing.expectEqual(Client.Stopped.still_running, (try ifUnused(&c, a, .fromMilliseconds(250))).stopping);
    var future = try testing.io.concurrent(ifUnused, .{ &c, a, Io.Duration.fromSeconds(10) });
    try testing.io.sleep(.fromMilliseconds(250), .awake);
    server.close();
    try testing.expectEqual(Client.Stopped.stopped, (try future.await(testing.io)).stopping);
}

test "waitForLock: false while a daemon holds the lock, true once it's released" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.mem.print(&path_buf, "{s}{c}{s}", .{ dir, Io.Dir.path.sep, daemon.lock_file });
    const held = try platform.lockFile(io, path, "pid 1\n");
    try testing.expect(!try waitForLock(io, dir, .after(io, .fromMilliseconds(200))));
    held.close(io);
    try testing.expect(try waitForLock(io, dir, .after(io, .fromMilliseconds(200))));
    try testing.expect(try waitForLock(io, "", .after(io, .zero)));
}

test "only a data line with kept answers stop-if-unused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var sink: KeptSink = .{ .arena = arena.allocator() };
    KeptSink.onLine(&sink, .{ .data = "{\"build\":\"x\"}" });
    KeptSink.onLine(&sink, .{ .data = "[1]" });
    KeptSink.onLine(&sink, .{ .data = "{\"kept\":3}" });
    try testing.expect(!sink.answered);
    KeptSink.onLine(&sink, .{ .data = "{\"kept\":\"music is playing\"}" });
    try testing.expect(sink.answered);
    try testing.expectEqualStrings("music is playing", sink.why.?);
    KeptSink.onLine(&sink, .{ .data = "{\"kept\":null}" });
    try testing.expectEqual(null, sink.why);
}

test "lockHeld: true while a daemon holds the lock, and the probe takes nothing from it" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = lockPath(&path_buf, dir).?;
    try testing.expect(!platform.lockHeld(io, path));
    const held = try platform.lockFile(io, path, "pid 1, port 47823\n");
    try testing.expect(platform.lockHeld(io, path));
    var text: [64]u8 = undefined;
    try testing.expectEqualStrings("pid 1, port 47823\n", try Io.Dir.cwd().readFile(io, path, &text));
    held.close(io);
    try testing.expect(!platform.lockHeld(io, path));
}
