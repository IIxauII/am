//! The channel between the background process and the engine page, carried over unchanged from
//! the Node POC: commands go to the page over Server-Sent Events (`GET /events`), state comes
//! back as `POST /report` about once a second and command results as `POST /result`.
//!
//! Each engine launch has a nonce. Only a page carrying the current one may claim the channel,
//! open an event stream or report: a relaunched Firefox may restore the previous engine page next
//! to the new one, and a second MusicKit instance would take over playback.
//!
//! Thread-safe: the server's connection handlers and the daemon's commands share one `Channel`.
const std = @import("std");
const Deadline = @import("../deadline.zig").Deadline;

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Hex of 16 random bytes.
pub const Nonce = [32]u8;

pub fn newNonce(io: Io) Nonce {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// How many commands an event stream can fall behind before it misses one. The CLI sends one
/// command at a time, so this is never reached in practice.
const outbox_len = 32;

pub const Channel = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    /// Broadcast on every change: a new command, a result, a report, a new nonce, a stream closing.
    changed: Io.Condition = .init,

    nonce: ?Nonce = null,
    /// The current sign-in page's (`am signin`): it may fetch the developer token and post a
    /// Music User Token, and nothing else.
    signin_nonce: ?Nonce = null,
    /// Bumped with every `setNonce`, so a stream notices that its launch is over.
    generation: u64 = 0,
    streams: u32 = 0,
    /// Commands for the page, by sequence number: `seq - outbox_len .. seq` are kept.
    outbox: [outbox_len]?[]u8 = @splat(null),
    seq: u64 = 0,
    next_id: u64 = 1,
    pending: std.ArrayList(Pending) = .empty,
    /// The latest report from the current page: its JSON as posted.
    report: ?[]u8 = null,
    report_at: ?Io.Clock.Timestamp = null,
    /// Bumped with every accepted report.
    report_count: u64 = 0,

    const Pending = struct {
        id: u64,
        /// Its command's sequence number in the outbox.
        seq: u64,
        /// How many of the streams open when it was queued are still open: only they can
        /// deliver its command, or have delivered it. A stream opened later starts past it.
        readers: u32,
        outcome: ?Outcome = null,
    };

    /// Owned by the channel's allocator until handed to the waiting `call`.
    const Outcome = union(enum) {
        ok: []u8,
        page_error: []u8,
        failed: CallError,
    };

    pub const CallError = error{
        /// No engine page holds an event stream.
        NoEnginePage,
        /// Every event stream that could deliver the command closed, or the engine stopped,
        /// before the page answered.
        Disconnected,
        Timeout,
    };

    pub fn init(io: Io, gpa: Allocator) Channel {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(c: *Channel) void {
        for (&c.outbox) |*slot| if (slot.*) |m| c.gpa.free(m);
        for (c.pending.items) |p| if (p.outcome) |o| freeOutcome(c.gpa, o);
        c.pending.deinit(c.gpa);
        if (c.report) |r| c.gpa.free(r);
        c.* = undefined;
    }

    /// Starts a new engine launch (or, with null, ends the current one). Streams of the old
    /// launch close, its pending commands fail and its last report is forgotten.
    pub fn setNonce(c: *Channel, nonce: ?Nonce) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.nonce = nonce;
        c.generation += 1;
        c.failPending(error.Disconnected);
        if (c.report) |r| c.gpa.free(r);
        c.report = null;
        c.report_at = null;
        c.changed.broadcast(c.io);
    }

    fn isCurrent(c: *const Channel, given: ?[]const u8) bool {
        const nonce = c.nonce orelse return false;
        const g = given orelse return false;
        return std.mem.eql(u8, &nonce, g);
    }

    /// A new sign-in page (or, with null, none). The previous one's nonce stops working.
    pub fn setSigninNonce(c: *Channel, nonce: ?Nonce) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.signin_nonce = nonce;
    }

    /// Whether a page with this nonce may sign in: the current sign-in page, or the current
    /// engine page (which has the same button, hidden).
    pub fn claimSignin(c: *Channel, given: ?[]const u8) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (c.isCurrent(given)) return true;
        const nonce = c.signin_nonce orelse return false;
        const g = given orelse return false;
        return std.mem.eql(u8, &nonce, g);
    }

    /// `GET /claim`: whether a page with this nonce may run (204) or must unload itself (409).
    pub fn claim(c: *Channel, given: ?[]const u8) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.isCurrent(given);
    }

    pub const Stream = struct {
        generation: u64,
        /// The outbox's sequence number when it opened: it reads the commands queued from then on.
        first_seq: u64,
        next_seq: u64,
    };

    /// `GET /events`: null for a stale nonce (409). Pair with one `closeStream` of the stream
    /// this returns.
    pub fn openStream(c: *Channel, given: ?[]const u8) ?Stream {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (!c.isCurrent(given)) return null;
        c.streams += 1;
        c.changed.broadcast(c.io);
        return .{ .generation = c.generation, .first_seq = c.seq, .next_seq = c.seq };
    }

    /// When the last stream that could deliver a pending command closes, nobody is left to
    /// answer it: it fails now rather than at its timeout, though a stream opened after it may
    /// still be open. When the last stream closes, every pending command fails.
    pub fn closeStream(c: *Channel, stream: Stream) void {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        c.streams -= 1;
        for (c.pending.items) |*p| if (p.outcome == null and p.seq >= stream.first_seq) {
            p.readers -= 1;
            if (p.readers == 0) p.outcome = .{ .failed = error.Disconnected };
        };
        c.changed.broadcast(c.io);
    }

    pub const Event = union(enum) {
        /// A command for the page, as the JSON of an SSE `data:` line. Allocated in the arena.
        command: []const u8,
        /// Nothing happened within the timeout: send a `: ping` comment.
        ping,
        /// The launch this stream belongs to is over.
        closed,
    };

    /// Waits for the next command for this stream, up to `timeout`.
    pub fn nextEvent(c: *Channel, arena: Allocator, stream: *Stream, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!Event {
        const deadline: Deadline = .after(c.io, timeout);
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (stream.generation != c.generation) return .closed;
            if (stream.next_seq < c.seq) {
                // A stream that fell further behind than the outbox holds skips what it missed.
                stream.next_seq = @max(stream.next_seq, c.seq -| outbox_len);
                const message = c.outbox[stream.next_seq % outbox_len].?;
                stream.next_seq += 1;
                return .{ .command = try arena.dupe(u8, message) };
            }
            c.changed.waitTimeout(c.io, &c.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) return .ping,
                error.Canceled => return error.Canceled,
            };
        }
    }

    pub const ReportVerdict = enum { accepted, stale, invalid };

    /// `POST /report`: kept only if it carries the current nonce (else 409).
    pub fn postReport(c: *Channel, body: []const u8) Allocator.Error!ReportVerdict {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const fields = std.json.parseFromSliceLeaky(struct { engine: ?[]const u8 = null }, arena.allocator(), body, .{
            .ignore_unknown_fields = true,
        }) catch return .invalid;

        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (!c.isCurrent(fields.engine)) return .stale;
        const copy = try c.gpa.dupe(u8, body);
        if (c.report) |r| c.gpa.free(r);
        c.report = copy;
        c.report_at = .now(c.io, .awake);
        c.report_count += 1;
        c.changed.broadcast(c.io);
        return .accepted;
    }

    pub const LastReport = struct {
        json: []const u8,
        age: Io.Duration,
        /// The launch it was read under (`currentLaunch`).
        generation: u64,
    };

    /// The current page's latest report, copied into `arena`.
    pub fn lastReport(c: *Channel, arena: Allocator) Allocator.Error!?LastReport {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const report = c.report orelse return null;
        return .{ .json = try arena.dupe(u8, report), .age = c.report_at.?.untilNow(c.io).raw, .generation = c.generation };
    }

    /// The current launch while an engine launch's nonce is set; null with no engine, and for a
    /// sign-in window, which has no engine page. Every launch and every end of a launch moves
    /// it, so a wait can tell that the launch it waits on is over.
    pub fn currentLaunch(c: *Channel) ?u64 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return if (c.nonce != null) c.generation else null;
    }

    /// Grows with every accepted report and every launch or end of a launch.
    fn changes(c: *const Channel) u64 {
        return c.generation + c.report_count;
    }

    /// Waits up to `timeout` until something changed since `after` (a value this returned
    /// before): a new report, or an engine launched or gone. With `after` null, answers at once.
    /// Returns the current change count.
    pub fn waitChange(c: *Channel, after: ?u64, timeout: Io.Duration) Io.Cancelable!u64 {
        const deadline: Deadline = .after(c.io, timeout);
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        const seen = after orelse return c.changes();
        while (c.changes() <= seen) {
            c.changed.waitTimeout(c.io, &c.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) break,
                error.Canceled => return error.Canceled,
            };
        }
        return c.changes();
    }

    pub const ResultVerdict = enum { settled, unknown, invalid };

    /// `POST /result`: `{id, ok, value}` or `{id, ok: false, error}` for a command sent earlier.
    pub fn postResult(c: *Channel, body: []const u8) Allocator.Error!ResultVerdict {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const result = std.json.parseFromSliceLeaky(struct {
            id: u64,
            ok: bool,
            value: ?std.json.Value = null,
            @"error": ?[]const u8 = null,
        }, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch return .invalid;

        const outcome: Outcome = if (result.ok)
            .{ .ok = try std.json.Stringify.valueAlloc(c.gpa, result.value orelse .null, .{}) }
        else
            .{ .page_error = try c.gpa.dupe(u8, result.@"error" orelse "unknown error") };

        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.pending.items) |*p| if (p.id == result.id and p.outcome == null) {
            p.outcome = outcome;
            c.changed.broadcast(c.io);
            return .settled;
        };
        freeOutcome(c.gpa, outcome);
        return .unknown;
    }

    pub const CallResult = union(enum) {
        /// The method's return value, as JSON. Allocated in the arena.
        ok: []const u8,
        /// The method threw; holds its message. Allocated in the arena.
        page_error: []const u8,
    };

    /// Runs `window.am[method](...args)` in the engine page and waits for its result.
    /// `args_json` is a JSON array.
    pub fn call(c: *Channel, arena: Allocator, method: []const u8, args_json: []const u8, timeout: Io.Duration) (CallError || Allocator.Error || Io.Cancelable)!CallResult {
        const deadline: Deadline = .after(c.io, timeout);
        try c.mutex.lock(c.io);
        defer c.mutex.unlock(c.io);
        if (c.streams == 0) return error.NoEnginePage;

        const id = c.next_id;
        c.next_id += 1;
        try c.pending.append(c.gpa, .{ .id = id, .seq = c.seq, .readers = c.streams });
        const message = c.gpa.print("{{\"id\":{d},\"method\":{f},\"args\":{s}}}", .{
            id, std.json.fmt(method, .{}), args_json,
        }) catch |e| {
            _ = c.pending.pop();
            return e;
        };
        const slot = &c.outbox[c.seq % outbox_len];
        if (slot.*) |old| c.gpa.free(old);
        slot.* = message;
        c.seq += 1;
        c.changed.broadcast(c.io);

        while (true) {
            const index = for (c.pending.items, 0..) |p, i| {
                if (p.id == id) break i;
            } else unreachable;
            if (c.pending.items[index].outcome) |outcome| {
                _ = c.pending.swapRemove(index);
                defer freeOutcome(c.gpa, outcome);
                return switch (outcome) {
                    .ok => |v| .{ .ok = try arena.dupe(u8, v) },
                    .page_error => |m| .{ .page_error = try arena.dupe(u8, m) },
                    .failed => |e| e,
                };
            }
            c.changed.waitTimeout(c.io, &c.mutex, .{ .deadline = deadline.at }) catch |e| switch (e) {
                error.Timeout => if (deadline.passed()) {
                    _ = c.pending.swapRemove(index);
                    return error.Timeout;
                },
                error.Canceled => {
                    _ = c.pending.swapRemove(index);
                    return error.Canceled;
                },
            };
        }
    }

    /// Whether an engine page holds an event stream.
    pub fn connected(c: *Channel) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.streams > 0;
    }

    fn failPending(c: *Channel, err: CallError) void {
        for (c.pending.items) |*p| if (p.outcome == null) {
            p.outcome = .{ .failed = err };
        };
    }

    fn freeOutcome(gpa: Allocator, outcome: Outcome) void {
        switch (outcome) {
            .ok, .page_error => |bytes| gpa.free(bytes),
            .failed => {},
        }
    }
};

const testing = std.testing;
const nonce_a: Nonce = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".*;
const nonce_b: Nonce = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".*;

test "only a page with the current launch's nonce may claim the channel or open a stream" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();

    // Before any launch, nobody.
    try testing.expect(!c.claim(&nonce_a));
    try testing.expectEqual(null, c.openStream(&nonce_a));

    c.setNonce(nonce_a);
    try testing.expect(c.claim(&nonce_a));
    try testing.expect(!c.claim(&nonce_b));
    try testing.expect(!c.claim(null));
    try testing.expect(!c.claim("aaaa"));
    try testing.expectEqual(null, c.openStream(&nonce_b));
    c.closeStream(c.openStream(&nonce_a).?);

    // After a relaunch the old page is stale.
    c.setNonce(nonce_b);
    try testing.expect(!c.claim(&nonce_a));
    try testing.expectEqual(null, c.openStream(&nonce_a));
    try testing.expect(c.claim(&nonce_b));
}

test "a report counts only with the current nonce" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);

    try testing.expectEqual(.stale, try c.postReport("{\"engine\":\"" ++ nonce_b ++ "\",\"configured\":true}"));
    try testing.expectEqual(.stale, try c.postReport("{\"configured\":true}"));
    try testing.expectEqual(.invalid, try c.postReport("not json"));
    try testing.expectEqual(null, try c.lastReport(testing.allocator));

    const report = "{\"engine\":\"" ++ nonce_a ++ "\",\"configured\":true,\"lastEvents\":[]}";
    try testing.expectEqual(.accepted, try c.postReport(report));
    const last = (try c.lastReport(testing.allocator)).?;
    defer testing.allocator.free(last.json);
    try testing.expectEqualStrings(report, last.json);

    // A relaunch forgets the old page's report.
    c.setNonce(nonce_b);
    try testing.expectEqual(null, try c.lastReport(testing.allocator));
}

test "currentLaunch names the launch while its nonce is set, and a last report the launch it was read under" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    try testing.expectEqual(null, c.currentLaunch());

    c.setNonce(nonce_a);
    const first = c.currentLaunch().?;
    try testing.expectEqual(.accepted, try c.postReport("{\"engine\":\"" ++ nonce_a ++ "\"}"));
    const last = (try c.lastReport(testing.allocator)).?;
    defer testing.allocator.free(last.json);
    try testing.expectEqual(first, last.generation);

    // Every launch moves it, and the end of a launch clears it.
    c.setNonce(nonce_b);
    const second = c.currentLaunch().?;
    try testing.expect(second != first);
    c.setNonce(null);
    try testing.expectEqual(null, c.currentLaunch());
    c.setNonce(nonce_a);
    try testing.expect(c.currentLaunch().? != second);
}

fn reportLater(c: *Channel, io: Io) !void {
    try io.sleep(.fromMilliseconds(50), .awake);
    _ = try c.postReport("{\"engine\":\"" ++ nonce_a ++ "\"}");
}

test "waitChange wakes on a new report and on a launch, and times out otherwise" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    const start = try c.waitChange(null, .zero);
    try testing.expectEqual(start, try c.waitChange(start, .fromMilliseconds(20)));

    c.setNonce(nonce_a);
    const launched = try c.waitChange(start, .fromSeconds(5));
    try testing.expect(launched > start);

    var page = try testing.io.concurrent(reportLater, .{ &c, testing.io });
    const reported = try c.waitChange(launched, .fromSeconds(5));
    try page.await(testing.io);
    try testing.expect(reported > launched);
    // A report from a stale page changes nothing.
    try testing.expectEqual(.stale, try c.postReport("{\"engine\":\"" ++ nonce_b ++ "\"}"));
    try testing.expectEqual(reported, try c.waitChange(reported, .fromMilliseconds(20)));
}

/// Plays the engine page: reads one command from its stream and answers it with `reply`.
fn fakePage(c: *Channel, stream: *Channel.Stream, reply: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const event = try c.nextEvent(arena.allocator(), stream, .fromSeconds(5));
    const command = std.json.parseFromSliceLeaky(struct { id: u64, method: []const u8, args: std.json.Value }, arena.allocator(), event.command, .{}) catch return error.TestUnexpectedResult;
    try testing.expectEqualStrings("drmProbe", command.method);
    const body = try arena.allocator().print("{{\"id\":{d},{s}}}", .{ command.id, reply });
    try testing.expectEqual(.settled, try c.postResult(body));
}

test "a command reaches the page over its stream and the page's result comes back" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    var stream = c.openStream(&nonce_a).?;
    defer c.closeStream(stream);

    var page = try testing.io.concurrent(fakePage, .{ &c, &stream, "\"ok\":true,\"value\":{\"widevine\":true}" });
    const result = try c.call(testing.allocator, "drmProbe", "[]", .fromSeconds(5));
    try page.await(testing.io);
    defer testing.allocator.free(result.ok);
    try testing.expectEqualStrings("{\"widevine\":true}", result.ok);

    var page2 = try testing.io.concurrent(fakePage, .{ &c, &stream, "\"ok\":false,\"error\":\"NotSupportedError\"" });
    const failed = try c.call(testing.allocator, "drmProbe", "[]", .fromSeconds(5));
    try page2.await(testing.io);
    defer testing.allocator.free(failed.page_error);
    try testing.expectEqualStrings("NotSupportedError", failed.page_error);
}

test "a command fails at once without a page, and times out when the page never answers" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    try testing.expectError(error.NoEnginePage, c.call(testing.allocator, "snapshot", "[]", .fromSeconds(5)));

    const stream = c.openStream(&nonce_a).?;
    defer c.closeStream(stream);
    try testing.expectError(error.Timeout, c.call(testing.allocator, "snapshot", "[]", .fromMilliseconds(50)));
    // A late answer for a command nobody waits for any more is ignored.
    try testing.expectEqual(.unknown, try c.postResult("{\"id\":1,\"ok\":true,\"value\":1}"));
}

fn closeAfter(c: *Channel, io: Io, stream: Channel.Stream) !void {
    try io.sleep(.fromMilliseconds(50), .awake);
    c.closeStream(stream);
}

test "when the last page disconnects, a pending command fails at once instead of at its timeout" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    const stream = c.openStream(&nonce_a).?;

    const start: Io.Clock.Timestamp = .now(testing.io, .awake);
    var closer = try testing.io.concurrent(closeAfter, .{ &c, testing.io, stream });
    try testing.expectError(error.Disconnected, c.call(testing.allocator, "snapshot", "[]", .fromSeconds(30)));
    try closer.await(testing.io);
    try testing.expect(start.untilNow(testing.io).raw.toSeconds() < 5);
}

/// Reads the next command on `stream` and leaves it unanswered.
fn takeCommand(c: *Channel, stream: *Channel.Stream) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try c.nextEvent(arena.allocator(), stream, .fromSeconds(5)) == .command);
}

/// A reload: the old page load takes the command and unloads, the new one opens its stream, and
/// only then does the server notice that `old` is dead.
fn reloadAfterTakingCommand(c: *Channel, old: *Channel.Stream) !Channel.Stream {
    try takeCommand(c, old);
    const new = c.openStream(&nonce_a).?;
    c.closeStream(old.*);
    return new;
}

test "a command stranded on a reload's dead stream fails once that stream closes, though the new page load's stream is open" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    var old = c.openStream(&nonce_a).?;

    const start: Io.Clock.Timestamp = .now(testing.io, .awake);
    var reload = try testing.io.concurrent(reloadAfterTakingCommand, .{ &c, &old });
    const result = c.call(testing.allocator, "drmProbe", "[]", .fromSeconds(30));
    const new = try reload.await(testing.io);
    defer c.closeStream(new);
    try testing.expectError(error.Disconnected, result);
    try testing.expect(start.untilNow(testing.io).raw.toSeconds() < 5);
    // The new page load's stream started past the command, so it can't deliver it.
    try testing.expect(c.connected());
}

/// The old page load takes the command and unloads; once the server has noticed, the new one
/// reads it and answers.
fn oldGoesNewAnswers(c: *Channel, old: *Channel.Stream, new: *Channel.Stream) !void {
    try takeCommand(c, old);
    c.closeStream(old.*);
    try fakePage(c, new, "\"ok\":true,\"value\":{\"widevine\":true}");
}

test "a command queued while a reload's old and new streams are both open waits for the new page load's answer after the old stream closes" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    var old = c.openStream(&nonce_a).?;
    var new = c.openStream(&nonce_a).?;
    defer c.closeStream(new);

    var pages = try testing.io.concurrent(oldGoesNewAnswers, .{ &c, &old, &new });
    const result = c.call(testing.allocator, "drmProbe", "[]", .fromSeconds(5));
    try pages.await(testing.io);
    const answered = try result;
    defer testing.allocator.free(answered.ok);
    try testing.expectEqualStrings("{\"widevine\":true}", answered.ok);
}

test "an idle stream gets a ping, and a relaunch closes the old launch's streams" {
    var c: Channel = .init(testing.io, testing.allocator);
    defer c.deinit();
    c.setNonce(nonce_a);
    var stream = c.openStream(&nonce_a).?;
    defer c.closeStream(stream);

    try testing.expectEqual(.ping, try c.nextEvent(testing.allocator, &stream, .fromMilliseconds(20)));
    c.setNonce(nonce_b);
    try testing.expectEqual(.closed, try c.nextEvent(testing.allocator, &stream, .fromSeconds(5)));
}
