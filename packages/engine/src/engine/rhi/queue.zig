const command_buffer = @import("command_buffer.zig");

pub const QueueClass = enum {
    graphics,
    compute,
    transfer,
};

pub const TimelineSemaphore = struct {
    id: u32,
    value: u64,
};

pub const SubmitDesc = struct {
    wait_semaphores: []const TimelineSemaphore = &.{},
    signal_semaphores: []const TimelineSemaphore = &.{},
};

pub const SubmitFn = *const fn (ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) anyerror!void;

pub const Queue = struct {
    class: QueueClass,
    ctx: *anyopaque,
    submit_fn: SubmitFn,

    pub fn submit(self: Queue, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) !void {
        return self.submit_fn(self.ctx, cmd, desc);
    }
};
