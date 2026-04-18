const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("engine/rhi_legacy/mod.zig");
const shader_support = @import("../shader_support.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const TonemapPass = struct {
    pub const TonemapParams = extern struct {
        exposure_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
        bloom_params: [4]f32 = .{ 0.0, 0.35, 0.0, 0.0 },
        color_grading_params: [4]f32 = .{ 0.0, 1.0, 1.0, 1.0 },
        lut_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
    };

    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_hdr_handle: usize = 0,
    bound_bloom_handle: usize = 0,
    bound_lut_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !TonemapPass {
        var pass = TonemapPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *TonemapPass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const TonemapPass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *TonemapPass,
        device: *rhi_mod.RhiDevice,
        hdr_texture: *const rhi_mod.Texture,
        bloom_texture: ?*const rhi_mod.Texture,
        lut_texture: ?*const rhi_mod.Texture,
    ) !void {
        const bloom_tex = bloom_texture orelse hdr_texture;
        const lut_tex = lut_texture orelse hdr_texture;

        const hdr_handle = hdr_texture.id;
        const bloom_handle = bloom_tex.id;
        const lut_handle = lut_tex.id;
        if (self.bind_group != null and
            self.bound_hdr_handle == hdr_handle and
            self.bound_bloom_handle == bloom_handle and
            self.bound_lut_handle == lut_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [3]rhi_mod.TextureSamplerBinding{
            .{ .texture = hdr_texture, .sampler = &self.sampler.? },
            .{ .texture = bloom_tex, .sampler = &self.sampler.? },
            .{ .texture = lut_tex, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_hdr_handle = hdr_handle;
        self.bound_bloom_handle = bloom_handle;
        self.bound_lut_handle = lut_handle;
    }

    pub fn draw(
        self: *TonemapPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        params: TonemapParams,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&params));
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *TonemapPass, device: *rhi_mod.RhiDevice) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "tonemap");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{};
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{};

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .bgra8_unorm_srgb,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });
    }
};
