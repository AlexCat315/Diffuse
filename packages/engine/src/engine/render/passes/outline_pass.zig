const std = @import("std");
const id_pass_mod = @import("id_pass.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx_legacy/mod.zig");
const gfx_types = @import("guava_gfx").types;
const scene_mod = @import("../../scene/scene.zig");
const shader_support = @import("../shader_support.zig");

const FullscreenVertex = extern struct {
    position: [2]f32,
};

const fullscreen_triangle = [_]FullscreenVertex{
    .{ .position = .{ -1.0, -1.0 } },
    .{ .position = .{ 3.0, -1.0 } },
    .{ .position = .{ -1.0, 3.0 } },
};

pub const OutlineUniforms = extern struct {
    selected_entity_color: [4]f32,
    outline_color: [4]f32,
};

pub const OutlinePass = struct {
    fullscreen_vertex_buffer: ?gfx_mod.Buffer = null,
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    bound_texture_handle: usize = 0,
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.GfxDevice) !OutlinePass {
        var pass = OutlinePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *OutlinePass, device: *gfx_mod.GfxDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.fullscreen_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const OutlinePass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    pub fn syncTexture(
        self: *OutlinePass,
        device: *gfx_mod.GfxDevice,
        id_texture: *const gfx_mod.Texture,
    ) !void {
        const texture_handle = id_texture.id;
        if (self.bind_group != null and self.bound_texture_handle == texture_handle) {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{
                .texture = id_texture,
                .sampler = &self.sampler.?,
            },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_texture_handle = texture_handle;
    }

    pub fn draw(
        self: *OutlinePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        selected_entities: []const scene_mod.EntityId,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);

        for (selected_entities) |entity_id| {
            var uniforms = OutlineUniforms{
                .selected_entity_color = id_pass_mod.encodeEntityIdColor(entity_id),
                .outline_color = .{ 1.0, 0.72, 0.18, 1.0 },
            };

            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
            device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += 1;
        }
        return stats;
    }

    /// Draw outlines with a custom color (used for AI Ghost Highlight — purple pulse).
    pub fn drawWithColor(
        self: *OutlinePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        entities: []const scene_mod.EntityId,
        color: [4]f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null or entities.len == 0) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);

        for (entities) |entity_id| {
            var uniforms = OutlineUniforms{
                .selected_entity_color = id_pass_mod.encodeEntityIdColor(entity_id),
                .outline_color = color,
            };

            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
            device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += 1;
        }
        return stats;
    }

    fn createResources(self: *OutlinePass, device: *gfx_mod.GfxDevice) !void {
        self.fullscreen_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(FullscreenVertex) * fullscreen_triangle.len,
            .usage = gfx_types.BufferUsage.vertex,
        });
        errdefer if (self.fullscreen_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.fullscreen_vertex_buffer.?, std.mem.sliceAsBytes(fullscreen_triangle[0..]));

        self.sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "outline");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(FullscreenVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{
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
            .color_format = device.runtimeInfo().swapchain_format,
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
