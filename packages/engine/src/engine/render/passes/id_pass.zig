const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const scene_mod = @import("../../scene/scene.zig");
const shader_support = @import("../shader_support.zig");

pub const IdPassUniforms = extern struct {
    entity_color: [4]f32,
};

pub fn encodeEntityIdColor(entity_id: scene_mod.EntityId) [4]f32 {
    const encoded_id: u32 = @intCast(entity_id & 0x00FF_FFFF);
    return .{
        @as(f32, @floatFromInt(encoded_id & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((encoded_id >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((encoded_id >> 16) & 0xFF)) / 255.0,
        1.0,
    };
}

pub fn decodeEntityIdBgra(pixel: [4]u8) ?scene_mod.EntityId {
    const encoded_id = @as(u32, pixel[2]) |
        (@as(u32, pixel[1]) << 8) |
        (@as(u32, pixel[0]) << 16);
    if (encoded_id == 0) {
        return null;
    }
    return encoded_id;
}

test "decodeEntityIdBgra decodes selection readback bytes" {
    try std.testing.expectEqual(@as(?scene_mod.EntityId, 0x123456), decodeEntityIdBgra(.{ 0x12, 0x34, 0x56, 0xFF }));
    try std.testing.expectEqual(@as(?scene_mod.EntityId, null), decodeEntityIdBgra(.{ 0x00, 0x00, 0x00, 0x00 }));
}

pub const IdPass = struct {
    id_texture: ?rhi_mod.Texture = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !IdPass {
        var pass = IdPass{};
        try pass.createResources(device);
        const runtime = device.runtimeInfo();
        try pass.ensureTargetSize(device, runtime.drawable_width, runtime.drawable_height);
        return pass;
    }

    pub fn deinit(self: *IdPass, device: *rhi_mod.RhiDevice) void {
        if (self.id_texture) |*id_texture| {
            device.releaseTexture(id_texture);
        }
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const IdPass) bool {
        return self.pipeline != null and self.id_texture != null;
    }

    pub fn texture(self: *IdPass) ?*const rhi_mod.Texture {
        if (self.id_texture) |*id_texture| {
            return id_texture;
        }
        return null;
    }

    pub fn ensureTarget(self: *IdPass, device: *rhi_mod.RhiDevice) !void {
        const runtime = device.runtimeInfo();
        try self.ensureTargetSize(device, runtime.drawable_width, runtime.drawable_height);
    }

    pub fn ensureTargetSize(self: *IdPass, device: *rhi_mod.RhiDevice, width: u32, height: u32) !void {
        if (width == 0 or height == 0) {
            if (self.id_texture) |*id_texture| {
                device.releaseTexture(id_texture);
            }
            self.id_texture = null;
            return;
        }

        if (self.id_texture) |existing_texture| {
            if (existing_texture.desc.width == width and existing_texture.desc.height == height) {
                return;
            }

            var old_texture = existing_texture;
            device.releaseTexture(&old_texture);
            self.id_texture = null;
        }

        self.id_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.color_target | rhi_types.TextureUsage.sampler,
        });
    }

    pub fn draw(
        self: *IdPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        for (prepared_scene.opaque_meshes) |item| {
            if (!item.pickable) {
                continue;
            }
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
                .skinning_meta = item.skinning_meta,
                .skin_matrices = item.skin_matrices,
            };
            var fragment_uniforms = IdPassUniforms{
                .entity_color = encodeEntityIdColor(item.entity_id),
            };

            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0);
            device.bindIndexBuffer(pass, &item.index_buffer, .u32, 0);
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
            device.drawIndexedPrimitives(pass, item.index_count, 1, 0, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += item.index_count / 3;
        }

        return stats;
    }

    fn createResources(self: *IdPass, device: *rhi_mod.RhiDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "id_pass");
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
            .color_format = .bgra8_unorm,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });
    }
};
