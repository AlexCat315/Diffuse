const std = @import("std");
const command_buffer = @import("command_buffer.zig");
const queue_mod = @import("queue.zig");
const state_tracker = @import("state_tracker.zig");
const binding_cache = @import("binding_cache.zig");
const rhi_types = @import("types.zig");

pub const Error = error{
    UnsupportedBackend,
    UnsupportedFeature,
    InvalidArgument,
    LayoutMismatch,
    OutOfMemory,
    SwapchainAcquireFailed,
    SubmitFailed,
    PresentFailed,
};

pub const QueueClass = queue_mod.QueueClass;
pub const Queue = queue_mod.Queue;
pub const SubmitDesc = queue_mod.SubmitDesc;
pub const TimelineSemaphore = queue_mod.TimelineSemaphore;

pub const ResourceStates = rhi_types.ResourceStates;
pub const Barrier = state_tracker.Barrier;
pub const ResourceKind = rhi_types.ResourceKind;
pub const ResourceRef = rhi_types.ResourceRef;
pub const BarrierSyncAction = rhi_types.BarrierSyncAction;
pub const BarrierPassScope = rhi_types.BarrierPassScope;

pub const Buffer = struct { id: u32 };
pub const Texture = struct { id: u32 };
pub const Sampler = struct { id: u32 };
pub const ShaderModule = struct { id: u32 };
pub const BindingLayout = struct { id: u32 };
pub const BindingSet = struct { id: u32 };
pub const PipelineLayout = struct { id: u32 };
pub const GraphicsPipeline = struct { id: u32 };
pub const ComputePipeline = struct { id: u32 };
pub const AccelStructure = struct { id: u32 };
pub const SwapchainImage = struct { id: u32, width: u32, height: u32 };

pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsageFlags,
    label: ?[]const u8 = null,
};

pub const BufferUsageFlags = packed struct(u32) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage_read: bool = false,
    storage_write: bool = false,
    indirect: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u24 = 0,

    pub fn bits(self: BufferUsageFlags) u32 {
        return @bitCast(self);
    }
};

pub const TextureDimension = enum {
    d2,
    d3,
    cube,
    array,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    depth: u32 = 1,
    layers: u32 = 1,
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
    format: rhi_types.TextureFormat,
    usage: TextureUsageFlags,
    dimension: TextureDimension = .d2,
    label: ?[]const u8 = null,
};

pub const TextureUsageFlags = packed struct(u32) {
    sampled: bool = false,
    color_target: bool = false,
    depth_stencil_target: bool = false,
    storage_read: bool = false,
    storage_write: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    present: bool = false,
    _padding: u24 = 0,

    pub fn bits(self: TextureUsageFlags) u32 {
        return @bitCast(self);
    }
};

pub const SamplerDesc = struct {
    min_filter: rhi_types.SamplerFilter = .linear,
    mag_filter: rhi_types.SamplerFilter = .linear,
    mipmap_mode: rhi_types.SamplerMipmapMode = .linear,
    address_mode_u: rhi_types.SamplerAddressMode = .repeat,
    address_mode_v: rhi_types.SamplerAddressMode = .repeat,
    address_mode_w: rhi_types.SamplerAddressMode = .repeat,
    enable_compare: bool = false,
    compare_op: rhi_types.CompareOp = .always,
};

pub const ShaderModuleDesc = struct {
    stage: rhi_types.ShaderStage,
    format: rhi_types.ShaderFormat,
    code: []const u8,
    entry_point: [:0]const u8 = "main",
};

pub const BindingType = enum {
    sampler,
    texture,
    storage_texture,
    uniform_buffer,
    storage_buffer,
    accel_structure,
};

pub const BindingLayoutEntry = struct {
    slot: u32,
    binding_type: BindingType,
    stage: rhi_types.ShaderStage,
    array_size: u32 = 1,
};

pub const BindingLayoutDesc = struct {
    entries: []const BindingLayoutEntry,
    label: ?[]const u8 = null,
};

pub const BindingResource = union(enum) {
    sampler: Sampler,
    texture: Texture,
    storage_texture: Texture,
    uniform_buffer: Buffer,
    storage_buffer: Buffer,
    accel_structure: AccelStructure,
};

pub const BindingSetEntry = struct {
    slot: u32,
    resource: BindingResource,
};

pub const BindingSetDesc = struct {
    entries: []const BindingSetEntry,
    label: ?[]const u8 = null,
};

pub const PipelineLayoutDesc = struct {
    set_layouts: []const BindingLayout,
    label: ?[]const u8 = null,
};

pub const DepthStencilState = struct {
    depth_compare: rhi_types.CompareOp = .less,
    depth_write: bool = true,
};

pub const VertexAttribute = struct {
    location: u32,
    format: rhi_types.VertexElementFormat,
    offset: u32,
    buffer_index: u32 = 0,
};

pub const VertexBufferLayout = struct {
    stride: u32,
    step_rate: rhi_types.VertexInputRate = .per_vertex,
};

pub const VertexLayoutDesc = struct {
    attributes: []const VertexAttribute,
    buffer_layouts: []const VertexBufferLayout,
};

pub const GraphicsPipelineDesc = struct {
    layout: PipelineLayout,
    vertex: ShaderModule,
    fragment: ?ShaderModule = null,
    color_format: rhi_types.TextureFormat = .unknown,
    depth_format: ?rhi_types.TextureFormat = .d32_float,
    primitive: rhi_types.PrimitiveType = .triangle_list,
    depth_stencil: ?DepthStencilState = .{},
    vertex_layout: ?VertexLayoutDesc = null,
    blend_state: ?rhi_types.ColorTargetBlendState = null,
};

pub const ComputePipelineDesc = struct {
    layout: PipelineLayout,
    shader: ShaderModule,
};

pub const DrawIndexedArgs = struct {
    index_count: u32,
    instance_count: u32 = 1,
    first_index: u32 = 0,
    vertex_offset: i32 = 0,
    first_instance: u32 = 0,
};

pub const BarrierDesc = struct {
    barriers: []const Barrier,
};

pub const RenderPassDesc = struct {
    color_target: ?Texture = null,
    depth_target: ?Texture = null,
};

pub const AccelStructureDesc = struct {
    max_geometry_count: u32,
    label: ?[]const u8 = null,
};

pub const RtPipelineState = struct {
    id: u32,
};

pub const Capabilities = struct {
    compute: bool,
    ray_tracing: bool,
    indirect_draw: bool,
    mesh_shaders: bool,
    texture_3d: bool,
    texture_cube_native: bool,
    max_queues: [3]u8,
};

pub const DeviceVTable = struct {
    create_buffer: *const fn (ctx: *anyopaque, desc: BufferDesc) Error!Buffer,
    create_texture: *const fn (ctx: *anyopaque, desc: TextureDesc) Error!Texture,
    destroy_buffer: *const fn (ctx: *anyopaque, buffer: Buffer) void,
    destroy_texture: *const fn (ctx: *anyopaque, texture: Texture) void,
    create_command_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Error!command_buffer.CommandBuffer,
    acquire_swapchain_image: *const fn (ctx: *anyopaque) Error!SwapchainImage,
    submit_command_buffer: *const fn (ctx: *anyopaque, queue: QueueClass, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) Error!void,
    present: *const fn (ctx: *anyopaque, image: SwapchainImage) Error!void,
    get_queue: *const fn (ctx: *anyopaque, class: QueueClass) Error!Queue,
    create_shader_module: *const fn (ctx: *anyopaque, desc: ShaderModuleDesc) Error!ShaderModule,
    create_graphics_pipeline: *const fn (ctx: *anyopaque, desc: GraphicsPipelineDesc) Error!GraphicsPipeline,
    create_compute_pipeline: *const fn (ctx: *anyopaque, desc: ComputePipelineDesc) Error!ComputePipeline,
    destroy_graphics_pipeline: *const fn (ctx: *anyopaque, pipeline: GraphicsPipeline) void,
    destroy_compute_pipeline: *const fn (ctx: *anyopaque, pipeline: ComputePipeline) void,
    create_sampler: *const fn (ctx: *anyopaque, desc: SamplerDesc) Error!Sampler,
    destroy_sampler: *const fn (ctx: *anyopaque, sampler: Sampler) void,
    upload_buffer_data: *const fn (ctx: *anyopaque, buffer: Buffer, offset: u64, data: []const u8) Error!void,
    upload_texture_data: ?*const fn (ctx: *anyopaque, texture: Texture, data: []const u8, width: u32, height: u32, bytes_per_row: u32) Error!void = null,
    read_texture_data: ?*const fn (ctx: *anyopaque, texture: Texture, width: u32, height: u32, bytes_per_row: u32, out_data: []u8) Error!void = null,
    register_binding_set: ?*const fn (ctx: *anyopaque, set_id: u32, layout_entries: []const BindingLayoutEntry, set_entries: []const BindingSetEntry) void = null,
};

const SubmissionTracking = struct {
    allocator: std.mem.Allocator,
    state_tracker: state_tracker.StateTracker,
    resource_queues: std.AutoHashMap(ResourceRef, QueueClass),
    pending_transfers: std.AutoHashMap(ResourceRef, PendingTransfer),
    queue_timelines: [3]QueueTimeline,
    next_timeline_semaphore_id: u32,
    binding_set_entries: std.AutoHashMap(u32, []BindingSetEntry),

    fn init(allocator: std.mem.Allocator) SubmissionTracking {
        return .{
            .allocator = allocator,
            .state_tracker = state_tracker.StateTracker.init(allocator),
            .resource_queues = std.AutoHashMap(ResourceRef, QueueClass).init(allocator),
            .pending_transfers = std.AutoHashMap(ResourceRef, PendingTransfer).init(allocator),
            .queue_timelines = .{ .{}, .{}, .{} },
            .next_timeline_semaphore_id = 1,
            .binding_set_entries = std.AutoHashMap(u32, []BindingSetEntry).init(allocator),
        };
    }

    fn deinit(self: *SubmissionTracking) void {
        var binding_set_it = self.binding_set_entries.iterator();
        while (binding_set_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.binding_set_entries.deinit();
        self.pending_transfers.deinit();
        self.resource_queues.deinit();
        self.state_tracker.deinit();
        self.* = undefined;
    }
};

const PendingTransfer = struct {
    src_queue: QueueClass,
    dst_queue: QueueClass,
    released_state: ResourceStates,
    semaphore: TimelineSemaphore,
};

const SplitReleaseRequest = struct {
    resource: ResourceRef,
    src_state: ResourceStates,
    src_queue: QueueClass,
    dst_queue: QueueClass,
};

const PreparedSubmission = struct {
    command_buffer: command_buffer.CommandBuffer,
    split_releases: std.ArrayList(SplitReleaseRequest),
    wait_semaphores: std.ArrayList(TimelineSemaphore),
    signal_semaphores: std.ArrayList(TimelineSemaphore),

    fn deinit(self: *PreparedSubmission, allocator: std.mem.Allocator) void {
        self.command_buffer.deinit();
        self.split_releases.deinit(allocator);
        self.wait_semaphores.deinit(allocator);
        self.signal_semaphores.deinit(allocator);
        self.* = undefined;
    }
};

const PlannedSubmit = struct {
    queue_class: QueueClass,
    command_buffer: command_buffer.CommandBuffer,
    wait_semaphores: std.ArrayList(TimelineSemaphore),
    signal_semaphores: std.ArrayList(TimelineSemaphore),

    fn deinit(self: *PlannedSubmit, allocator: std.mem.Allocator) void {
        self.command_buffer.deinit();
        self.wait_semaphores.deinit(allocator);
        self.signal_semaphores.deinit(allocator);
        self.* = undefined;
    }
};

const SubmitPlan = struct {
    submits: std.ArrayList(PlannedSubmit),

    fn init() SubmitPlan {
        return .{ .submits = .empty };
    }

    fn deinit(self: *SubmitPlan, allocator: std.mem.Allocator) void {
        for (self.submits.items) |*submit| {
            submit.deinit(allocator);
        }
        self.submits.deinit(allocator);
        self.* = undefined;
    }
};

const QueueTimeline = struct {
    id: u32 = 0,
    next_value: u64 = 0,
};

const PassBlockKind = enum {
    render,
    compute,
    copy,
};

pub const Device = struct {
    ctx: *anyopaque,
    vtable: *const DeviceVTable,
    capabilities: Capabilities,
    pipeline_layout_cache: binding_cache.PipelineLayoutCache,
    binding_set_cache: binding_cache.BindingSetCache,
    binding_layout_descs: std.AutoHashMap(u32, []BindingLayoutEntry),
    pipeline_layout_sets: std.AutoHashMap(u32, []u32),
    binding_set_layouts: std.AutoHashMap(u32, u32),
    submission_tracking: *SubmissionTracking,
    next_binding_layout_id: u32 = 1,
    prev_frame_stats: binding_cache.BindingSetCacheStats = .{},

    pub fn initWithCache(ctx: *anyopaque, vtable: *const DeviceVTable, capabilities: Capabilities, allocator: std.mem.Allocator) Device {
        const tracking = allocator.create(SubmissionTracking) catch @panic("failed to allocate submission tracking");
        tracking.* = SubmissionTracking.init(allocator);
        return .{
            .ctx = ctx,
            .vtable = vtable,
            .capabilities = capabilities,
            .pipeline_layout_cache = binding_cache.PipelineLayoutCache.init(allocator),
            .binding_set_cache = binding_cache.BindingSetCache.init(allocator),
            .binding_layout_descs = std.AutoHashMap(u32, []BindingLayoutEntry).init(allocator),
            .pipeline_layout_sets = std.AutoHashMap(u32, []u32).init(allocator),
            .binding_set_layouts = std.AutoHashMap(u32, u32).init(allocator),
            .submission_tracking = tracking,
        };
    }

    pub fn deinit(self: *Device) void {
        const allocator = self.pipeline_layout_cache.allocator;
        var layout_it = self.binding_layout_descs.iterator();
        while (layout_it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }

        var pl_it = self.pipeline_layout_sets.iterator();
        while (pl_it.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }

        self.binding_set_layouts.deinit();
        self.pipeline_layout_sets.deinit();
        self.binding_layout_descs.deinit();
        self.binding_set_cache.deinit();
        self.pipeline_layout_cache.deinit();
        self.submission_tracking.deinit();
        allocator.destroy(self.submission_tracking);
    }

    pub fn createBindingLayout(self: *Device, desc: BindingLayoutDesc) Error!BindingLayout {
        if (desc.entries.len == 0) return error.InvalidArgument;

        const id = self.next_binding_layout_id;
        self.next_binding_layout_id += 1;

        const copied = self.pipeline_layout_cache.allocator.dupe(BindingLayoutEntry, desc.entries) catch return error.OutOfMemory;
        self.binding_layout_descs.put(id, copied) catch return error.OutOfMemory;

        return .{ .id = id };
    }

    pub fn createBindingSetCached(self: *Device, layout: BindingLayout, desc: BindingSetDesc) Error!BindingSet {
        const layout_entries = self.binding_layout_descs.get(layout.id) orelse return error.InvalidArgument;
        try self.validateBindingSetDesc(layout_entries, desc);

        const key_hash = hashBindingSet(layout.id, desc.entries);
        if (self.binding_set_cache.getByHash(key_hash)) |id| {
            return .{ .id = id };
        }

        const id = self.binding_set_cache.nextSyntheticId();
        self.binding_set_cache.putByHash(key_hash, id) catch return error.OutOfMemory;
        self.binding_set_layouts.put(id, layout.id) catch return error.OutOfMemory;

        // Notify backend so it can map set_id → real GPU resources
        if (self.vtable.register_binding_set) |reg_fn| {
            reg_fn(self.ctx, id, layout_entries, desc.entries);
        }

        const copied_entries = self.pipeline_layout_cache.allocator.dupe(BindingSetEntry, desc.entries) catch return error.OutOfMemory;
        self.submission_tracking.binding_set_entries.put(id, copied_entries) catch {
            self.pipeline_layout_cache.allocator.free(copied_entries);
            return error.OutOfMemory;
        };

        return .{ .id = id };
    }

    pub fn validateBindingSetForPipelineSlot(self: *const Device, pipeline_layout: PipelineLayout, slot: u32, binding_set: BindingSet) Error!void {
        const layout_ids = self.pipeline_layout_sets.get(pipeline_layout.id) orelse return error.InvalidArgument;
        if (slot >= layout_ids.len) return error.LayoutMismatch;

        const expected_layout_id = layout_ids[slot];
        const actual_layout_id = self.binding_set_layouts.get(binding_set.id) orelse return error.InvalidArgument;
        if (expected_layout_id != actual_layout_id) return error.LayoutMismatch;
    }

    pub fn bindingSetCacheStats(self: *const Device) binding_cache.BindingSetCacheStats {
        return self.binding_set_cache.stats;
    }

    pub fn resetBindingSetCacheStats(self: *Device) void {
        self.binding_set_cache.resetStats();
        self.prev_frame_stats = .{};
    }

    /// Snapshot current stats as the previous frame baseline and return the delta.
    pub fn snapshotFrameStats(self: *Device) binding_cache.BindingSetCacheStats {
        const current = self.binding_set_cache.stats;
        const d = current.delta(self.prev_frame_stats);
        self.prev_frame_stats = current;
        return d;
    }

    pub fn bindingSetCacheEntryCount(self: *const Device) u32 {
        return self.binding_set_cache.entryCount();
    }

    pub fn createBuffer(self: *const Device, desc: BufferDesc) Error!Buffer {
        return self.vtable.create_buffer(self.ctx, desc);
    }

    pub fn createTexture(self: *const Device, desc: TextureDesc) Error!Texture {
        return self.vtable.create_texture(self.ctx, desc);
    }

    pub fn destroyBuffer(self: *const Device, buffer: Buffer) void {
        const resource = ResourceRef{ .kind = .buffer, .id = buffer.id };
        self.submission_tracking.state_tracker.removeResource(resource);
        _ = self.submission_tracking.resource_queues.remove(resource);
        _ = self.submission_tracking.pending_transfers.remove(resource);
        self.vtable.destroy_buffer(self.ctx, buffer);
    }

    pub fn destroyTexture(self: *const Device, texture: Texture) void {
        const resource = ResourceRef{ .kind = .texture, .id = texture.id };
        self.submission_tracking.state_tracker.removeResource(resource);
        _ = self.submission_tracking.resource_queues.remove(resource);
        _ = self.submission_tracking.pending_transfers.remove(resource);
        self.vtable.destroy_texture(self.ctx, texture);
    }

    pub fn createCommandBuffer(self: *const Device, allocator: std.mem.Allocator) Error!command_buffer.CommandBuffer {
        return self.vtable.create_command_buffer(self.ctx, allocator);
    }

    pub fn acquireSwapchainImage(self: *const Device) Error!SwapchainImage {
        return self.vtable.acquire_swapchain_image(self.ctx);
    }

    pub fn submitCommandBuffer(self: *const Device, queue_class: QueueClass, cmd: *const command_buffer.CommandBuffer, desc: SubmitDesc) Error!void {
        var prepared_submission = try self.prepareSubmissionForSubmit(queue_class, cmd);
        defer prepared_submission.deinit(self.pipeline_layout_cache.allocator);
        var submit_plan = try self.buildSubmitPlan(queue_class, &prepared_submission, desc);
        defer submit_plan.deinit(self.pipeline_layout_cache.allocator);
        return self.executeSubmitPlan(&submit_plan);
    }

    pub fn present(self: *const Device, image: SwapchainImage) Error!void {
        return self.vtable.present(self.ctx, image);
    }

    pub fn getQueue(self: *const Device, class: QueueClass) Error!Queue {
        return self.vtable.get_queue(self.ctx, class);
    }

    pub fn createShaderModule(self: *const Device, desc: ShaderModuleDesc) Error!ShaderModule {
        return self.vtable.create_shader_module(self.ctx, desc);
    }

    pub fn createGraphicsPipeline(self: *const Device, desc: GraphicsPipelineDesc) Error!GraphicsPipeline {
        return self.vtable.create_graphics_pipeline(self.ctx, desc);
    }

    pub fn createComputePipeline(self: *const Device, desc: ComputePipelineDesc) Error!ComputePipeline {
        return self.vtable.create_compute_pipeline(self.ctx, desc);
    }

    pub fn destroyGraphicsPipeline(self: *const Device, pipeline: GraphicsPipeline) void {
        self.vtable.destroy_graphics_pipeline(self.ctx, pipeline);
    }

    pub fn destroyComputePipeline(self: *const Device, pipeline: ComputePipeline) void {
        self.vtable.destroy_compute_pipeline(self.ctx, pipeline);
    }

    pub fn createSampler(self: *const Device, desc: SamplerDesc) Error!Sampler {
        return self.vtable.create_sampler(self.ctx, desc);
    }

    pub fn destroySampler(self: *const Device, sampler: Sampler) void {
        self.vtable.destroy_sampler(self.ctx, sampler);
    }

    pub fn uploadBufferData(self: *const Device, buffer: Buffer, offset: u64, data: []const u8) Error!void {
        return self.vtable.upload_buffer_data(self.ctx, buffer, offset, data);
    }

    pub fn uploadTextureData(self: *const Device, texture: Texture, data: []const u8, width: u32, height: u32, bytes_per_row: u32) Error!void {
        const func = self.vtable.upload_texture_data orelse return error.UnsupportedFeature;
        return func(self.ctx, texture, data, width, height, bytes_per_row);
    }

    pub fn readTextureData(self: *const Device, texture: Texture, width: u32, height: u32, bytes_per_row: u32, out_data: []u8) Error!void {
        const func = self.vtable.read_texture_data orelse return error.UnsupportedFeature;
        return func(self.ctx, texture, width, height, bytes_per_row, out_data);
    }

    pub fn resolvePipelineLayout(
        self: *Device,
        binding_layouts: []const BindingLayout,
    ) Error!PipelineLayout {
        if (binding_layouts.len == 0) return error.InvalidArgument;

        var ids = std.ArrayList(u32).empty;
        defer ids.deinit(self.pipeline_layout_cache.allocator);
        for (binding_layouts) |layout| {
            if (!self.binding_layout_descs.contains(layout.id)) return error.InvalidArgument;
            ids.append(self.pipeline_layout_cache.allocator, layout.id) catch return error.OutOfMemory;
        }

        if (self.pipeline_layout_cache.get(ids.items)) |id| {
            return .{ .id = id };
        }

        const id = self.pipeline_layout_cache.nextSyntheticId();
        try self.pipeline_layout_cache.put(ids.items, id);
        const copied_layout_ids = self.pipeline_layout_cache.allocator.dupe(u32, ids.items) catch return error.OutOfMemory;
        self.pipeline_layout_sets.put(id, copied_layout_ids) catch return error.OutOfMemory;
        return .{ .id = id };
    }

    fn prepareCommandBufferForSubmit(
        self: *const Device,
        queue_class: QueueClass,
        original: *const command_buffer.CommandBuffer,
    ) Error!command_buffer.CommandBuffer {
        var prepared_submission = try self.prepareSubmissionForSubmit(queue_class, original);
        defer {
            prepared_submission.split_releases.deinit(self.pipeline_layout_cache.allocator);
            prepared_submission.wait_semaphores.deinit(self.pipeline_layout_cache.allocator);
            prepared_submission.signal_semaphores.deinit(self.pipeline_layout_cache.allocator);
        }
        return prepared_submission.command_buffer;
    }

    fn prepareSubmissionForSubmit(
        self: *const Device,
        queue_class: QueueClass,
        original: *const command_buffer.CommandBuffer,
    ) Error!PreparedSubmission {
        var prepared = command_buffer.CommandBuffer.init(self.pipeline_layout_cache.allocator);
        errdefer prepared.deinit();

        var split_releases = std.ArrayList(SplitReleaseRequest).empty;
        errdefer split_releases.deinit(self.pipeline_layout_cache.allocator);
        var wait_semaphores = std.ArrayList(TimelineSemaphore).empty;
        errdefer wait_semaphores.deinit(self.pipeline_layout_cache.allocator);
        var signal_semaphores = std.ArrayList(TimelineSemaphore).empty;
        errdefer signal_semaphores.deinit(self.pipeline_layout_cache.allocator);

        var decoder = original.decoder();
        while (true) {
            const maybe_decoded = try nextDecodedCommand(&decoder);
            const decoded = maybe_decoded orelse break;
            switch (decoded) {
                .begin_render_pass => try self.preparePassBlockForSubmit(&prepared, &split_releases, &wait_semaphores, &signal_semaphores, &decoder, queue_class, decoded, .render),
                .begin_compute_pass => try self.preparePassBlockForSubmit(&prepared, &split_releases, &wait_semaphores, &signal_semaphores, &decoder, queue_class, decoded, .compute),
                .begin_copy_pass => try self.preparePassBlockForSubmit(&prepared, &split_releases, &wait_semaphores, &signal_semaphores, &decoder, queue_class, decoded, .copy),
                .pipeline_barrier => |barrier| {
                    if (try self.resolveExplicitBarrierForQueue(&split_releases, &wait_semaphores, &signal_semaphores, queue_class, barrier)) |resolved| {
                        prepared.encodePipelineBarrier(resolved) catch |err| return mapCommandBufferError(err);
                        try self.applyExplicitBarrier(resolved);
                    }
                },
                else => {
                    var pending_barriers = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
                    defer pending_barriers.deinit(self.pipeline_layout_cache.allocator);

                    try self.collectAutomaticBarriersForCommand(
                        &pending_barriers,
                        &split_releases,
                        &wait_semaphores,
                        queue_class,
                        decoded,
                        .outside_pass,
                    );
                    try flushPendingBarriers(&prepared, pending_barriers.items);
                    prepared.encodeDecoded(decoded) catch |err| return mapCommandBufferError(err);
                },
            }
        }

        return .{
            .command_buffer = prepared,
            .split_releases = split_releases,
            .wait_semaphores = wait_semaphores,
            .signal_semaphores = signal_semaphores,
        };
    }

    fn preparePassBlockForSubmit(
        self: *const Device,
        prepared: *command_buffer.CommandBuffer,
        split_releases: *std.ArrayList(SplitReleaseRequest),
        wait_semaphores: *std.ArrayList(TimelineSemaphore),
        signal_semaphores: *std.ArrayList(TimelineSemaphore),
        decoder: *command_buffer.Decoder,
        queue_class: QueueClass,
        begin_decoded: command_buffer.DecodedCommand,
        pass_kind: PassBlockKind,
    ) Error!void {
        var pre_barriers = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
        defer pre_barriers.deinit(self.pipeline_layout_cache.allocator);

        var post_barriers = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
        defer post_barriers.deinit(self.pipeline_layout_cache.allocator);

        var body_commands = std.ArrayList(command_buffer.DecodedCommand).empty;
        defer body_commands.deinit(self.pipeline_layout_cache.allocator);

        try self.collectAutomaticBarriersForCommand(
            &pre_barriers,
            split_releases,
            wait_semaphores,
            queue_class,
            begin_decoded,
            .before_pass,
        );

        const end_opcode = passBlockEndOpcode(pass_kind);
        while (true) {
            const maybe_decoded = try nextDecodedCommand(decoder);
            const decoded = maybe_decoded orelse return error.SubmitFailed;
            if (std.meta.activeTag(decoded) == end_opcode) break;

            switch (decoded) {
                .pipeline_barrier => |barrier| switch (try decodeBarrierPassScope(barrier.pass_scope)) {
                    .before_pass => {
                        if (try self.resolveExplicitBarrierForQueue(split_releases, wait_semaphores, signal_semaphores, queue_class, barrier)) |resolved| {
                            try pre_barriers.append(self.pipeline_layout_cache.allocator, resolved);
                            try self.applyExplicitBarrier(resolved);
                        }
                    },
                    .after_pass => {
                        if (try self.resolveExplicitBarrierForQueue(split_releases, wait_semaphores, signal_semaphores, queue_class, barrier)) |resolved| {
                            try post_barriers.append(self.pipeline_layout_cache.allocator, resolved);
                        }
                    },
                    .outside_pass => return error.SubmitFailed,
                },
                else => {
                    try self.collectAutomaticBarriersForCommand(
                        &pre_barriers,
                        split_releases,
                        wait_semaphores,
                        queue_class,
                        decoded,
                        .before_pass,
                    );
                    try body_commands.append(self.pipeline_layout_cache.allocator, decoded);
                },
            }
        }

        try flushPendingBarriers(prepared, pre_barriers.items);
        prepared.encodeDecoded(begin_decoded) catch |err| return mapCommandBufferError(err);

        for (body_commands.items) |decoded| {
            prepared.encodeDecoded(decoded) catch |err| return mapCommandBufferError(err);
        }

        switch (pass_kind) {
            .render => prepared.encodeEndRenderPass() catch |err| return mapCommandBufferError(err),
            .compute => prepared.encodeEndComputePass() catch |err| return mapCommandBufferError(err),
            .copy => prepared.encodeEndCopyPass() catch |err| return mapCommandBufferError(err),
        }

        try flushPendingBarriers(prepared, post_barriers.items);
        for (post_barriers.items) |barrier| {
            try self.applyExplicitBarrier(barrier);
        }
    }

    fn collectAutomaticBarriersForCommand(
        self: *const Device,
        pending_barriers: *std.ArrayList(command_buffer.PipelineBarrierCmd),
        split_releases: *std.ArrayList(SplitReleaseRequest),
        wait_semaphores: *std.ArrayList(TimelineSemaphore),
        queue_class: QueueClass,
        decoded: command_buffer.DecodedCommand,
        pass_scope: BarrierPassScope,
    ) Error!void {
        switch (decoded) {
            .begin_render_pass => |cmd| {
                if (cmd.color_target_id != 0) {
                    try self.collectTrackedStateTransitions(
                        pending_barriers,
                        split_releases,
                        wait_semaphores,
                        queue_class,
                        .{ .kind = .texture, .id = cmd.color_target_id },
                        ResourceStates{ .render_target = true },
                        pass_scope,
                    );
                }
                if (cmd.depth_target_id != 0) {
                    try self.collectTrackedStateTransitions(
                        pending_barriers,
                        split_releases,
                        wait_semaphores,
                        queue_class,
                        .{ .kind = .texture, .id = cmd.depth_target_id },
                        ResourceStates{ .depth_write = true },
                        pass_scope,
                    );
                }
            },
            .set_binding_set => |cmd| {
                const entries = self.submission_tracking.binding_set_entries.get(cmd.set_id) orelse return;
                for (entries) |entry| {
                    const tracked = trackedResourceForBinding(entry) orelse continue;
                    try self.collectTrackedStateTransitions(
                        pending_barriers,
                        split_releases,
                        wait_semaphores,
                        queue_class,
                        tracked.resource,
                        tracked.state,
                        pass_scope,
                    );
                }
            },
            .set_vertex_buffer => |cmd| {
                try self.collectTrackedStateTransitions(
                    pending_barriers,
                    split_releases,
                    wait_semaphores,
                    queue_class,
                    .{ .kind = .buffer, .id = cmd.buffer_id },
                    ResourceStates{ .vertex_buffer = true },
                    pass_scope,
                );
            },
            .set_index_buffer => |cmd| {
                try self.collectTrackedStateTransitions(
                    pending_barriers,
                    split_releases,
                    wait_semaphores,
                    queue_class,
                    .{ .kind = .buffer, .id = cmd.buffer_id },
                    ResourceStates{ .index_buffer = true },
                    pass_scope,
                );
            },
            .draw_indirect => |cmd| {
                try self.collectTrackedStateTransitions(
                    pending_barriers,
                    split_releases,
                    wait_semaphores,
                    queue_class,
                    .{ .kind = .buffer, .id = cmd.buffer_id },
                    ResourceStates{ .indirect_argument = true },
                    pass_scope,
                );
            },
            .dispatch_indirect => |cmd| {
                try self.collectTrackedStateTransitions(
                    pending_barriers,
                    split_releases,
                    wait_semaphores,
                    queue_class,
                    .{ .kind = .buffer, .id = cmd.buffer_id },
                    ResourceStates{ .indirect_argument = true },
                    pass_scope,
                );
            },
            else => {},
        }
    }

    fn collectTrackedStateTransitions(
        self: *const Device,
        pending_barriers: *std.ArrayList(command_buffer.PipelineBarrierCmd),
        split_releases: *std.ArrayList(SplitReleaseRequest),
        wait_semaphores: *std.ArrayList(TimelineSemaphore),
        queue_class: QueueClass,
        resource: ResourceRef,
        desired: ResourceStates,
        pass_scope: BarrierPassScope,
    ) Error!void {
        try self.submission_tracking.state_tracker.requireState(resource, desired);
        const barriers = try self.submission_tracking.state_tracker.commitBarriers(self.pipeline_layout_cache.allocator);
        defer self.pipeline_layout_cache.allocator.free(barriers);

        for (barriers) |barrier| {
            const src_queue = self.submission_tracking.resource_queues.get(barrier.resource) orelse queue_class;
            const cross_queue = src_queue != queue_class;
            if (cross_queue) {
                if (self.matchingPendingTransfer(barrier.resource, src_queue, queue_class, barrier.before)) |pending| {
                    try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, wait_semaphores, pending.semaphore);
                } else {
                    try self.appendSplitReleaseRequest(
                        split_releases,
                        .{
                            .resource = barrier.resource,
                            .src_state = barrier.before,
                            .src_queue = src_queue,
                            .dst_queue = queue_class,
                        },
                    );
                }
            }
            try pending_barriers.append(self.pipeline_layout_cache.allocator, .{
                .resource_id = barrier.resource.id,
                .src_state_bits = barrier.before.asBits(),
                .dst_state_bits = barrier.after.asBits(),
                .subresource_base = barrier.resource.subresource_base,
                .subresource_count = barrier.resource.subresource_count,
                .resource_kind = @intCast(@intFromEnum(barrier.resource.kind)),
                .sync_action = @intCast(@intFromEnum(deriveBarrierSyncAction(src_queue, queue_class))),
                .pass_scope = @intCast(@intFromEnum(pass_scope)),
                .src_queue = @intCast(@intFromEnum(src_queue)),
                .dst_queue = @intCast(@intFromEnum(queue_class)),
            });
            if (cross_queue) {
                _ = self.submission_tracking.pending_transfers.remove(barrier.resource);
            }
            try self.submission_tracking.resource_queues.put(barrier.resource, queue_class);
        }
    }

    fn applyExplicitBarrier(self: *const Device, barrier: command_buffer.PipelineBarrierCmd) Error!void {
        const resource_kind = std.enums.fromInt(ResourceKind, barrier.resource_kind) orelse return error.SubmitFailed;
        const resource = ResourceRef{
            .kind = resource_kind,
            .id = barrier.resource_id,
            .subresource_base = barrier.subresource_base,
            .subresource_count = barrier.subresource_count,
        };
        const src_queue: QueueClass = @enumFromInt(@as(u8, barrier.src_queue));
        const dst_queue: QueueClass = @enumFromInt(@as(u8, barrier.dst_queue));
        const sync_action = std.enums.fromInt(BarrierSyncAction, barrier.sync_action) orelse return error.SubmitFailed;
        switch (sync_action) {
            .full => {
                try self.submission_tracking.state_tracker.setCurrentState(resource, ResourceStates.fromBits(barrier.dst_state_bits));
                try self.submission_tracking.resource_queues.put(resource, dst_queue);
                _ = self.submission_tracking.pending_transfers.remove(resource);
            },
            .acquire => {
                if (self.submission_tracking.pending_transfers.get(resource)) |pending| {
                    if (pending.src_queue != src_queue or pending.dst_queue != dst_queue) {
                        return error.SubmitFailed;
                    }
                    if (pending.released_state.asBits() != barrier.src_state_bits) {
                        return error.SubmitFailed;
                    }
                    _ = self.submission_tracking.pending_transfers.remove(resource);
                }
                try self.submission_tracking.state_tracker.setCurrentState(resource, ResourceStates.fromBits(barrier.dst_state_bits));
                try self.submission_tracking.resource_queues.put(resource, dst_queue);
            },
            .release => {
                const released_state = ResourceStates.fromBits(barrier.src_state_bits);
                try self.submission_tracking.state_tracker.setCurrentState(resource, released_state);
                try self.submission_tracking.resource_queues.put(resource, src_queue);
                if (src_queue == dst_queue) {
                    _ = self.submission_tracking.pending_transfers.remove(resource);
                    return;
                }
                const existing_semaphore = if (self.submission_tracking.pending_transfers.get(resource)) |pending|
                    pending.semaphore
                else
                    TimelineSemaphore{ .id = 0, .value = 0 };
                try self.submission_tracking.pending_transfers.put(resource, .{
                    .src_queue = src_queue,
                    .dst_queue = dst_queue,
                    .released_state = released_state,
                    .semaphore = existing_semaphore,
                });
            },
        }
    }

    fn resolveExplicitBarrierForQueue(
        self: *const Device,
        split_releases: *std.ArrayList(SplitReleaseRequest),
        wait_semaphores: *std.ArrayList(TimelineSemaphore),
        signal_semaphores: *std.ArrayList(TimelineSemaphore),
        queue_class: QueueClass,
        barrier: command_buffer.PipelineBarrierCmd,
    ) Error!?command_buffer.PipelineBarrierCmd {
        const sync_action = try decodeBarrierSyncAction(barrier.sync_action);
        const src_queue: QueueClass = @enumFromInt(@as(u8, barrier.src_queue));
        const dst_queue: QueueClass = @enumFromInt(@as(u8, barrier.dst_queue));
        const resource_kind = std.enums.fromInt(ResourceKind, barrier.resource_kind) orelse return error.SubmitFailed;
        const resource = ResourceRef{
            .kind = resource_kind,
            .id = barrier.resource_id,
            .subresource_base = barrier.subresource_base,
            .subresource_count = barrier.subresource_count,
        };

        if (src_queue == dst_queue) {
            return barrier;
        }

        switch (sync_action) {
            .full => {
                if (queue_class != dst_queue) return null;
                if (self.matchingPendingTransfer(resource, src_queue, dst_queue, ResourceStates.fromBits(barrier.src_state_bits))) |pending| {
                    try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, wait_semaphores, pending.semaphore);
                } else {
                    try self.appendSplitReleaseRequest(split_releases, .{
                        .resource = resource,
                        .src_state = ResourceStates.fromBits(barrier.src_state_bits),
                        .src_queue = src_queue,
                        .dst_queue = dst_queue,
                    });
                }

                var acquire = barrier;
                acquire.sync_action = @intCast(@intFromEnum(BarrierSyncAction.acquire));
                return acquire;
            },
            .acquire => {
                if (queue_class != dst_queue) return null;
                if (self.matchingPendingTransfer(resource, src_queue, dst_queue, ResourceStates.fromBits(barrier.src_state_bits))) |pending| {
                    try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, wait_semaphores, pending.semaphore);
                } else {
                    try self.appendSplitReleaseRequest(split_releases, .{
                        .resource = resource,
                        .src_state = ResourceStates.fromBits(barrier.src_state_bits),
                        .src_queue = src_queue,
                        .dst_queue = dst_queue,
                    });
                }
                return barrier;
            },
            .release => {
                if (queue_class != src_queue) return null;
                if (src_queue != dst_queue) {
                    const semaphore = try self.ensureSubmitSignalSemaphore(queue_class, signal_semaphores);
                    try self.submission_tracking.pending_transfers.put(resource, .{
                        .src_queue = src_queue,
                        .dst_queue = dst_queue,
                        .released_state = ResourceStates.fromBits(barrier.src_state_bits),
                        .semaphore = semaphore,
                    });
                }
                var release = barrier;
                release.dst_state_bits = release.src_state_bits;
                return release;
            },
        }
    }

    fn appendSplitReleaseRequest(
        self: *const Device,
        split_releases: *std.ArrayList(SplitReleaseRequest),
        request: SplitReleaseRequest,
    ) Error!void {
        for (split_releases.items) |*existing| {
            if (std.meta.eql(existing.resource, request.resource) and existing.src_queue == request.src_queue and existing.dst_queue == request.dst_queue) {
                existing.src_state = ResourceStates.fromBits(existing.src_state.asBits() | request.src_state.asBits());
                return;
            }
        }
        try split_releases.append(self.pipeline_layout_cache.allocator, request);
    }

    fn matchingPendingTransfer(
        self: *const Device,
        resource: ResourceRef,
        src_queue: QueueClass,
        dst_queue: QueueClass,
        released_state: ResourceStates,
    ) ?PendingTransfer {
        const pending = self.submission_tracking.pending_transfers.get(resource) orelse return null;
        if (pending.src_queue != src_queue or pending.dst_queue != dst_queue or pending.released_state.asBits() != released_state.asBits()) {
            return null;
        }
        return pending;
    }

    fn ensureSubmitSignalSemaphore(
        self: *const Device,
        queue_class: QueueClass,
        signal_semaphores: *std.ArrayList(TimelineSemaphore),
    ) Error!TimelineSemaphore {
        if (signal_semaphores.items.len > 0) {
            return signal_semaphores.items[0];
        }

        const semaphore = try self.nextQueueTimelineSemaphore(queue_class);
        try signal_semaphores.append(self.pipeline_layout_cache.allocator, semaphore);
        return semaphore;
    }

    fn nextQueueTimelineSemaphore(self: *const Device, queue_class: QueueClass) Error!TimelineSemaphore {
        const index = queueClassIndex(queue_class);
        var track = &self.submission_tracking.queue_timelines[index];
        if (track.id == 0) {
            track.id = self.submission_tracking.next_timeline_semaphore_id;
            self.submission_tracking.next_timeline_semaphore_id += 1;
        }
        track.next_value += 1;
        return .{
            .id = track.id,
            .value = track.next_value,
        };
    }

    fn buildSubmitPlan(
        self: *const Device,
        queue_class: QueueClass,
        prepared_submission: *PreparedSubmission,
        desc: SubmitDesc,
    ) Error!SubmitPlan {
        var plan = SubmitPlan.init();
        errdefer plan.deinit(self.pipeline_layout_cache.allocator);

        var graphics_release = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
        defer graphics_release.deinit(self.pipeline_layout_cache.allocator);
        var compute_release = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
        defer compute_release.deinit(self.pipeline_layout_cache.allocator);
        var transfer_release = std.ArrayList(command_buffer.PipelineBarrierCmd).empty;
        defer transfer_release.deinit(self.pipeline_layout_cache.allocator);

        for (prepared_submission.split_releases.items) |request| {
            const release_barrier: command_buffer.PipelineBarrierCmd = .{
                .resource_id = request.resource.id,
                .src_state_bits = request.src_state.asBits(),
                .dst_state_bits = request.src_state.asBits(),
                .subresource_base = request.resource.subresource_base,
                .subresource_count = request.resource.subresource_count,
                .resource_kind = @intCast(@intFromEnum(request.resource.kind)),
                .sync_action = @intCast(@intFromEnum(BarrierSyncAction.release)),
                .pass_scope = @intCast(@intFromEnum(BarrierPassScope.outside_pass)),
                .src_queue = @intCast(@intFromEnum(request.src_queue)),
                .dst_queue = @intCast(@intFromEnum(request.dst_queue)),
            };

            switch (request.src_queue) {
                .graphics => try graphics_release.append(self.pipeline_layout_cache.allocator, release_barrier),
                .compute => try compute_release.append(self.pipeline_layout_cache.allocator, release_barrier),
                .transfer => try transfer_release.append(self.pipeline_layout_cache.allocator, release_barrier),
            }
        }

        try self.appendReleaseSubmitToPlan(&plan, .graphics, graphics_release.items, &prepared_submission.wait_semaphores);
        try self.appendReleaseSubmitToPlan(&plan, .compute, compute_release.items, &prepared_submission.wait_semaphores);
        try self.appendReleaseSubmitToPlan(&plan, .transfer, transfer_release.items, &prepared_submission.wait_semaphores);

        for (desc.wait_semaphores) |semaphore| {
            try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, &prepared_submission.wait_semaphores, semaphore);
        }
        for (desc.signal_semaphores) |semaphore| {
            try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, &prepared_submission.signal_semaphores, semaphore);
        }

        const final_waits = prepared_submission.wait_semaphores;
        prepared_submission.wait_semaphores = .empty;
        const final_signals = prepared_submission.signal_semaphores;
        prepared_submission.signal_semaphores = .empty;
        const final_command_buffer = prepared_submission.command_buffer;
        prepared_submission.command_buffer = command_buffer.CommandBuffer.init(self.pipeline_layout_cache.allocator);

        try plan.submits.append(self.pipeline_layout_cache.allocator, .{
            .queue_class = queue_class,
            .command_buffer = final_command_buffer,
            .wait_semaphores = final_waits,
            .signal_semaphores = final_signals,
        });

        return plan;
    }

    fn appendReleaseSubmitToPlan(
        self: *const Device,
        plan: *SubmitPlan,
        queue_class: QueueClass,
        barriers: []const command_buffer.PipelineBarrierCmd,
        consumer_waits: *std.ArrayList(TimelineSemaphore),
    ) Error!void {
        if (barriers.len == 0) return;

        const signal_semaphore = try self.nextQueueTimelineSemaphore(queue_class);
        try appendUniqueSemaphore(self.pipeline_layout_cache.allocator, consumer_waits, signal_semaphore);

        var release_cmd = command_buffer.CommandBuffer.init(self.pipeline_layout_cache.allocator);
        errdefer release_cmd.deinit();
        release_cmd.encodePipelineBarriers(barriers) catch |err| return mapCommandBufferError(err);

        var signal_semaphores = std.ArrayList(TimelineSemaphore).empty;
        errdefer signal_semaphores.deinit(self.pipeline_layout_cache.allocator);
        try signal_semaphores.append(self.pipeline_layout_cache.allocator, signal_semaphore);

        try plan.submits.append(self.pipeline_layout_cache.allocator, .{
            .queue_class = queue_class,
            .command_buffer = release_cmd,
            .wait_semaphores = .empty,
            .signal_semaphores = signal_semaphores,
        });
    }

    fn executeSubmitPlan(self: *const Device, plan: *const SubmitPlan) Error!void {
        for (plan.submits.items) |submit| {
            try self.vtable.submit_command_buffer(self.ctx, submit.queue_class, &submit.command_buffer, .{
                .wait_semaphores = submit.wait_semaphores.items,
                .signal_semaphores = submit.signal_semaphores.items,
            });
        }
    }

    fn validateBindingSetDesc(self: *const Device, layout_entries: []const BindingLayoutEntry, desc: BindingSetDesc) Error!void {
        _ = self;
        if (desc.entries.len != layout_entries.len) return error.LayoutMismatch;

        for (layout_entries) |layout_entry| {
            const binding_entry = findBindingEntry(desc.entries, layout_entry.slot) orelse return error.LayoutMismatch;
            if (!resourceMatchesBindingType(binding_entry.resource, layout_entry.binding_type)) {
                return error.LayoutMismatch;
            }
        }
    }
};

fn findBindingEntry(entries: []const BindingSetEntry, slot: u32) ?BindingSetEntry {
    for (entries) |entry| {
        if (entry.slot == slot) return entry;
    }
    return null;
}

fn resourceMatchesBindingType(resource: BindingResource, binding_type: BindingType) bool {
    return switch (resource) {
        .sampler => binding_type == .sampler,
        .texture => binding_type == .texture,
        .storage_texture => binding_type == .storage_texture,
        .uniform_buffer => binding_type == .uniform_buffer,
        .storage_buffer => binding_type == .storage_buffer,
        .accel_structure => binding_type == .accel_structure,
    };
}

fn mapCommandBufferError(err: command_buffer.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidOpcode,
        error.TruncatedStream,
        => error.SubmitFailed,
    };
}

fn nextDecodedCommand(decoder: *command_buffer.Decoder) Error!?command_buffer.DecodedCommand {
    return decoder.next() catch |err| return mapCommandBufferError(err);
}

fn flushPendingBarriers(prepared: *command_buffer.CommandBuffer, pending_barriers: []const command_buffer.PipelineBarrierCmd) Error!void {
    if (pending_barriers.len == 0) return;
    prepared.encodePipelineBarriers(pending_barriers) catch |err| return mapCommandBufferError(err);
}

fn passBlockEndOpcode(pass_kind: PassBlockKind) command_buffer.OpCode {
    return switch (pass_kind) {
        .render => .end_render_pass,
        .compute => .end_compute_pass,
        .copy => .end_copy_pass,
    };
}

fn decodeBarrierPassScope(raw_scope: u8) Error!BarrierPassScope {
    return std.enums.fromInt(BarrierPassScope, raw_scope) orelse return error.SubmitFailed;
}

fn deriveBarrierSyncAction(src_queue: QueueClass, dst_queue: QueueClass) BarrierSyncAction {
    if (src_queue != dst_queue) {
        return .acquire;
    }
    return .full;
}

fn decodeBarrierSyncAction(raw_action: u8) Error!BarrierSyncAction {
    return std.enums.fromInt(BarrierSyncAction, raw_action) orelse return error.SubmitFailed;
}

fn queueClassIndex(queue_class: QueueClass) usize {
    return switch (queue_class) {
        .graphics => 0,
        .compute => 1,
        .transfer => 2,
    };
}

fn appendUniqueSemaphore(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(TimelineSemaphore),
    semaphore: TimelineSemaphore,
) !void {
    if (semaphore.id == 0) return;
    for (list.items) |existing| {
        if (existing.id == semaphore.id and existing.value == semaphore.value) return;
    }
    try list.append(allocator, semaphore);
}

const TrackedBindingResource = struct {
    resource: ResourceRef,
    state: ResourceStates,
};

fn trackedResourceForBinding(entry: BindingSetEntry) ?TrackedBindingResource {
    return switch (entry.resource) {
        .sampler => null,
        .texture => |texture| .{
            .resource = .{ .kind = .texture, .id = texture.id },
            .state = .{ .shader_resource = true },
        },
        .storage_texture => |texture| .{
            .resource = .{ .kind = .texture, .id = texture.id },
            .state = .{ .shader_resource = true, .unordered_access = true },
        },
        .uniform_buffer => |buffer| .{
            .resource = .{ .kind = .buffer, .id = buffer.id },
            .state = .{ .constant_buffer = true },
        },
        .storage_buffer => |buffer| .{
            .resource = .{ .kind = .buffer, .id = buffer.id },
            .state = .{ .shader_resource = true, .unordered_access = true },
        },
        .accel_structure => |accel| .{
            .resource = .{ .kind = .accel_structure, .id = accel.id },
            .state = .{ .accel_struct_read = true },
        },
    };
}

fn hashBindingSet(layout_id: u32, entries: []const BindingSetEntry) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&layout_id));
    for (entries) |entry| {
        h.update(std.mem.asBytes(&entry.slot));
        const tag: u8 = @intFromEnum(std.meta.activeTag(entry.resource));
        h.update(std.mem.asBytes(&tag));
        const rid: u32 = switch (entry.resource) {
            .sampler => |r| r.id,
            .texture => |r| r.id,
            .storage_texture => |r| r.id,
            .uniform_buffer => |r| r.id,
            .storage_buffer => |r| r.id,
            .accel_structure => |r| r.id,
        };
        h.update(std.mem.asBytes(&rid));
    }
    return h.final();
}

pub const CommandBuffer = command_buffer.CommandBuffer;
pub const CommandDecoder = command_buffer.Decoder;
pub const OpCode = command_buffer.OpCode;
pub const StateTracker = state_tracker.StateTracker;

test "binding set cache returns stable id for same layout/resources" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });

    const tex = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(tex);

    const set_a = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });
    const set_b = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });

    try std.testing.expectEqual(set_a.id, set_b.id);
}

test "pipeline layout binding slot validation catches mismatched layout" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout_a = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });
    const layout_b = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .uniform_buffer,
            .stage = .fragment,
        }},
    });

    const pipeline_layout = try device.resolvePipelineLayout(&.{layout_a});
    const buf = try device.createBuffer(.{
        .size = 64,
        .usage = .{ .uniform = true },
    });
    defer device.destroyBuffer(buf);

    const bad_set = try device.createBindingSetCached(layout_b, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = buf } }},
    });

    try std.testing.expectError(error.LayoutMismatch, device.validateBindingSetForPipelineSlot(pipeline_layout, 0, bad_set));
}

test "submit command buffer injects render target barrier before render pass" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const color = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .color_target = true },
    });
    defer device.destroyTexture(color);

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();
    try cmd.encodeBeginRenderPass(.{
        .color_target_id = color.id,
        .depth_target_id = 0,
        .clear_mask = 0,
    });
    try cmd.encodeEndRenderPass();

    try device.submitCommandBuffer(.graphics, &cmd, .{});

    const tracked_bits = backend.resource_state_bits.get(.{ .kind = .texture, .id = color.id }) orelse 0;
    try std.testing.expectEqual((ResourceStates{ .render_target = true }).asBits(), tracked_bits);
}

test "submit command buffer injects shader resource state for bound sampled texture" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });
    const tex = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(tex);

    const set = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = tex } }},
    });

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();
    try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = set.id });

    try device.submitCommandBuffer(.graphics, &cmd, .{});

    const tracked_bits = backend.resource_state_bits.get(.{ .kind = .texture, .id = tex.id }) orelse 0;
    try std.testing.expectEqual((ResourceStates{ .shader_resource = true }).asBits(), tracked_bits);
}

test "prepare command buffer hoists automatic barriers to pass boundary" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });
    const sampled_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(sampled_texture);
    const color_target = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .color_target = true },
    });
    defer device.destroyTexture(color_target);

    const set = try device.createBindingSetCached(layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = sampled_texture } }},
    });

    var original = try device.createCommandBuffer(std.testing.allocator);
    defer original.deinit();
    try original.encodeBeginRenderPass(.{
        .color_target_id = color_target.id,
        .depth_target_id = 0,
        .clear_mask = 0,
    });
    try original.encodeSetBindingSet(.{ .slot = 0, .set_id = set.id });
    try original.encodeDraw(.{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try original.encodeEndRenderPass();

    var prepared = try device.prepareCommandBufferForSubmit(.graphics, &original);
    defer prepared.deinit();

    var decoder = prepared.decoder();
    var saw_begin_render_pass = false;
    var saw_end_render_pass = false;
    var barrier_count_before_pass: usize = 0;
    while (try decoder.next()) |decoded| {
        switch (decoded) {
            .pipeline_barrier => {
                if (saw_begin_render_pass and !saw_end_render_pass) {
                    return error.TestUnexpectedResult;
                }
                barrier_count_before_pass += 1;
            },
            .begin_render_pass => saw_begin_render_pass = true,
            .end_render_pass => saw_end_render_pass = true,
            else => {},
        }
    }

    try std.testing.expect(saw_begin_render_pass);
    try std.testing.expect(saw_end_render_pass);
    try std.testing.expect(barrier_count_before_pass >= 2);
}

test "prepare command buffer rejects explicit outside-pass barrier inside render pass" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const color_target = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .color_target = true },
    });
    defer device.destroyTexture(color_target);

    var original = try device.createCommandBuffer(std.testing.allocator);
    defer original.deinit();
    try original.encodeBeginRenderPass(.{
        .color_target_id = color_target.id,
        .depth_target_id = 0,
        .clear_mask = 0,
    });
    try original.encodePipelineBarrier(.{
        .resource_id = color_target.id,
        .src_state_bits = 0,
        .dst_state_bits = (ResourceStates{ .shader_resource = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .pass_scope = @intCast(@intFromEnum(BarrierPassScope.outside_pass)),
    });
    try original.encodeEndRenderPass();

    try std.testing.expectError(error.SubmitFailed, device.prepareCommandBufferForSubmit(.graphics, &original));
}

test "submit command buffer keeps buffer and texture states separate when ids overlap" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const layout = try device.createBindingLayout(.{
        .entries = &.{
            .{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            },
            .{
                .slot = 1,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            },
        },
    });

    const uniform_buffer = try device.createBuffer(.{
        .size = 64,
        .usage = .{ .uniform = true },
    });
    defer device.destroyBuffer(uniform_buffer);

    const sampled_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true },
    });
    defer device.destroyTexture(sampled_texture);

    try std.testing.expectEqual(uniform_buffer.id, sampled_texture.id);

    const set = try device.createBindingSetCached(layout, .{
        .entries = &.{
            .{ .slot = 0, .resource = .{ .texture = sampled_texture } },
            .{ .slot = 1, .resource = .{ .uniform_buffer = uniform_buffer } },
        },
    });

    var cmd = try device.createCommandBuffer(std.testing.allocator);
    defer cmd.deinit();
    try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = set.id });

    try device.submitCommandBuffer(.graphics, &cmd, .{});

    const texture_bits = backend.resource_state_bits.get(.{ .kind = .texture, .id = sampled_texture.id }) orelse 0;
    const buffer_bits = backend.resource_state_bits.get(.{ .kind = .buffer, .id = uniform_buffer.id }) orelse 0;
    try std.testing.expectEqual((ResourceStates{ .shader_resource = true }).asBits(), texture_bits);
    try std.testing.expectEqual((ResourceStates{ .constant_buffer = true }).asBits(), buffer_bits);
}

test "submit command buffer schedules producer-side release before cross-queue acquire" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const compute_layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .storage_texture,
            .stage = .compute,
        }},
    });
    const graphics_layout = try device.createBindingLayout(.{
        .entries = &.{.{
            .slot = 0,
            .binding_type = .texture,
            .stage = .fragment,
        }},
    });

    const shared_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .storage_write = true },
    });
    defer device.destroyTexture(shared_texture);

    const color_target = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .color_target = true },
    });
    defer device.destroyTexture(color_target);

    const compute_set = try device.createBindingSetCached(compute_layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .storage_texture = shared_texture } }},
    });
    const graphics_set = try device.createBindingSetCached(graphics_layout, .{
        .entries = &.{.{ .slot = 0, .resource = .{ .texture = shared_texture } }},
    });

    var compute_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer compute_cmd.deinit();
    try compute_cmd.encodeBeginComputePass(.{});
    try compute_cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = compute_set.id });
    try compute_cmd.encodeDispatch(.{ .x = 1, .y = 1, .z = 1 });
    try compute_cmd.encodeEndComputePass();

    try device.submitCommandBuffer(.compute, &compute_cmd, .{});

    var graphics_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer graphics_cmd.deinit();
    try graphics_cmd.encodeBeginRenderPass(.{
        .color_target_id = color_target.id,
        .depth_target_id = 0,
        .clear_mask = 0,
    });
    try graphics_cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = graphics_set.id });
    try graphics_cmd.encodeDraw(.{
        .vertex_count = 3,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    try graphics_cmd.encodeEndRenderPass();

    try device.submitCommandBuffer(.graphics, &graphics_cmd, .{});

    try std.testing.expectEqual(@as(usize, 3), backend.submit_queue_history.items.len);
    try std.testing.expectEqual(QueueClass.compute, backend.submit_queue_history.items[0]);
    try std.testing.expectEqual(QueueClass.compute, backend.submit_queue_history.items[1]);
    try std.testing.expectEqual(QueueClass.graphics, backend.submit_queue_history.items[2]);
    try std.testing.expectEqual(@as(usize, 3), backend.submit_records.items.len);
    try std.testing.expectEqual(@as(usize, 0), backend.submit_records.items[0].wait_count);
    try std.testing.expectEqual(@as(usize, 0), backend.submit_records.items[0].signal_count);
    try std.testing.expectEqual(@as(usize, 0), backend.submit_records.items[1].wait_count);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[1].signal_count);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[2].wait_count);

    const tracked_bits = backend.resource_state_bits.get(.{ .kind = .texture, .id = shared_texture.id }) orelse 0;
    try std.testing.expectEqual((ResourceStates{ .shader_resource = true }).asBits(), tracked_bits);
    try std.testing.expectEqual(QueueClass.graphics, backend.resource_owner_queue.get(.{ .kind = .texture, .id = shared_texture.id }).?);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_transfers.count());
}

test "consumer-side explicit full barrier triggers split release scheduling" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .storage_write = true },
    });
    defer device.destroyTexture(texture);

    var producer_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer producer_cmd.deinit();
    try producer_cmd.encodePipelineBarrier(.{
        .resource_id = texture.id,
        .src_state_bits = 0,
        .dst_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .src_queue = @intCast(@intFromEnum(QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(QueueClass.compute)),
    });
    try device.submitCommandBuffer(.compute, &producer_cmd, .{});

    var consumer_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer consumer_cmd.deinit();
    try consumer_cmd.encodePipelineBarrier(.{
        .resource_id = texture.id,
        .src_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .dst_state_bits = (ResourceStates{ .shader_resource = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .src_queue = @intCast(@intFromEnum(QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(QueueClass.graphics)),
    });
    try device.submitCommandBuffer(.graphics, &consumer_cmd, .{});

    try std.testing.expectEqual(@as(usize, 3), backend.submit_queue_history.items.len);
    try std.testing.expectEqual(QueueClass.compute, backend.submit_queue_history.items[1]);
    try std.testing.expectEqual(QueueClass.graphics, backend.submit_queue_history.items[2]);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[1].signal_count);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[2].wait_count);
    try std.testing.expectEqual(QueueClass.graphics, backend.resource_owner_queue.get(.{ .kind = .texture, .id = texture.id }).?);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_transfers.count());
}

test "explicit release stores semaphore and later acquire waits on it" {
    const metal_backend = @import("metal/metal_backend.zig");

    var backend = metal_backend.MetalBackend.init(std.testing.allocator);
    defer backend.deinit();
    var device = backend.createDevice();
    defer device.deinit();

    const texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .rgba8_unorm,
        .usage = .{ .sampled = true, .storage_write = true },
    });
    defer device.destroyTexture(texture);

    var producer_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer producer_cmd.deinit();
    try producer_cmd.encodePipelineBarrier(.{
        .resource_id = texture.id,
        .src_state_bits = 0,
        .dst_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .src_queue = @intCast(@intFromEnum(QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(QueueClass.compute)),
    });
    try producer_cmd.encodePipelineBarrier(.{
        .resource_id = texture.id,
        .src_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .dst_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .sync_action = @intCast(@intFromEnum(BarrierSyncAction.release)),
        .src_queue = @intCast(@intFromEnum(QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(QueueClass.graphics)),
    });
    try device.submitCommandBuffer(.compute, &producer_cmd, .{});

    var consumer_cmd = try device.createCommandBuffer(std.testing.allocator);
    defer consumer_cmd.deinit();
    try consumer_cmd.encodePipelineBarrier(.{
        .resource_id = texture.id,
        .src_state_bits = (ResourceStates{ .shader_resource = true, .unordered_access = true }).asBits(),
        .dst_state_bits = (ResourceStates{ .shader_resource = true }).asBits(),
        .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        .sync_action = @intCast(@intFromEnum(BarrierSyncAction.acquire)),
        .src_queue = @intCast(@intFromEnum(QueueClass.compute)),
        .dst_queue = @intCast(@intFromEnum(QueueClass.graphics)),
    });
    try device.submitCommandBuffer(.graphics, &consumer_cmd, .{});

    try std.testing.expectEqual(@as(usize, 2), backend.submit_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[0].signal_count);
    try std.testing.expectEqual(@as(usize, 1), backend.submit_records.items[1].wait_count);
    try std.testing.expectEqual(QueueClass.graphics, backend.resource_owner_queue.get(.{ .kind = .texture, .id = texture.id }).?);
    try std.testing.expectEqual(@as(usize, 0), backend.pending_transfers.count());
}
