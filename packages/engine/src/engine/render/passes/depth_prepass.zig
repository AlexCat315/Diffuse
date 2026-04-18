const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx/mod.zig");
const shader_support = @import("../shader_support.zig");

pub const DepthPrepass = struct {
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    vertex_stage: ?gfx_mod.ShaderModule = null,

    pub fn init(device: *gfx_mod.GfxDevice) !DepthPrepass {
        var pass = DepthPrepass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *DepthPrepass, device: *gfx_mod.GfxDevice) void {
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.vertex_stage) |*vertex_stage| {
            device.releaseShaderModule(vertex_stage);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const DepthPrepass) bool {
        return self.pipeline != null;
    }

    pub fn draw(
        self: *DepthPrepass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        for (prepared_scene.opaque_meshes) |item| {
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
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

    fn createResources(self: *DepthPrepass, device: *gfx_mod.GfxDevice) !void {
        self.vertex_stage = try shader_support.loadVertexStage(device, "depth_prepass");
        errdefer if (self.vertex_stage) |*vertex_stage| {
            device.releaseShaderModule(vertex_stage);
        };

        const vertex_layouts = mesh_pass_mod.gpuVertexBufferLayouts();
        const vertex_attributes = mesh_pass_mod.gpuVertexAttributes();

        self.pipeline = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..]);
    }

    fn createPipeline(
        self: *DepthPrepass,
        device: *gfx_mod.GfxDevice,
        vertex_layouts: []const gfx_mod.VertexBufferLayoutDesc,
        vertex_attributes: []const gfx_mod.VertexAttributeDesc,
    ) !gfx_mod.GraphicsPipeline {
        return device.createGraphicsPipeline(.{
            .vertex_shader = &self.vertex_stage.?,
            .vertex_buffer_layouts = vertex_layouts,
            .vertex_attributes = vertex_attributes,
            .color_format = null,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });
    }
};
