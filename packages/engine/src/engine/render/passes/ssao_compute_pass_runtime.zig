const std = @import("std");
const gfx_mod = @import("../render_context.zig");
const gfx_types = @import("guava_rhi").types;
const shader_support = @import("../shader_support.zig");

pub const SSAOUniforms = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    view: [16]f32 = std.mem.zeroes([16]f32),
    inv_view: [16]f32 = std.mem.zeroes([16]f32),
    resolution: [2]f32 = .{ 1.0, 1.0 },
    radius: f32 = 0.5,
    bias: f32 = 0.025,
    intensity: f32 = 1.0,
    power: f32 = 2.0,
    kernel_size: u32 = 16,
    // std140 rounds the following vec2 up to the next 8-byte boundary.
    kernel_padding: u32 = 0,
    noise_scale: [2]f32 = .{ 1.0, 1.0 },
    padding: [2]f32 = .{ 0.0, 0.0 },
};

comptime {
    std.debug.assert(@sizeOf(SSAOUniforms) == 304);
    std.debug.assert(@offsetOf(SSAOUniforms, "noise_scale") == 288);
    std.debug.assert(@offsetOf(SSAOUniforms, "padding") == 296);
}

pub const SSAOComputePass = struct {
    pipeline: ?gfx_mod.ComputePipeline = null,
    sampler: ?gfx_mod.Sampler = null,
    noise_sampler: ?gfx_mod.Sampler = null,
    noise_texture: ?gfx_mod.Texture = null,

    pub fn init(device: *gfx_mod.RenderContext) !SSAOComputePass {
        var pass = SSAOComputePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SSAOComputePass, device: *gfx_mod.RenderContext) void {
        if (self.pipeline) |*p| device.releaseComputePipeline(p);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.noise_sampler) |*s| device.releaseSampler(s);
        if (self.noise_texture) |*t| device.releaseTexture(t);
        self.* = undefined;
    }

    pub fn isReady(self: *const SSAOComputePass) bool {
        return self.pipeline != null and self.sampler != null and self.noise_texture != null;
    }

    pub fn dispatch(
        self: *SSAOComputePass,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        depth_texture: *const gfx_mod.Texture,
        output_texture: *const gfx_mod.Texture,
        uniforms: SSAOUniforms,
    ) void {
        if (!self.isReady()) return;

        const compute_pass = device.beginComputePass(frame, &.{output_texture}, &.{}) catch return;
        device.bindComputePipeline(compute_pass, &self.pipeline.?);
        device.bindComputeSampledTextureBinding(compute_pass, 0, depth_texture, &self.sampler.?);
        device.bindComputeStorageTextureBinding(compute_pass, 1, output_texture);
        device.bindComputeSampledTextureBinding(compute_pass, 2, &self.noise_texture.?, &self.noise_sampler.?);
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&uniforms));

        const output_desc = device.textureDesc(output_texture);
        const group_x = (output_desc.width + 7) / 8;
        const group_y = (output_desc.height + 7) / 8;
        device.dispatchCompute(compute_pass, group_x, group_y, 1);
        device.endComputePass(compute_pass);
    }

    fn createResources(self: *SSAOComputePass, device: *gfx_mod.RenderContext) !void {
        self.pipeline = try shader_support.loadComputePipelineRW(device, "ssao_compute", 1, 0);
        errdefer if (self.pipeline) |*p| {
            device.releaseComputePipeline(p);
            self.pipeline = null;
        };

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*s| {
            device.releaseSampler(s);
            self.sampler = null;
        };

        self.noise_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });
        errdefer if (self.noise_sampler) |*s| {
            device.releaseSampler(s);
            self.noise_sampler = null;
        };

        var noise_data: [16 * 4]u8 = undefined;
        var rng = std.Random.DefaultPrng.init(123);
        for (0..16) |i| {
            const rx = rng.random().float(f32) * 2.0 - 1.0;
            const ry = rng.random().float(f32) * 2.0 - 1.0;
            const len = @sqrt(rx * rx + ry * ry);
            const nx: f32 = if (len > 0.001) rx / len else 0.0;
            const ny: f32 = if (len > 0.001) ry / len else 0.0;
            const base = i * 4;
            noise_data[base + 0] = @intFromFloat(@round((nx * 0.5 + 0.5) * 255.0));
            noise_data[base + 1] = @intFromFloat(@round((ny * 0.5 + 0.5) * 255.0));
            noise_data[base + 2] = 0;
            noise_data[base + 3] = 255;
        }

        self.noise_texture = try device.createTexture(.{
            .width = 4,
            .height = 4,
            .format = .rgba8_unorm,
            .usage = gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.noise_texture) |*t| {
            device.releaseTexture(t);
            self.noise_texture = null;
        };
        try device.uploadTextureData(&self.noise_texture.?, &noise_data, 4, 4);
    }
};
