//! Polling until a deadline: `while (try deadline.sleep(interval)) { if (done()) break; }`.
const std = @import("std");

const Io = std.Io;

pub const Deadline = struct {
    io: Io,
    at: Io.Clock.Timestamp,

    pub fn after(io: Io, duration: Io.Duration) Deadline {
        return .{ .io = io, .at = .fromNow(io, .{ .raw = duration, .clock = .awake }) };
    }

    /// `duration` after `start`, a timestamp on the `awake` clock.
    pub fn since(io: Io, start: Io.Timestamp, duration: Io.Duration) Deadline {
        return .{ .io = io, .at = .{ .raw = start.addDuration(duration), .clock = .awake } };
    }

    /// What's left; zero or negative once the deadline has passed.
    pub fn left(d: Deadline) Io.Duration {
        return d.at.durationFromNow(d.io).raw;
    }

    pub fn passed(d: Deadline) bool {
        return d.left().nanoseconds <= 0;
    }

    /// Sleeps for `interval`, or for what's left if that's less. False, without sleeping, once
    /// the deadline has passed.
    pub fn sleep(d: Deadline, interval: Io.Duration) Io.Cancelable!bool {
        const left_now = d.left();
        if (left_now.nanoseconds <= 0) return false;
        try d.io.sleep(.{ .nanoseconds = @min(interval.nanoseconds, left_now.nanoseconds) }, .awake);
        return true;
    }
};

fn ReturnType(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

/// Runs `function(args)` on another thread for at most `timeout`: its result, or null once the
/// time is up (the call is then canceled, and waited for). Without a thread to spare it runs
/// here, unbounded. Whatever `args` point to is used from that thread meanwhile.
pub fn withTimeout(io: Io, timeout: Io.Duration, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) Io.Cancelable!?ReturnType(function) {
    const Race = union(enum) {
        done: ReturnType(function),
        late: Io.Cancelable!void,
    };
    var results: [2]Race = undefined;
    var race: Io.Select(Race) = .init(io, &results);
    race.concurrent(.done, function, args) catch return @call(.auto, function, args);
    defer race.cancelDiscard();
    race.concurrent(.late, Io.sleep, .{ io, timeout, .awake }) catch {};
    return switch (try race.await()) {
        .done => |result| result,
        .late => null,
    };
}

const testing = std.testing;

fn sleepThen(io: Io, duration: Io.Duration, value: u32) Io.Cancelable!u32 {
    try io.sleep(duration, .awake);
    return value;
}

test "withTimeout: the result when it comes in time, null when it doesn't" {
    const io = testing.io;
    try testing.expectEqual(@as(u32, 7), (try withTimeout(io, .fromSeconds(10), sleepThen, .{ io, Io.Duration.fromMilliseconds(10), 7 })).? catch unreachable);
    const start: Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectEqual(null, try withTimeout(io, .fromMilliseconds(100), sleepThen, .{ io, Io.Duration.fromSeconds(60), 7 }));
    try testing.expect(start.untilNow(io).raw.toMilliseconds() < 5000);
}

/// A clock for tests that never waits, so the scheduler can't change what a test sees: a sleep
/// moves it on by what was asked plus `late` (a busy machine waking late) and is noted. Every
/// other `Io` call fails, as in `Io.failing`.
const FakeClock = struct {
    at: Io.Timestamp = .zero,
    late: Io.Duration = .zero,
    slept_buffer: [8]Io.Duration = undefined,
    sleeps: usize = 0,
    /// A clock other than `awake` that was read or slept on; `Deadline` keeps to `awake`.
    other_clock: ?Io.Clock = null,

    const vtable: Io.VTable = fake: {
        var v = Io.failing.vtable.*;
        v.now = now;
        v.sleep = sleep;
        break :fake v;
    };

    fn io(c: *FakeClock) Io {
        return .{ .userdata = c, .vtable = &vtable };
    }

    fn slept(c: *const FakeClock) []const Io.Duration {
        return c.slept_buffer[0..c.sleeps];
    }

    fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
        const c: *FakeClock = @ptrCast(@alignCast(userdata));
        if (clock != .awake) c.other_clock = clock;
        return c.at;
    }

    fn sleep(userdata: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const c: *FakeClock = @ptrCast(@alignCast(userdata));
        // A sleep without end, or more sleeps than any test here expects: polling that doesn't
        // stop fails the test rather than hanging it.
        const duration = timeout.toDurationFromNow(c.io()) orelse return error.Canceled;
        if (c.sleeps == c.slept_buffer.len) return error.Canceled;
        if (duration.clock != .awake) c.other_clock = duration.clock;
        c.slept_buffer[c.sleeps] = duration.raw;
        c.sleeps += 1;
        c.at = c.at.addDuration(duration.raw).addDuration(c.late);
    }
};

test "polling stops at the deadline, not an interval later" {
    var clock: FakeClock = .{};
    const deadline: Deadline = .after(clock.io(), .fromMilliseconds(120));
    var polls: usize = 0;
    while (try deadline.sleep(.fromMilliseconds(50))) polls += 1;
    try testing.expectEqual(@as(usize, 3), polls);
    // The last sleep is only what's left, so polling ends right at the deadline.
    try testing.expectEqualSlices(Io.Duration, &.{ .fromMilliseconds(50), .fromMilliseconds(50), .fromMilliseconds(20) }, clock.slept());
    try testing.expectEqual(Io.Duration.fromMilliseconds(120), Io.Timestamp.zero.durationTo(clock.at));
    try testing.expect(deadline.passed());
    try testing.expectEqual(null, clock.other_clock);
}

test "a late wake, as on a busy machine, shortens the next sleep and adds no poll" {
    // Each sleep ends 30 ms late: at 80 ms, 40 are left; at 150 ms, none.
    var clock: FakeClock = .{ .late = .fromMilliseconds(30) };
    const deadline: Deadline = .after(clock.io(), .fromMilliseconds(120));
    var polls: usize = 0;
    while (try deadline.sleep(.fromMilliseconds(50))) polls += 1;
    try testing.expectEqual(@as(usize, 2), polls);
    try testing.expectEqualSlices(Io.Duration, &.{ .fromMilliseconds(50), .fromMilliseconds(40) }, clock.slept());
}

test "a passed deadline doesn't sleep at all" {
    const deadline: Deadline = .after(testing.io, .zero);
    try testing.expect(!try deadline.sleep(.fromSeconds(10)));
}
