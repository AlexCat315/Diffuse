const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("engine/render/render_context.zig");
const shader_support = @import("../shader_support.zig");

pub const ShadowPass = struct {
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    vertex_stage: ?gfx_mod.ShaderModule = null,

    pub fn init(device: *gfx_mod.RenderContext) !ShadowPass {
        var pass = ShadowPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *ShadowPass, device: *gfx_mod.RenderContext) void {
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.vertex_stage) |*vertex_stage| {
            device.releaseShaderModule(vertex_stage);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const ShadowPass) bool {
        return self.pipeline != null;
    }

    pub fn draw(
        self: *ShadowPass,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        light_space_matrix: [16]f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        for (prepared_scene.opaque_meshes) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = light_space_matrix,
                .model = item.model,
                .skinning_meta = item.skinning_meta,
                .skin_matrices = item.skin_matrices,
            };
            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0);
            device.bindIndexBuffer(pass, &item.index_buffer, .u32, 0);
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.drawIndexedPrimitives(pass, item.index_count, 1, 0, 0, 0);
            stats.draw_calls += 1;
            stats.triangles_drawn += item.index_count / 3;
        }

        return stats;
    }

    fn createResources(self: *ShadowPass, device: *gfx_mod.RenderContext) !void {
        self.vertex_stage = try shader_support.loadVertexStage(device, "shadow_pass");
        errdefer if (self.vertex_stage) |*vertex_stage| {
            device.releaseShaderModule(vertex_stage);
        };

        const vertex_layouts = mesh_pass_mod.gpuVertexBufferLayouts();
        const vertex_attributes = mesh_pass_mod.gpuVertexAttributes();

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.vertex_stage.?,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = null, // Depth only
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .front,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });
    }
};
