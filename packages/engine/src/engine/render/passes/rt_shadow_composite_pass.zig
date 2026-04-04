const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const shader_support = @import("../shader_support.zig");

const FullscreenVertex = extern struct {
    position: [2]f32,
};

const ShadowCompositeUniforms = extern struct {
    shadow_params: [4]f32 = .{ 0.85, 0.15, 0.0, 0.0 },
};

const fullscreen_triangle = [_]FullscreenVertex{
    .{ .position = .{ -1.0, -1.0 } },
    .{ .position = .{ 3.0, -1.0 } },
    .{ .position = .{ -1.0, 3.0 } },
};

/// RT 阴影遮罩合成 Pass — 将屏幕空间 RT 阴影遮罩以乘法混合叠加到 HDR 颜色缓冲。
pub const RtShadowCompositePass = struct {
    fullscreen_vertex_buffer: ?rhi_mod.Buffer = null,
    sampler: ?rhi_mod.Sampler = null,
    bind_group: ?rhi_mod.BindGroup = null,
    bound_texture_handle: usize = 0,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !RtShadowCompositePass {
        var pass = RtShadowCompositePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *RtShadowCompositePass, device: *rhi_mod.RhiDevice) void {
        if (self.bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.fullscreen_vertex_buffer) |*b| device.releaseBuffer(b);
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        self.* = undefined;
    }

    pub fn isReady(self: *const RtShadowCompositePass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    /// 绑定 RT 阴影遮罩纹理。
    pub fn syncTexture(
        self: *RtShadowCompositePass,
        device: *rhi_mod.RhiDevice,
        shadow_mask_texture: *const rhi_mod.Texture,
    ) !void {
        const handle = shadow_mask_texture.id;
        if (self.bind_group != null and self.bound_texture_handle == handle) return;

        if (self.bind_group) |*bg| device.releaseBindGroup(bg);

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{ .texture = shadow_mask_texture, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_texture_handle = handle;
    }

    pub fn draw(
        self: *RtShadowCompositePass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        shadow_strength: f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) return stats;

        var uniforms = ShadowCompositeUniforms{
            .shadow_params = .{ shadow_strength, 0.05, 0.0, 0.0 },
        };

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn createResources(self: *RtShadowCompositePass, device: *rhi_mod.RhiDevice) !void {
        self.fullscreen_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(FullscreenVertex) * fullscreen_triangle.len,
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer if (self.fullscreen_vertex_buffer) |*b| device.releaseBuffer(b);
        try device.uploadBufferData(&self.fullscreen_vertex_buffer.?, std.mem.sliceAsBytes(fullscreen_triangle[0..]));

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*s| device.releaseSampler(s);

        self.stages = try shader_support.loadProgramStages(device, "rt_shadow_composite");
        errdefer if (self.stages) |*s| s.deinit(device);

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(FullscreenVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(FullscreenVertex, "position"),
            },
        };

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
            .blend_state = .{
                .enable_blend = true,
                // result = src * dst_color + dst * 0 = src * dst — 乘法混合
                .src_color_blendfactor = .dst_color,
                .dst_color_blendfactor = .zero,
                .color_blend_op = .add,
                .src_alpha_blendfactor = .one,
                .dst_alpha_blendfactor = .zero,
                .alpha_blend_op = .add,
            },
        });
    }
};
