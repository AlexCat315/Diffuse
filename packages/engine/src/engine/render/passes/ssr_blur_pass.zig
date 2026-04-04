const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../../rhi/device.zig");
const shader_support = @import("../shader_support.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const SSRBlurParams = extern struct {
    direction: [2]f32 = .{ 1.0, 0.0 },
    blur_strength: f32 = 1.0,
    depth_threshold: f32 = 0.01,
};

pub const SSRBlurPass = struct {
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_ssr_handle: usize = 0,
    bound_depth_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SSRBlurPass {
        var pass = SSRBlurPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SSRBlurPass, device: *rhi_mod.RhiDevice) void {
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

    pub fn isReady(self: *const SSRBlurPass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *SSRBlurPass,
        device: *rhi_mod.RhiDevice,
        ssr_texture: *const rhi_mod.Texture,
        depth_texture: *const rhi_mod.Texture,
    ) !void {
        const ssr_handle = ssr_texture.id;
        const depth_handle = depth_texture.id;
        if (self.bind_group != null and self.bound_ssr_handle == ssr_handle and self.bound_depth_handle == depth_handle) {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [2]rhi_mod.TextureSamplerBinding{
            .{ .texture = ssr_texture, .sampler = &self.sampler.? },
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_ssr_handle = ssr_handle;
        self.bound_depth_handle = depth_handle;
    }

    pub fn draw(
        self: *SSRBlurPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        uniforms: SSRBlurParams,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *SSRBlurPass, device: *rhi_mod.RhiDevice) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "ssr_blur");
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
            .color_format = .rgba16_float,
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
