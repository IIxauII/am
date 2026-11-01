//! Runs the engine page's tests for `zig build test`: `page-tests <test file> <progress file>`
//! runs node on the test file with its output going straight through, and fails if they fail. Where
//! there is no usable node 24 or newer (none on PATH, or one whose `node --version` fails or
//! answers something else), it says the page tests were skipped and succeeds, so the Zig tests
//! still run on such a machine. A node that doesn't finish in time is stopped, and the step fails
//! naming the test it was in (from the progress file, which the tests keep up to date).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Child = std.process.Child;

/// package.json's `engines`.
const min_node_major = 24;
const version_limit_s = 30;
/// The suite takes well under a second; past this, node is stopped, so `zig build test` never
/// hangs on it.
const run_limit_s = 120;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) std.process.fatal("usage: {s} <test file> <progress file>", .{args[0]});
    const test_file = args[1];
    const progress_file = args[2];

    if (!try usableNode(arena, io)) return;

    Io.Dir.cwd().deleteFile(io, progress_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    };
    try init.environ_map.put("AM_PAGE_TEST_PROGRESS", progress_file);
    // `node <file>`, not `node --test <file>`: --test reads its paths as globs, so a checkout
    // whose path holds `[` or `*` would find no file. The report goes to stderr, which the build
    // system protocol (`--listen=-`) still shows for a failed step; it drops stdout.
    const argv = &.{ "node", "--test-reporter=spec", "--test-reporter-destination=stderr", test_file };
    var child = std.process.spawn(io, .{ .argv = argv, .environ_map = init.environ_map }) catch |err|
        std.process.fatal("page tests: node can't be run: {t}", .{err});
    var deadline: Deadline = .{};
    deadline.arm(io, &child, run_limit_s) catch |err| {
        child.kill(io);
        return err;
    };
    const term = child.wait(io) catch |err| {
        _ = deadline.disarm(io);
        return err;
    };
    if (deadline.disarm(io)) {
        const stopped = "page tests: node didn't finish within {d} s and was stopped";
        const at = Io.Dir.cwd().readFileAlloc(io, progress_file, arena, .limited(4 << 10)) catch "";
        if (at.len == 0) std.process.fatal(stopped ++ ", before the tests reported anything", .{run_limit_s});
        std.process.fatal(stopped ++ "; it was {s}", .{ run_limit_s, at });
    }
    if (!term.success()) std.process.fatal("page tests failed: node {f}", .{term});
}

/// Whether node is there and new enough; if not, says the page tests were skipped. Fails only
/// for what a missing or unusable node doesn't explain (a node that hangs, a spawn that fails
/// otherwise).
fn usableNode(arena: std.mem.Allocator, io: Io) !bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "node", "--version" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return skip("node is not on PATH", .{}),
        else => |e| std.process.fatal("page tests: node --version can't be run: {t}", .{e}),
    };
    var deadline: Deadline = .{};
    deadline.arm(io, &child, version_limit_s) catch |err| {
        child.kill(io);
        return err;
    };
    // The readers are done or cancelled before any kill below, since a kill closes their pipes.
    const output = readVersionOutput(arena, io, &child) catch |err| {
        _ = deadline.disarm(io);
        child.kill(io);
        return err;
    } orelse {
        _ = deadline.disarm(io);
        child.kill(io);
        return skip("node --version printed over 4 KiB to stdout or 64 KiB to stderr", .{});
    };
    const term = child.wait(io) catch |err| {
        _ = deadline.disarm(io);
        return err;
    };
    if (deadline.disarm(io)) std.process.fatal("node --version didn't answer within {d} s and was stopped", .{version_limit_s});

    if (!term.success()) {
        const why = std.mem.sliceTo(std.mem.trim(u8, output.stderr, " \r\n"), '\n');
        return skip("node --version {f}: {s}", .{ term, why });
    }
    const text = std.mem.trim(u8, output.stdout, " \r\n");
    const major_text = std.mem.sliceTo(std.mem.trimStart(u8, text, "v"), '.');
    const major = std.fmt.parseInt(u32, major_text, 10) catch return skip("node --version printed \"{s}\"", .{text});
    if (major < min_node_major) return skip("node {s} is older than {d}", .{ text, min_node_major });
    return true;
}

/// `node --version`'s stdout and stderr, read together so a node that floods one never stalls
/// on the other; null when it printed too much. Its readers are cancelled when it returns.
fn readVersionOutput(arena: std.mem.Allocator, io: Io, child: *Child) !?struct { stdout: []u8, stderr: []u8 } {
    var buffers: Io.File.MultiReader.Buffer(2) = undefined;
    var output: Io.File.MultiReader = undefined;
    output.init(arena, io, buffers.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer output.deinit();
    while (output.fill(64, .none)) |_| {
        if (output.reader(0).bufferedLen() > 4 << 10 or output.reader(1).bufferedLen() > 64 << 10) return null;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try output.checkAnyError();
    return .{
        .stdout = try arena.dupe(u8, output.reader(0).buffered()),
        .stderr = try arena.dupe(u8, output.reader(1).buffered()),
    };
}

/// Stops a child that runs past its time, from a concurrent task, so it also covers a child
/// that closed its output but keeps running.
const Deadline = struct {
    fired: std.atomic.Value(bool) = .init(false),
    future: Io.Future(Io.Cancelable!void) = undefined,

    fn arm(d: *Deadline, io: Io, child: *const Child, seconds: i64) Io.ConcurrentError!void {
        d.future = try io.concurrent(expire, .{ d, io, child.id.?, seconds });
    }

    /// Whether it stopped the child. Call once the child was waited for.
    fn disarm(d: *Deadline, io: Io) bool {
        d.future.cancel(io) catch {};
        return d.fired.load(.acquire);
    }

    fn expire(d: *Deadline, io: Io, id: Child.Id, seconds: i64) Io.Cancelable!void {
        try io.sleep(.fromSeconds(seconds), .awake);
        d.fired.store(true, .release);
        if (builtin.os.tag == .windows) {
            _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1));
        } else {
            std.posix.kill(id, .KILL) catch {};
        }
    }
};

fn skip(comptime reason: []const u8, reason_args: anytype) bool {
    std.debug.print("page tests skipped: " ++ reason ++ "; they need node {d} or newer (npm run test:page)\n", reason_args ++ .{min_node_major});
    return false;
}
