const std = @import("std");
const rhi_mod = @import("../../rhi/device.zig");
const shader_support = @import("../shader_support.zig");
const math = @import("../../math/mat4.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const base_pass_mod = @import("base_pass.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const SkyboxUniforms = extern struct {
    projection: [16]f32,
    view: [16]f32,
    camera_position: [4]f32,
    inv_vp: [16]f32, // Precomputed inverse of (projection * view_rot_only)
    sky_intensity: f32,
    _pad0: f32 = 0,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
};

pub const SkyboxPass = struct {
    sampler: ?rhi_mod.Sampler = null,
    pipeline_hdr: ?rhi_mod.GraphicsPipeline = null,
    pipeline_ldr: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *rhi_mod.RhiDevice) !SkyboxPass {
        var pass = SkyboxPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *SkyboxPass, device: *rhi_mod.RhiDevice) void {
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const SkyboxPass) bool {
        return self.pipeline_hdr != null and self.pipeline_ldr != null and self.sampler != null;
    }

    pub fn draw(
        self: *SkyboxPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        env_map_texture: *const rhi_mod.Texture,
        target: base_pass_mod.DrawTarget,
        sky_intensity: f32,
    ) void {
        if (!self.isReady()) {
            return;
        }

        const pipeline = switch (target) {
            .hdr => &self.pipeline_hdr.?,
            .ldr => &self.pipeline_ldr.?,
        };
        device.bindGraphicsPipeline(pass, pipeline);

        // Extract view rotation only (remove translation)
        var view_rot_only = prepared_scene.view_matrix;
        view_rot_only[12] = 0.0;
        view_rot_only[13] = 0.0;
        view_rot_only[14] = 0.0;

        // Compute VP = projection * view_rot_only
        const vp = math.mul(prepared_scene.projection_matrix, view_rot_only);

        // Precompute inverse VP on CPU
        const inv_vp = math.inverse(vp) orelse math.identity();

        var uniforms = SkyboxUniforms{
            .projection = prepared_scene.projection_matrix,
            .view = prepared_scene.view_matrix,
            .camera_position = prepared_scene.camera_world_position,
            .inv_vp = inv_vp,
            .sky_intensity = sky_intensity,
        };
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&uniforms));

        // Create a temporary bind group for the environment map or keep it cached
        // For simplicity we create it temporarily, though caching is better.
        // In a real implementation we'd cache it or put it in a bind group state.
        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = env_map_texture,
                .sampler = &self.sampler.?,
            },
        };
        var bind_group = device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
            .slot_offset = 0,
        }) catch |err| {
            std.log.err("skybox createBindGroup FAILED: {s} tex_id={d} sampler_id={d}", .{
                @errorName(err), env_map_texture.id, self.sampler.?.id,
            });
            return;
        };
        defer device.releaseBindGroup(&bind_group);

        device.bindGroup(pass, &bind_group);
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);
    }

    fn createResources(self: *SkyboxPass, device: *rhi_mod.RhiDevice) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        self.stages = try shader_support.loadProgramStages(device, "skybox");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{};
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{};

        self.pipeline_hdr = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });

        self.pipeline_ldr = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .bgra8_unorm_srgb,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });
    }
};
