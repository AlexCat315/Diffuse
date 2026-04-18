const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("../render_context.zig");
const scene_mod = @import("../../scene/scene.zig");
const shader_support = @import("../shader_support.zig");

pub const VelocityVertexUniforms = extern struct {
    current_view_projection: [16]f32,
    prev_view_projection: [16]f32,
    model: [16]f32,
    prev_model: [16]f32,
    skinning_meta: [4]u32,
    skin_matrices: [mesh_pass_mod.max_skin_joints][16]f32,
};

pub const VelocityPass = struct {
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.RenderContext) !VelocityPass {
        var pass = VelocityPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *VelocityPass, device: *gfx_mod.RenderContext) void {
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const VelocityPass) bool {
        return self.pipeline != null;
    }

    pub fn draw(
        self: *VelocityPass,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        current_view_projection: [16]f32,
        prev_view_projection: [16]f32,
        prev_models: *const std.AutoHashMap(scene_mod.EntityId, [16]f32),
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        for (prepared_scene.opaque_meshes) |item| {
            const prev_model = prev_models.get(item.entity_id) orelse item.model;
            var vertex_uniforms = VelocityVertexUniforms{
                .current_view_projection = current_view_projection,
                .prev_view_projection = prev_view_projection,
                .model = item.model,
                .prev_model = prev_model,
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

    fn createResources(self: *VelocityPass, device: *gfx_mod.RenderContext) !void {
        self.stages = try shader_support.loadProgramStages(device, "velocity");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = mesh_pass_mod.gpuVertexBufferLayouts();
        const vertex_attributes = mesh_pass_mod.gpuVertexAttributes();

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });
    }
};
