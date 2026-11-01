//! What the background process and the engine cost: process count, memory and CPU, measured
//! over a short window. `am status` and `am play`'s verdict print it.
const std = @import("std");
const platform = @import("platform.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Footprint = struct {
    processes: u32 = 0,
    memory_bytes: u64 = 0,
    /// How the processes were measured; `.pss` may include some measured by RSS.
    memory: platform.MemoryMeasure = .rss,
    /// With `.pss`: processes whose PSS couldn't be read (sandboxed Chrome), counted by RSS.
    rss_processes: u32 = 0,
    /// Of one core, over the measuring window.
    cpu_percent: f64 = 0,

    /// `8 processes, 432 MiB PSS, CPU 17.0% of one core`
    pub fn format(f: Footprint, w: *Io.Writer) Io.Writer.Error!void {
        const mib = @as(f64, @floatFromInt(f.memory_bytes)) / (1024 * 1024);
        try w.print("{d} process{s}, ", .{ f.processes, if (f.processes == 1) "" else "es" });
        if (mib < 100) try w.print("{d:.1} MiB", .{mib}) else try w.print("{d:.0} MiB", .{mib});
        switch (f.memory) {
            .pss => if (f.rss_processes > 0)
                try w.print(" (PSS; RSS for {d} sandboxed process{s}, which over-counts shared pages)", .{ f.rss_processes, if (f.rss_processes == 1) "" else "es" })
            else
                try w.writeAll(" PSS"),
            .rss => try w.writeAll(" RSS (over-counts shared pages)"),
            .phys_footprint => try w.writeAll(" phys_footprint"),
            .private_working_set => try w.writeAll(" private working set"),
        }
        try w.print(", CPU {d:.1}% of one core", .{f.cpu_percent});
    }
};

pub const Sample = struct {
    pid: platform.ProcessId,
    usage: platform.ProcessUsage,
};

/// The usage of each process that can be read; the others (exited meanwhile) are left out.
/// Caller frees.
pub fn sample(gpa: Allocator, io: Io, pids: []const platform.ProcessId) Allocator.Error![]Sample {
    var samples: std.ArrayList(Sample) = .empty;
    errdefer samples.deinit(gpa);
    for (pids) |pid| {
        const usage = platform.processUsage(io, pid) catch continue;
        try samples.append(gpa, .{ .pid = pid, .usage = usage });
    }
    return samples.toOwnedSlice(gpa);
}

/// Memory from `after`; CPU from what each process used between the samples, `elapsed` apart.
pub fn combine(before: []const Sample, after: []const Sample, elapsed: Io.Duration) Footprint {
    var f: Footprint = .{ .processes = @intCast(after.len) };
    var pss = false;
    var footprint = false;
    var private = false;
    var rss: u32 = 0;
    var cpu_ns: u64 = 0;
    for (after) |a| {
        f.memory_bytes += a.usage.memory_bytes;
        switch (a.usage.memory) {
            .pss => pss = true,
            .rss => rss += 1,
            .phys_footprint => footprint = true,
            .private_working_set => private = true,
        }
        for (before) |b| if (b.pid == a.pid) {
            cpu_ns += a.usage.cpu_ns -| b.usage.cpu_ns;
        };
    }
    f.memory = if (footprint) .phys_footprint else if (private) .private_working_set else if (pss) .pss else .rss;
    f.rss_processes = if (f.memory == .pss) rss else 0;
    if (elapsed.nanoseconds > 0)
        f.cpu_percent = @as(f64, @floatFromInt(cpu_ns)) / @as(f64, @floatFromInt(elapsed.nanoseconds)) * 100;
    return f;
}

/// Samples `pids` twice, `window` apart.
pub fn measure(gpa: Allocator, io: Io, pids: []const platform.ProcessId, window: Io.Duration) (Allocator.Error || Io.Cancelable)!Footprint {
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const before = try sample(gpa, io, pids);
    defer gpa.free(before);
    try io.sleep(window, .awake);
    const after = try sample(gpa, io, pids);
    defer gpa.free(after);
    return combine(before, after, start.untilNow(io).raw);
}

const testing = std.testing;

fn fakeUsage(memory_mib: u64, memory: platform.MemoryMeasure, cpu_ms: u64) platform.ProcessUsage {
    return .{ .memory_bytes = memory_mib * 1024 * 1024, .memory = memory, .cpu_ns = cpu_ms * std.time.ns_per_ms };
}

test "a tree's footprint: memory summed, CPU per process over the window, gone and new processes handled" {
    const before = [_]Sample{
        .{ .pid = 1, .usage = fakeUsage(200, .pss, 1000) },
        .{ .pid = 2, .usage = fakeUsage(100, .pss, 500) },
        .{ .pid = 3, .usage = fakeUsage(50, .pss, 100) }, // exits during the window
    };
    const after = [_]Sample{
        .{ .pid = 1, .usage = fakeUsage(210, .pss, 1100) },
        .{ .pid = 2, .usage = fakeUsage(100, .pss, 570) },
        .{ .pid = 4, .usage = fakeUsage(30, .rss, 900) }, // new: its CPU so far isn't in the window
    };
    const f = combine(&before, &after, .fromSeconds(1));
    try testing.expectEqual(@as(u32, 3), f.processes);
    try testing.expectEqual(@as(u64, 340 * 1024 * 1024), f.memory_bytes);
    try testing.expectEqual(platform.MemoryMeasure.pss, f.memory);
    try testing.expectEqual(@as(u32, 1), f.rss_processes);
    try testing.expectApproxEqAbs(@as(f64, 17.0), f.cpu_percent, 0.001);
}

test "Windows' private working set names the footprint, even with some processes measured by RSS" {
    const after = [_]Sample{
        .{ .pid = 1, .usage = fakeUsage(200, .private_working_set, 0) },
        .{ .pid = 2, .usage = fakeUsage(50, .rss, 0) },
    };
    const f = combine(&.{}, &after, .fromSeconds(1));
    try testing.expectEqual(platform.MemoryMeasure.private_working_set, f.memory);
    try testing.expectEqual(@as(u64, 250 * 1024 * 1024), f.memory_bytes);
}

test "a footprint line names how memory was measured" {
    var buf: [400]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}\n", .{Footprint{ .processes = 8, .memory_bytes = 432 * 1024 * 1024, .memory = .pss, .cpu_percent = 17 }});
    try w.print("{f}\n", .{Footprint{ .processes = 9, .memory_bytes = 500 * 1024 * 1024, .memory = .pss, .rss_processes = 3, .cpu_percent = 16.55 }});
    try w.print("{f}\n", .{Footprint{ .processes = 1, .memory_bytes = 7 * 1024 * 1024 + 300 * 1024, .memory = .phys_footprint, .cpu_percent = 0.04 }});
    try w.print("{f}\n", .{Footprint{ .processes = 2, .memory_bytes = 600 * 1024 * 1024, .memory = .rss, .cpu_percent = 3 }});
    try w.print("{f}\n", .{Footprint{ .processes = 4, .memory_bytes = 300 * 1024 * 1024, .memory = .private_working_set, .cpu_percent = 2 }});
    try testing.expectEqualStrings(
        \\8 processes, 432 MiB PSS, CPU 17.0% of one core
        \\9 processes, 500 MiB (PSS; RSS for 3 sandboxed processes, which over-counts shared pages), CPU 16.6% of one core
        \\1 process, 7.3 MiB phys_footprint, CPU 0.0% of one core
        \\2 processes, 600 MiB RSS (over-counts shared pages), CPU 3.0% of one core
        \\4 processes, 300 MiB private working set, CPU 2.0% of one core
        \\
    , w.buffered());
}

test "measuring this process gives one process with memory" {
    const f = try measure(testing.allocator, testing.io, &.{ platform.currentPid(), 999_999_999 }, .fromMilliseconds(50));
    try testing.expectEqual(@as(u32, 1), f.processes);
    try testing.expect(f.memory_bytes > 0);
}
