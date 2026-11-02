//! Linux-only parts of the POSIX backend: finding and measuring processes through `/proc`.
const std = @import("std");
const platform = @import("../platform.zig");
const posix_backend = @import("posix.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const pid_t = std.posix.pid_t;

/// The most of a command line we read. A longer one is matched on its first whole arguments:
/// ours name the profile among their first few.
const max_cmdline_bytes = 1 << 20;

/// Calls `visit(context, pid, exe, args)` for every process whose executable and command line
/// can be read (other users' processes usually can't).
pub fn forEachProcess(gpa: Allocator, io: Io, context: anytype, comptime visit: fn (@TypeOf(context), pid_t, []const u8, []const []const u8) anyerror!void) !void {
    var proc = try Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();
    var path_buffer: [proc_path_max]u8 = undefined;
    var exe_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    const cmdline_buffer = try gpa.alloc(u8, max_cmdline_bytes);
    defer gpa.free(cmdline_buffer);
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(pid_t, entry.name, 10) catch continue;
        // Kernel threads have no executable.
        const exe_len = Io.Dir.readLinkAbsolute(io, procPath(&path_buffer, pid, "exe"), &exe_buffer) catch |e|
            if (processUnreadable(e)) continue else return e;
        const cmdline = readCmdline(io, pid, cmdline_buffer) catch |e|
            if (processUnreadable(e)) continue else return e;
        const args = try posix_backend.splitNul(gpa, cmdline);
        defer gpa.free(args);
        try visit(context, pid, exe_buffer[0..exe_len], args);
    }
}

/// Whether `err`, from reading one process's `/proc` files, means only that this process can't
/// be read: it exited (`FileNotFound`) or isn't ours. `Unexpected` counts too: std gives it for
/// the ESRCH of a read once the process is gone, and for any errno std doesn't name, which leaves
/// the process just as unread (Debug builds also print std's trace for it). Any other error
/// (`Canceled`, out of file descriptors) is not about the process.
fn processUnreadable(err: anytype) bool {
    return switch (err) {
        error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.Unexpected => true,
        else => false,
    };
}

/// `/proc/<pid>/cmdline`, read into `buffer`. When it fills the buffer it may have been cut, so
/// only its whole arguments are kept: a cut one might end in our profile path by chance.
fn readCmdline(io: Io, pid: pid_t, buffer: []u8) ProcFile.Error![]u8 {
    var path_buffer: [proc_path_max]u8 = undefined;
    const bytes = try readProcPrefix(io, procPath(&path_buffer, pid, "cmdline"), buffer);
    return if (bytes.len < buffer.len) bytes else wholeArguments(bytes);
}

/// `cmdline` up to and including its last NUL.
fn wholeArguments(cmdline: []u8) []u8 {
    const end = std.mem.findScalarLast(u8, cmdline, 0) orelse return cmdline[0..0];
    return cmdline[0 .. end + 1];
}

pub fn processGroupOf(pid: pid_t) ?pid_t {
    const rc = linux.getpgid(pid);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

// ---- Reading /proc ----

/// A `/proc` file, read as a stream. Every `/proc` read here goes through it: `/proc` files
/// report size 0, and `Dir.readFileAlloc` goes by that size and reads nothing.
const ProcFile = struct {
    reader: Io.File.Reader,

    const Error = Io.File.OpenError || Io.File.Reader.Error;

    /// `buffer` is the reader's; it may be empty.
    fn open(io: Io, path: []const u8, buffer: []u8) Io.File.OpenError!ProcFile {
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        return .{ .reader = file.readerStreaming(io, buffer) };
    }

    fn close(f: *ProcFile, io: Io) void {
        f.reader.file.close(io);
    }

    /// The error behind the reader's `error.ReadFailed`.
    fn readError(f: *const ProcFile) Io.File.Reader.Error {
        return f.reader.err.?;
    }
};

/// The start of a `/proc` file, as much as fits in `buffer`: all of it when shorter.
fn readProcPrefix(io: Io, path: []const u8, buffer: []u8) ProcFile.Error![]u8 {
    var f = try ProcFile.open(io, path, &.{});
    defer f.close(io);
    const n = f.reader.interface.readSliceShort(buffer) catch return f.readError();
    return buffer[0..n];
}

/// The `<name>:   <n> kB` line of a `/proc` file like `status`, `smaps_rollup` or `meminfo`, in
/// bytes; null when there is none. Read a line at a time, so no line before it (`Groups:` in
/// `status` lists every group) can push it out of a buffer.
fn readProcKbField(io: Io, path: []const u8, name: []const u8) ProcFile.Error!?u64 {
    // Longer than any kB line.
    var line_buffer: [256]u8 = undefined;
    var f = try ProcFile.open(io, path, &line_buffer);
    defer f.close(io);
    const r = &f.reader.interface;
    while (true) {
        const line = r.takeDelimiter('\n') catch |e| switch (e) {
            error.ReadFailed => return f.readError(),
            error.StreamTooLong => {
                // Not a kB line: skipped.
                _ = r.discardDelimiterInclusive('\n') catch |skip_error| switch (skip_error) {
                    error.ReadFailed => return f.readError(),
                    error.EndOfStream => return null,
                };
                continue;
            },
        } orelse return null;
        if (posix_backend.parseKbField(line, name)) |bytes| return bytes;
    }
}

/// `/proc/<pid>/stat`; null when malformed. Its start is enough: the fields `parseStat` reads
/// end within about 330 bytes (a name of at most 64 bytes, then numbers of at most 20 digits).
fn readStat(io: Io, pid: pid_t) ProcFile.Error!?posix_backend.Stat {
    var path_buffer: [proc_path_max]u8 = undefined;
    var buffer: [512]u8 = undefined;
    return posix_backend.parseStat(try readProcPrefix(io, procPath(&path_buffer, pid, "stat"), &buffer));
}

/// Room for `/proc/<pid>/<name>` with any pid (at most 11 characters) and the names read here.
const proc_path_max = 64;

fn procPath(buffer: *[proc_path_max]u8, pid: pid_t, name: []const u8) []const u8 {
    return std.mem.print(buffer, "/proc/{d}/{s}", .{ pid, name }) catch unreachable;
}

// ---- Footprint and free memory ----

/// `USER_HZ`, the unit of `/proc/<pid>/stat` times: 100 on every architecture Linux runs on.
const clock_ticks_per_second = 100;

/// The footprint functions' errors can't carry `error.Canceled`: a cancelation is kept for the
/// caller's next cancelation point instead.
fn keepCancel(io: Io, err: anyerror) void {
    if (err == error.Canceled) io.recancel();
}

pub fn processTree(gpa: Allocator, io: Io, pgid: pid_t) platform.ProcessTreeError![]pid_t {
    var entries: std.ArrayList(posix_backend.TreeEntry) = .empty;
    defer entries.deinit(gpa);
    var proc = Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch |e| {
        keepCancel(io, e);
        return error.CantListProcesses;
    };
    defer proc.close(io);
    var it = proc.iterate();
    while (it.next(io) catch |e| {
        keepCancel(io, e);
        return error.CantListProcesses;
    }) |entry| {
        const pid = std.fmt.parseInt(pid_t, entry.name, 10) catch continue;
        const stat = readStat(io, pid) catch |e| {
            if (processUnreadable(e)) continue;
            keepCancel(io, e);
            return error.CantListProcesses;
        } orelse continue;
        try entries.append(gpa, .{ .pid = pid, .ppid = stat.ppid, .pgid = stat.pgrp });
    }
    return posix_backend.treeOf(gpa, entries.items, pgid);
}

pub fn processUsage(io: Io, pid: pid_t) platform.ProcessUsageError!platform.ProcessUsage {
    const stat = readStat(io, pid) catch |e| {
        keepCancel(io, e);
        return error.CantReadProcess;
    } orelse return error.CantReadProcess;
    const cpu_ns = stat.cpu_ticks * (std.time.ns_per_s / clock_ticks_per_second);
    var path_buffer: [proc_path_max]u8 = undefined;
    const pss = readProcKbField(io, procPath(&path_buffer, pid, "smaps_rollup"), "Pss") catch |e| switch (e) {
        error.Canceled => {
            io.recancel();
            return error.CantReadProcess;
        },
        // Sandboxed Chrome processes aren't dumpable, so their smaps_rollup can't be read.
        else => null,
    };
    if (pss) |bytes| return .{ .memory_bytes = bytes, .memory = .pss, .cpu_ns = cpu_ns };
    const rss = readProcKbField(io, procPath(&path_buffer, pid, "status"), "VmRSS") catch |e| {
        keepCancel(io, e);
        return error.CantReadProcess;
    };
    // Kernel threads have no VmRSS.
    return .{ .memory_bytes = rss orelse 0, .memory = .rss, .cpu_ns = cpu_ns };
}

pub fn availableMemory(io: Io) platform.AvailableMemoryError!u64 {
    const available = readProcKbField(io, "/proc/meminfo", "MemAvailable") catch |e| {
        keepCancel(io, e);
        return error.CantReadMemory;
    };
    return available orelse error.CantReadMemory;
}

const testing = std.testing;

test "every process is visited with its executable and command line, this one too" {
    const Visit = struct {
        own: pid_t,
        seen: bool = false,

        fn visit(v: *@This(), pid: pid_t, exe: []const u8, args: []const []const u8) !void {
            if (pid != v.own) return;
            v.seen = true;
            try testing.expect(Io.Dir.path.isAbsolute(exe));
            try testing.expect(args.len > 0 and args[0].len > 0);
        }
    };
    var v: Visit = .{ .own = linux.getpid() };
    try forEachProcess(testing.allocator, testing.io, &v, Visit.visit);
    try testing.expect(v.seen);
}

test "/proc/self/cmdline is the NUL-terminated arguments; cut short, the whole ones" {
    var buffer: [1 << 16]u8 = undefined;
    const cmdline = try readCmdline(testing.io, linux.getpid(), &buffer);
    try testing.expect(cmdline.len > 0 and cmdline.len < buffer.len);
    try testing.expectEqual(@as(u8, 0), cmdline[cmdline.len - 1]);
    const args = try posix_backend.splitNul(testing.allocator, cmdline);
    defer testing.allocator.free(args);
    try testing.expect(args.len > 0 and args[0].len > 0);

    // One byte short: the last argument loses its NUL, so it is left out.
    var short: [1 << 16]u8 = undefined;
    const cut = try readCmdline(testing.io, linux.getpid(), short[0 .. cmdline.len - 1]);
    try testing.expectEqualStrings(cmdline[0 .. cmdline.len - args[args.len - 1].len - 1], cut);
}

test "a command line that fills the buffer keeps only its whole arguments" {
    var cut = "firefox\x00--profile\x00/home/u/.config/am/firefox-pro".*;
    try testing.expectEqualStrings("firefox\x00--profile\x00", wholeArguments(&cut));
    var no_whole = "/usr/lib/firefox/fire".*;
    try testing.expectEqualStrings("", wholeArguments(&no_whole));
}

test "a /proc file reads to its end, or as much as fits" {
    var buffer: [16]u8 = undefined;
    const start = try readProcPrefix(testing.io, "/proc/self/status", &buffer);
    try testing.expectEqual(buffer.len, start.len);
    try testing.expect(std.mem.startsWith(u8, start, "Name:"));
    var big: [1 << 16]u8 = undefined;
    const whole = try readProcPrefix(testing.io, "/proc/self/status", &big);
    try testing.expect(whole.len < big.len);
    try testing.expect(std.mem.endsWith(u8, whole, "\n"));
}

test "a kB field is found after a line longer than any buffer, as VmRSS after many Groups" {
    const io = testing.io;
    try testing.expect((try readProcKbField(io, "/proc/self/status", "VmRSS")).? > 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(testing.allocator);
    try status.appendSlice(testing.allocator, "Name:\tfirefox\nGroups:\t");
    for (0..20_000) |group| try status.print(testing.allocator, "{d} ", .{100_000 + group});
    try status.appendSlice(testing.allocator, "\nVmRSS:\t    5120 kB\nMems_allowed:\t1");
    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = status.items });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try Io.Dir.path.join(testing.allocator, &.{ root, "status" });
    defer testing.allocator.free(path);

    try testing.expectEqual(@as(?u64, 5120 * 1024), try readProcKbField(io, path, "VmRSS"));
    try testing.expectEqual(@as(?u64, null), try readProcKbField(io, path, "VmSwap"));
}

test "a process that isn't there is skipped, a cancelation is not" {
    var buffer: [64]u8 = undefined;
    const gone = readCmdline(testing.io, 999_999_999, &buffer);
    try testing.expectError(error.FileNotFound, gone);
    if (gone) |_| {} else |e| try testing.expect(processUnreadable(e));
    const canceled: ProcFile.Error = error.Canceled;
    try testing.expect(!processUnreadable(canceled));
}

test "this process's stat names its parent and group" {
    const stat = (try readStat(testing.io, linux.getpid())).?;
    try testing.expectEqual(linux.getppid(), stat.ppid);
    try testing.expectEqual(processGroupOf(0).?, stat.pgrp);
}
