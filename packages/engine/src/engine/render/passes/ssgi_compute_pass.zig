const std = @import("std");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const shader_support = @import("../shader_support.zig");

pub const SSGIUniforms = extern struct {
    projection: [16]f32,
    inv_projection: [16]f32,
    view: [16]f32,
    inv_view: [16]f32,
    resolution: [2]f32,
    radius: f32,
    intensity: f32,
    bias: f32,
    ray_count: u32,
    step_count: u32,
    padding: f32 = 0.0,
};

pub const SSGIComputePass = struct {
    pipeline: ?rhi_mod.ComputePipeline = null,
    sampler: ?rhi_mod.Sampler = null,
    noise_texture: ?rhi_mod.Texture = null,
    noise_sampler: ?rhi_mod.Sampler = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SSGIComputePass {
        var pass = SSGIComputePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SSGIComputePass, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline) |*p| device.releaseComputePipeline(p);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.noise_sampler) |*s| device.releaseSampler(s);
        if (self.noise_texture) |*t| {
            var tex_mut = t.*;
            device.releaseTexture(&tex_mut);
        }
    }

    pub fn isReady(self: *const SSGIComputePass) bool {
        return self.pipeline != null and self.sampler != null and self.noise_texture != null and self.noise_sampler != null;
    }

    pub fn execute(
        self: *SSGIComputePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        output_texture: *const rhi_mod.Texture,
        depth_texture: *const rhi_mod.Texture,
        hdr_color_texture: *const rhi_mod.Texture,
        uniforms: SSGIUniforms,
    ) void {
        if (!self.isReady()) return;

        const compute_pass = device.beginComputePass(frame, &.{output_texture}, &.{}) catch return;
        device.bindComputePipeline(compute_pass, &self.pipeline.?);
        device.bindComputeSampledTextureBinding(compute_pass, 0, depth_texture, &self.sampler.?);
        device.bindComputeStorageTextureBinding(compute_pass, 1, output_texture);
        device.bindComputeSampledTextureBinding(compute_pass, 2, hdr_color_texture, &self.sampler.?);
        device.bindComputeSampledTextureBinding(compute_pass, 3, &self.noise_texture.?, &self.noise_sampler.?);
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&uniforms));

        const group_x = (output_texture.desc.width + 7) / 8;
        const group_y = (output_texture.desc.height + 7) / 8;
        device.dispatchCompute(compute_pass, group_x, group_y, 1);
        device.endComputePass(compute_pass);
    }

    fn createResources(self: *SSGIComputePass, device: *rhi_mod.RhiDevice) !void {
        self.pipeline = try shader_support.loadComputePipelineRW(device, "ssgi_compute", 1, 0);

        errdefer {
            if (self.pipeline) |*p| device.releaseComputePipeline(p);
        }

        self.sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        self.noise_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });

        // 4x4 noise texture for SSGI randomization
        var noise_data: [16 * 4]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(54321);
        const random = prng.random();
        for (0..16) |i| {
            const rx = random.float(f32) * 2.0 - 1.0;
            const ry = random.float(f32) * 2.0 - 1.0;
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
            .usage = rhi_types.TextureUsage.sampler,
            .label = "ssgi_noise",
        });
        errdefer if (self.noise_texture) |*t| {
            var tm = t.*;
            device.releaseTexture(&tm);
        };
        try device.uploadTextureData(&self.noise_texture.?, &noise_data, 4, 4);
    }
};
