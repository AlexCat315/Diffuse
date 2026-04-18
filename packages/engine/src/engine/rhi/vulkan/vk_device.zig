const std = @import("std");
const rhi = @import("../rhi.zig");
const rhi_types = @import("guava_rhi").types;
const command_buffer = @import("guava_rhi").command_buffer;
const queue_mod = @import("guava_rhi").queue;

/// Vulkan backend — implements DeviceVTable via Vulkan C API through vk_bridge.
///
/// Architecture (mirrors Metal backend pattern):
///   VulkanDevice (Zig, vtable impl) → vk_bridge.c (C) → Vulkan API
///
/// Resource model: u32 IDs → internal map of VkBuffer/VkImage/VkSampler etc. in bridge.
/// Command model: Software CommandBuffer byte stream decoded in vk_bridge submit.
pub const VulkanDevice = struct {
    allocator: std.mem.Allocator,
    bridge_ctx: *anyopaque,
    last_submit_queue: ?rhi.QueueClass = null,

    // ── Extern C bridge functions ─────────────────────────────────────
    const bridge = struct {
        // Lifecycle
        extern fn guava_vk_rhi_init(enable_validation: bool) ?*anyopaque;
        extern fn guava_vk_rhi_destroy(ctx: *anyopaque) void;
        // Surface / swapchain
        extern fn guava_vk_rhi_create_surface(ctx: *anyopaque, native_window: *anyopaque) bool;
        extern fn guava_vk_rhi_create_swapchain(ctx: *anyopaque, width: u32, height: u32, vsync_enabled: bool) bool;
        // Resource creation
        extern fn guava_vk_rhi_create_buffer(ctx: *anyopaque, size: u64, usage_bits: u32, label: ?[*:0]const u8) u32;
        extern fn guava_vk_rhi_create_texture(ctx: *anyopaque, desc: *const TextureDescC, label: ?[*:0]const u8) u32;
        extern fn guava_vk_rhi_create_sampler(ctx: *anyopaque, desc: *const SamplerDescC) u32;
        extern fn guava_vk_rhi_create_shader_module(ctx: *anyopaque, stage: u32, format: u32, code: [*]const u8, code_len: u32, entry_point: [*:0]const u8) u32;
        extern fn guava_vk_rhi_create_graphics_pipeline(ctx: *anyopaque, desc: *const GfxPipelineDescC, attrs: ?[*]const VertexAttributeC, buf_layouts: ?[*]const VertexBufferLayoutC) u32;
        extern fn guava_vk_rhi_create_compute_pipeline(ctx: *anyopaque, shader_id: u32) u32;
        // Resource destruction
        extern fn guava_vk_rhi_destroy_buffer(ctx: *anyopaque, id: u32) void;
        extern fn guava_vk_rhi_destroy_texture(ctx: *anyopaque, id: u32) void;
        extern fn guava_vk_rhi_destroy_sampler(ctx: *anyopaque, id: u32) void;
        extern fn guava_vk_rhi_destroy_graphics_pipeline(ctx: *anyopaque, id: u32) void;
        extern fn guava_vk_rhi_destroy_compute_pipeline(ctx: *anyopaque, id: u32) void;
        // Data transfer
        extern fn guava_vk_rhi_upload_buffer_data(ctx: *anyopaque, buffer_id: u32, offset: u64, data: [*]const u8, size: u64) bool;
        extern fn guava_vk_rhi_upload_texture_data(ctx: *anyopaque, texture_id: u32, data: [*]const u8, size: u64, width: u32, height: u32, bytes_per_row: u32) bool;
        extern fn guava_vk_rhi_read_texture_data(ctx: *anyopaque, texture_id: u32, width: u32, height: u32, bytes_per_row: u32, out_data: [*]u8, out_size: u64) bool;
        // Binding set
        extern fn guava_vk_rhi_register_binding_set(ctx: *anyopaque, set_id: u32, entries: [*]const BindingEntryC, count: u32) void;
        // Command submission
        extern fn guava_vk_rhi_submit(ctx: *anyopaque, queue_class: u32, cmd_bytes: [*]const u8, cmd_len: u32, desc: *const SubmitDescC) bool;
        // Swapchain
        extern fn guava_vk_rhi_acquire_swapchain(ctx: *anyopaque, out_id: *u32, out_w: *u32, out_h: *u32) bool;
        extern fn guava_vk_rhi_present(ctx: *anyopaque, swapchain_id: u32) bool;
        // Debug
        extern fn guava_vk_rhi_get_device_name(ctx: *anyopaque) ?[*:0]const u8;
        // Shared texture (cross-process viewport)
        extern fn guava_vk_rhi_create_shared_texture(ctx: *anyopaque, width: u32, height: u32, format: u32, usage_bits: u32, label: ?[*:0]const u8) SharedTextureResultC;
        extern fn guava_vk_rhi_blit_shared_texture(ctx: *anyopaque, texture_id: u32) bool;
        extern fn guava_vk_rhi_destroy_shared_texture(ctx: *anyopaque, texture_id: u32) void;
    };

    // ── FFI-compatible packed structs ──────────────────────────────────
    const TextureDescC = extern struct {
        width: u32,
        height: u32,
        depth: u32,
        layers: u32,
        mip_levels: u32,
        sample_count: u32,
        format: u32,
        usage_bits: u32,
        dimension: u32,
    };

    const SamplerDescC = extern struct {
        min_filter: u32,
        mag_filter: u32,
        mipmap_mode: u32,
        address_u: u32,
        address_v: u32,
        address_w: u32,
        enable_compare: u32,
        compare_op: u32,
    };

    const GfxPipelineDescC = extern struct {
        vertex_shader_id: u32,
        fragment_shader_id: u32,
        color_format: u32,
        depth_format: u32,
        primitive: u32,
        depth_compare_op: u32,
        depth_write_enabled: u32,
        vertex_attr_count: u32,
        vertex_buffer_layout_count: u32,
        blend_enabled: u32,
        src_color_blend: u32,
        dst_color_blend: u32,
        color_blend_op: u32,
        src_alpha_blend: u32,
        dst_alpha_blend: u32,
        alpha_blend_op: u32,
    };

    const VertexAttributeC = extern struct {
        location: u32,
        format: u32,
        offset: u32,
        buffer_index: u32,
    };

    const VertexBufferLayoutC = extern struct {
        stride: u32,
        step_rate: u32,
    };

    pub const BindingEntryC = extern struct {
        slot: u32,
        resource_type: u32, // 0=sampler,1=texture,2=storage_texture,3=uniform_buffer,4=storage_buffer
        stage: u32, // 0=vertex,1=fragment,2=compute
        resource_id: u32,
    };

    const TimelineSemaphoreC = extern struct {
        id: u32,
        value: u64,
    };

    const SubmitDescC = extern struct {
        wait_semaphores: ?[*]const TimelineSemaphoreC,
        wait_count: u32,
        signal_semaphores: ?[*]const TimelineSemaphoreC,
        signal_count: u32,
    };

    const SharedTextureResultC = extern struct {
        texture_id: u32,
        shm_name: [64]u8,
    };

    const MarshaledSubmitDesc = struct {
        wait_semaphores: []TimelineSemaphoreC = &.{},
        signal_semaphores: []TimelineSemaphoreC = &.{},
        desc: SubmitDescC,

        fn deinit(self: *MarshaledSubmitDesc, allocator: std.mem.Allocator) void {
            if (self.wait_semaphores.len > 0) allocator.free(self.wait_semaphores);
            if (self.signal_semaphores.len > 0) allocator.free(self.signal_semaphores);
            self.* = undefined;
        }
    };

    // ── Lifecycle ─────────────────────────────────────────────────────
    pub fn init(allocator: std.mem.Allocator, enable_validation: bool) ?VulkanDevice {
        const ctx = bridge.guava_vk_rhi_init(enable_validation) orelse return null;
        return .{
            .allocator = allocator,
            .bridge_ctx = ctx,
        };
    }

    pub fn deinit(self: *VulkanDevice) void {
        bridge.guava_vk_rhi_destroy(self.bridge_ctx);
        self.* = undefined;
    }

    pub fn createSurface(self: *VulkanDevice, native_window: *anyopaque) bool {
        return bridge.guava_vk_rhi_create_surface(self.bridge_ctx, native_window);
    }

    pub fn createSwapchain(self: *VulkanDevice, width: u32, height: u32, vsync_enabled: bool) bool {
        return bridge.guava_vk_rhi_create_swapchain(self.bridge_ctx, width, height, vsync_enabled);
    }

    pub fn createDevice(self: *VulkanDevice) rhi.Device {
        return rhi.Device.initWithCache(
            @ptrCast(self),
            &device_vtable,
            .{
                .compute = true,
                .ray_tracing = false, // TODO: probe VK_KHR_ray_tracing_pipeline
                .indirect_draw = true,
                .mesh_shaders = false,
                .texture_3d = true,
                .texture_cube_native = true,
                .max_queues = .{ 1, 1, 1 },
            },
            self.allocator,
        );
    }

    pub fn getDeviceName(self: *const VulkanDevice) []const u8 {
        const name = bridge.guava_vk_rhi_get_device_name(self.bridge_ctx) orelse return "Unknown Vulkan Device";
        return std.mem.sliceTo(name, 0);
    }

    // ── Shared texture (Linux cross-process viewport) ─────────────────

    pub const SharedTextureResult = struct { texture_id: u32, shm_name: [64]u8 };

    pub fn createSharedTexture(
        self: *VulkanDevice,
        width: u32,
        height: u32,
        format: u32,
        usage_bits: u32,
        label: ?[*:0]const u8,
    ) SharedTextureResult {
        const c_result = bridge.guava_vk_rhi_create_shared_texture(
            self.bridge_ctx,
            width,
            height,
            format,
            usage_bits,
            label,
        );
        return .{ .texture_id = c_result.texture_id, .shm_name = c_result.shm_name };
    }

    pub fn blitSharedTexture(self: *VulkanDevice, texture_id: u32) bool {
        return bridge.guava_vk_rhi_blit_shared_texture(self.bridge_ctx, texture_id);
    }

    /// Register a binding set with the Vulkan bridge so it knows what resources
    /// to bind when the command buffer references this set_id.
    pub fn registerBindingSet(
        self: *VulkanDevice,
        set_id: u32,
        layout_entries: []const rhi.BindingLayoutEntry,
        set_entries: []const rhi.BindingSetEntry,
    ) void {
        var c_entries = std.ArrayList(BindingEntryC).empty;
        defer c_entries.deinit(self.allocator);

        for (set_entries) |se| {
            var stage: u32 = 1; // default fragment
            var res_type: u32 = 1; // default texture
            for (layout_entries) |le| {
                if (le.slot == se.slot) {
                    stage = @intFromEnum(le.stage);
                    res_type = @intFromEnum(le.binding_type);
                    break;
                }
            }
            const resource_id: u32 = switch (se.resource) {
                .sampler => |r| r.id,
                .texture => |r| r.id,
                .storage_texture => |r| r.id,
                .uniform_buffer => |r| r.id,
                .storage_buffer => |r| r.id,
                .accel_structure => |r| r.id,
            };
            c_entries.append(self.allocator, .{
                .slot = se.slot,
                .resource_type = res_type,
                .stage = stage,
                .resource_id = resource_id,
            }) catch return;
        }

        if (c_entries.items.len > 0) {
            bridge.guava_vk_rhi_register_binding_set(
                self.bridge_ctx,
                set_id,
                c_entries.items.ptr,
                @intCast(c_entries.items.len),
            );
        }
    }
};

// ===================================================================
// VTable implementation — each function casts ctx to *VulkanDevice
// ===================================================================

fn vtCreateBuffer(ctx: *anyopaque, desc: rhi.BufferDesc) rhi.Error!rhi.Buffer {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    const label_ptr: ?[*:0]const u8 = if (desc.label) |l| @ptrCast(l.ptr) else null;
    const id = VulkanDevice.bridge.guava_vk_rhi_create_buffer(
        self.bridge_ctx,
        desc.size,
        desc.usage.bits(),
        label_ptr,
    );
    if (id == 0) return error.OutOfMemory;
    return .{ .id = id };
}

fn vtCreateTexture(ctx: *anyopaque, desc: rhi.TextureDesc) rhi.Error!rhi.Texture {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    const c_desc = VulkanDevice.TextureDescC{
        .width = desc.width,
        .height = desc.height,
        .depth = desc.depth,
        .layers = desc.layers,
        .mip_levels = desc.mip_levels,
        .sample_count = desc.sample_count,
        .format = @intFromEnum(desc.format),
        .usage_bits = desc.usage.bits(),
        .dimension = @intFromEnum(desc.dimension),
    };
    const label_ptr: ?[*:0]const u8 = if (desc.label) |l| @ptrCast(l.ptr) else null;
    const id = VulkanDevice.bridge.guava_vk_rhi_create_texture(self.bridge_ctx, &c_desc, label_ptr);
    if (id == 0) return error.OutOfMemory;
    return .{ .id = id };
}

fn vtDestroyBuffer(ctx: *anyopaque, buffer: rhi.Buffer) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    VulkanDevice.bridge.guava_vk_rhi_destroy_buffer(self.bridge_ctx, buffer.id);
}

fn vtDestroyTexture(ctx: *anyopaque, texture: rhi.Texture) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    VulkanDevice.bridge.guava_vk_rhi_destroy_texture(self.bridge_ctx, texture.id);
}

fn vtCreateCommandBuffer(ctx: *anyopaque, allocator: std.mem.Allocator) rhi.Error!command_buffer.CommandBuffer {
    _ = ctx;
    return command_buffer.CommandBuffer.init(allocator);
}

fn vtAcquireSwapchainImage(ctx: *anyopaque) rhi.Error!rhi.SwapchainImage {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    var out_id: u32 = 0;
    var out_w: u32 = 0;
    var out_h: u32 = 0;
    if (!VulkanDevice.bridge.guava_vk_rhi_acquire_swapchain(
        self.bridge_ctx,
        &out_id,
        &out_w,
        &out_h,
    )) return error.SwapchainAcquireFailed;
    return .{ .id = out_id, .width = out_w, .height = out_h };
}

fn vtSubmitCommandBuffer(
    ctx: *anyopaque,
    queue_class: rhi.QueueClass,
    cmd: *const command_buffer.CommandBuffer,
    desc: rhi.SubmitDesc,
) rhi.Error!void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    self.last_submit_queue = queue_class;

    const bytes = cmd.rawBytes();
    var marshaled_desc = try marshalSubmitDesc(self.allocator, desc);
    defer marshaled_desc.deinit(self.allocator);

    if (!VulkanDevice.bridge.guava_vk_rhi_submit(
        self.bridge_ctx,
        @intFromEnum(queue_class),
        bytes.ptr,
        @intCast(bytes.len),
        &marshaled_desc.desc,
    )) return error.SubmitFailed;
}

fn vtPresent(ctx: *anyopaque, image: rhi.SwapchainImage) rhi.Error!void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    if (!VulkanDevice.bridge.guava_vk_rhi_present(self.bridge_ctx, image.id))
        return error.PresentFailed;
}

fn vtGetQueue(ctx: *anyopaque, class: rhi.QueueClass) rhi.Error!queue_mod.Queue {
    return switch (class) {
        .graphics => .{ .class = .graphics, .ctx = ctx, .submit_fn = submitGraphics },
        .compute => .{ .class = .compute, .ctx = ctx, .submit_fn = submitCompute },
        .transfer => .{ .class = .transfer, .ctx = ctx, .submit_fn = submitTransfer },
    };
}

fn submitGraphics(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    return vtSubmitCommandBuffer(ctx, .graphics, cmd, desc);
}

fn submitCompute(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    return vtSubmitCommandBuffer(ctx, .compute, cmd, desc);
}

fn submitTransfer(ctx: *anyopaque, cmd: *const command_buffer.CommandBuffer, desc: queue_mod.SubmitDesc) !void {
    return vtSubmitCommandBuffer(ctx, .transfer, cmd, desc);
}

fn marshalSubmitDesc(allocator: std.mem.Allocator, desc: queue_mod.SubmitDesc) !VulkanDevice.MarshaledSubmitDesc {
    const wait_semaphores = try marshalTimelineSemaphores(allocator, desc.wait_semaphores);
    errdefer if (wait_semaphores.len > 0) allocator.free(wait_semaphores);
    const signal_semaphores = try marshalTimelineSemaphores(allocator, desc.signal_semaphores);
    errdefer if (signal_semaphores.len > 0) allocator.free(signal_semaphores);

    return .{
        .wait_semaphores = wait_semaphores,
        .signal_semaphores = signal_semaphores,
        .desc = .{
            .wait_semaphores = if (wait_semaphores.len > 0) wait_semaphores.ptr else null,
            .wait_count = @intCast(wait_semaphores.len),
            .signal_semaphores = if (signal_semaphores.len > 0) signal_semaphores.ptr else null,
            .signal_count = @intCast(signal_semaphores.len),
        },
    };
}

fn marshalTimelineSemaphores(allocator: std.mem.Allocator, semaphores: []const queue_mod.TimelineSemaphore) ![]VulkanDevice.TimelineSemaphoreC {
    if (semaphores.len == 0) return &.{};

    const marshaled = try allocator.alloc(VulkanDevice.TimelineSemaphoreC, semaphores.len);
    for (semaphores, marshaled) |src, *dst| {
        dst.* = .{
            .id = src.id,
            .value = src.value,
        };
    }
    return marshaled;
}

fn vtCreateShaderModule(ctx: *anyopaque, desc: rhi.ShaderModuleDesc) rhi.Error!rhi.ShaderModule {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    const id = VulkanDevice.bridge.guava_vk_rhi_create_shader_module(
        self.bridge_ctx,
        @intFromEnum(desc.stage),
        @intFromEnum(desc.format),
        desc.code.ptr,
        @intCast(desc.code.len),
        desc.entry_point.ptr,
    );
    if (id == 0) return error.InvalidArgument;
    return .{ .id = id };
}

fn vtCreateGraphicsPipeline(ctx: *anyopaque, desc: rhi.GraphicsPipelineDesc) rhi.Error!rhi.GraphicsPipeline {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));

    const ds = desc.depth_stencil orelse rhi.DepthStencilState{};
    const depth_compare: u32 = @intFromEnum(ds.depth_compare);
    const depth_write: u32 = if (ds.depth_write) 1 else 0;

    const vl = desc.vertex_layout;
    const attr_count: u32 = if (vl) |v| @intCast(v.attributes.len) else 0;
    const buf_layout_count: u32 = if (vl) |v| @intCast(v.buffer_layouts.len) else 0;

    const c_desc = VulkanDevice.GfxPipelineDescC{
        .vertex_shader_id = desc.vertex.id,
        .fragment_shader_id = if (desc.fragment) |fragment| fragment.id else 0,
        .color_format = @intFromEnum(desc.color_format),
        .depth_format = if (desc.depth_format) |df| @intFromEnum(df) else 0,
        .primitive = @intFromEnum(desc.primitive),
        .depth_compare_op = depth_compare,
        .depth_write_enabled = depth_write,
        .vertex_attr_count = attr_count,
        .vertex_buffer_layout_count = buf_layout_count,
        .blend_enabled = if (desc.blend_state) |bs| @intFromBool(bs.enable_blend) else 0,
        .src_color_blend = if (desc.blend_state) |bs| @intFromEnum(bs.src_color_blendfactor) else 0,
        .dst_color_blend = if (desc.blend_state) |bs| @intFromEnum(bs.dst_color_blendfactor) else 0,
        .color_blend_op = if (desc.blend_state) |bs| @intFromEnum(bs.color_blend_op) else 0,
        .src_alpha_blend = if (desc.blend_state) |bs| @intFromEnum(bs.src_alpha_blendfactor) else 0,
        .dst_alpha_blend = if (desc.blend_state) |bs| @intFromEnum(bs.dst_alpha_blendfactor) else 0,
        .alpha_blend_op = if (desc.blend_state) |bs| @intFromEnum(bs.alpha_blend_op) else 0,
    };

    var c_attrs_buf: [32]VulkanDevice.VertexAttributeC = undefined;
    var c_layouts_buf: [8]VulkanDevice.VertexBufferLayoutC = undefined;
    var c_attrs_ptr: ?[*]const VulkanDevice.VertexAttributeC = null;
    var c_layouts_ptr: ?[*]const VulkanDevice.VertexBufferLayoutC = null;

    if (vl) |v| {
        for (v.attributes, 0..) |attr, i| {
            if (i >= c_attrs_buf.len) break;
            c_attrs_buf[i] = .{
                .location = attr.location,
                .format = @intFromEnum(attr.format),
                .offset = attr.offset,
                .buffer_index = attr.buffer_index,
            };
        }
        if (attr_count > 0) c_attrs_ptr = &c_attrs_buf;

        for (v.buffer_layouts, 0..) |bl, i| {
            if (i >= c_layouts_buf.len) break;
            c_layouts_buf[i] = .{
                .stride = bl.stride,
                .step_rate = @intFromEnum(bl.step_rate),
            };
        }
        if (buf_layout_count > 0) c_layouts_ptr = &c_layouts_buf;
    }

    const id = VulkanDevice.bridge.guava_vk_rhi_create_graphics_pipeline(
        self.bridge_ctx,
        &c_desc,
        c_attrs_ptr,
        c_layouts_ptr,
    );
    if (id == 0) return error.InvalidArgument;
    return .{ .id = id };
}

fn vtCreateComputePipeline(ctx: *anyopaque, desc: rhi.ComputePipelineDesc) rhi.Error!rhi.ComputePipeline {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    const id = VulkanDevice.bridge.guava_vk_rhi_create_compute_pipeline(
        self.bridge_ctx,
        desc.shader.id,
    );
    if (id == 0) return error.InvalidArgument;
    return .{ .id = id };
}

fn vtDestroyGraphicsPipeline(ctx: *anyopaque, pipeline: rhi.GraphicsPipeline) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    VulkanDevice.bridge.guava_vk_rhi_destroy_graphics_pipeline(self.bridge_ctx, pipeline.id);
}

fn vtDestroyComputePipeline(ctx: *anyopaque, pipeline: rhi.ComputePipeline) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    VulkanDevice.bridge.guava_vk_rhi_destroy_compute_pipeline(self.bridge_ctx, pipeline.id);
}

fn vtCreateSampler(ctx: *anyopaque, desc: rhi.SamplerDesc) rhi.Error!rhi.Sampler {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    const c_desc = VulkanDevice.SamplerDescC{
        .min_filter = @intFromEnum(desc.min_filter),
        .mag_filter = @intFromEnum(desc.mag_filter),
        .mipmap_mode = @intFromEnum(desc.mipmap_mode),
        .address_u = @intFromEnum(desc.address_mode_u),
        .address_v = @intFromEnum(desc.address_mode_v),
        .address_w = @intFromEnum(desc.address_mode_w),
        .enable_compare = if (desc.enable_compare) 1 else 0,
        .compare_op = @intFromEnum(desc.compare_op),
    };
    const id = VulkanDevice.bridge.guava_vk_rhi_create_sampler(self.bridge_ctx, &c_desc);
    if (id == 0) return error.OutOfMemory;
    return .{ .id = id };
}

fn vtDestroySampler(ctx: *anyopaque, sampler: rhi.Sampler) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    VulkanDevice.bridge.guava_vk_rhi_destroy_sampler(self.bridge_ctx, sampler.id);
}

fn vtUploadBufferData(ctx: *anyopaque, buffer: rhi.Buffer, offset: u64, data: []const u8) rhi.Error!void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    if (!VulkanDevice.bridge.guava_vk_rhi_upload_buffer_data(
        self.bridge_ctx,
        buffer.id,
        offset,
        data.ptr,
        data.len,
    )) return error.InvalidArgument;
}

fn vtRegisterBindingSet(ctx: *anyopaque, set_id: u32, layout_entries: []const rhi.BindingLayoutEntry, set_entries: []const rhi.BindingSetEntry) void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    self.registerBindingSet(set_id, layout_entries, set_entries);
}

fn vtUploadTextureData(ctx: *anyopaque, texture: rhi.Texture, data: []const u8, width: u32, height: u32, bytes_per_row: u32) rhi.Error!void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    if (!VulkanDevice.bridge.guava_vk_rhi_upload_texture_data(
        self.bridge_ctx,
        texture.id,
        data.ptr,
        data.len,
        width,
        height,
        bytes_per_row,
    )) return error.InvalidArgument;
}

fn vtReadTextureData(ctx: *anyopaque, texture: rhi.Texture, width: u32, height: u32, bytes_per_row: u32, out_data: []u8) rhi.Error!void {
    const self: *VulkanDevice = @ptrCast(@alignCast(ctx));
    if (!VulkanDevice.bridge.guava_vk_rhi_read_texture_data(
        self.bridge_ctx,
        texture.id,
        width,
        height,
        bytes_per_row,
        out_data.ptr,
        out_data.len,
    )) return error.InvalidArgument;
}

const device_vtable = rhi.DeviceVTable{
    .create_buffer = vtCreateBuffer,
    .create_texture = vtCreateTexture,
    .destroy_buffer = vtDestroyBuffer,
    .destroy_texture = vtDestroyTexture,
    .create_command_buffer = vtCreateCommandBuffer,
    .acquire_swapchain_image = vtAcquireSwapchainImage,
    .submit_command_buffer = vtSubmitCommandBuffer,
    .present = vtPresent,
    .get_queue = vtGetQueue,
    .create_shader_module = vtCreateShaderModule,
    .create_graphics_pipeline = vtCreateGraphicsPipeline,
    .create_compute_pipeline = vtCreateComputePipeline,
    .destroy_graphics_pipeline = vtDestroyGraphicsPipeline,
    .destroy_compute_pipeline = vtDestroyComputePipeline,
    .create_sampler = vtCreateSampler,
    .destroy_sampler = vtDestroySampler,
    .upload_buffer_data = vtUploadBufferData,
    .upload_texture_data = vtUploadTextureData,
    .read_texture_data = vtReadTextureData,
    .register_binding_set = vtRegisterBindingSet,
};

test "marshalSubmitDesc encodes timeline semaphores" {
    const testing = std.testing;
    var marshaled = try marshalSubmitDesc(testing.allocator, .{
        .wait_semaphores = &.{.{ .id = 11, .value = 13 }},
        .signal_semaphores = &.{.{ .id = 17, .value = 19 }},
    });
    defer marshaled.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), marshaled.desc.wait_count);
    try testing.expectEqual(@as(u32, 1), marshaled.desc.signal_count);
    try testing.expect(marshaled.desc.wait_semaphores != null);
    try testing.expect(marshaled.desc.signal_semaphores != null);
    try testing.expectEqual(@as(u32, 11), marshaled.wait_semaphores[0].id);
    try testing.expectEqual(@as(u64, 13), marshaled.wait_semaphores[0].value);
    try testing.expectEqual(@as(u32, 17), marshaled.signal_semaphores[0].id);
    try testing.expectEqual(@as(u64, 19), marshaled.signal_semaphores[0].value);
}

test "marshalSubmitDesc leaves empty semaphore lists null" {
    const testing = std.testing;
    var marshaled = try marshalSubmitDesc(testing.allocator, .{});
    defer marshaled.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), marshaled.desc.wait_count);
    try testing.expectEqual(@as(u32, 0), marshaled.desc.signal_count);
    try testing.expect(marshaled.desc.wait_semaphores == null);
    try testing.expect(marshaled.desc.signal_semaphores == null);
}
