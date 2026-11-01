//! `am signin`'s side of the daemon. Each `POST /user-token` from the sign-in page records how
//! Apple answered in the `Log`; the `signin` endpoint waits there for results newer than the
//! ones that came before it and reports each.
//!
//! The log is thread-safe: the page's request and the endpoint run in different connection
//! handlers.
const std = @import("std");
const engine = @import("../engine.zig");
const host_mod = @import("host.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Deadline = @import("../deadline.zig").Deadline;
const Host = host_mod.Host;
const Io = std.Io;
const Reply = protocol.Reply;

/// What `am signin` sends. Without `engine`, the CLI has opened the page in the normal browser.
pub const Request = struct {
    /// Open the page in a visible window of this engine's profile.
    engine: ?engine.Kind = null,
};

pub const Options = struct {
    timeout: Io.Duration = .fromSeconds(10 * 60),
    /// How long one wait lasts before the endpoint checks that the CLI is still there.
    poll: Io.Duration = .fromSeconds(15),
};

/// The `signin-page` endpoint: the address of a new sign-in page, for the CLI to open in the
/// user's normal browser before it runs `signin`.
pub fn newPage(host: Host, r: *Reply) Reply.Error!void {
    try r.print("{s}\n", .{try host.signinPage(r.arena)});
}

/// The `signin` endpoint: waits for the sign-in page to post a token Apple accepts, printing a
/// line for each one it doesn't.
pub fn run(host: Host, io: Io, r: *Reply, request: Request, options: Options) Reply.Error!void {
    const a = r.arena;
    // Results from before this request don't count.
    var seen = (try host.waitSignin(a, null, .zero)).count;
    if (request.engine) |kind| {
        var problem: []const u8 = "";
        const window = host.openSigninWindow(a, kind, &problem) catch |e| switch (e) {
            error.EngineFailed => return r.fail("can't open a {t} window: {s}", .{ kind, problem }),
            error.Canceled, error.OutOfMemory => |other| return other,
        };
        try r.print("Opened {s} in a window of the {t} engine profile.\n", .{ window.url, kind });
    }
    try r.print("Click \"Sign in to Apple Music\" and finish Apple's sign-in (waiting up to {d} min)…\n", .{@divFloor(options.timeout.toSeconds(), 60)});

    const deadline: Deadline = .after(io, options.timeout);
    while (!deadline.passed()) {
        const wait = try host.waitSignin(a, seen, .{ .nanoseconds = @min(deadline.left().nanoseconds, options.poll.nanoseconds) });
        seen = wait.count;
        if (wait.result) |json| {
            const result = std.json.parseFromSliceLeaky(struct {
                ok: bool = false,
                status: u16 = 0,
                storefront: ?[]const u8 = null,
                @"error": ?[]const u8 = null,
            }, a, json, .{ .ignore_unknown_fields = true }) catch return r.fail("unreadable sign-in result: {s}", .{json});
            if (result.ok) {
                try r.print("✔ signed in (storefront {s}); Music User Token saved to {s}\n", .{ result.storefront orelse "?", try host.userTokenPath(a) });
                return;
            }
            if (result.status == 401)
                try r.print("✘ Apple refused the developer token (HTTP 401): check it with `am token`, then click the button again\n", .{})
            else if (result.status != 0)
                try r.print("✘ Apple rejected that token (HTTP {d}); click the button again\n", .{result.status})
            else
                try r.print("✘ the token couldn't be checked: {s}; fix that and click the button again\n", .{result.@"error" orelse "unknown error"});
        } else {
            // Nothing new: an empty line fails once the CLI has gone (Ctrl-C), ending the wait.
            try r.print("", .{});
        }
        if (request.engine != null and !wait.window_open) return r.fail("the sign-in window was closed before sign-in finished", .{});
    }
    return r.fail("no successful sign-in within {d} minutes", .{@divFloor(options.timeout.toSeconds(), 60)});
}

pub const Log = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    changed: Io.Condition = .init,
    /// How many results were recorded.
    count: u64 = 0,
    /// The latest result's JSON (`{ok, status, storefront}` or `{ok, status, error}`).
    last: ?[]u8 = null,

    pub fn init(io: Io, gpa: Allocator) Log {
        return .{ .io = io, .gpa = gpa };
    }

    pub fn deinit(l: *Log) void {
        if (l.last) |last| l.gpa.free(last);
        l.* = undefined;
    }

    pub fn record(l: *Log, result_json: []const u8) Allocator.Error!void {
        const copy = try l.gpa.dupe(u8, result_json);
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        if (l.last) |last| l.gpa.free(last);
        l.last = copy;
        l.count += 1;
        l.changed.broadcast(l.io);
    }

    pub const Seen = struct {
        count: u64,
        /// The latest result if it is newer than `after`; copied into the arena.
        result: ?[]const u8,
    };

    /// Waits up to `timeout` for a result newer than `after`. With `after` null, answers at once
    /// with the current count, so a CLI can start waiting from there.
    pub fn wait(l: *Log, arena: Allocator, after: ?u64, timeout: Io.Duration) (Allocator.Error || Io.Cancelable)!Seen {
        const deadline: Io.Clock.Timestamp = .fromNow(l.io, .{ .raw = timeout, .clock = .awake });
        try l.mutex.lock(l.io);
        defer l.mutex.unlock(l.io);
        const seen = after orelse return .{ .count = l.count, .result = null };
        while (l.count <= seen) {
            l.changed.waitTimeout(l.io, &l.mutex, .{ .deadline = deadline }) catch |e| switch (e) {
                error.Timeout => if (deadline.durationFromNow(l.io).raw.nanoseconds <= 0) return .{ .count = l.count, .result = null },
                error.Canceled => return error.Canceled,
            };
        }
        return .{ .count = l.count, .result = try arena.dupe(u8, l.last.?) };
    }
};

const testing = std.testing;

fn recordLater(l: *Log, io: Io, json: []const u8) !void {
    try io.sleep(.fromMilliseconds(50), .awake);
    try l.record(json);
}

test "a waiting CLI gets the next result as soon as the page posts it, and only newer ones" {
    var l: Log = .init(testing.io, testing.allocator);
    defer l.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const start = try l.wait(a, null, .fromSeconds(5));
    try testing.expectEqual(Log.Seen{ .count = 0, .result = null }, start);
    // Nothing new: the wait times out with no result.
    try testing.expectEqual(Log.Seen{ .count = 0, .result = null }, try l.wait(a, 0, .fromMilliseconds(20)));

    var page = try testing.io.concurrent(recordLater, .{ &l, testing.io, "{\"ok\":false,\"status\":401}" });
    const rejected = try l.wait(a, 0, .fromSeconds(5));
    try page.await(testing.io);
    try testing.expectEqual(@as(u64, 1), rejected.count);
    try testing.expectEqualStrings("{\"ok\":false,\"status\":401}", rejected.result.?);

    try l.record("{\"ok\":true,\"status\":200,\"storefront\":\"gb\"}");
    const accepted = try l.wait(a, 1, .fromSeconds(5));
    try testing.expectEqualStrings("{\"ok\":true,\"status\":200,\"storefront\":\"gb\"}", accepted.result.?);
    // A CLI that starts now doesn't see the old results.
    try testing.expectEqual(Log.Seen{ .count = 2, .result = null }, try l.wait(a, null, .fromSeconds(5)));
}

const Fake = host_mod.Fake;

fn runSignin(f: *Fake, arena: Allocator, request: Request, options: Options) !protocol.TestReply.Printed {
    var t: protocol.TestReply = undefined;
    t.init(arena);
    return t.finish(run(f.host(), testing.io, &t.reply, request, options));
}

test "signin keeps waiting through rejected tokens and succeeds on the next" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{
        .arena = arena.allocator(),
        .signin_waits = &.{
            // Three results from earlier sign-ins: not this one's.
            .{ .count = 3, .result = null, .window_open = false },
            .{ .count = 3, .result = null, .window_open = false },
            .{ .count = 4, .result = "{\"ok\":false,\"status\":403,\"storefront\":null}", .window_open = false },
            .{ .count = 5, .result = "{\"ok\":false,\"status\":401,\"storefront\":null}", .window_open = false },
            .{ .count = 6, .result = "{\"ok\":false,\"status\":0,\"error\":\"developer token missing: run am token --key-stdin\"}", .window_open = false },
            .{ .count = 7, .result = "{\"ok\":true,\"status\":200,\"storefront\":\"gb\"}", .window_open = false },
        },
    };
    const printed = try runSignin(&f, arena.allocator(), .{}, .{});
    try testing.expectEqual(@as(u8, 0), printed.code);
    try testing.expectEqualStrings(
        \\Click "Sign in to Apple Music" and finish Apple's sign-in (waiting up to 10 min)…
        \\✘ Apple rejected that token (HTTP 403); click the button again
        \\✘ Apple refused the developer token (HTTP 401): check it with `am token`, then click the button again
        \\✘ the token couldn't be checked: developer token missing: run am token --key-stdin; fix that and click the button again
        \\✔ signed in (storefront gb); Music User Token saved to /home/u/.config/am/music-user-token
        \\
    , printed.out);
}

test "signin gives up after its timeout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .arena = arena.allocator() };
    const printed = try runSignin(&f, arena.allocator(), .{}, .{ .timeout = .fromMilliseconds(30), .poll = .fromMilliseconds(5) });
    try testing.expectEqual(@as(u8, 1), printed.code);
    try testing.expectEqualStrings("error: no successful sign-in within 0 minutes\n", printed.err);
}

test "signin --engine opens a window of that profile and stops when it is closed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var f: Fake = .{ .arena = arena.allocator(), .signin_waits = &.{
        .{ .count = 0, .result = null, .window_open = false },
        .{ .count = 0, .result = null, .window_open = true },
        .{ .count = 0, .result = null, .window_open = false },
    } };
    const printed = try runSignin(&f, arena.allocator(), .{ .engine = .firefox }, .{});
    try testing.expectEqual(engine.Kind.firefox, f.window_opened.?);
    try testing.expect(std.mem.startsWith(u8, printed.out, "Opened http://localhost:47823/?signin&engine=5555 in a window of the firefox engine profile.\n"));
    try testing.expectEqualStrings("error: the sign-in window was closed before sign-in finished\n", printed.err);
}
