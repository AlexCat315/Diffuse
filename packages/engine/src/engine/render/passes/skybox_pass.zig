const std = @import("std");
const rhi_mod = @import("../../rhi/device.zig");
const shader_support = @import("../shader_support.zig");
const math = @import("../../math/mat4.zig");
const mesh_pass_mod = @import("mesh_pass.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const SkyboxUniforms = extern struct {
    projection: [16]f32,
    view: [16]f32,
    camera_position: [4]f32,
    inv_vp: [16]f32, // Precomputed inverse of (projection * view_rot_only)
};

pub const SkyboxPass = struct {
    sampler: ?rhi_mod.Sampler = null,
    pipeline: ?rhi_mod.GraphicsPipeline = null,
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
        if (self.pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const SkyboxPass) bool {
        return self.pipeline != null and self.sampler != null;
    }

    pub fn draw(
        self: *SkyboxPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        env_map_texture: *const rhi_mod.Texture,
    ) void {
        if (!self.isReady()) {
            return;
        }

        device.bindGraphicsPipeline(pass, &self.pipeline.?);

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
        }) catch return;
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

        self.pipeline = try device.createGraphicsPipeline(.{
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
            .depth_compare = .less_or_equal, // Skybox is drawn at Z=1.0
            .depth_test = true,
            .depth_write = false,
        });
    }
};
