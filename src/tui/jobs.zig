//! A bounded job runner: a fixed number of worker tasks take jobs from a fixed-size queue. The
//! UI thread submits without ever blocking (a full queue refuses the job); a job posts its own
//! result back to the UI as an event. Canceling the group the workers run in stops them, and a
//! job's blocking call then fails with `error.Canceled`. Close the pools before canceling: a job
//! can swallow its cancelation (std.http turns a canceled read into `ReadFailed`), and its
//! worker then finds the queue closed instead of waiting on it forever.
const std = @import("std");

const Io = std.Io;

/// Embed in a job's struct; `run` gets it back with `@fieldParentPtr`.
pub const Task = struct {
    run: *const fn (task: *Task, io: Io) void,
    /// Frees a job that never ran (`Pool.drain`).
    drop: ?*const fn (task: *Task) void = null,
};

pub const Pool = struct {
    queue: Io.Queue(*Task),
    /// Jobs waiting or running.
    busy: std.atomic.Value(u32) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),

    pub fn init(buffer: []*Task) Pool {
        return .{ .queue = .init(buffer) };
    }

    /// Starts `workers` tasks in `group`.
    pub fn start(p: *Pool, io: Io, group: *Io.Group, workers: usize) Io.ConcurrentError!void {
        for (0..workers) |_| try group.concurrent(io, worker, .{ p, io });
    }

    /// Queues `task` unless the queue is full. Never blocks.
    pub fn submit(p: *Pool, io: Io, task: *Task) bool {
        const n = p.queue.put(io, &.{task}, 0) catch return false;
        if (n == 1) _ = p.busy.fetchAdd(1, .monotonic);
        return n == 1;
    }

    /// Refuses new jobs and lets every worker return once its current job is done; jobs still
    /// queued are dropped (for the exit, where nobody reads their results).
    pub fn close(p: *Pool, io: Io) void {
        p.closing.store(true, .release);
        p.queue.close(io);
    }

    /// Once the workers are gone (after `close` and canceling their group): drops the jobs
    /// still queued, which would otherwise leak.
    pub fn drain(p: *Pool, io: Io) void {
        var buf: [16]*Task = undefined;
        while (true) {
            const n = p.queue.getUncancelable(io, &buf, 0) catch return;
            if (n == 0) return;
            for (buf[0..n]) |t| {
                _ = p.busy.fetchSub(1, .monotonic);
                if (t.drop) |drop| drop(t);
            }
        }
    }

    pub fn pending(p: *const Pool) u32 {
        return p.busy.load(.monotonic);
    }

    fn worker(p: *Pool, io: Io) Io.Cancelable!void {
        while (!p.closing.load(.acquire)) {
            const task = p.queue.getOne(io) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                error.Closed => return,
            };
            task.run(task, io);
            _ = p.busy.fetchSub(1, .monotonic);
            // A job that swallowed a cancelation must not keep this worker alive.
            try io.checkCancel();
        }
    }
};

const testing = std.testing;

const Counter = struct {
    task: Task = .{ .run = run, .drop = drop },
    done: *std.atomic.Value(u32),
    dropped: bool = false,

    fn run(t: *Task, io: Io) void {
        _ = io;
        const c: *Counter = @fieldParentPtr("task", t);
        _ = c.done.fetchAdd(1, .monotonic);
    }

    fn drop(t: *Task) void {
        const c: *Counter = @fieldParentPtr("task", t);
        c.dropped = true;
    }
};

test "jobs run on the workers; a full queue refuses instead of blocking; cancel stops the workers" {
    const io = testing.io;
    var buffer: [4]*Task = undefined;
    var pool: Pool = .init(&buffer);
    var done: std.atomic.Value(u32) = .init(0);
    var jobs: [4]Counter = @splat(.{ .done = &done });

    // No workers yet: four fit, the fifth is refused.
    for (&jobs) |*j| try testing.expect(pool.submit(io, &j.task));
    var extra: Counter = .{ .done = &done };
    try testing.expect(!pool.submit(io, &extra.task));

    var group: Io.Group = .init;
    defer group.cancel(io);
    try pool.start(io, &group, 2);
    var waited: usize = 0;
    while (done.load(.monotonic) < 4 and waited < 500) : (waited += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqual(@as(u32, 4), done.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pool.pending());
    group.cancel(io);
}

const Swallower = struct {
    task: Task = .{ .run = run },
    started: *std.atomic.Value(bool),

    /// Waits until canceled and keeps the cancelation to itself, as a job whose HTTP request
    /// got canceled does.
    fn run(t: *Task, io: Io) void {
        const s: *Swallower = @fieldParentPtr("task", t);
        s.started.store(true, .release);
        io.sleep(.fromSeconds(60), .awake) catch {};
    }
};

test "closing the pool ends a worker whose job swallowed the cancelation" {
    const io = testing.io;
    var buffer: [4]*Task = undefined;
    var pool: Pool = .init(&buffer);
    var started: std.atomic.Value(bool) = .init(false);
    var job: Swallower = .{ .started = &started };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try pool.start(io, &group, 1);
    try testing.expect(pool.submit(io, &job.task));
    var waited: usize = 0;
    while (!started.load(.acquire) and waited < 500) : (waited += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expect(started.load(.acquire));
    pool.close(io);
    // Without the close, this would wait forever: the worker would be back in getOne.
    group.cancel(io);
    var refused: Counter = .{ .done = undefined };
    try testing.expect(!pool.submit(io, &refused.task));
}

test "drain drops the jobs a closed pool never ran" {
    const io = testing.io;
    var buffer: [4]*Task = undefined;
    var pool: Pool = .init(&buffer);
    var done: std.atomic.Value(u32) = .init(0);
    var queued: [2]Counter = @splat(.{ .done = &done });
    for (&queued) |*j| try testing.expect(pool.submit(io, &j.task));
    pool.close(io);
    pool.drain(io);
    for (queued) |j| try testing.expect(j.dropped);
    try testing.expectEqual(@as(u32, 0), done.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), pool.pending());
}
