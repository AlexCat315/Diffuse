const std = @import("std");
const types = @import("guava_gfx").types;
const gfx = @import("guava_gfx").gfx;
const metal_backend_mod = @import("guava_gfx").metal_backend;
const window_mod = @import("../engine/platform/window.zig");

pub const Error = error{
    OutOfMemory,
};

pub const MockInitResult = struct {
    device: *gfx.Device,
    backend: *metal_backend_mod.MetalBackend,
    runtime_info: types.RuntimeInfo,
};

pub fn init(
    allocator: std.mem.Allocator,
    window: *window_mod.Window,
) Error!MockInitResult {
    const backend_ptr = allocator.create(metal_backend_mod.MetalBackend) catch return error.OutOfMemory;
    errdefer allocator.destroy(backend_ptr);
    backend_ptr.* = metal_backend_mod.MetalBackend.init(allocator);
    errdefer backend_ptr.deinit();

    const dev_ptr = allocator.create(gfx.Device) catch return error.OutOfMemory;
    errdefer allocator.destroy(dev_ptr);
    dev_ptr.* = backend_ptr.createDevice();

    var runtime_info: types.RuntimeInfo = .{
        .backend = .metal,
        .drawable_width = window.drawable_width,
        .drawable_height = window.drawable_height,
        .swapchain_format = .bgra8_unorm_srgb,
        .depth_format = .d32_float,
        .has_depth = true,
    };
    copyCStringSlice(runtime_info.device_name[0..], "Mock Metal Device");
    copyCStringSlice(runtime_info.driver_name[0..], "Mock");
    copyCStringSlice(runtime_info.driver_info[0..], "Guava Mock GFX");

    return .{
        .device = dev_ptr,
        .backend = backend_ptr,
        .runtime_info = runtime_info,
    };
}

fn copyCStringSlice(dest: []u8, src: []const u8) void {
    if (dest.len == 0) return;
    const max_copy = if (dest.len > 0) dest.len - 1 else 0;
    const count = @min(max_copy, src.len);
    @memset(dest, 0);
    std.mem.copyForwards(u8, dest[0..count], src[0..count]);
    dest[count] = 0;
}
