const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx_legacy/mod.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../shader_support.zig");
const render_types = @import("../types.zig");
const vec3 = @import("../../math/vec3.zig");
const render_log = std.log.scoped(.viewport_render);

var g_logged_metal_binding_mode: bool = false;

pub const DrawTarget = enum {
    hdr,
    ldr,
};

pub const DrawPhase = enum {
    opaque_pass,
    transparent_pass,
    all,
};

pub const DrawSettings = struct {
    render_mode: render_types.EditorViewportRenderMode = .textured,
    target: DrawTarget = .hdr,
    phase: DrawPhase = .all,
    blend_opaque: bool = false,
    alpha_multiplier: f32 = 1.0,
    preview_tint_strength: f32 = 0.0,
    override_base_color: ?[4]f32 = null,
};

pub const BasePass = struct {
    fill_pipeline_hdr: ?gfx_mod.GraphicsPipeline = null,
    fill_pipeline_ldr: ?gfx_mod.GraphicsPipeline = null,
    ghost_fill_pipeline_hdr: ?gfx_mod.GraphicsPipeline = null,
    ghost_fill_pipeline_ldr: ?gfx_mod.GraphicsPipeline = null,
    transparent_fill_pipeline_hdr: ?gfx_mod.GraphicsPipeline = null,
    transparent_fill_pipeline_ldr: ?gfx_mod.GraphicsPipeline = null,
    wireframe_pipeline_hdr: ?gfx_mod.GraphicsPipeline = null,
    wireframe_pipeline_ldr: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    wireframe_stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.GfxDevice) !BasePass {
        var pass = BasePass{};
        try pass.createResources(device);
        return pass;
    }

    fn releasePipeline(device: *gfx_mod.GfxDevice, p: *?gfx_mod.GraphicsPipeline) void {
        if (p.*) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
            p.* = null;
        }
    }

    pub fn deinit(self: *BasePass, device: *gfx_mod.GfxDevice) void {
        releasePipeline(device, &self.wireframe_pipeline_ldr);
        releasePipeline(device, &self.wireframe_pipeline_hdr);
        releasePipeline(device, &self.ghost_fill_pipeline_ldr);
        releasePipeline(device, &self.ghost_fill_pipeline_hdr);
        releasePipeline(device, &self.transparent_fill_pipeline_ldr);
        releasePipeline(device, &self.transparent_fill_pipeline_hdr);
        releasePipeline(device, &self.fill_pipeline_ldr);
        releasePipeline(device, &self.fill_pipeline_hdr);

        // 释放 shader program stage 相关的资源（如果存在）
        if (self.stages) |*stages| stages.deinit(device);
        if (self.wireframe_stages) |*stages| stages.deinit(device);

        // 把结构体置为 undefined，避免在析构后误用已释放的字段
        self.* = undefined;
    }

    pub fn isReady(self: *const BasePass) bool {
        return self.fill_pipeline_hdr != null and
            self.fill_pipeline_ldr != null and
            self.ghost_fill_pipeline_hdr != null and
            self.ghost_fill_pipeline_ldr != null and
            self.transparent_fill_pipeline_hdr != null and
            self.transparent_fill_pipeline_ldr != null and
            self.wireframe_pipeline_hdr != null and
            self.wireframe_pipeline_ldr != null;
    }

    pub fn draw(
        self: *BasePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        settings: DrawSettings,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }
        const use_metal_combined_bindings = device.api == .metal;
        if (use_metal_combined_bindings and !g_logged_metal_binding_mode) {
            render_log.info("base pass using Metal combined sampler binding path", .{});
            g_logged_metal_binding_mode = true;
        }

        const is_wireframe = settings.render_mode == .wireframe;
        const opaque_pipeline = switch (settings.render_mode) {
            .wireframe => self.pipelineFor(settings.target, .wireframe, false),
            .textured, .unlit => self.pipelineFor(
                settings.target,
                if (settings.blend_opaque) .ghost_fill else .fill,
                false,
            ),
        };
        const transparent_pipeline = if (is_wireframe)
            opaque_pipeline
        else
            self.pipelineFor(settings.target, .fill, true);

        var shadow_bg: ?gfx_mod.BindGroup = null;
        defer if (shadow_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        var ibl_bg: ?gfx_mod.BindGroup = null;
        defer if (ibl_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        var rt_shadow_bg: ?gfx_mod.BindGroup = null;
        defer if (rt_shadow_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        var cluster_bg: ?gfx_mod.BindGroup = null;
        defer if (cluster_bg) |*bind_group| {
            device.releaseBindGroup(bind_group);
        };
        if (!use_metal_combined_bindings) {
            if (prepared_scene.shadow_maps[0]) |_| {
                const shadow_bindings = [_]gfx_mod.TextureSamplerBinding{
                    .{ .texture = prepared_scene.shadow_maps[0].?, .sampler = prepared_scene.shadow_sampler.? },
                    .{ .texture = prepared_scene.shadow_maps[1] orelse prepared_scene.shadow_maps[0].?, .sampler = prepared_scene.shadow_sampler.? },
                    .{ .texture = prepared_scene.shadow_maps[2] orelse prepared_scene.shadow_maps[0].?, .sampler = prepared_scene.shadow_sampler.? },
                    .{ .texture = prepared_scene.shadow_maps[3] orelse prepared_scene.shadow_maps[0].?, .sampler = prepared_scene.shadow_sampler.? },
                };
                shadow_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = shadow_bindings[0..],
                    .slot_offset = 5,
                });
                device.bindGroup(pass, &shadow_bg.?);
            }

            if (prepared_scene.irradiance_map != null and
                prepared_scene.prefiltered_env_map != null and
                prepared_scene.brdf_lut != null and
                prepared_scene.environment_map != null and
                prepared_scene.texture_sampler != null)
            {
                const ibl_bindings = [_]gfx_mod.TextureSamplerBinding{
                    .{ .texture = prepared_scene.irradiance_map.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.prefiltered_env_map.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.brdf_lut.?, .sampler = prepared_scene.texture_sampler.? },
                    .{ .texture = prepared_scene.environment_map.?, .sampler = prepared_scene.texture_sampler.? },
                };
                ibl_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = ibl_bindings[0..],
                    .slot_offset = 9,
                });
                device.bindGroup(pass, &ibl_bg.?);
            }

            if (prepared_scene.texture_sampler != null) {
                const rt_shadow_texture = prepared_scene.rt_shadow_mask orelse prepared_scene.brdf_lut orelse prepared_scene.environment_map orelse prepared_scene.irradiance_map;
                if (rt_shadow_texture) |texture| {
                    const rt_bindings = [_]gfx_mod.TextureSamplerBinding{
                        .{ .texture = texture, .sampler = prepared_scene.texture_sampler.? },
                    };
                    rt_shadow_bg = try device.createBindGroup(.{
                        .stage = .fragment,
                        .texture_sampler_bindings = rt_bindings[0..],
                        .slot_offset = 13,
                    });
                    device.bindGroup(pass, &rt_shadow_bg.?);
                }
            }

            // Clustered Forward+: bind cluster data textures at bindings 14-15.
            if (prepared_scene.cluster_count_texture != null and
                prepared_scene.cluster_indices_texture != null and
                prepared_scene.cluster_nearest_sampler != null)
            {
                const cluster_bindings = [_]gfx_mod.TextureSamplerBinding{
                    .{ .texture = prepared_scene.cluster_count_texture.?, .sampler = prepared_scene.cluster_nearest_sampler.? },
                    .{ .texture = prepared_scene.cluster_indices_texture.?, .sampler = prepared_scene.cluster_nearest_sampler.? },
                };
                cluster_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = cluster_bindings[0..],
                    .slot_offset = 14,
                });
                device.bindGroup(pass, &cluster_bg.?);
            }
        }

        switch (settings.phase) {
            .opaque_pass => {
                device.bindGraphicsPipeline(pass, opaque_pipeline);
                stats.add(try self.drawMeshList(
                    device,
                    frame,
                    pass,
                    prepared_scene,
                    prepared_scene.opaque_meshes,
                    settings,
                    use_metal_combined_bindings,
                    false,
                ));
            },
            .transparent_pass => {
                device.bindGraphicsPipeline(pass, transparent_pipeline);
                stats.add(try self.drawMeshList(
                    device,
                    frame,
                    pass,
                    prepared_scene,
                    prepared_scene.transparent_meshes,
                    settings,
                    use_metal_combined_bindings,
                    true,
                ));
            },
            .all => {
                if (prepared_scene.opaque_meshes.len > 0) {
                    device.bindGraphicsPipeline(pass, opaque_pipeline);
                    stats.add(try self.drawMeshList(
                        device,
                        frame,
                        pass,
                        prepared_scene,
                        prepared_scene.opaque_meshes,
                        settings,
                        use_metal_combined_bindings,
                        false,
                    ));
                }
                if (prepared_scene.transparent_meshes.len > 0) {
                    if (transparent_pipeline != opaque_pipeline) {
                        device.bindGraphicsPipeline(pass, transparent_pipeline);
                    }
                    stats.add(try self.drawMeshList(
                        device,
                        frame,
                        pass,
                        prepared_scene,
                        prepared_scene.transparent_meshes,
                        settings,
                        use_metal_combined_bindings,
                        true,
                    ));
                }
            },
        }

        return stats;
    }

    // 绘制一组 DrawItem。
    // 对每个项的典型顺序：构建 vertex/fragment uniforms -> 绑定 vertex/index buffers -> 绑定材质 bind group（或 Metal 的合并绑定）
    // -> 推送 uniform 数据 -> 发出 drawIndexedPrimitives。
    fn drawMeshList(
        self: *BasePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        items: []const mesh_pass_mod.DrawItem,
        settings: DrawSettings,
        use_metal_combined_bindings: bool,
        transparent_pass: bool,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};

        for (items) |item| {
            // 顶点阶段 uniforms：包含 VP 矩阵、模型矩阵以及蒙皮信息（若有）
            var vertex_uniforms = mesh_pass_mod.VertexUniforms{
                .view_projection = prepared_scene.view_projection,
                .model = item.model,
                .skinning_meta = item.skinning_meta,
                .skin_matrices = item.skin_matrices,
            };
            // 片段阶段 uniforms：光照、IBL、阴影参数等由 makeFragmentUniforms 汇总
            var fragment_uniforms = self.makeFragmentUniforms(
                item,
                prepared_scene,
                settings,
                transparent_pass,
            );

            // 绑定顶点/索引缓冲
            device.bindVertexBuffer(pass, 0, &item.vertex_buffer, 0); // vertex slot 0
            const draw_index_buffer = if (settings.render_mode == .wireframe)
                &item.wireframe_index_buffer
            else
                &item.index_buffer;
            const draw_index_count = if (settings.render_mode == .wireframe)
                item.wireframe_index_count
            else
                item.index_count;
            device.bindIndexBuffer(pass, draw_index_buffer, .u32, 0);
            if (use_metal_combined_bindings) {
                const shadow_texture_0 = prepared_scene.shadow_maps[0] orelse return error.TextureNotFound;
                const shadow_sampler = prepared_scene.shadow_sampler orelse return error.SamplerCreateFailed;
                const texture_sampler = prepared_scene.texture_sampler orelse return error.SamplerCreateFailed;
                const irradiance_map = prepared_scene.irradiance_map orelse return error.TextureNotFound;
                const prefiltered_env_map = prepared_scene.prefiltered_env_map orelse return error.TextureNotFound;
                const brdf_lut = prepared_scene.brdf_lut orelse return error.TextureNotFound;
                const environment_map = prepared_scene.environment_map orelse return error.TextureNotFound;
                const rt_shadow_texture = prepared_scene.rt_shadow_mask orelse brdf_lut;
                // Fallback for cluster textures: use brdf_lut if not available.
                // In practice cluster textures are always valid after the cluster pass inits.
                const cluster_count_tex = prepared_scene.cluster_count_texture orelse brdf_lut;
                const cluster_indices_tex = prepared_scene.cluster_indices_texture orelse brdf_lut;
                const cluster_sampler = prepared_scene.cluster_nearest_sampler orelse texture_sampler;

                const combined_bindings = [_]gfx_mod.TextureSamplerBinding{
                    .{ .texture = item.material_textures[0], .sampler = texture_sampler }, // binding 0: u_base_color_map
                    .{ .texture = item.material_textures[1], .sampler = texture_sampler }, // binding 1: u_metallic_roughness_map
                    .{ .texture = item.material_textures[2], .sampler = texture_sampler }, // binding 2: u_normal_map
                    .{ .texture = item.material_textures[3], .sampler = texture_sampler }, // binding 3: u_occlusion_map
                    .{ .texture = item.material_textures[4], .sampler = texture_sampler }, // binding 4: u_emissive_map
                    .{ .texture = shadow_texture_0, .sampler = shadow_sampler }, // binding 5: u_shadow_map_0
                    .{ .texture = prepared_scene.shadow_maps[1] orelse shadow_texture_0, .sampler = shadow_sampler }, // binding 6: u_shadow_map_1
                    .{ .texture = prepared_scene.shadow_maps[2] orelse shadow_texture_0, .sampler = shadow_sampler }, // binding 7: u_shadow_map_2
                    .{ .texture = prepared_scene.shadow_maps[3] orelse shadow_texture_0, .sampler = shadow_sampler }, // binding 8: u_shadow_map_3
                    .{ .texture = irradiance_map, .sampler = texture_sampler }, // binding 9: u_irradiance_map
                    .{ .texture = prefiltered_env_map, .sampler = texture_sampler }, // binding 10: u_prefiltered_env_map
                    .{ .texture = brdf_lut, .sampler = texture_sampler }, // binding 11: u_brdf_lut
                    .{ .texture = environment_map, .sampler = texture_sampler }, // binding 12: u_environment_map
                    .{ .texture = rt_shadow_texture, .sampler = texture_sampler }, // binding 13: u_rt_shadow_mask
                    .{ .texture = cluster_count_tex, .sampler = cluster_sampler }, // binding 14: u_cluster_counts
                    .{ .texture = cluster_indices_tex, .sampler = cluster_sampler }, // binding 15: u_cluster_light_indices
                };
                // Metal 后端：将所有纹理/采样器合并成单个 bind group，便于 shader 的单绑定点访问
                var combined_bg = try device.createBindGroup(.{
                    .stage = .fragment,
                    .texture_sampler_bindings = combined_bindings[0..],
                });
                defer device.releaseBindGroup(&combined_bg);
                device.bindGroup(pass, &combined_bg);
            } else {
                device.bindGroup(pass, &item.bind_group);
            }

            // 推送 uniforms 到 GPU（通常写入环形 uniform buffer / dynamic buffer）
            device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
            // 发起索引绘制：count, instanceCount, firstIndex, baseVertex, firstInstance
            device.drawIndexedPrimitives(pass, draw_index_count, 1, 0, 0, 0);

            stats.draw_calls += 1;
            stats.triangles_drawn += if (settings.render_mode == .wireframe)
                draw_index_count / 2
            else
                item.index_count / 3;
        }

        return stats;
    }

    fn makeFragmentUniforms(
        self: *BasePass,
        item: mesh_pass_mod.DrawItem,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        settings: DrawSettings,
        transparent_pass: bool,
    ) mesh_pass_mod.BasePassUniforms {
        _ = self;

        // Fill directional light arrays (up to max_directional_lights)
        var dir_directions: [mesh_pass_mod.max_directional_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_directional_lights;
        var dir_colors: [mesh_pass_mod.max_directional_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_directional_lights;
        const dir_count = @min(prepared_scene.lights.directional_lights.len, mesh_pass_mod.max_directional_lights);
        for (0..dir_count) |i| {
            const dl = prepared_scene.lights.directional_lights[i];
            dir_directions[i] = .{ dl.direction[0], dl.direction[1], dl.direction[2], 0.0 };
            dir_colors[i] = .{ dl.color[0], dl.color[1], dl.color[2], dl.intensity };
        }
        // Fill point light arrays (up to max_point_lights)
        var pt_positions: [mesh_pass_mod.max_point_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_point_lights;
        var pt_colors: [mesh_pass_mod.max_point_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_point_lights;
        const pt_count = @min(prepared_scene.lights.point_lights.len, mesh_pass_mod.max_point_lights);
        for (0..pt_count) |i| {
            const pl = prepared_scene.lights.point_lights[i];
            pt_positions[i] = .{ pl.position[0], pl.position[1], pl.position[2], pl.range };
            pt_colors[i] = .{ pl.color[0], pl.color[1], pl.color[2], pl.intensity };
        }

        var spot_positions: [mesh_pass_mod.max_spot_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_spot_lights;
        var spot_directions: [mesh_pass_mod.max_spot_lights][4]f32 = .{.{ 0, 0, -1, 0 }} ** mesh_pass_mod.max_spot_lights;
        var spot_colors: [mesh_pass_mod.max_spot_lights][4]f32 = .{.{ 0, 0, 0, 0 }} ** mesh_pass_mod.max_spot_lights;
        var spot_angles: [mesh_pass_mod.max_spot_lights][4]f32 = .{.{ -1, 0, 0, 0 }} ** mesh_pass_mod.max_spot_lights;
        const spot_count = @min(prepared_scene.lights.spot_lights.len, mesh_pass_mod.max_spot_lights);
        for (0..spot_count) |i| {
            const sl = prepared_scene.lights.spot_lights[i];
            spot_positions[i] = .{ sl.position[0], sl.position[1], sl.position[2], sl.range };
            spot_directions[i] = .{ sl.direction[0], sl.direction[1], sl.direction[2], sl.inner_angle_cos };
            spot_colors[i] = .{ sl.color[0], sl.color[1], sl.color[2], sl.intensity };
            spot_angles[i] = .{ sl.outer_angle_cos, 0.0, 0.0, 0.0 };
        }

        var fragment_uniforms = mesh_pass_mod.BasePassUniforms{
            .base_color_factor = item.base_color_factor,
            .emissive_factor = item.emissive_factor,
            .pbr_factors = item.pbr_factors,
            .has_textures = item.has_textures,
            .camera_world_position = prepared_scene.camera_world_position,
            .dir_light_directions = dir_directions,
            .dir_light_colors = dir_colors,
            .light_space_matrix = prepared_scene.light_space_matrix,
            .point_light_positions = pt_positions,
            .point_light_colors = pt_colors,
            .spot_light_positions = spot_positions,
            .spot_light_directions = spot_directions,
            .spot_light_colors = spot_colors,
            .spot_light_angles = spot_angles,
            .light_counts = .{ @intCast(dir_count), @intCast(pt_count), @intCast(spot_count), 0 },
            .ambient_color = prepared_scene.ambient_color,
            .shadow_params = .{ 0.0065, 0.0, 0.0, 0.0 }, // bias
            .rt_shadow_params = .{
                if (prepared_scene.rt_shadow_mask != null) 1.0 else 0.0,
                prepared_scene.rt_shadow_strength,
                prepared_scene.rt_shadow_ambient_floor,
                0.0,
            },
            .ibl_params = item.ibl_params,
            .cascade_matrices = prepared_scene.cascade_matrices,
            .cascade_splits = prepared_scene.cascade_splits,
            .view_matrix = prepared_scene.view_matrix,
            .cluster_params = prepared_scene.cluster_params,
        };

        if (settings.render_mode == .unlit) {
            fragment_uniforms.light_counts = .{ 0, 0, 0, 0 };
            fragment_uniforms.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 };
            fragment_uniforms.rt_shadow_params = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.ibl_params = .{ 0.0, 0.0, 0.0, 0.0 };
        } else if (settings.render_mode == .wireframe) {
            fragment_uniforms.base_color_factor = settings.override_base_color orelse .{ 0.08, 0.08, 0.08, 1.0 };
            fragment_uniforms.emissive_factor = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.has_textures = .{ 0, 0, 0, 0 };
            fragment_uniforms.light_counts = .{ 0, 0, 0, 0 };
            fragment_uniforms.ambient_color = .{ 1.0, 1.0, 1.0, 1.0 };
            fragment_uniforms.rt_shadow_params = .{ 0.0, 0.0, 0.0, 0.0 };
            fragment_uniforms.ibl_params = .{ 0.0, 0.0, 0.0, 0.0 };
        }

        fragment_uniforms.pbr_factors[3] = settings.alpha_multiplier;
        if (settings.render_mode != .wireframe) {
            if (settings.override_base_color) |preview_tint| {
                fragment_uniforms.shadow_params[1] = preview_tint[0];
                fragment_uniforms.shadow_params[2] = preview_tint[1];
                fragment_uniforms.shadow_params[3] = preview_tint[2];
                fragment_uniforms.ibl_params[2] = settings.preview_tint_strength;
            }
        }

        if (transparent_pass or (settings.render_mode == .wireframe and fragment_uniforms.base_color_factor[3] < 1.0)) {
            fragment_uniforms.pbr_factors[2] = 0.0;
        }

        return fragment_uniforms;
    }

    fn createResources(self: *BasePass, device: *gfx_mod.GfxDevice) !void {
        self.stages = try shader_support.loadProgramStages(device, "mesh");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        self.wireframe_stages = try shader_support.loadProgramStages(device, "wireframe");
        errdefer if (self.wireframe_stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = mesh_pass_mod.gpuVertexBufferLayouts();
        const vertex_attributes = mesh_pass_mod.gpuVertexAttributes();

        self.fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .fill, false, true, true);
        errdefer if (self.fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm_srgb, .fill, false, true, true);
        errdefer if (self.fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.ghost_fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .ghost_fill, true, false, false);
        errdefer if (self.ghost_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.ghost_fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm_srgb, .ghost_fill, true, false, false);
        errdefer if (self.ghost_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.transparent_fill_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .fill, true, true, false);
        errdefer if (self.transparent_fill_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.transparent_fill_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm_srgb, .fill, true, true, false);
        errdefer if (self.transparent_fill_pipeline_ldr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.wireframe_pipeline_hdr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .rgba16_float, .wireframe, false, true, true);
        errdefer if (self.wireframe_pipeline_hdr) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        };
        self.wireframe_pipeline_ldr = try self.createPipeline(device, vertex_layouts[0..], vertex_attributes[0..], .bgra8_unorm_srgb, .wireframe, false, true, true);
    }

    const PipelineMode = enum {
        fill,
        ghost_fill,
        wireframe,
    };

    fn pipelineFor(self: *BasePass, target: DrawTarget, mode: PipelineMode, transparent: bool) *gfx_mod.GraphicsPipeline {
        return switch (mode) {
            .fill => switch (target) {
                .hdr => if (transparent) &self.transparent_fill_pipeline_hdr.? else &self.fill_pipeline_hdr.?,
                .ldr => if (transparent) &self.transparent_fill_pipeline_ldr.? else &self.fill_pipeline_ldr.?,
            },
            .ghost_fill => switch (target) {
                .hdr => &self.ghost_fill_pipeline_hdr.?,
                .ldr => &self.ghost_fill_pipeline_ldr.?,
            },
            .wireframe => switch (target) {
                .hdr => &self.wireframe_pipeline_hdr.?,
                .ldr => &self.wireframe_pipeline_ldr.?,
            },
        };
    }

    fn createPipeline(
        self: *BasePass,
        device: *gfx_mod.GfxDevice,
        vertex_layouts: []const gfx_mod.VertexBufferLayoutDesc,
        vertex_attributes: []const gfx_mod.VertexAttributeDesc,
        color_format: gfx_types.TextureFormat,
        mode: PipelineMode,
        enable_blend: bool,
        depth_test: bool,
        depth_write: bool,
    ) !gfx_mod.GraphicsPipeline {
        const shader_stages = if (mode == .wireframe) self.wireframe_stages.? else self.stages.?;
        return device.createGraphicsPipeline(.{
            .vertex_shader = &shader_stages.vertex,
            .fragment_shader = &shader_stages.fragment,
            .vertex_buffer_layouts = vertex_layouts,
            .vertex_attributes = vertex_attributes,
            .color_format = color_format,
            .blend_state = if (enable_blend)
                @as(?gfx_types.ColorTargetBlendState, .{
                    .enable_blend = true,
                })
            else
                null,
            .depth_format = .d32_float,
            .primitive_type = if (mode == .wireframe) .line_list else .triangle_list,
            .fill_mode = .fill,
            .cull_mode = if (mode == .wireframe) .none else .back,
            .front_face = .counter_clockwise,
            .depth_compare = if (depth_test) .less_or_equal else .always,
            .depth_test = depth_test,
            .depth_write = depth_write,
        });
    }
};
