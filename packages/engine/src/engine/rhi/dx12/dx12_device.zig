const std = @import("std");
const rhi = @import("../rhi.zig");
const rhi_types = @import("../types.zig");
const command_buffer = @import("../command_buffer.zig");
const queue_mod = @import("../queue.zig");

/// DX12 backend — stub skeleton (Windows only).
///
/// Architecture (same pattern as Vulkan/Metal backends):
///   Dx12Device (Zig, vtable impl) → dx12_bridge.cpp (C++) → D3D12 API
///
/// This is a skeleton that returns UnsupportedBackend for all operations
/// until the D3D12 C++ bridge is implemented.
pub const Dx12Device = struct {
    allocator: std.mem.Allocator,
    bridge_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, _: bool) ?Dx12Device {
        // TODO: implement D3D12 device creation via dx12_bridge.cpp
        _ = allocator;
        return null; // DX12 not yet implemented
    }

    pub fn deinit(self: *Dx12Device) void {
        self.* = undefined;
    }

    pub fn createDevice(self: *Dx12Device) rhi.Device {
        return rhi.Device.initWithCache(
            @ptrCast(self),
            &device_vtable,
            .{
                .compute = true,
                .ray_tracing = false,
                .indirect_draw = true,
                .mesh_shaders = false,
                .texture_3d = true,
                .texture_cube_native = true,
                .max_queues = .{ 1, 1, 1 },
            },
            self.allocator,
        );
    }

    pub fn getDeviceName(_: *const Dx12Device) []const u8 {
        return "DX12 (not implemented)";
    }
};

// ===================================================================
// VTable — stubs returning UnsupportedBackend
// ===================================================================

fn vtCreateBuffer(_: *anyopaque, _: rhi.BufferDesc) rhi.Error!rhi.Buffer {
    return error.UnsupportedBackend;
}

fn vtCreateTexture(_: *anyopaque, _: rhi.TextureDesc) rhi.Error!rhi.Texture {
    return error.UnsupportedBackend;
}

fn vtDestroyBuffer(_: *anyopaque, _: rhi.Buffer) void {}
fn vtDestroyTexture(_: *anyopaque, _: rhi.Texture) void {}

fn vtCreateCommandBuffer(_: *anyopaque, allocator: std.mem.Allocator) rhi.Error!command_buffer.CommandBuffer {
    return command_buffer.CommandBuffer.init(allocator);
}

fn vtAcquireSwapchainImage(_: *anyopaque) rhi.Error!rhi.SwapchainImage {
    return error.UnsupportedBackend;
}

fn vtSubmitCommandBuffer(_: *anyopaque, _: rhi.QueueClass, _: *const command_buffer.CommandBuffer, _: rhi.SubmitDesc) rhi.Error!void {
    return error.UnsupportedBackend;
}

fn vtPresent(_: *anyopaque, _: rhi.SwapchainImage) rhi.Error!void {
    return error.UnsupportedBackend;
}

fn vtGetQueue(_: *anyopaque, _: rhi.QueueClass) rhi.Error!queue_mod.Queue {
    return error.UnsupportedBackend;
}

fn vtCreateShaderModule(_: *anyopaque, _: rhi.ShaderModuleDesc) rhi.Error!rhi.ShaderModule {
    return error.UnsupportedBackend;
}

fn vtCreateGraphicsPipeline(_: *anyopaque, _: rhi.GraphicsPipelineDesc) rhi.Error!rhi.GraphicsPipeline {
    return error.UnsupportedBackend;
}

fn vtCreateComputePipeline(_: *anyopaque, _: rhi.ComputePipelineDesc) rhi.Error!rhi.ComputePipeline {
    return error.UnsupportedBackend;
}

fn vtDestroyGraphicsPipeline(_: *anyopaque, _: rhi.GraphicsPipeline) void {}
fn vtDestroyComputePipeline(_: *anyopaque, _: rhi.ComputePipeline) void {}

fn vtCreateSampler(_: *anyopaque, _: rhi.SamplerDesc) rhi.Error!rhi.Sampler {
    return error.UnsupportedBackend;
}

fn vtDestroySampler(_: *anyopaque, _: rhi.Sampler) void {}

fn vtUploadBufferData(_: *anyopaque, _: rhi.Buffer, _: u64, _: []const u8) rhi.Error!void {
    return error.UnsupportedBackend;
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
};
