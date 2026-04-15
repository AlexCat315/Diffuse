const std = @import("std");
const rhi = @import("../rhi.zig");
const command_buffer = @import("../command_buffer.zig");
const queue_mod = @import("../queue.zig");

pub const MetalBackend = struct {
    allocator: std.mem.Allocator,
    next_swapchain_id: u32 = 1,
    next_buffer_id: u32 = 1,
    next_texture_id: u32 = 1,
    next_shader_module_id: u32 = 1,
    next_graphics_pipeline_id: u32 = 1,
    next_compute_pipeline_id: u32 = 1,
    next_sampler_id: u32 = 1,
    resource_state_bits: std.AutoHashMap(rhi.ResourceRef, u32),
    resource_owner_queue: std.AutoHashMap(rhi.ResourceRef, rhi.QueueClass),
    pending_transfers: std.AutoHashMap(rhi.ResourceRef, PendingTransfer),
    semaphore_values: std.AutoHashMap(u32, u64),
    last_submit_queue: ?rhi.QueueClass = null,
    submit_queue_history: std.ArrayList(rhi.QueueClass),
    submit_records: std.ArrayList(SubmitRecord),

    pub fn init(allocator: std.mem.Allocator) MetalBackend {
        return .{
            .allocator = allocator,
            .resource_state_bits = std.AutoHashMap(rhi.ResourceRef, u32).init(allocator),
            .resource_owner_queue = std.AutoHashMap(rhi.ResourceRef, rhi.QueueClass).init(allocator),
            .pending_transfers = std.AutoHashMap(rhi.ResourceRef, PendingTransfer).init(allocator),
            .semaphore_values = std.AutoHashMap(u32, u64).init(allocator),
            .submit_queue_history = .empty,
            .submit_records = .empty,
        };
    }

    pub fn deinit(self: *MetalBackend) void {
        self.submit_records.deinit(self.allocator);
        self.submit_queue_history.deinit(self.allocator);
        self.semaphore_values.deinit();
        self.pending_transfers.deinit();
        self.resource_state_bits.deinit();
        self.resource_owner_queue.deinit();
        self.* = undefined;
    }

    pub fn createDevice(self: *MetalBackend) rhi.Device {
        return rhi.Device.initWithCache(
            @ptrCast(self),
            &device_vtable,
            .{
                .compute = true,
                .ray_tracing = true,
                .indirect_draw = true,
                .mesh_shaders = false,
                .texture_3d = true,
                .texture_cube_native = true,
                .max_queues = .{ 1, 1, 1 },
            },
            self.allocator,
        );
    }

    pub fn translateAndSubmit(self: *MetalBackend, queue_class: rhi.QueueClass, soft_buf: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
        self.last_submit_queue = queue_class;
        try self.submit_queue_history.append(self.allocator, queue_class);
        try self.submit_records.append(self.allocator, .{
            .queue_class = queue_class,
            .wait_count = desc.wait_semaphores.len,
            .signal_count = desc.signal_semaphores.len,
        });

        for (desc.wait_semaphores) |wait| {
            const signaled = self.semaphore_values.get(wait.id) orelse 0;
            if (signaled < wait.value) return error.SubmitFailed;
        }

        var decoder = soft_buf.decoder();
        var inside_pass = false;
        while (try decoder.next()) |cmd| {
            switch (cmd) {
                .begin_render_pass => inside_pass = true,
                .end_render_pass => inside_pass = false,
                .begin_compute_pass => inside_pass = true,
                .end_compute_pass => inside_pass = false,
                .begin_copy_pass => inside_pass = true,
                .end_copy_pass => inside_pass = false,
                .set_binding_set => {},
                .set_vertex_buffer => {},
                .set_index_buffer => {},
                .set_pipeline => {},
                .draw_indexed => {},
                .draw_indirect => {},
                .dispatch => {},
                .dispatch_indirect => {},
                .draw => {},
                .push_uniform => {},
                .set_viewport => {},
                .set_scissor => {},
                .pipeline_barrier => |b| {
                    const pass_scope = std.meta.intToEnum(rhi.BarrierPassScope, b.pass_scope) catch return error.SubmitFailed;
                    if (inside_pass and pass_scope != .outside_pass) {
                        return error.SubmitFailed;
                    }

                    const resource = resourceRefFromBarrier(b) catch return error.SubmitFailed;
                    const prev_state = self.resource_state_bits.get(resource) orelse 0;
                    const src_q: rhi.QueueClass = @enumFromInt(@as(u8, b.src_queue));
                    const dst_q: rhi.QueueClass = @enumFromInt(@as(u8, b.dst_queue));
                    const sync_action = std.meta.intToEnum(rhi.BarrierSyncAction, b.sync_action) catch return error.SubmitFailed;

                    switch (sync_action) {
                        .full => {
                            if (prev_state != 0 and prev_state != b.src_state_bits) {
                                return error.SubmitFailed;
                            }
                            const owner = self.resource_owner_queue.get(resource) orelse src_q;
                            if (owner != src_q) return error.SubmitFailed;
                            _ = self.pending_transfers.remove(resource);
                            try self.resource_state_bits.put(resource, b.dst_state_bits);
                            try self.resource_owner_queue.put(resource, dst_q);
                        },
                        .release => {
                            if (prev_state != 0 and prev_state != b.src_state_bits) {
                                return error.SubmitFailed;
                            }
                            const owner = self.resource_owner_queue.get(resource) orelse src_q;
                            if (owner != src_q) return error.SubmitFailed;
                            if (src_q != dst_q and desc.signal_semaphores.len == 0) return error.SubmitFailed;
                            const semaphore = if (src_q != dst_q) desc.signal_semaphores[0] else rhi.TimelineSemaphore{ .id = 0, .value = 0 };
                            try self.pending_transfers.put(resource, .{
                                .src_queue = src_q,
                                .dst_queue = dst_q,
                                .released_state_bits = b.src_state_bits,
                                .semaphore = semaphore,
                            });
                            try self.resource_state_bits.put(resource, b.src_state_bits);
                        },
                        .acquire => {
                            const pending = self.pending_transfers.get(resource) orelse return error.SubmitFailed;
                            if (pending.src_queue != src_q or pending.dst_queue != dst_q or pending.released_state_bits != b.src_state_bits) {
                                return error.SubmitFailed;
                            }
                            if (pending.semaphore.id != 0 and !submitHasWait(desc, pending.semaphore)) {
                                return error.SubmitFailed;
                            }
                            _ = self.pending_transfers.remove(resource);
                            try self.resource_state_bits.put(resource, b.dst_state_bits);
                            try self.resource_owner_queue.put(resource, dst_q);
                        },
                    }
                },
            }
        }

        for (desc.signal_semaphores) |signal| {
            const previous = self.semaphore_values.get(signal.id) orelse 0;
            if (signal.value <= previous) return error.SubmitFailed;
            try self.semaphore_values.put(signal.id, signal.value);
        }
    }
};

const PendingTransfer = struct {
    src_queue: rhi.QueueClass,
    dst_queue: rhi.QueueClass,
    released_state_bits: u32,
    semaphore: rhi.TimelineSemaphore,
};

pub const SubmitRecord = struct {
    queue_class: rhi.QueueClass,
    wait_count: usize,
    signal_count: usize,
};

fn createBuffer(ctx: *anyopaque, desc: rhi.BufferDesc) rhi.Error!rhi.Buffer {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_buffer_id;
    backend.next_buffer_id += 1;
    return .{ .id = id };
}

fn createTexture(ctx: *anyopaque, desc: rhi.TextureDesc) rhi.Error!rhi.Texture {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_texture_id;
    backend.next_texture_id += 1;
    return .{ .id = id };
}

fn destroyBuffer(ctx: *anyopaque, buffer: rhi.Buffer) void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    _ = backend.resource_state_bits.remove(.{ .kind = .buffer, .id = buffer.id });
    _ = backend.resource_owner_queue.remove(.{ .kind = .buffer, .id = buffer.id });
    _ = backend.pending_transfers.remove(.{ .kind = .buffer, .id = buffer.id });
}

fn destroyTexture(ctx: *anyopaque, texture: rhi.Texture) void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    _ = backend.resource_state_bits.remove(.{ .kind = .texture, .id = texture.id });
    _ = backend.resource_owner_queue.remove(.{ .kind = .texture, .id = texture.id });
    _ = backend.pending_transfers.remove(.{ .kind = .texture, .id = texture.id });
}

fn submitGraphicsQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.graphics, cmd, desc);
}

fn submitComputeQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.compute, cmd, desc);
}

fn submitTransferQueue(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    try backend.translateAndSubmit(.transfer, cmd, desc);
}

fn createCommandBuffer(ctx: *anyopaque, allocator: std.mem.Allocator) rhi.Error!command_buffer.CommandBuffer {
    _ = ctx;
    return command_buffer.CommandBuffer.init(allocator);
}

fn acquireSwapchainImage(ctx: *anyopaque) rhi.Error!rhi.SwapchainImage {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_swapchain_id;
    backend.next_swapchain_id += 1;
    return .{ .id = id, .width = 1280, .height = 720 };
}

fn submitCommandBuffer(
    ctx: *anyopaque,
    queue_class: rhi.QueueClass,
    cmd: *const command_buffer.CommandBuffer,
    desc: rhi.SubmitDesc,
) rhi.Error!void {
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    backend.translateAndSubmit(queue_class, cmd, desc) catch return error.SubmitFailed;
}

fn present(ctx: *anyopaque, image: rhi.SwapchainImage) rhi.Error!void {
    _ = ctx;
    _ = image;
}

fn getQueue(ctx: *anyopaque, class: rhi.QueueClass) rhi.Error!rhi.Queue {
    _ = @as(*MetalBackend, @ptrCast(@alignCast(ctx)));
    return switch (class) {
        .graphics => .{ .class = .graphics, .ctx = ctx, .submit_fn = submitGraphicsQueue },
        .compute => .{ .class = .compute, .ctx = ctx, .submit_fn = submitComputeQueue },
        .transfer => .{ .class = .transfer, .ctx = ctx, .submit_fn = submitTransferQueue },
    };
}

fn createShaderModule(ctx: *anyopaque, desc: rhi.ShaderModuleDesc) rhi.Error!rhi.ShaderModule {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_shader_module_id;
    backend.next_shader_module_id += 1;
    return .{ .id = id };
}

fn createGraphicsPipeline(ctx: *anyopaque, desc: rhi.GraphicsPipelineDesc) rhi.Error!rhi.GraphicsPipeline {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_graphics_pipeline_id;
    backend.next_graphics_pipeline_id += 1;
    return .{ .id = id };
}

fn createComputePipeline(ctx: *anyopaque, desc: rhi.ComputePipelineDesc) rhi.Error!rhi.ComputePipeline {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_compute_pipeline_id;
    backend.next_compute_pipeline_id += 1;
    return .{ .id = id };
}

fn destroyGraphicsPipeline(ctx: *anyopaque, pipeline: rhi.GraphicsPipeline) void {
    _ = ctx;
    _ = pipeline;
}

fn destroyComputePipeline(ctx: *anyopaque, pipeline: rhi.ComputePipeline) void {
    _ = ctx;
    _ = pipeline;
}

fn createSampler(ctx: *anyopaque, desc: rhi.SamplerDesc) rhi.Error!rhi.Sampler {
    _ = desc;
    var backend: *MetalBackend = @ptrCast(@alignCast(ctx));
    const id = backend.next_sampler_id;
    backend.next_sampler_id += 1;
    return .{ .id = id };
}

fn destroySampler(ctx: *anyopaque, sampler: rhi.Sampler) void {
    _ = ctx;
    _ = sampler;
}

fn uploadBufferData(ctx: *anyopaque, buffer: rhi.Buffer, offset: u64, data: []const u8) rhi.Error!void {
    _ = ctx;
    _ = buffer;
    _ = offset;
    _ = data;
}

fn submitHasWait(desc: queue_mod.SubmitDesc, expected: rhi.TimelineSemaphore) bool {
    for (desc.wait_semaphores) |wait| {
        if (wait.id == expected.id and wait.value >= expected.value) return true;
    }
    return false;
}

fn resourceRefFromBarrier(barrier: command_buffer.PipelineBarrierCmd) !rhi.ResourceRef {
    const kind = std.meta.intToEnum(rhi.ResourceKind, barrier.resource_kind) catch return error.InvalidArgument;
    return .{
        .kind = kind,
        .id = barrier.resource_id,
        .subresource_base = barrier.subresource_base,
        .subresource_count = barrier.subresource_count,
    };
}

const device_vtable = rhi.DeviceVTable{
    .create_buffer = createBuffer,
    .create_texture = createTexture,
    .destroy_buffer = destroyBuffer,
    .destroy_texture = destroyTexture,
    .create_command_buffer = createCommandBuffer,
    .acquire_swapchain_image = acquireSwapchainImage,
    .submit_command_buffer = submitCommandBuffer,
    .present = present,
    .get_queue = getQueue,
    .create_shader_module = createShaderModule,
    .create_graphics_pipeline = createGraphicsPipeline,
    .create_compute_pipeline = createComputePipeline,
    .destroy_graphics_pipeline = destroyGraphicsPipeline,
    .destroy_compute_pipeline = destroyComputePipeline,
    .create_sampler = createSampler,
    .destroy_sampler = destroySampler,
    .upload_buffer_data = uploadBufferData,
};

test "metal backend handles compute queue barrier ownership transfer" {
    var backend = MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();

    try cmd.encodePipelineBarrier(.{
        .resource_id = 99,
        .src_state_bits = 0,
        .dst_state_bits = 1,
        .resource_kind = @intCast(@intFromEnum(rhi.ResourceKind.texture)),
        .src_queue = @intCast(@intFromEnum(rhi.QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(rhi.QueueClass.graphics)),
    });

    try device.submitCommandBuffer(.compute, &cmd, .{});
    try std.testing.expectEqual(rhi.QueueClass.compute, backend.last_submit_queue.?);
}
