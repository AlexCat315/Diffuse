const std = @import("std");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const shader_support = @import("../shader_support.zig");

/// GPU-accelerated IBL precomputation using compute shaders.
/// Provides BRDF LUT generation and irradiance convolution on the GPU,
/// replacing the CPU path in ibl_precompute.zig.
pub const IBLComputePass = struct {
    brdf_pipeline: ?rhi_mod.ComputePipeline = null,
    irradiance_pipeline: ?rhi_mod.ComputePipeline = null,
    linear_sampler: ?rhi_mod.Sampler = null,

    pub fn init(device: *rhi_mod.RhiDevice) IBLComputePass {
        var pass = IBLComputePass{};
        pass.brdf_pipeline = shader_support.loadComputePipelineRW(device, "brdf_lut", 1, 0) catch null;
        pass.irradiance_pipeline = shader_support.loadComputePipelineRW(device, "irradiance_convolve", 1, 0) catch null;
        pass.linear_sampler = device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        }) catch null;
        return pass;
    }

    pub fn deinit(self: *IBLComputePass, device: *rhi_mod.RhiDevice) void {
        if (self.brdf_pipeline) |*p| device.releaseComputePipeline(p);
        if (self.irradiance_pipeline) |*p| device.releaseComputePipeline(p);
        if (self.linear_sampler) |*s| device.releaseSampler(s);
        self.* = undefined;
    }

    pub fn hasBRDF(self: *const IBLComputePass) bool {
        return self.brdf_pipeline != null;
    }

    pub fn hasIrradiance(self: *const IBLComputePass) bool {
        return self.irradiance_pipeline != null and self.linear_sampler != null;
    }

    /// Generate BRDF LUT into the given texture via GPU compute.
    /// The output texture must have usage compute_storage_write and format rg16_float.
    pub fn generateBRDFLUT(
        self: *IBLComputePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        output: *const rhi_mod.Texture,
        size: u32,
        sample_count: u32,
    ) !void {
        const pipeline = self.brdf_pipeline orelse return error.ComputePipelineCreateFailed;

        const compute_pass = try device.beginComputePass(frame, &.{output}, &.{});
        device.bindComputePipeline(compute_pass, &pipeline);

        device.bindComputeStorageTextureBinding(compute_pass, 0, output);

        const BRDFParams = extern struct {
            size: u32,
            sample_count: u32,
            padding: [2]f32,
        };
        const params = BRDFParams{
            .size = size,
            .sample_count = sample_count,
            .padding = .{ 0, 0 },
        };
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&params));

        device.dispatchCompute(compute_pass, (size + 7) / 8, (size + 7) / 8, 1);
        device.endComputePass(compute_pass);
    }

    /// Convolve an equirectangular environment map into a diffuse irradiance map.
    /// env_texture: source HDR equirectangular map (sampler2D).
    /// output: target irradiance texture (compute_storage_write, rgba16f).
    pub fn generateIrradianceMap(
        self: *IBLComputePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        env_texture: *const rhi_mod.Texture,
        output: *const rhi_mod.Texture,
        output_size: u32,
        sample_count: u32,
    ) !void {
        const pipeline = self.irradiance_pipeline orelse return error.ComputePipelineCreateFailed;
        const sampler = self.linear_sampler orelse return error.SamplerCreateFailed;

        const compute_pass = try device.beginComputePass(frame, &.{output}, &.{});
        device.bindComputePipeline(compute_pass, &pipeline);

        device.bindComputeSampledTextureBinding(compute_pass, 0, env_texture, &sampler);
        device.bindComputeStorageTextureBinding(compute_pass, 1, output);

        const IrradianceParams = extern struct {
            output_size: u32,
            sample_count: u32,
            padding: [2]f32,
        };
        const params = IrradianceParams{
            .output_size = output_size,
            .sample_count = sample_count,
            .padding = .{ 0, 0 },
        };
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&params));

        device.dispatchCompute(compute_pass, (output_size + 7) / 8, (output_size + 7) / 8, 1);
        device.endComputePass(compute_pass);
    }
};
