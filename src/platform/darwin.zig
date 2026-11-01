//! macOS-only parts of the POSIX backend: finding and measuring processes through libproc and
//! `sysctl(KERN_PROCARGS2)`, free memory through Mach. libproc is part of libSystem but not
//! bound by std.
const std = @import("std");
const platform = @import("../platform.zig");
const posix_backend = @import("posix.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const pid_t = std.posix.pid_t;

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buffer: *anyopaque, buffersize: u32) c_int;
extern "c" fn getpgid(pid: pid_t) pid_t;
extern "c" fn proc_listpgrppids(pgrpid: pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_listchildpids(ppid: pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV0) c_int;
extern "c" fn host_statistics64(host: std.c.mach_port_t, flavor: c_int, info: *VmStatistics64, count: *std.c.natural_t) std.c.kern_return_t;

const proc_pidpath_maxsize = 4 * 1024;

/// Calls `visit(context, pid, exe, args)` for every process whose executable and arguments can
/// be read (other users' processes usually can't).
pub fn forEachProcess(gpa: Allocator, io: Io, context: anytype, comptime visit: fn (@TypeOf(context), pid_t, []const u8, []const []const u8) anyerror!void) !void {
    _ = io;
    const count = proc_listallpids(null, 0);
    if (count <= 0) return error.Unexpected;
    // Room for processes started between the two calls.
    const pids = try gpa.alloc(c_int, @as(usize, @intCast(count)) + 64);
    defer gpa.free(pids);
    const n = proc_listallpids(pids.ptr, @intCast(pids.len * @sizeOf(c_int)));
    if (n <= 0) return error.Unexpected;

    var argmax: c_int = 0;
    var argmax_len: usize = @sizeOf(c_int);
    try std.posix.sysctl(&.{ std.c.CTL.KERN, std.c.KERN.ARGMAX }, &argmax, &argmax_len, null, 0);
    const procargs = try gpa.alloc(u8, @intCast(argmax));
    defer gpa.free(procargs);

    var exe_buffer: [proc_pidpath_maxsize]u8 = undefined;
    for (pids[0..@intCast(n)]) |pid| {
        if (pid <= 0) continue;
        const exe_len = proc_pidpath(pid, &exe_buffer, exe_buffer.len);
        if (exe_len <= 0) continue;
        var len: usize = procargs.len;
        // Called directly: std.posix.sysctl dumps a stack trace on the EINVAL that processes we
        // may not inspect (other users', system ones) answer with.
        var name = [_]c_int{ std.c.CTL.KERN, std.c.KERN.PROCARGS2, pid };
        if (std.c.sysctl(&name, name.len, procargs.ptr, &len, null, 0) != 0) continue;
        const args = parseProcArgs2(gpa, procargs[0..len]) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Malformed => continue,
        };
        defer gpa.free(args);
        try visit(context, pid, exe_buffer[0..@intCast(exe_len)], args);
    }
}

/// `KERN_PROCARGS2` is `argc` (an int), the exec path, NUL padding, then `argc` NUL-terminated
/// arguments (followed by the environment, which we skip). Caller frees the returned slice;
/// its strings point into `buffer`.
pub fn parseProcArgs2(gpa: Allocator, buffer: []const u8) error{ OutOfMemory, Malformed }![]const []const u8 {
    if (buffer.len < @sizeOf(c_int)) return error.Malformed;
    const argc = std.mem.readInt(c_int, buffer[0..@sizeOf(c_int)], .native);
    if (argc < 0) return error.Malformed;
    var rest = buffer[@sizeOf(c_int)..];
    const exec_end = std.mem.findScalar(u8, rest, 0) orelse return error.Malformed;
    rest = rest[exec_end..];
    while (rest.len > 0 and rest[0] == 0) rest = rest[1..];

    const args = try gpa.alloc([]const u8, @intCast(argc));
    errdefer gpa.free(args);
    for (args) |*arg| {
        const end = std.mem.findScalar(u8, rest, 0) orelse return error.Malformed;
        arg.* = rest[0..end];
        rest = rest[end + 1 ..];
    }
    return args;
}

pub fn processGroupOf(pid: pid_t) ?pid_t {
    const pgid = getpgid(pid);
    return if (pgid < 0) null else pgid;
}

// ---- Footprint and free memory ----

/// The most processes one call lists; an engine has about ten.
const max_listed = 1024;

/// The group's members, then breadth-first everything they started.
pub fn processTree(gpa: Allocator, io: Io, pgid: pid_t) platform.ProcessTreeError![]pid_t {
    _ = io;
    var tree: std.ArrayList(pid_t) = .empty;
    errdefer tree.deinit(gpa);
    var listed: [max_listed]pid_t = undefined;
    const members = proc_listpgrppids(pgid, &listed, @sizeOf(@TypeOf(listed)));
    if (members < 0) return error.CantListProcesses;
    try tree.appendSlice(gpa, listed[0..@intCast(members)]);
    var next: usize = 0;
    while (next < tree.items.len) : (next += 1) {
        const children = proc_listchildpids(tree.items[next], &listed, @sizeOf(@TypeOf(listed)));
        if (children <= 0) continue;
        for (listed[0..@intCast(children)]) |child| {
            if (child > 0 and std.mem.findScalar(pid_t, tree.items, child) == null) try tree.append(gpa, child);
        }
    }
    return tree.toOwnedSlice(gpa);
}

/// `struct rusage_info_v0` from `<sys/resource.h>`. Times are in Mach absolute time units.
const RusageInfoV0 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
};
const rusage_info_v0 = 0;

pub fn processUsage(io: Io, pid: pid_t) platform.ProcessUsageError!platform.ProcessUsage {
    _ = io;
    var info: RusageInfoV0 = undefined;
    if (proc_pid_rusage(pid, rusage_info_v0, &info) != 0) return error.CantReadProcess;
    // Mach time units are nanoseconds on Intel, 125/3 ns on Apple silicon.
    var timebase: std.c.mach_timebase_info_data = undefined;
    if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.CantReadProcess;
    const ticks: u128 = @as(u128, info.user_time) + info.system_time;
    return .{
        .memory_bytes = info.phys_footprint,
        .memory = .phys_footprint,
        .cpu_ns = @intCast(ticks * timebase.numer / timebase.denom),
    };
}

/// `struct vm_statistics64` from `<mach/vm_statistics.h>`, up to the fields we read.
/// `HOST_VM_INFO64_COUNT` asks for the whole structure (160 bytes), so the rest is padding.
const VmStatistics64 = extern struct {
    free_count: std.c.natural_t,
    active_count: std.c.natural_t,
    inactive_count: std.c.natural_t,
    rest: [148]u8 align(4),
};
const host_vm_info64 = 4;

/// Free plus inactive pages, as psutil counts "available" on macOS. Free pages include the
/// speculative ones; inactive pages are reclaimed before anything is compressed or swapped.
pub fn availableMemory(io: Io) platform.AvailableMemoryError!u64 {
    _ = io;
    var stats: VmStatistics64 align(8) = undefined;
    var count: std.c.natural_t = @sizeOf(VmStatistics64) / @sizeOf(std.c.integer_t);
    if (host_statistics64(std.c.mach_host_self(), host_vm_info64, &stats, &count) != 0) return error.CantReadMemory;
    return (@as(u64, stats.free_count) + stats.inactive_count) * std.heap.pageSize();
}

const testing = std.testing;

test "KERN_PROCARGS2 is argc, the exec path, padding, then the arguments" {
    const argc: c_int = 3;
    const buffer = std.mem.asBytes(&argc) ++ "/Applications/X.app/Contents/MacOS/X\x00\x00\x00\x00" ++
        "X\x00--user-data-dir=/u/.config/am/chrome-profile\x00http://localhost:47823/\x00HOME=/u\x00";
    const args = try parseProcArgs2(testing.allocator, buffer);
    defer testing.allocator.free(args);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "X", "--user-data-dir=/u/.config/am/chrome-profile", "http://localhost:47823/" }), args);

    try testing.expectError(error.Malformed, parseProcArgs2(testing.allocator, "ab"));
    const two: c_int = 2;
    try testing.expectError(error.Malformed, parseProcArgs2(testing.allocator, std.mem.asBytes(&two) ++ "/bin/x\x00x\x00"));
}

test "the Mach structures match the C headers" {
    // Measured with clang against the macOS SDK.
    try testing.expectEqual(96, @sizeOf(RusageInfoV0));
    try testing.expectEqual(72, @offsetOf(RusageInfoV0, "phys_footprint"));
    try testing.expectEqual(160, @sizeOf(VmStatistics64));
    try testing.expectEqual(8, @offsetOf(VmStatistics64, "inactive_count"));
}
