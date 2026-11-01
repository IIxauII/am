//! How the CLI and the background process talk. The CLI sends `POST /cli/<endpoint>` with a JSON
//! body and the `X-AM-Secret` header. The daemon answers 200 and streams JSON lines while the
//! endpoint runs:
//!
//!     {"out":"text for stdout"}      any number, printed as they arrive
//!     {"data":<JSON>}                any number, for programs (the TUI); the CLI skips them
//!     {"exit":0}                     last line: success
//!     {"exit":1,"error":"message"}   last line: failure, printed as `error: message`
//!
//! So the CLI stays thin: it prints what the daemon says and exits with its code. An unknown
//! endpoint gets 404, a missing or wrong secret 403.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const content_type = "application/x-ndjson";

/// The daemon's side: what an endpoint writes to.
pub const Reply = struct {
    arena: Allocator,
    out: *Io.Writer,
    /// Pushes what `out` holds to the CLI right away.
    flushFn: *const fn (ctx: *anyopaque) Io.Writer.Error!void,
    flush_ctx: *anyopaque,
    /// Set by `fail`.
    failure: ?[]const u8 = null,
    /// Carry on when the CLI goes away: what it asked for still happens (the TUI's `queue`,
    /// sent just before it quit), and the lines meant for it are dropped.
    outlives_client: bool = false,
    /// The CLI went away and `outlives_client` is set.
    hung_up: bool = false,
    /// Set by the server once the CLI closed its end of the connection; null when it can't tell.
    client_gone: ?*const std.atomic.Value(bool) = null,
    /// The client the CLI names itself as (`guard.client_header`), if it does.
    client_id: ?[]const u8 = null,
    /// The backend's record of this request (the daemon's `Requests.Ticket`).
    request: ?*anyopaque = null,

    pub const Error = error{
        /// The endpoint failed; the message is in `failure`.
        Failed,
        /// The CLI went away.
        WriteFailed,
    } || Allocator.Error || Io.Cancelable;

    /// Text for the CLI's stdout, sent at once.
    pub fn print(r: *Reply, comptime fmt: []const u8, args: anytype) Error!void {
        if (r.hung_up) return;
        const text = try r.arena.print(fmt, args);
        r.out.print("{{\"out\":{f}}}\n", .{std.json.fmt(text, .{})}) catch |e| return r.hangUp(e);
        r.flushFn(r.flush_ctx) catch |e| return r.hangUp(e);
    }

    /// A write failed: the CLI is gone. An error, unless the reply outlives it.
    fn hangUp(r: *Reply, e: Io.Writer.Error) Error!void {
        if (!r.outlives_client) return e;
        r.hung_up = true;
    }

    /// A machine-readable line: `{"data":<json>}`, sent at once. `json` must be one JSON value;
    /// it goes out verbatim (newlines, which can only be whitespace in valid JSON, become spaces).
    pub fn data(r: *Reply, json: []const u8) Error!void {
        if (r.hung_up) return;
        r.writeData(json) catch |e| return r.hangUp(e);
    }

    fn writeData(r: *Reply, json: []const u8) Io.Writer.Error!void {
        try r.out.writeAll("{\"data\":");
        var rest = json;
        while (std.mem.findAny(u8, rest, "\r\n")) |i| {
            try r.out.writeAll(rest[0..i]);
            try r.out.writeByte(' ');
            rest = rest[i + 1 ..];
        }
        try r.out.writeAll(rest);
        try r.out.writeAll("}\n");
        try r.flushFn(r.flush_ctx);
    }

    /// `✔ label`, `✘ label`, or `? label` when the check couldn't be made, as in the Node POC.
    pub fn check(r: *Reply, ok: ?bool, comptime fmt: []const u8, args: anytype) Error!void {
        const mark = if (ok) |o| (if (o) "✔ " else "✘ ") else "? ";
        try r.print("{s}" ++ fmt ++ "\n", .{mark} ++ args);
    }

    /// A reply nobody reads, for an endpoint's work the daemon does on its own behalf (the
    /// TUI's q stopping a play of its own). `sink` must outlive it.
    pub fn discarding(arena: Allocator, sink: *Io.Writer.Discarding) Reply {
        return .{ .arena = arena, .out = &sink.writer, .flushFn = noFlush, .flush_ctx = sink };
    }

    fn noFlush(_: *anyopaque) Io.Writer.Error!void {}

    /// Ends the endpoint with a failure: the CLI prints `error: <message>` and exits 1.
    pub fn fail(r: *Reply, comptime fmt: []const u8, args: anytype) Error {
        r.failure = try r.arena.print(fmt, args);
        return error.Failed;
    }

    /// Writes the last line for the endpoint's result.
    pub fn finish(r: *Reply, result: anyerror!void) Io.Writer.Error!void {
        if (result) |_| {
            try r.out.writeAll("{\"exit\":0}\n");
        } else |e| {
            const message = switch (e) {
                error.Failed => r.failure orelse "failed",
                // The daemon ends every request when it shuts down.
                error.Canceled => "the background process shut down",
                else => @errorName(e),
            };
            try r.out.print("{{\"exit\":1,\"error\":{f}}}\n", .{std.json.fmt(message, .{})});
        }
        try r.flushFn(r.flush_ctx);
    }
};

pub const ReadError = error{
    /// The stream ended without its last line: the daemon went away mid-request.
    Truncated,
    /// A line that isn't one of ours.
    Malformed,
} || Io.Reader.Error || Io.Writer.Error || Allocator.Error || error{StreamTooLong};

/// The CLI's side: prints the stream's text to `out` and its error to `err`, and returns the
/// exit code. Data lines are skipped.
pub fn readReply(arena: Allocator, in: *Io.Reader, out: *Io.Writer, err: *Io.Writer) ReadError!u8 {
    while (try in.takeDelimiter('\n')) |line| {
        switch (try parseLine(arena, line)) {
            .skip, .data => {},
            .out => |text| {
                try out.writeAll(text);
                try out.flush();
            },
            .exit => |e| {
                if (e.message) |message| try err.print("error: {s}\n", .{message});
                return e.code;
            },
        }
    }
    return error.Truncated;
}

/// One line of a reply.
pub const Line = union(enum) {
    /// Empty.
    skip,
    out: []const u8,
    /// The raw JSON inside `{"data":…}`.
    data: []const u8,
    exit: struct { code: u8, message: ?[]const u8 },
};

const data_prefix = "{\"data\":";

/// Text and messages are allocated in `arena`; `data` slices `line`.
pub fn parseLine(arena: Allocator, line: []const u8) error{ Malformed, OutOfMemory }!Line {
    if (line.len == 0) return .skip;
    // `Reply.data` writes exactly this shape; its JSON is passed on unparsed.
    if (std.mem.startsWith(u8, line, data_prefix) and std.mem.endsWith(u8, line, "}"))
        return .{ .data = line[data_prefix.len .. line.len - 1] };
    const parsed = std.json.parseFromSliceLeaky(struct {
        out: ?[]const u8 = null,
        exit: ?u8 = null,
        @"error": ?[]const u8 = null,
    }, arena, line, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Malformed;
    if (parsed.exit) |code| return .{ .exit = .{ .code = code, .message = parsed.@"error" } };
    if (parsed.out) |text| return .{ .out = text };
    return error.Malformed;
}

/// For tests: an endpoint's reply, read back the way the CLI prints it.
pub const TestReply = struct {
    wire: Io.Writer.Allocating,
    reply: Reply,

    pub const Printed = struct { out: []const u8, err: []const u8, code: u8 };

    pub fn init(t: *TestReply, arena: Allocator) void {
        t.wire = .init(arena);
        t.reply = .{ .arena = arena, .out = &t.wire.writer, .flushFn = Reply.noFlush, .flush_ctx = &t.wire };
    }

    pub fn finish(t: *TestReply, result: anyerror!void) !Printed {
        try t.reply.finish(result);
        var in: Io.Reader = .fixed(t.wire.written());
        var out: Io.Writer.Allocating = .init(t.reply.arena);
        var err: Io.Writer.Allocating = .init(t.reply.arena);
        const code = try readReply(t.reply.arena, &in, &out.writer, &err.writer);
        return .{ .out = out.written(), .err = err.written(), .code = code };
    }
};

const testing = std.testing;

test "a reply that outlives its client drops what it says once the client is gone; others fail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var gone: Io.Writer = .failing;
    var r: Reply = .{ .arena = arena.allocator(), .out = &gone, .flushFn = Reply.noFlush, .flush_ctx = &gone };
    try testing.expectError(error.WriteFailed, r.print("starting the engine…\n", .{}));
    r.outlives_client = true;
    try r.print("starting the engine…\n", .{});
    try testing.expect(r.hung_up);
    try r.data("{}");
}

fn endpoint(r: *Reply, fail: bool) Reply.Error!void {
    try r.print("engine: {s}, pid {d}\n", .{ "chrome", 42 });
    try r.print("✔ codecs: \"probably\"", .{});
    try r.print("\n", .{});
    if (fail) return r.fail("the engine didn't start: {s}", .{"chrome not found"});
}

test "what an endpoint prints reaches the CLI's stdout, and its failure becomes exit 1" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_]bool{ false, true }) |fail| {
        var wire: Io.Writer.Allocating = .init(arena.allocator());
        var dummy: u8 = 0;
        var reply: Reply = .{ .arena = arena.allocator(), .out = &wire.writer, .flushFn = Reply.noFlush, .flush_ctx = &dummy };
        try reply.finish(endpoint(&reply, fail));

        var in: Io.Reader = .fixed(wire.written());
        var out: Io.Writer.Allocating = .init(arena.allocator());
        var err: Io.Writer.Allocating = .init(arena.allocator());
        const code = try readReply(arena.allocator(), &in, &out.writer, &err.writer);
        try testing.expectEqualStrings("engine: chrome, pid 42\n✔ codecs: \"probably\"\n", out.written());
        if (fail) {
            try testing.expectEqual(@as(u8, 1), code);
            try testing.expectEqualStrings("error: the engine didn't start: chrome not found\n", err.written());
        } else {
            try testing.expectEqual(@as(u8, 0), code);
            try testing.expectEqualStrings("", err.written());
        }
    }
}

test "data lines carry their JSON verbatim, and the CLI skips them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var t: TestReply = undefined;
    t.init(arena.allocator());
    try t.reply.print("hi\n", .{});
    try t.reply.data("{\"build\":\"ab\",\n\"x\":[1, 2]}");
    try testing.expectEqualStrings("{\"out\":\"hi\\n\"}\n{\"data\":{\"build\":\"ab\", \"x\":[1, 2]}}\n", t.wire.written());
    try testing.expectEqualStrings("{\"build\":\"ab\", \"x\":[1, 2]}", (try parseLine(arena.allocator(), "{\"data\":{\"build\":\"ab\", \"x\":[1, 2]}}")).data);
    const printed = try t.finish({});
    try testing.expectEqualStrings("hi\n", printed.out);
    try testing.expectEqual(@as(u8, 0), printed.code);
}

test "a stream without its last line is truncated; junk is malformed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    var in: Io.Reader = .fixed("{\"out\":\"half\"}\n");
    try testing.expectError(error.Truncated, readReply(arena.allocator(), &in, &out.writer, &out.writer));
    var junk: Io.Reader = .fixed("<html>\n");
    try testing.expectError(error.Malformed, readReply(arena.allocator(), &junk, &out.writer, &out.writer));
}
