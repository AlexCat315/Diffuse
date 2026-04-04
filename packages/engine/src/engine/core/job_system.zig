const std = @import("std");

pub const JobPriority = enum {
    high,
    normal,
    low,
};

pub const JobStatus = enum(u8) {
    pending,
    running,
    completed,
    failed,
};

const JobState = struct {
    allocator: std.mem.Allocator,
    status: std.atomic.Value(JobStatus),
    ref_count: std.atomic.Value(u32),

    fn create(allocator: std.mem.Allocator) !*JobState {
        const self = try allocator.create(JobState);
        self.* = .{
            .allocator = allocator,
            .status = std.atomic.Value(JobStatus).init(.pending),
            .ref_count = std.atomic.Value(u32).init(1),
        };
        return self;
    }

    fn retain(self: *JobState) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *JobState) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.allocator.destroy(self);
        }
    }
};

pub const JobHandle = struct {
    id: u64,
    state: *JobState,

    pub fn status(self: JobHandle) JobStatus {
        return self.state.status.load(.acquire);
    }

    pub fn isDone(self: JobHandle) bool {
        return switch (self.status()) {
            .completed, .failed => true,
            else => false,
        };
    }

    pub fn wait(self: JobHandle) void {
        while (!self.isDone()) {
            std.Thread.yield() catch {};
        }
    }

    pub fn deinit(self: *JobHandle) void {
        self.state.release();
        self.* = undefined;
    }
};

pub const JobFunc = *const fn (context: ?*anyopaque) void;
pub const JobCleanupFunc = *const fn (context: ?*anyopaque) void;

const Job = struct {
    id: u64,
    func: JobFunc,
    context: ?*anyopaque,
    cleanup: ?JobCleanupFunc,
    priority: JobPriority,
    state: *JobState,
};

pub const JobSystem = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: std.ArrayList(Job),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    running: std.atomic.Value(bool),
    job_id_counter: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, thread_count: ?usize) !*JobSystem {
        const actual_thread_count = thread_count orelse (std.Thread.getCpuCount() catch 4);
        const self = try allocator.create(JobSystem);
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, actual_thread_count),
            .queue = std.ArrayList(Job).empty,
            .mutex = .{},
            .condition = .{},
            .running = std.atomic.Value(bool).init(true),
            .job_id_counter = std.atomic.Value(u64).init(0),
        };

        for (0..actual_thread_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        return self;
    }

    pub fn deinit(self: *JobSystem) void {
        var queued_jobs = std.ArrayList(Job).empty;
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.running.store(false, .release);
            queued_jobs = self.queue;
            self.queue = .empty;
        }
        self.condition.broadcast();

        for (queued_jobs.items) |job| {
            job.state.status.store(.failed, .release);
            if (job.cleanup) |cleanup| {
                cleanup(job.context);
            }
            job.state.release();
        }

        for (self.threads) |thread| {
            thread.join();
        }

        queued_jobs.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    pub fn enqueue(self: *JobSystem, func: JobFunc, context: ?*anyopaque, priority: JobPriority) !JobHandle {
        return self.enqueueWithCleanup(func, context, null, priority);
    }

    pub fn enqueueWithCleanup(
        self: *JobSystem,
        func: JobFunc,
        context: ?*anyopaque,
        cleanup: ?JobCleanupFunc,
        priority: JobPriority,
    ) !JobHandle {
        const id = self.job_id_counter.fetchAdd(1, .monotonic);
        const state = try JobState.create(self.allocator);
        errdefer state.release();

        const job = Job{
            .id = id,
            .func = func,
            .context = context,
            .cleanup = cleanup,
            .priority = priority,
            .state = state,
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(self.allocator, job);
        }

        state.retain();
        self.condition.signal();
        return JobHandle{ .id = id, .state = state };
    }

    fn workerLoop(self: *JobSystem) void {
        while (true) {
            var job: ?Job = null;
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                while (self.queue.items.len == 0) {
                    if (!self.running.load(.acquire)) {
                        return;
                    }
                    self.condition.wait(&self.mutex);
                }

                if (self.queue.items.len > 0) {
                    // Simple FIFO for now, ignoring priority for implementation speed
                    job = self.queue.orderedRemove(0);
                }
            }

            if (job) |j| {
                defer j.state.release();
                j.state.status.store(.running, .release);
                j.func(j.context);
                j.state.status.store(.completed, .release);
            }
        }
    }
};

fn testNoopJob(context: ?*anyopaque) void {
    const executed: *std.atomic.Value(bool) = @ptrCast(@alignCast(context));
    executed.store(true, .release);
}

const TestCleanupContext = struct {
    allocator: std.mem.Allocator,
    cleaned: *std.atomic.Value(bool),
};

fn testCleanupJob(context: ?*anyopaque) void {
    _ = context;
}

fn testCleanupContext(context: ?*anyopaque) void {
    const cleanup_context: *TestCleanupContext = @ptrCast(@alignCast(context));
    cleanup_context.cleaned.store(true, .release);
    cleanup_context.allocator.destroy(cleanup_context);
}

test "JobHandle wait completes for successful jobs" {
    const system = try JobSystem.init(std.testing.allocator, 1);
    defer system.deinit();

    var executed = std.atomic.Value(bool).init(false);
    var handle = try system.enqueue(testNoopJob, &executed, .normal);
    defer handle.deinit();

    handle.wait();

    try std.testing.expect(executed.load(.acquire));
    try std.testing.expectEqual(JobStatus.completed, handle.status());
}

test "JobSystem deinit fails queued jobs and runs cleanup" {
    const system = try JobSystem.init(std.testing.allocator, 0);

    var cleaned = std.atomic.Value(bool).init(false);
    const cleanup_context = try std.testing.allocator.create(TestCleanupContext);
    cleanup_context.* = .{
        .allocator = std.testing.allocator,
        .cleaned = &cleaned,
    };

    var handle = try system.enqueueWithCleanup(testCleanupJob, cleanup_context, testCleanupContext, .normal);
    defer handle.deinit();

    try std.testing.expectEqual(JobStatus.pending, handle.status());

    system.deinit();

    handle.wait();
    try std.testing.expect(cleaned.load(.acquire));
    try std.testing.expectEqual(JobStatus.failed, handle.status());
}
