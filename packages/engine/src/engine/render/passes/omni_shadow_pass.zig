const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const rhi_mod = @import("engine/rhi_legacy/mod.zig");
const rhi_types = @import("guava_rhi").types;
const shader_support = @import("../shader_support.zig");

pub const OmniShadowPass = struct {
    pipeline: ?rhi_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    cube_texture: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,
    render_passes: [6]?rhi_mod.RenderPass = [_]?rhi_mod.RenderPass{null} ** 6,
    framebuffers: [6]?rhi_mod.Framebuffer = [_]?rhi_mod.Framebuffer{null} ** 6,

    pub fn init(device: *rhi_mod.RhiDevice) !OmniShadowPass {
        var pass = OmniShadowPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *OmniShadowPass, device: *rhi_mod.RhiDevice) void {
        for (self.render_passes) |*rp| {
            if (rp.*) |*render_pass| {
                device.releaseRenderPass(render_pass);
            }
        }
        for (self.framebuffers) |*fb| {
            if (fb.*) |*framebuffer| {
                device.releaseFramebuffer(framebuffer);
            }
        }
        if (self.cube_texture) |*texture| {
            device.releaseTexture(texture);
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

    pub fn isReady(self: *const OmniShadowPass) bool {
        return self.pipeline != null and self.cube_texture != null;
    }

    pub fn getCubeTexture(self: *const OmniShadowPass) ?*const rhi_mod.Texture {
        return &self.cube_texture.?;
    }

    pub fn getSampler(self: *const OmniShadowPass) ?*const rhi_mod.Sampler {
        return &self.sampler.?;
    }

    pub fn resize(self: *OmniShadowPass, device: *rhi_mod.RhiDevice, size: u32) !void {
        if (self.cube_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.cube_texture = null;

        for (self.render_passes) |*rp| {
            if (rp.*) |*render_pass| {
                device.releaseRenderPass(render_pass);
            }
            rp.* = null;
        }
        for (self.framebuffers) |*fb| {
            if (fb.*) |*framebuffer| {
                device.releaseFramebuffer(framebuffer);
            }
            fb.* = null;
        }

        self.cube_texture = try device.createTexture(.{
            .width = size,
            .height = size,
            .depth_or_array_layers = 6,
            .format = .depth32_float,
            .usage = rhi_types.TextureUsage.render_target | rhi_types.TextureUsage.sampled,
            .dimension = .cube,
        });

        for (0..6) |face| {
            self.render_passes[face] = try device.createRenderPass(.{
                .color_formats = &.{},
                .depth_format = .depth32_float,
                .depth_clear_value = 1.0,
                .depth_load_op = .clear,
                .depth_store_op = .store,
            });

            self.framebuffers[face] = try device.createFramebuffer(.{
                .render_pass = &self.render_passes[face].?,
                .color_attachments = &.{},
                .depth_attachment = &self.cube_texture.?,
                .depth_layer = @intCast(face),
                .width = size,
                .height = size,
            });
        }
    }

    pub fn draw(
        self: *OmniShadowPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        light_position: [3]f32,
        far_plane: f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const shadow_proj = perspectiveMatrix(std.math.pi / 2.0, 1.0, 0.1, far_plane);

        const face_transforms = [6]struct { target: [3]f32, up: [3]f32 }{
            .{ .target = .{ 1.0, 0.0, 0.0 }, .up = .{ 0.0, -1.0, 0.0 } },
            .{ .target = .{ -1.0, 0.0, 0.0 }, .up = .{ 0.0, -1.0, 0.0 } },
            .{ .target = .{ 0.0, 1.0, 0.0 }, .up = .{ 0.0, 0.0, 1.0 } },
            .{ .target = .{ 0.0, -1.0, 0.0 }, .up = .{ 0.0, 0.0, -1.0 } },
            .{ .target = .{ 0.0, 0.0, 1.0 }, .up = .{ 0.0, -1.0, 0.0 } },
            .{ .target = .{ 0.0, 0.0, -1.0 }, .up = .{ 0.0, -1.0, 0.0 } },
        };

        for (0..6) |face| {
            const view = lookAtMatrix(light_position, face_transforms[face].target, face_transforms[face].up);
            const light_space_matrix = multiplyMatrices(shadow_proj, view);

            const render_pass = self.render_passes[face].?;
            const framebuffer = self.framebuffers[face].?;

            device.beginRenderPass(frame, render_pass, framebuffer);
            defer device.endRenderPass(frame, render_pass);

            device.bindGraphicsPipeline(render_pass, &self.pipeline.?);

            for (prepared_scene.opaque_meshes) |item| {
                var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                    .view_projection = light_space_matrix,
                    .model = item.model,
                    .skinning_meta = item.skinning_meta,
                    .skin_matrices = item.skin_matrices,
                };
                device.bindVertexBuffer(render_pass, 0, &item.vertex_buffer, 0);
                device.bindIndexBuffer(render_pass, &item.index_buffer, .u32, 0);
                device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
                device.drawIndexedPrimitives(render_pass, item.index_count, 1, 0, 0, 0);
                stats.draw_calls += 1;
                stats.triangles_drawn += item.index_count / 3;
            }
        }

        return stats;
    }

    fn createResources(self: *OmniShadowPass, device: *rhi_mod.RhiDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "omni_shadow_pass");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .compare_mode = .compare_ref_to_texture,
            .compare_op = .less,
        });
        errdefer if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        };

        try self.resize(device, 512);

        const vertex_layouts = [_]rhi_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(mesh_pass_mod.GpuVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]rhi_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "position"),
            },
            .{
                .location = 4,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "joints"),
            },
            .{
                .location = 5,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(mesh_pass_mod.GpuVertex, "weights"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_test = true,
            .depth_write = true,
            .depth_compare = .less,
            .blend_enabled = false,
            .color_format = .invalid,
            .depth_format = .depth32_float,
        });
    }

    fn perspectiveMatrix(fov: f32, aspect: f32, near: f32, far: f32) [16]f32 {
        const tan_half_fov = @tan(fov / 2.0);
        var result: [16]f32 = std.mem.zeroes([16]f32);
        result[0] = 1.0 / (aspect * tan_half_fov);
        result[5] = 1.0 / tan_half_fov;
        result[10] = -(far + near) / (far - near);
        result[11] = -1.0;
        result[14] = -(2.0 * far * near) / (far - near);
        return result;
    }

    fn lookAtMatrix(eye: [3]f32, target: [3]f32, up: [3]f32) [16]f32 {
        const f = normalize3(.{
            target[0] - eye[0],
            target[1] - eye[1],
            target[2] - eye[2],
        });
        const s = normalize3(cross3(f, up));
        const u = cross3(s, f);

        var result: [16]f32 = std.mem.zeroes([16]f32);
        result[0] = s[0];
        result[1] = u[0];
        result[2] = -f[0];
        result[4] = s[1];
        result[5] = u[1];
        result[6] = -f[1];
        result[8] = s[2];
        result[9] = u[2];
        result[10] = -f[2];
        result[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
        result[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
        result[14] = f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2];
        result[15] = 1.0;
        return result;
    }

    fn multiplyMatrices(a: [16]f32, b: [16]f32) [16]f32 {
        var result: [16]f32 = std.mem.zeroes([16]f32);
        for (0..4) |row| {
            for (0..4) |col| {
                var sum: f32 = 0.0;
                for (0..4) |k| {
                    sum += a[row + k * 4] * b[k + col * 4];
                }
                result[row + col * 4] = sum;
            }
        }
        return result;
    }

    fn normalize3(v: [3]f32) [3]f32 {
        const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        if (len < 0.0001) return .{ 0, 0, 0 };
        return .{ v[0] / len, v[1] / len, v[2] / len };
    }

    fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
        return .{
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        };
    }
};
