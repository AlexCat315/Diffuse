const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("engine/render/render_context.zig");
const shader_support = @import("../shader_support.zig");

pub const RtShadowDenoiseUniforms = extern struct {
    resolution: [2]f32 = .{ 1.0, 1.0 },
    inv_resolution: [2]f32 = .{ 1.0, 1.0 },
    filter_params: [4]f32 = .{ 2.0, 140.0, 2.0, 0.0 },
};

pub const RtShadowDenoisePass = struct {
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    bound_shadow_handle: usize = 0,
    bound_depth_handle: usize = 0,
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.RenderContext) !RtShadowDenoisePass {
        var pass = RtShadowDenoisePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *RtShadowDenoisePass, device: *gfx_mod.RenderContext) void {
        if (self.bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        self.* = undefined;
    }

    pub fn isReady(self: *const RtShadowDenoisePass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    pub fn syncTextures(
        self: *RtShadowDenoisePass,
        device: *gfx_mod.RenderContext,
        shadow_mask_texture: *const gfx_mod.Texture,
        depth_texture: *const gfx_mod.Texture,
    ) !void {
        const shadow_handle = shadow_mask_texture.id;
        const depth_handle = depth_texture.id;
        if (self.bind_group != null and self.bound_shadow_handle == shadow_handle and self.bound_depth_handle == depth_handle) {
            return;
        }

        if (self.bind_group) |*bg| device.releaseBindGroup(bg);

        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{ .texture = shadow_mask_texture, .sampler = &self.sampler.? },
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_shadow_handle = shadow_handle;
        self.bound_depth_handle = depth_handle;
    }

    pub fn draw(
        self: *RtShadowDenoisePass,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: RtShadowDenoiseUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) return stats;

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, 3, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *RtShadowDenoisePass, device: *gfx_mod.RenderContext) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*s| device.releaseSampler(s);

        self.stages = try shader_support.loadProgramStages(device, "rt_shadow_denoise");
        errdefer if (self.stages) |*s| s.deinit(device);

        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{};
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{};

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .r8_unorm,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
            .blend_state = .{},
        });
    }
};
