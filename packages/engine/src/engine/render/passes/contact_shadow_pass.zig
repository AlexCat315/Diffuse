const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx_legacy/mod.zig");
const shader_support = @import("../shader_support.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const ContactShadowParams = extern struct {
    projection: [16]f32 = std.mem.zeroes([16]f32),
    inv_projection: [16]f32 = std.mem.zeroes([16]f32),
    view: [16]f32 = std.mem.zeroes([16]f32),
    light_direction: [4]f32 = .{ 0.3, -0.9, -0.2, 0.0 },
    resolution: [2]f32 = .{ 1.0, 1.0 },
    max_distance: f32 = 0.5,
    thickness: f32 = 0.1,
    intensity: f32 = 0.7,
    bias: f32 = 0.01,
    num_steps: i32 = 16,
    padding: f32 = 0.0,
};

pub const ContactShadowPass = struct {
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    bound_depth_handle: usize = 0,
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.GfxDevice) !ContactShadowPass {
        var pass = ContactShadowPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *ContactShadowPass, device: *gfx_mod.GfxDevice) void {
        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const ContactShadowPass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    pub fn syncTexture(
        self: *ContactShadowPass,
        device: *gfx_mod.GfxDevice,
        depth_texture: *const gfx_mod.Texture,
    ) !void {
        const depth_handle = depth_texture.id;
        if (self.bind_group != null and self.bound_depth_handle == depth_handle) {
            return;
        }

        if (self.bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }

        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        self.bound_depth_handle = depth_handle;
    }

    pub fn draw(
        self: *ContactShadowPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: ContactShadowParams,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or self.bind_group == null) {
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

    fn createResources(self: *ContactShadowPass, device: *gfx_mod.GfxDevice) !void {
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

        self.stages = try shader_support.loadProgramStages(device, "contact_shadow");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

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
        });
    }
};
