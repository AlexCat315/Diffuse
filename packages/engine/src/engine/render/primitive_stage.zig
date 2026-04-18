const std = @import("std");
const math = @import("../math/mat4.zig");
const rhi_mod = @import("engine/rhi_legacy/mod.zig");
const rhi_types = @import("guava_rhi").types;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

pub const DrawStats = struct {
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,
};

const Vertex = extern struct {
    position: [3]f32,
    color: [4]f32,
    uv: [2]f32,
};

const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
    tint: [4]f32,
};

const CameraState = struct {
    transform: components.Transform,
    camera: components.Camera,
};

const triangle_vertices = [_]Vertex{
    .{
        .position = .{ -0.8, -0.6, 0.0 },
        .color = .{ 1.0, 0.35, 0.3, 1.0 },
        .uv = .{ 0.0, 1.0 },
    },
    .{
        .position = .{ 0.8, -0.6, 0.0 },
        .color = .{ 0.2, 0.85, 0.45, 1.0 },
        .uv = .{ 1.0, 1.0 },
    },
    .{
        .position = .{ 0.0, 0.75, 0.0 },
        .color = .{ 0.25, 0.45, 1.0, 1.0 },
        .uv = .{ 0.5, 0.0 },
    },
};

const cube_vertices = [_]Vertex{
    // Front
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.5, 0.4, 1.0 }, .uv = .{ 0.0, 0.0 } },
    // Back
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.4, 0.9, 1.0, 1.0 }, .uv = .{ 0.0, 0.0 } },
    // Left
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.55, 0.65, 1.0, 1.0 }, .uv = .{ 0.0, 0.0 } },
    // Right
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 1.0, 0.85, 0.4, 1.0 }, .uv = .{ 0.0, 0.0 } },
    // Top
    .{ .position = .{ -0.5, 0.5, 0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, 0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, 0.5, -0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, 0.5, -0.5 }, .color = .{ 0.7, 1.0, 0.55, 1.0 }, .uv = .{ 0.0, 0.0 } },
    // Bottom
    .{ .position = .{ -0.5, -0.5, -0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 0.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, -0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ 0.5, -0.5, 0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ -0.5, -0.5, 0.5 }, .color = .{ 0.95, 0.5, 0.95, 1.0 }, .uv = .{ 0.0, 0.0 } },
};

const cube_indices = [_]u16{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const checker_texture_bgra = [_]u8{
    0xFF, 0xFF, 0xFF, 0xFF,
    0x40, 0x70, 0xFF, 0xFF,
    0x50, 0xD0, 0x60, 0xFF,
    0x20, 0x20, 0x30, 0xFF,
};

pub const PrimitiveStage = struct {
    allocator: std.mem.Allocator,
    supported: bool = false,
    triangle_vertex_buffer: ?rhi_mod.Buffer = null,
    cube_vertex_buffer: ?rhi_mod.Buffer = null,
    cube_index_buffer: ?rhi_mod.Buffer = null,
    checker_texture: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,
    fragment_bind_group: ?rhi_mod.BindGroup = null,
    vertex_shader: ?rhi_mod.ShaderModule = null,
    fragment_shader: ?rhi_mod.ShaderModule = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,

    pub fn init(allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) !PrimitiveStage {
        var stage = PrimitiveStage{
            .allocator = allocator,
        };
        if (device.api != .vulkan) {
            return stage;
        }

        try stage.createResources(device);
        stage.supported = true;
        return stage;
    }

    pub fn deinit(self: *PrimitiveStage, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.fragment_shader) |*fragment_shader| {
            device.releaseShaderModule(fragment_shader);
        }
        if (self.vertex_shader) |*vertex_shader| {
            device.releaseShaderModule(vertex_shader);
        }
        if (self.fragment_bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.checker_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.cube_index_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.cube_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.triangle_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const PrimitiveStage) bool {
        return self.supported and self.pipeline != null;
    }

    pub fn draw(
        self: *PrimitiveStage,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        scene: *const scene_mod.Scene,
    ) !DrawStats {
        var stats = DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        if (self.fragment_bind_group) |*bind_group| {
            device.bindGroup(pass, bind_group);
        }

        const camera_state = chooseCamera(scene);
        const aspect_ratio = if (frame.swapchain_image.height == 0) 1.0 else @as(f32, @floatFromInt(frame.swapchain_image.width)) / @as(f32, @floatFromInt(frame.swapchain_image.height));
        const view_projection = math.mul(
            math.projectionForCamera(camera_state.camera, aspect_ratio),
            math.viewMatrix(camera_state.transform),
        );

        device.bindVertexBuffer(pass, 0, &self.triangle_vertex_buffer.?, 0);
        var triangle_uniforms = VertexUniforms{
            .view_projection = view_projection,
            .model = math.transformMatrix(.{
                .translation = .{ -2.1, 1.1, 0.0 },
                .rotation = @import("../math/quat.zig").fromEuler(.{ 0.0, -0.5, 0.0 }),
                .scale = .{ 1.0, 1.0, 1.0 },
            }),
            .tint = .{ 1.0, 1.0, 1.0, 1.0 },
        };
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&triangle_uniforms));
        device.drawPrimitives(pass, triangle_vertices.len, 1, 0, 0);
        stats.draw_calls += 1;
        stats.triangles_drawn += 1;

        device.bindVertexBuffer(pass, 0, &self.cube_vertex_buffer.?, 0);
        device.bindIndexBuffer(pass, &self.cube_index_buffer.?, .u16, 0);

        for (scene.entities.items) |entity| {
            if (!entity.visible) {
                continue;
            }
            const mesh = entity.mesh orelse continue;
            if (mesh.primitive != .cube) {
                continue;
            }

            var cube_uniforms = VertexUniforms{
                .view_projection = view_projection,
                .model = math.transformMatrix(entity.transform),
                .tint = colorForEntity(entity.id),
            };
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&cube_uniforms));
            device.drawIndexedPrimitives(pass, cube_indices.len, 1, 0, 0, 0);
            stats.draw_calls += 1;
            stats.triangles_drawn += cube_indices.len / 3;
        }

        return stats;
    }

    fn createResources(self: *PrimitiveStage, device: *rhi_mod.RhiDevice) !void {
        self.triangle_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(Vertex) * triangle_vertices.len,
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer if (self.triangle_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.triangle_vertex_buffer.?, std.mem.sliceAsBytes(triangle_vertices[0..]));

        self.cube_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(Vertex) * cube_vertices.len,
            .usage = rhi_types.BufferUsage.vertex,
        });
        errdefer if (self.cube_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.cube_vertex_buffer.?, std.mem.sliceAsBytes(cube_vertices[0..]));

        self.cube_index_buffer = try device.createBuffer(.{
            .size = @sizeOf(u16) * cube_indices.len,
            .usage = rhi_types.BufferUsage.index,
        });
        errdefer if (self.cube_index_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.cube_index_buffer.?, std.mem.sliceAsBytes(cube_indices[0..]));

        self.checker_texture = try device.createTexture(.{
            .width = 2,
            .height = 2,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.checker_texture) |*texture| {
            device.releaseTexture(texture);
        };
        try device.uploadTextureData(&self.checker_texture.?, checker_texture_bgra[0..], 2, 2);

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        const fragment_bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = &self.checker_texture.?,
                .sampler = &self.sampler.?,
            },
        };
        self.fragment_bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = fragment_bindings[0..],
        });
        errdefer if (self.fragment_bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };

        self.vertex_shader = try device.createShaderModule(.{
            .code = @embedFile("shaders/vulkan/primitive.vert.spv"),
            .stage = .vertex,
            .format = .spirv,
            .num_uniform_buffers = 1,
        });
        errdefer if (self.vertex_shader) |*shader| {
            device.releaseShaderModule(shader);
        };

        self.fragment_shader = try device.createShaderModule(.{
            .code = @embedFile("shaders/vulkan/primitive.frag.spv"),
            .stage = .fragment,
            .format = .spirv,
            .num_samplers = 1,
        });
        errdefer if (self.fragment_shader) |*shader| {
            device.releaseShaderModule(shader);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(Vertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(Vertex, "position"),
            },
            .{
                .location = 1,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(Vertex, "color"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(Vertex, "uv"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.vertex_shader.?,
            .fragment_shader = &self.fragment_shader.?,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
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

fn chooseCamera(scene: *const scene_mod.Scene) CameraState {
    var fallback: ?CameraState = null;

    for (scene.entities.items) |entity| {
        const camera = entity.camera orelse continue;
        const candidate: CameraState = .{
            .transform = entity.transform,
            .camera = camera,
        };

        if (camera.is_primary) {
            return candidate;
        }
        if (fallback == null) {
            fallback = candidate;
        }
    }

    return fallback orelse .{
        .transform = .{
            .translation = .{ 0.0, 1.5, 5.0 },
        },
        .camera = .{ .is_primary = true },
    };
}

fn colorForEntity(id: scene_mod.EntityId) [4]f32 {
    const scaled = @as(f32, @floatFromInt((id % 7) + 1));
    return .{
        0.65 + 0.04 * @mod(scaled, 3.0),
        0.72 + 0.03 * @mod(scaled + 1.0, 2.0),
        0.85 + 0.02 * @mod(scaled + 2.0, 4.0),
        1.0,
    };
}
