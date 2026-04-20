//! 战争迷雾 GPU 渲染通道
//!
//! 全屏 fragment pass：读取可见性纹理（R8），在场景颜色上叠加迷雾。
//! 遵循引擎 PostProcess pass 模式（FXAA/Tonemap 等）。

const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("../render_context.zig");
const gfx_types = @import("guava_rhi").types;
const shader_support = @import("../shader_support.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

/// 传递给 fragment shader 的 uniform 参数
pub const FogUniforms = extern struct {
    /// 未探索区域颜色 (R, G, B, A)
    unexplored_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    /// 已探索区域颜色 (R, G, B, A)
    explored_color: [4]f32 = .{ 0.0, 0.0, 0.0, 0.6 },
    /// 网格在世界空间的参数: (origin_x, origin_z, 1/total_width_world, 1/total_height_world)
    grid_world_params: [4]f32 = .{ 0.0, 0.0, 1.0, 1.0 },
    /// 相机逆 VP 矩阵 — 用于从 UV 重建世界坐标
    inv_view_projection: [16]f32 = std.mem.zeroes([16]f32),
};

comptime {
    // 确保 layout 与 std140 期望一致：3 × vec4 + mat4 = 48 + 64 = 112
    std.debug.assert(@sizeOf(FogUniforms) == 112);
}

pub const FogOfWarPass = struct {
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    bound_texture_handle: usize = 0,
    /// 可见性纹理（R8）
    fog_texture: ?gfx_mod.Texture = null,
    fog_texture_width: u16 = 0,
    fog_texture_height: u16 = 0,

    pub fn init(device: *gfx_mod.RenderContext) !FogOfWarPass {
        var pass = FogOfWarPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *FogOfWarPass, device: *gfx_mod.RenderContext) void {
        if (self.bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        if (self.fog_texture) |*t| device.releaseTexture(t);
        self.* = undefined;
    }

    pub fn isReady(self: *const FogOfWarPass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    /// 上传可见性数据到 GPU 纹理。如果尺寸变化则重新创建纹理。
    pub fn uploadVisibility(
        self: *FogOfWarPass,
        device: *gfx_mod.RenderContext,
        data: []const u8,
        width: u16,
        height: u16,
    ) !void {
        // 如果尺寸变化，重建纹理
        if (self.fog_texture == null or self.fog_texture_width != width or self.fog_texture_height != height) {
            if (self.fog_texture) |*t| device.releaseTexture(t);
            if (self.bind_group) |*bg| {
                device.releaseBindGroup(bg);
                self.bind_group = null;
            }
            self.fog_texture = try device.createTexture(.{
                .width = width,
                .height = height,
                .format = .r8_unorm,
                .usage = gfx_types.TextureUsage.sampler,
            });
            self.fog_texture_width = width;
            self.fog_texture_height = height;
        }

        try device.uploadTextureData(&self.fog_texture.?, data, width, height);

        // 重建 bind group（纹理可能是新的）
        const tex_handle = self.fog_texture.?.id;
        if (self.bind_group == null or self.bound_texture_handle != tex_handle) {
            if (self.bind_group) |*bg| device.releaseBindGroup(bg);
            const bindings = [_]gfx_mod.TextureSamplerBinding{
                .{ .texture = &self.fog_texture.?, .sampler = &self.sampler.? },
            };
            self.bind_group = try device.createBindGroup(.{
                .stage = .fragment,
                .texture_sampler_bindings = bindings[0..],
            });
            self.bound_texture_handle = tex_handle;
        }
    }

    /// 绘制迷雾叠加
    pub fn draw(
        self: *FogOfWarPass,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: FogUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null or self.fog_texture == null) {
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

    fn createResources(self: *FogOfWarPass, device: *gfx_mod.RenderContext) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*s| device.releaseSampler(s);

        self.stages = try shader_support.loadProgramStages(device, "fog_of_war");
        errdefer if (self.stages) |*s| s.deinit(device);

        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{};
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{};

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
            // 启用 alpha 混合，让迷雾半透明叠加
            .blend_state = .{
                .enable_blend = true,
                .src_color_blendfactor = .src_alpha,
                .dst_color_blendfactor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blendfactor = .one,
                .dst_alpha_blendfactor = .one_minus_src_alpha,
                .alpha_blend_op = .add,
            },
        });
    }
};
