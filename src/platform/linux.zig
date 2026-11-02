//! Linux-only parts of the POSIX backend: finding processes through `/proc`.
const std = @import("std");
const platform = @import("../platform.zig");
const posix_backend = @import("posix.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const pid_t = std.posix.pid_t;

/// Calls `visit(context, pid, exe, args)` for every process whose executable and command line
/// can be read (other users' processes usually can't).
pub fn forEachProcess(gpa: Allocator, io: Io, context: anytype, comptime visit: fn (@TypeOf(context), pid_t, []const u8, []const []const u8) anyerror!void) !void {
    var proc = try Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();
    var path_buffer: [64]u8 = undefined;
    var exe_buffer: [Io.Dir.max_path_bytes]u8 = undefined;
    while (try it.next(io)) |entry| {
        const pid = std.fmt.parseInt(pid_t, entry.name, 10) catch continue;
        const exe_path = std.mem.print(&path_buffer, "/proc/{d}/exe", .{pid}) catch continue;
        const exe_len = Io.Dir.readLinkAbsolute(io, exe_path, &exe_buffer) catch continue;
        const cmdline_path = std.mem.print(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch continue;
        const cmdline = readProcFileAlloc(gpa, io, cmdline_path) catch continue;
        defer gpa.free(cmdline);
        const args = try posix_backend.splitNul(gpa, cmdline);
        defer gpa.free(args);
        try visit(context, pid, exe_buffer[0..exe_len], args);
    }
}

/// The whole of a `/proc` file. Read as a stream: `/proc` files report size 0, and
/// `Dir.readFileAlloc` stops at the reported size, so it reads nothing from them.
fn readProcFileAlloc(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.ReadFailed => reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |other| other,
    };
}

pub fn processGroupOf(pid: pid_t) ?pid_t {
    const rc = linux.getpgid(pid);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

// ---- Footprint and free memory ----

/// `USER_HZ`, the unit of `/proc/<pid>/stat` times: 100 on every architecture Linux runs on.
const clock_ticks_per_second = 100;

fn readProcFile(io: Io, pid: pid_t, name: []const u8, buffer: []u8) ?[]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.mem.print(&path_buffer, "/proc/{d}/{s}", .{ pid, name }) catch return null;
    return Io.Dir.cwd().readFile(io, path, buffer) catch null;
}

pub fn processTree(gpa: Allocator, io: Io, pgid: pid_t) platform.ProcessTreeError![]pid_t {
    var entries: std.ArrayList(posix_backend.TreeEntry) = .empty;
    defer entries.deinit(gpa);
    var proc = Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return error.CantListProcesses;
    defer proc.close(io);
    var it = proc.iterate();
    var buffer: [1024]u8 = undefined;
    while (it.next(io) catch return error.CantListProcesses) |entry| {
        const pid = std.fmt.parseInt(pid_t, entry.name, 10) catch continue;
        const stat = posix_backend.parseStat(readProcFile(io, pid, "stat", &buffer) orelse continue) orelse continue;
        try entries.append(gpa, .{ .pid = pid, .ppid = stat.ppid, .pgid = stat.pgrp });
    }
    return posix_backend.treeOf(gpa, entries.items, pgid);
}

pub fn processUsage(io: Io, pid: pid_t) platform.ProcessUsageError!platform.ProcessUsage {
    var buffer: [4096]u8 = undefined;
    const stat = posix_backend.parseStat(readProcFile(io, pid, "stat", &buffer) orelse return error.CantReadProcess) orelse return error.CantReadProcess;
    const cpu_ns = stat.cpu_ticks * (std.time.ns_per_s / clock_ticks_per_second);
    // Sandboxed Chrome processes aren't dumpable, so their smaps_rollup can't be read.
    if (readProcFile(io, pid, "smaps_rollup", &buffer)) |rollup| if (posix_backend.parseKbField(rollup, "Pss")) |pss|
        return .{ .memory_bytes = pss, .memory = .pss, .cpu_ns = cpu_ns };
    const status = readProcFile(io, pid, "status", &buffer) orelse return error.CantReadProcess;
    // Kernel threads have no VmRSS.
    return .{ .memory_bytes = posix_backend.parseKbField(status, "VmRSS") orelse 0, .memory = .rss, .cpu_ns = cpu_ns };
}

pub fn availableMemory(io: Io) platform.AvailableMemoryError!u64 {
    var buffer: [8192]u8 = undefined;
    const meminfo = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buffer) catch return error.CantReadMemory;
    return posix_backend.parseKbField(meminfo, "MemAvailable") orelse error.CantReadMemory;
}
