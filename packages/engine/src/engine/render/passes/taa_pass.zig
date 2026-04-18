const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx_legacy/mod.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../shader_support.zig");

const FullscreenVertex = extern struct {
    position: [2]f32,
};

const fullscreen_triangle = [_]FullscreenVertex{
    .{ .position = .{ -1.0, -1.0 } },
    .{ .position = .{ 3.0, -1.0 } },
    .{ .position = .{ -1.0, 3.0 } },
};

pub const TAAUniforms = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    view: [16]f32 = std.mem.zeroes([16]f32),
    prev_view: [16]f32 = std.mem.zeroes([16]f32),
    resolution: [2]f32 = .{ 1.0, 1.0 },
    jitter: [2]f32 = .{ 0.0, 0.0 },
    blend_factor: f32 = 0.1,
    motion_blur_scale: f32 = 1.0,
    feedback_min: f32 = 0.88,
    feedback_max: f32 = 0.97,
    padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const TAAPass = struct {
    fullscreen_vertex_buffer: ?gfx_mod.Buffer = null,
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    bound_color_handle: usize = 0,
    bound_history_handle: usize = 0,
    bound_velocity_handle: usize = 0,
    bound_depth_handle: usize = 0,
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    history_texture: ?gfx_mod.Texture = null,
    history_valid: bool = false,
    frame_index: u32 = 0,
    halton_sequence: [8][2]f32 = undefined,

    pub fn init(device: *gfx_mod.GfxDevice) !TAAPass {
        var pass = TAAPass{};
        try pass.createResources(device);
        pass.generateHaltonSequence();
        return pass;
    }

    pub fn deinit(self: *TAAPass, device: *gfx_mod.GfxDevice) void {
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
        if (self.history_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const TAAPass) bool {
        return self.pipeline != null and self.fullscreen_vertex_buffer != null and self.sampler != null;
    }

    pub fn getJitter(self: *const TAAPass) [2]f32 {
        const index = self.frame_index % 8;
        return self.halton_sequence[index];
    }

    pub fn advanceFrame(self: *TAAPass) void {
        self.frame_index += 1;
    }

    pub fn invalidateHistory(self: *TAAPass) void {
        self.history_valid = false;
    }

    pub fn hasValidHistory(self: *const TAAPass) bool {
        return self.history_valid and self.history_texture != null;
    }

    pub fn markHistoryValid(self: *TAAPass) void {
        self.history_valid = self.history_texture != null;
    }

    pub fn ensureHistoryTexture(self: *TAAPass, device: *gfx_mod.GfxDevice, width: u32, height: u32) !void {
        if (self.history_texture) |ht| {
            if (ht.desc.width == width and ht.desc.height == height) return;
            var tex = self.history_texture.?;
            device.releaseTexture(&tex);
            self.history_texture = null;
            self.history_valid = false;
        }
        self.history_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        self.history_valid = false;
    }

    pub fn syncTextures(
        self: *TAAPass,
        device: *gfx_mod.GfxDevice,
        color_texture: *const gfx_mod.Texture,
        velocity_texture: ?*const gfx_mod.Texture,
        depth_texture: ?*const gfx_mod.Texture,
    ) !void {
        const color_handle = color_texture.id;
        const history_handle = if (self.history_texture) |ht| ht.id else 0;
        const velocity_handle = if (velocity_texture) |vt| vt.id else 0;
        const depth_handle = if (depth_texture) |dt| dt.id else 0;

        if (self.bind_group != null and
            self.bound_color_handle == color_handle and
            self.bound_history_handle == history_handle and
            self.bound_velocity_handle == velocity_handle and
            self.bound_depth_handle == depth_handle)
        {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        // Always bind 4 textures to match shader layout (set=2, binding 0-3).
        // Use current color as fallback for missing history/velocity/depth.
        const history_tex = if (self.history_texture) |*ht| @as(*const gfx_mod.Texture, ht) else color_texture;
        const velocity_tex = if (velocity_texture) |vt| vt else color_texture;
        const depth_tex = if (depth_texture) |dt| dt else color_texture;

        const bindings = [4]gfx_mod.TextureSamplerBinding{
            .{ .texture = color_texture, .sampler = &self.sampler.? },
            .{ .texture = history_tex, .sampler = &self.sampler.? },
            .{ .texture = velocity_tex, .sampler = &self.sampler.? },
            .{ .texture = depth_tex, .sampler = &self.sampler.? },
        };

        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_color_handle = color_handle;
        self.bound_history_handle = history_handle;
        self.bound_velocity_handle = velocity_handle;
        self.bound_depth_handle = depth_handle;
    }

    pub fn draw(
        self: *TAAPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: TAAUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
            return stats;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.fullscreen_vertex_buffer.?, 0);
        device.bindGroup(pass, &self.bind_group.?);
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle.len, 1, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn generateHaltonSequence(self: *TAAPass) void {
        const halton_2 = [_]f32{ 0.5, 0.25, 0.75, 0.125, 0.625, 0.375, 0.875, 0.0625 };
        const halton_3 = [_]f32{ 0.333333, 0.666667, 0.111111, 0.444444, 0.777778, 0.222222, 0.555556, 0.888889 };

        for (0..8) |i| {
            self.halton_sequence[i] = .{ halton_2[i] - 0.5, halton_3[i] - 0.5 };
        }
    }

    fn createResources(self: *TAAPass, device: *gfx_mod.GfxDevice) !void {
        self.fullscreen_vertex_buffer = try device.createBuffer(.{
            .size = @sizeOf(FullscreenVertex) * fullscreen_triangle.len,
            .usage = gfx_types.BufferUsage.vertex,
        });
        errdefer if (self.fullscreen_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };
        try device.uploadBufferData(&self.fullscreen_vertex_buffer.?, std.mem.sliceAsBytes(fullscreen_triangle[0..]));

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

        self.stages = try shader_support.loadProgramStages(device, "taa");
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
                .offset = 0,
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
        });
    }
};
