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

test "polling stops at the deadline, not an interval later" {
    const io = testing.io;
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const deadline: Deadline = .after(io, .fromMilliseconds(120));
    var polls: usize = 0;
    while (try deadline.sleep(.fromMilliseconds(50))) polls += 1;
    // 50 + 50 + 20 ms, or one fewer on a busy machine.
    try testing.expect(polls == 2 or polls == 3);
    try testing.expect(deadline.passed());
    const took = start.untilNow(io).raw.toMilliseconds();
    try testing.expect(took >= 120 and took < 1000);
}

test "a passed deadline doesn't sleep at all" {
    const deadline: Deadline = .after(testing.io, .zero);
    try testing.expect(!try deadline.sleep(.fromSeconds(10)));
}
