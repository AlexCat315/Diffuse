const std = @import("std");
const assets_lib = @import("../../assets/library.zig");
const handles = @import("../../assets/handles.zig");
const material_ast_mod = @import("../../assets/material_ast.zig");
const material_resource_mod = @import("../../assets/material_resource.zig");
const texture_resource_mod = @import("../../assets/texture_resource.zig");
const texture_import_mod = @import("../../assets/texture_import.zig");
const mesh_pass_mod = @import("../passes/mesh_pass.zig");
const components = @import("../../scene/components.zig");
const scene_mod = @import("../../scene/scene.zig");
const AABB = @import("../../math/aabb.zig").AABB;
const mat4_mod = @import("../../math/mat4.zig");
const vec3 = @import("../../math/vec3.zig");
const rhi_types = @import("../../rhi/types.zig");
const path_trace_common = @import("path_trace_common.zig");
const rt_backend = @import("../../rt/rt_backend.zig");
const image_export = @import("../image_export.zig");
const io_globals = @import("io_globals");

pub const PathTraceTriangle = path_trace_common.PathTraceTriangle;
pub const PathTraceTexture = path_trace_common.PathTraceTexture;
pub const PathTraceEnvironment = path_trace_common.PathTraceEnvironment;
pub const PathTraceTextureIndices = path_trace_common.PathTraceTextureIndices;
pub const PathTraceMaterialSample = path_trace_common.PathTraceMaterialSample;
pub const PathTracePrimaryRay = path_trace_common.PathTracePrimaryRay;
pub const PathTraceGuidePixel = path_trace_common.PathTraceGuidePixel;
pub const PathTraceGuideBuffers = path_trace_common.PathTraceGuideBuffers;
pub const PathTraceEnvImportance = path_trace_common.PathTraceEnvImportance;
pub const PathTraceEmissiveLight = path_trace_common.PathTraceEmissiveLight;
pub const PathTracePointLight = path_trace_common.PathTracePointLight;
pub const PathTraceSpotLight = path_trace_common.PathTraceSpotLight;
pub const PathTraceMesh = path_trace_common.PathTraceMesh;
pub const PathTraceProgressiveState = path_trace_common.PathTraceProgressiveState;
pub const path_trace_adaptive_tile_dim = path_trace_common.path_trace_adaptive_tile_dim;
pub const path_trace_adaptive_tile_capacity = path_trace_common.path_trace_adaptive_tile_capacity;
pub const PathTraceAdaptiveTileBlock = path_trace_common.PathTraceAdaptiveTileBlock;

pub const HwRtState = struct {
    triangles: ?[]rt_backend.RtTriangle = null,
    texture_atlas: ?[]u8 = null,
    texture_meta: ?[]rt_backend.RtTextureMeta = null,
    textures_uploaded: bool = false,
    sampling_table_data: ?[]u8 = null,
    sampling_table_meta: ?[]rt_backend.RtSamplingTableMeta = null,
    sampling_tables_uploaded: bool = false,
    environment_importance: ?[]PathTraceEnvImportance = null,
    emissive_lights: ?[]PathTraceEmissiveLight = null,
    environment_importance_width: u32 = 0,
    environment_importance_height: u32 = 0,
    emissive_total_area: f32 = 0.0,
    light_radiance: [3]f32 = .{ 0, 0, 0 },
    trace_pixels: ?[]u8 = null,
    display_pixels: ?[]u8 = null,
    /// 累积辐射度缓冲区（float32 RGB，用于渐进式路径追踪多帧累积）
    accum_pixels: ?[]f32 = null,
    /// 已累积的帧数（每帧 1 spp，累积到 target_samples 后停止）
    accum_frame_count: u32 = 0,
    trace_width: u32 = 0,
    trace_height: u32 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    accel_built: bool = false,
    needs_retrace: bool = true,
    last_view_projection: [16]f32 = mat4_mod.identity(),
    last_samples: u32 = 0,
    last_bounces: u32 = 0,
    last_resolution_scale: f32 = 0.0,
    last_scene_signature: u64 = 0,
    environment_texture_index: i32 = -1,

    /// 完全重置（场景变化时：重建三角形、加速结构、纹理等）
    pub fn reset(self: *HwRtState, allocator: std.mem.Allocator) void {
        if (self.triangles) |t| allocator.free(t);
        if (self.texture_atlas) |a| allocator.free(a);
        if (self.texture_meta) |m| allocator.free(m);
        if (self.sampling_table_data) |data| allocator.free(data);
        if (self.sampling_table_meta) |meta| allocator.free(meta);
        if (self.environment_importance) |items| allocator.free(items);
        if (self.emissive_lights) |items| allocator.free(items);
        self.triangles = null;
        self.texture_atlas = null;
        self.texture_meta = null;
        self.sampling_table_data = null;
        self.sampling_table_meta = null;
        self.environment_importance = null;
        self.emissive_lights = null;
        self.environment_importance_width = 0;
        self.environment_importance_height = 0;
        self.emissive_total_area = 0.0;
        self.textures_uploaded = false;
        self.sampling_tables_uploaded = false;
        self.accel_built = false;
        self.needs_retrace = true;
        self.accum_frame_count = 0;
        if (self.accum_pixels) |accum| @memset(accum, 0.0);
        self.environment_texture_index = -1;
    }

    /// 仅重置累积状态（相机/参数变化时：保留场景数据，重新开始累积）
    pub fn resetAccumulation(self: *HwRtState) void {
        self.accum_frame_count = 0;
        if (self.accum_pixels) |accum| @memset(accum, 0.0);
        self.needs_retrace = true;
    }

    pub fn deinit(self: *HwRtState, allocator: std.mem.Allocator) void {
        if (self.triangles) |t| allocator.free(t);
        if (self.texture_atlas) |a| allocator.free(a);
        if (self.texture_meta) |m| allocator.free(m);
        if (self.sampling_table_data) |data| allocator.free(data);
        if (self.sampling_table_meta) |meta| allocator.free(meta);
        if (self.environment_importance) |items| allocator.free(items);
        if (self.emissive_lights) |items| allocator.free(items);
        if (self.trace_pixels) |p| allocator.free(p);
        if (self.display_pixels) |p| allocator.free(p);
        if (self.accum_pixels) |p| allocator.free(p);
        self.* = .{};
    }
};

pub fn mulMat4Vec4(matrix: [16]f32, vector: [4]f32) [4]f32 {
    return .{
        matrix[0] * vector[0] + matrix[4] * vector[1] + matrix[8] * vector[2] + matrix[12] * vector[3],
        matrix[1] * vector[0] + matrix[5] * vector[1] + matrix[9] * vector[2] + matrix[13] * vector[3],
        matrix[2] * vector[0] + matrix[6] * vector[1] + matrix[10] * vector[2] + matrix[14] * vector[3],
        matrix[3] * vector[0] + matrix[7] * vector[1] + matrix[11] * vector[2] + matrix[15] * vector[3],
    };
}

pub fn unprojectNdc(inv_view_projection: [16]f32, ndc_x: f32, ndc_y: f32, ndc_z: f32) [3]f32 {
    const clip = [4]f32{ ndc_x, ndc_y, ndc_z, 1.0 };
    const world = mulMat4Vec4(inv_view_projection, clip);
    const inv_w = if (@abs(world[3]) > 0.000001) 1.0 / world[3] else 1.0;
    return .{ world[0] * inv_w, world[1] * inv_w, world[2] * inv_w };
}

pub fn hashU32(value: u32) u32 {
    var x = value;
    x ^= x >> 17;
    x *%= 0xed5ad4bb;
    x ^= x >> 11;
    x *%= 0xac4c1b51;
    x ^= x >> 15;
    x *%= 0x31848bab;
    x ^= x >> 14;
    return x;
}

pub fn hashUnitFloat(seed: u32) f32 {
    const h = hashU32(seed);
    return @as(f32, @floatFromInt(h & 0x00FFFFFF)) / 16777215.0;
}

pub fn transformPoint(model: [16]f32, p: [3]f32) [3]f32 {
    const w = mulMat4Vec4(model, .{ p[0], p[1], p[2], 1.0 });
    const inv_w = if (@abs(w[3]) > 0.000001) 1.0 / w[3] else 1.0;
    return .{ w[0] * inv_w, w[1] * inv_w, w[2] * inv_w };
}

pub fn transformNormal(model: [16]f32, n: [3]f32) [3]f32 {
    // Transform normal by upper 3x3 of model matrix (ignoring translation)
    return vec3.normalize(.{
        model[0] * n[0] + model[4] * n[1] + model[8] * n[2],
        model[1] * n[0] + model[5] * n[1] + model[9] * n[2],
        model[2] * n[0] + model[6] * n[1] + model[10] * n[2],
    });
}

pub const TriangleHit = struct {
    t: f32,
    u: f32,
    v: f32,
};

/// Möller–Trumbore ray-triangle intersection
pub fn intersectTriangle(origin: [3]f32, direction: [3]f32, tri: PathTraceTriangle, t_min: f32, t_max: f32) ?TriangleHit {
    const edge1 = vec3.sub(tri.v1, tri.v0);
    const edge2 = vec3.sub(tri.v2, tri.v0);
    const h = vec3.cross(direction, edge2);
    const a = vec3.dot(edge1, h);

    if (@abs(a) < 0.0000001) return null; // Ray parallel to triangle

    const f = 1.0 / a;
    const s = vec3.sub(origin, tri.v0);
    const u = f * vec3.dot(s, h);
    if (u < 0.0 or u > 1.0) return null;

    const q = vec3.cross(s, edge1);
    const v = f * vec3.dot(direction, q);
    if (v < 0.0 or u + v > 1.0) return null;

    const t = f * vec3.dot(edge2, q);
    if (t > t_min and t < t_max) {
        return .{ .t = t, .u = u, .v = v };
    }
    return null;
}

pub fn sampleSky(direction: [3]f32, environment_texture: ?PathTraceTexture) [3]f32 {
    if (environment_texture) |environment| {
        const dir = vec3.normalize(direction);
        const u = std.math.atan2(dir[2], dir[0]) / (2.0 * std.math.pi) + 0.5;
        const v = 0.5 - std.math.asin(std.math.clamp(dir[1], -1.0, 1.0)) / std.math.pi;
        return sampleTextureBilinear(environment, u, v);
    }
    return .{ 0.0, 0.0, 0.0 };
}

pub fn mixVec3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped_t = std.math.clamp(t, 0.0, 1.0);
    return .{
        a[0] + (b[0] - a[0]) * clamped_t,
        a[1] + (b[1] - a[1]) * clamped_t,
        a[2] + (b[2] - a[2]) * clamped_t,
    };
}

pub fn wyhashUpdateValue(hasher: *std.hash.Wyhash, value: anytype) void {
    hasher.update(std.mem.asBytes(&value));
}

pub fn wyhashUpdateTextureResource(
    hasher: *std.hash.Wyhash,
    resources: *const assets_lib.ResourceLibrary,
    texture_handle: ?handles.TextureHandle,
) void {
    const resolved_handle = texture_handle orelse return;
    wyhashUpdateValue(hasher, @intFromEnum(resolved_handle));
    if (resources.texture(resolved_handle)) |texture| {
        wyhashUpdateValue(hasher, texture.width);
        wyhashUpdateValue(hasher, texture.height);
        // 用像素长度代替全量 hash，句柄 + 尺寸 + 长度 已唯一标识纹理内容
        wyhashUpdateValue(hasher, texture.pixels.len);
    }
}

pub fn computePathTraceSceneSignature(
    prepared_scene: *const mesh_pass_mod.PreparedScene,
    scene: *const scene_mod.Scene,
    environment: PathTraceEnvironment,
) u64 {
    var hasher = std.hash.Wyhash.init(0);

    wyhashUpdateValue(&hasher, prepared_scene.opaque_meshes.len);
    wyhashUpdateValue(&hasher, prepared_scene.transparent_meshes.len);
    wyhashUpdateValue(&hasher, prepared_scene.ambient_color);
    wyhashUpdateValue(&hasher, prepared_scene.lights.directional_lights.len);
    wyhashUpdateValue(&hasher, prepared_scene.lights.point_lights.len);
    wyhashUpdateValue(&hasher, prepared_scene.lights.spot_lights.len);
    for (prepared_scene.lights.directional_lights) |light| {
        wyhashUpdateValue(&hasher, light.direction);
        wyhashUpdateValue(&hasher, light.color);
        wyhashUpdateValue(&hasher, light.intensity);
    }
    for (prepared_scene.lights.point_lights) |light| {
        wyhashUpdateValue(&hasher, light.position);
        wyhashUpdateValue(&hasher, light.color);
        wyhashUpdateValue(&hasher, light.intensity);
        wyhashUpdateValue(&hasher, light.range);
    }
    for (prepared_scene.lights.spot_lights) |light| {
        wyhashUpdateValue(&hasher, light.position);
        wyhashUpdateValue(&hasher, light.direction);
        wyhashUpdateValue(&hasher, light.color);
        wyhashUpdateValue(&hasher, light.intensity);
        wyhashUpdateValue(&hasher, light.range);
        wyhashUpdateValue(&hasher, light.inner_angle_cos);
        wyhashUpdateValue(&hasher, light.outer_angle_cos);
    }

    wyhashUpdateValue(&hasher, environment.handle);
    if (environment.texture) |env_texture| {
        wyhashUpdateValue(&hasher, env_texture.width);
        wyhashUpdateValue(&hasher, env_texture.height);
        // 用像素长度代替全量 hash，handle + 尺寸 + 长度已唯一标识纹理
        wyhashUpdateValue(&hasher, env_texture.pixels.len);
    }

    for (prepared_scene.opaque_meshes) |item| {
        wyhashUpdateValue(&hasher, item.entity_id);
        wyhashUpdateValue(&hasher, @intFromEnum(item.mesh_handle));
        wyhashUpdateValue(&hasher, item.model);
        wyhashUpdateValue(&hasher, item.base_color_factor);
        wyhashUpdateValue(&hasher, item.emissive_factor);
        wyhashUpdateValue(&hasher, item.pbr_factors);
        wyhashUpdateValue(&hasher, item.has_textures);
        wyhashUpdateValue(&hasher, item.ibl_params);

        if (handles.isValid(item.mesh_handle)) {
            if (scene.resources.mesh(item.mesh_handle)) |mesh| {
                // 用顶点/索引数量代替全量 hash，mesh_handle 已唯一标识几何体
                wyhashUpdateValue(&hasher, mesh.vertices.len);
                wyhashUpdateValue(&hasher, mesh.indices.len);
            }
        }

        if (scene.getEntityConst(item.entity_id)) |entity| {
            if (entity.material) |mat_comp| {
                if (mat_comp.handle) |mat_handle| {
                    wyhashUpdateValue(&hasher, @intFromEnum(mat_handle));
                    if (scene.resources.material(mat_handle)) |material| {
                        const material_ast = material_ast_mod.MaterialAst.fromResource(material);
                        wyhashUpdateValue(&hasher, material_ast.base_color_factor);
                        wyhashUpdateValue(&hasher, material_ast.emissive_factor);
                        wyhashUpdateValue(&hasher, material_ast.metallic_factor);
                        wyhashUpdateValue(&hasher, material_ast.roughness_factor);
                        wyhashUpdateValue(&hasher, material_ast.alpha_cutoff);
                        wyhashUpdateValue(&hasher, material_ast.use_ibl);
                        wyhashUpdateValue(&hasher, material_ast.ibl_intensity);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.base_color);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.metallic_roughness);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.normal);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.occlusion);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.emissive);
                    }
                }
            }
        }
    }

    for (prepared_scene.transparent_meshes) |item| {
        wyhashUpdateValue(&hasher, item.entity_id);
        wyhashUpdateValue(&hasher, @intFromEnum(item.mesh_handle));
        wyhashUpdateValue(&hasher, item.model);
        wyhashUpdateValue(&hasher, item.base_color_factor);
        wyhashUpdateValue(&hasher, item.emissive_factor);
        wyhashUpdateValue(&hasher, item.pbr_factors);
        wyhashUpdateValue(&hasher, item.has_textures);
        wyhashUpdateValue(&hasher, item.ibl_params);

        if (handles.isValid(item.mesh_handle)) {
            if (scene.resources.mesh(item.mesh_handle)) |mesh| {
                // 用顶点/索引数量代替全量 hash
                wyhashUpdateValue(&hasher, mesh.vertices.len);
                wyhashUpdateValue(&hasher, mesh.indices.len);
            }
        }

        if (scene.getEntityConst(item.entity_id)) |entity| {
            if (entity.material) |mat_comp| {
                if (mat_comp.handle) |mat_handle| {
                    wyhashUpdateValue(&hasher, @intFromEnum(mat_handle));
                    if (scene.resources.material(mat_handle)) |material| {
                        const material_ast = material_ast_mod.MaterialAst.fromResource(material);
                        wyhashUpdateValue(&hasher, material_ast.base_color_factor);
                        wyhashUpdateValue(&hasher, material_ast.emissive_factor);
                        wyhashUpdateValue(&hasher, material_ast.metallic_factor);
                        wyhashUpdateValue(&hasher, material_ast.roughness_factor);
                        wyhashUpdateValue(&hasher, material_ast.alpha_cutoff);
                        wyhashUpdateValue(&hasher, material_ast.use_ibl);
                        wyhashUpdateValue(&hasher, material_ast.ibl_intensity);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.base_color);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.metallic_roughness);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.normal);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.occlusion);
                        wyhashUpdateTextureResource(&hasher, &scene.resources, material_ast.textures.emissive);
                    }
                }
            }
        }
    }

    return hasher.final();
}

pub fn reflectVector(incident: [3]f32, normal: [3]f32) [3]f32 {
    return vec3.sub(incident, vec3.scale(normal, 2.0 * vec3.dot(incident, normal)));
}

pub fn refractVector(incident: [3]f32, normal: [3]f32, eta: f32) ?[3]f32 {
    const cos_i = std.math.clamp(-vec3.dot(normal, incident), -1.0, 1.0);
    const k = 1.0 - eta * eta * (1.0 - cos_i * cos_i);
    if (k < 0.0) return null;
    return vec3.add(
        vec3.scale(incident, eta),
        vec3.scale(normal, eta * cos_i - std.math.sqrt(k)),
    );
}

fn findSceneEnvironmentAssetId(resources: *const assets_lib.ResourceLibrary) ?[]const u8 {
    const environment_asset_id = resources.sceneEnvironmentAssetId() orelse return null;
    const record = resources.asset_registry.recordById(environment_asset_id) orelse return null;
    if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
        return null;
    }
    std.fs.cwd().access(record.source_path, .{}) catch return null;
    return record.id;
}

pub fn resolvePathTraceEnvironment(self: anytype, scene: *scene_mod.Scene) PathTraceEnvironment {
    const borrowed_asset_id = findSceneEnvironmentAssetId(&scene.resources) orelse return .{};
    const environment_asset_id = self.allocator.dupe(u8, borrowed_asset_id) catch return .{};
    defer self.allocator.free(environment_asset_id);

    const handle = scene.resources.textureHandleByAssetId(environment_asset_id) orelse blk: {
        _ = texture_import_mod.loadTextureAsset(
            self.allocator,
            &scene.resources,
            &scene.resources.asset_registry,
            environment_asset_id,
        ) catch return .{};
        break :blk scene.resources.textureHandleByAssetId(environment_asset_id) orelse return .{};
    };
    const texture = scene.resources.texture(handle) orelse return .{};
    if (texture.width == 0 or texture.height == 0 or texture.pixels.len == 0) {
        return .{};
    }

    return .{
        .handle = @intFromEnum(handle),
        .texture = .{
            .pixels = texture.pixels,
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
        },
    };
}

/// bilinear sample a CPU texture, return linear RGB
pub fn sampleTextureBilinear(tex: PathTraceTexture, u_in: f32, v_in: f32) [3]f32 {
    // Wrap UVs to [0,1)
    var u = u_in - @floor(u_in);
    var v = v_in - @floor(v_in);
    if (u < 0.0) u += 1.0;
    if (v < 0.0) v += 1.0;
    const fx = u * @as(f32, @floatFromInt(tex.width)) - 0.5;
    const fy = v * @as(f32, @floatFromInt(tex.height)) - 0.5;
    const x0_i = @as(i32, @intFromFloat(@floor(fx)));
    const y0_i = @as(i32, @intFromFloat(@floor(fy)));
    const frac_x = fx - @floor(fx);
    const frac_y = fy - @floor(fy);
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);

    const x0: u32 = @intCast(@mod(x0_i, w) + (if (@mod(x0_i, w) < 0) w else @as(i32, 0)));
    const y0: u32 = @intCast(@mod(y0_i, h) + (if (@mod(y0_i, h) < 0) h else @as(i32, 0)));
    const x1: u32 = @intCast(@mod(x0_i + 1, w) + (if (@mod(x0_i + 1, w) < 0) w else @as(i32, 0)));
    const y1: u32 = @intCast(@mod(y0_i + 1, h) + (if (@mod(y0_i + 1, h) < 0) h else @as(i32, 0)));

    const c00 = readTexelLinear(tex, x0, y0);
    const c10 = readTexelLinear(tex, x1, y0);
    const c01 = readTexelLinear(tex, x0, y1);
    const c11 = readTexelLinear(tex, x1, y1);
    return .{
        (c00[0] * (1.0 - frac_x) + c10[0] * frac_x) * (1.0 - frac_y) + (c01[0] * (1.0 - frac_x) + c11[0] * frac_x) * frac_y,
        (c00[1] * (1.0 - frac_x) + c10[1] * frac_x) * (1.0 - frac_y) + (c01[1] * (1.0 - frac_x) + c11[1] * frac_x) * frac_y,
        (c00[2] * (1.0 - frac_x) + c10[2] * frac_x) * (1.0 - frac_y) + (c01[2] * (1.0 - frac_x) + c11[2] * frac_x) * frac_y,
    };
}

pub fn readTexelLinear(tex: PathTraceTexture, x: u32, y: u32) [3]f32 {
    const pixel_index = @as(usize, y) * @as(usize, tex.width) + @as(usize, x);
    return switch (tex.format) {
        .rgba32_float => blk: {
            const idx = pixel_index * 16;
            if (idx + 15 >= tex.pixels.len) break :blk [3]f32{ 0.5, 0.5, 0.5 };
            const r_bits: u32 = @as(u32, tex.pixels[idx + 0]) |
                (@as(u32, tex.pixels[idx + 1]) << 8) |
                (@as(u32, tex.pixels[idx + 2]) << 16) |
                (@as(u32, tex.pixels[idx + 3]) << 24);
            const g_bits: u32 = @as(u32, tex.pixels[idx + 4]) |
                (@as(u32, tex.pixels[idx + 5]) << 8) |
                (@as(u32, tex.pixels[idx + 6]) << 16) |
                (@as(u32, tex.pixels[idx + 7]) << 24);
            const b_bits: u32 = @as(u32, tex.pixels[idx + 8]) |
                (@as(u32, tex.pixels[idx + 9]) << 8) |
                (@as(u32, tex.pixels[idx + 10]) << 16) |
                (@as(u32, tex.pixels[idx + 11]) << 24);
            break :blk .{
                @bitCast(r_bits),
                @bitCast(g_bits),
                @bitCast(b_bits),
            };
        },
        .rgba16_float => blk: {
            const idx = pixel_index * 8;
            if (idx + 7 >= tex.pixels.len) break :blk [3]f32{ 0.5, 0.5, 0.5 };
            const r_bits: u16 = @as(u16, tex.pixels[idx + 0]) | (@as(u16, tex.pixels[idx + 1]) << 8);
            const g_bits: u16 = @as(u16, tex.pixels[idx + 2]) | (@as(u16, tex.pixels[idx + 3]) << 8);
            const b_bits: u16 = @as(u16, tex.pixels[idx + 4]) | (@as(u16, tex.pixels[idx + 5]) << 8);
            break :blk .{
                @as(f32, @floatCast(@as(f16, @bitCast(r_bits)))),
                @as(f32, @floatCast(@as(f16, @bitCast(g_bits)))),
                @as(f32, @floatCast(@as(f16, @bitCast(b_bits)))),
            };
        },
        else => blk: {
            const idx = pixel_index * 4;
            if (idx + 3 >= tex.pixels.len) break :blk [3]f32{ 0.5, 0.5, 0.5 };
            const is_bgra = (tex.format == .bgra8_unorm or tex.format == .bgra8_unorm_srgb);
            const r_byte = tex.pixels[idx + if (is_bgra) @as(usize, 2) else @as(usize, 0)];
            const g_byte = tex.pixels[idx + 1];
            const b_byte = tex.pixels[idx + if (is_bgra) @as(usize, 0) else @as(usize, 2)];
            const r = @as(f32, @floatFromInt(r_byte)) / 255.0;
            const g = @as(f32, @floatFromInt(g_byte)) / 255.0;
            const b = @as(f32, @floatFromInt(b_byte)) / 255.0;
            break :blk .{
                std.math.pow(f32, r, 2.2),
                std.math.pow(f32, g, 2.2),
                std.math.pow(f32, b, 2.2),
            };
        },
    };
}

pub fn readTexelRaw(tex: PathTraceTexture, x: u32, y: u32) [3]f32 {
    const pixel_index = @as(usize, y) * @as(usize, tex.width) + @as(usize, x);
    return switch (tex.format) {
        .rgba32_float, .rgba16_float => readTexelLinear(tex, x, y),
        else => blk: {
            const idx = pixel_index * 4;
            if (idx + 3 >= tex.pixels.len) break :blk [3]f32{ 0.5, 0.5, 0.5 };
            const is_bgra = (tex.format == .bgra8_unorm or tex.format == .bgra8_unorm_srgb);
            const r_byte = tex.pixels[idx + if (is_bgra) @as(usize, 2) else @as(usize, 0)];
            const g_byte = tex.pixels[idx + 1];
            const b_byte = tex.pixels[idx + if (is_bgra) @as(usize, 0) else @as(usize, 2)];
            break :blk .{
                @as(f32, @floatFromInt(r_byte)) / 255.0,
                @as(f32, @floatFromInt(g_byte)) / 255.0,
                @as(f32, @floatFromInt(b_byte)) / 255.0,
            };
        },
    };
}

pub fn sampleTextureBilinearRaw(tex: PathTraceTexture, u_in: f32, v_in: f32) [3]f32 {
    var u = u_in - @floor(u_in);
    var v = v_in - @floor(v_in);
    if (u < 0.0) u += 1.0;
    if (v < 0.0) v += 1.0;
    const fx = u * @as(f32, @floatFromInt(tex.width)) - 0.5;
    const fy = v * @as(f32, @floatFromInt(tex.height)) - 0.5;
    const x0_i = @as(i32, @intFromFloat(@floor(fx)));
    const y0_i = @as(i32, @intFromFloat(@floor(fy)));
    const frac_x = fx - @floor(fx);
    const frac_y = fy - @floor(fy);
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);

    const x0: u32 = @intCast(@mod(x0_i, w) + (if (@mod(x0_i, w) < 0) w else @as(i32, 0)));
    const y0: u32 = @intCast(@mod(y0_i, h) + (if (@mod(y0_i, h) < 0) h else @as(i32, 0)));
    const x1: u32 = @intCast(@mod(x0_i + 1, w) + (if (@mod(x0_i + 1, w) < 0) w else @as(i32, 0)));
    const y1: u32 = @intCast(@mod(y0_i + 1, h) + (if (@mod(y0_i + 1, h) < 0) h else @as(i32, 0)));

    const c00 = readTexelRaw(tex, x0, y0);
    const c10 = readTexelRaw(tex, x1, y0);
    const c01 = readTexelRaw(tex, x0, y1);
    const c11 = readTexelRaw(tex, x1, y1);
    return .{
        (c00[0] * (1.0 - frac_x) + c10[0] * frac_x) * (1.0 - frac_y) + (c01[0] * (1.0 - frac_x) + c11[0] * frac_x) * frac_y,
        (c00[1] * (1.0 - frac_x) + c10[1] * frac_x) * (1.0 - frac_y) + (c01[1] * (1.0 - frac_x) + c11[1] * frac_x) * frac_y,
        (c00[2] * (1.0 - frac_x) + c10[2] * frac_x) * (1.0 - frac_y) + (c01[2] * (1.0 - frac_x) + c11[2] * frac_x) * frac_y,
    };
}

pub fn pathTraceTextureAt(textures: []const PathTraceTexture, texture_index: i32) ?PathTraceTexture {
    if (texture_index < 0) return null;
    const index: usize = @intCast(texture_index);
    if (index >= textures.len) return null;
    return textures[index];
}

pub const PathTraceSceneHit = struct {
    tri_index: usize,
    t: f32,
    u: f32,
    v: f32,
};

pub const PathTraceBsdfProbabilities = struct {
    diffuse: f32,
    specular: f32,
};

pub const PathTraceBsdfEval = struct {
    value: [3]f32,
    pdf: f32,
};

pub const PathTraceDirectLightSample = struct {
    direction: [3]f32,
    radiance: [3]f32,
    pdf: f32,
    distance: f32,
    delta: bool,
};

pub const TangentFrame = struct {
    tangent: [3]f32,
    bitangent: [3]f32,
    normal: [3]f32,
};

pub fn sqr(value: f32) f32 {
    return value * value;
}

pub fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

pub fn maxComponent(rgb: [3]f32) f32 {
    return @max(rgb[0], @max(rgb[1], rgb[2]));
}

pub fn oneMinusVec3(value: [3]f32) [3]f32 {
    return .{ 1.0 - value[0], 1.0 - value[1], 1.0 - value[2] };
}

pub fn powerHeuristic(pdf_a: f32, pdf_b: f32) f32 {
    const a2 = pdf_a * pdf_a;
    const b2 = pdf_b * pdf_b;
    const denom = a2 + b2;
    if (denom <= 0.0) return 0.0;
    return a2 / denom;
}

pub fn directionToEnvironmentUv(direction: [3]f32) [2]f32 {
    const dir = vec3.normalize(direction);
    return .{
        std.math.atan2(dir[2], dir[0]) / (2.0 * std.math.pi) + 0.5,
        0.5 - std.math.asin(std.math.clamp(dir[1], -1.0, 1.0)) / std.math.pi,
    };
}

pub fn environmentUvToDirection(u: f32, v: f32) [3]f32 {
    const phi = (u - 0.5) * (2.0 * std.math.pi);
    const theta = std.math.clamp(v, 0.0, 1.0) * std.math.pi;
    const sin_theta = std.math.sin(theta);
    return vec3.normalize(.{
        std.math.cos(phi) * sin_theta,
        std.math.cos(theta),
        std.math.sin(phi) * sin_theta,
    });
}

pub fn triangleArea(tri: PathTraceTriangle) f32 {
    return 0.5 * vec3.length(vec3.cross(vec3.sub(tri.v1, tri.v0), vec3.sub(tri.v2, tri.v0)));
}

pub fn triangleGeometricNormal(tri: PathTraceTriangle) [3]f32 {
    return vec3.normalize(vec3.cross(vec3.sub(tri.v1, tri.v0), vec3.sub(tri.v2, tri.v0)));
}

pub fn tracePathTraceScene(
    origin: [3]f32,
    direction: [3]f32,
    triangles: []const PathTraceTriangle,
    meshes: []const PathTraceMesh,
    t_min: f32,
    t_max: f32,
) ?PathTraceSceneHit {
    var closest_t = t_max;
    var best_hit: ?PathTraceSceneHit = null;

    for (meshes) |mesh| {
        if (mesh.aabb.rayIntersection(origin, direction, closest_t) == null) continue;
        const end = mesh.tri_start + mesh.tri_count;
        var tri_index = mesh.tri_start;
        while (tri_index < end) : (tri_index += 1) {
            const tri = triangles[tri_index];
            if (intersectTriangle(origin, direction, tri, t_min, closest_t)) |hit| {
                closest_t = hit.t;
                best_hit = .{
                    .tri_index = tri_index,
                    .t = hit.t,
                    .u = hit.u,
                    .v = hit.v,
                };
            }
        }
    }

    return best_hit;
}

pub fn isPathTraceOccluded(
    origin: [3]f32,
    direction: [3]f32,
    max_distance: f32,
    triangles: []const PathTraceTriangle,
    meshes: []const PathTraceMesh,
) bool {
    return tracePathTraceScene(origin, direction, triangles, meshes, 0.001, max_distance) != null;
}

pub fn buildTangentFrame(normal: [3]f32) TangentFrame {
    const up = if (@abs(normal[1]) < 0.999) [3]f32{ 0.0, 1.0, 0.0 } else [3]f32{ 1.0, 0.0, 0.0 };
    const tangent = vec3.normalize(vec3.cross(up, normal));
    return .{
        .tangent = tangent,
        .bitangent = vec3.cross(normal, tangent),
        .normal = normal,
    };
}

pub fn buildTriangleTangentFrame(tri: PathTraceTriangle, normal: [3]f32) TangentFrame {
    const edge1 = vec3.sub(tri.v1, tri.v0);
    const edge2 = vec3.sub(tri.v2, tri.v0);
    const duv1 = .{ tri.uv1[0] - tri.uv0[0], tri.uv1[1] - tri.uv0[1] };
    const duv2 = .{ tri.uv2[0] - tri.uv0[0], tri.uv2[1] - tri.uv0[1] };
    const det = duv1[0] * duv2[1] - duv1[1] * duv2[0];
    if (@abs(det) <= 0.000001) {
        return buildTangentFrame(normal);
    }

    const inv_det = 1.0 / det;
    var tangent: [3]f32 = .{
        (edge1[0] * duv2[1] - edge2[0] * duv1[1]) * inv_det,
        (edge1[1] * duv2[1] - edge2[1] * duv1[1]) * inv_det,
        (edge1[2] * duv2[1] - edge2[2] * duv1[1]) * inv_det,
    };
    if (vec3.length(tangent) <= 0.000001) {
        return buildTangentFrame(normal);
    }
    tangent = vec3.normalize(vec3.sub(tangent, vec3.scale(normal, vec3.dot(normal, tangent))));
    var bitangent = vec3.cross(normal, tangent);
    const bitangent_raw: [3]f32 = .{
        (edge2[0] * duv1[0] - edge1[0] * duv2[0]) * inv_det,
        (edge2[1] * duv1[0] - edge1[1] * duv2[0]) * inv_det,
        (edge2[2] * duv1[0] - edge1[2] * duv2[0]) * inv_det,
    };
    if (vec3.dot(bitangent, bitangent_raw) < 0.0) {
        bitangent = vec3.scale(bitangent, -1.0);
    }
    return .{
        .tangent = tangent,
        .bitangent = bitangent,
        .normal = normal,
    };
}

pub fn samplePathTraceMaterial(
    tri: PathTraceTriangle,
    textures: []const PathTraceTexture,
    hit_uv: [2]f32,
    geometric_normal: [3]f32,
    interpolated_normal: [3]f32,
) PathTraceMaterialSample {
    var albedo = tri.albedo;
    if (pathTraceTextureAt(textures, tri.base_color_texture_index)) |texture| {
        const tex_color = sampleTextureBilinear(texture, hit_uv[0], hit_uv[1]);
        albedo = vec3.mul(albedo, tex_color);
    }

    if (pathTraceTextureAt(textures, tri.occlusion_texture_index)) |texture| {
        const ao = std.math.clamp(sampleTextureBilinearRaw(texture, hit_uv[0], hit_uv[1])[0], 0.0, 1.0);
        // AO is treated as an artist-authored diffuse attenuation for PT parity with raster materials.
        albedo = vec3.scale(albedo, ao);
    }

    var emissive = tri.emissive;
    if (pathTraceTextureAt(textures, tri.emissive_texture_index)) |texture| {
        const tex_emissive = sampleTextureBilinear(texture, hit_uv[0], hit_uv[1]);
        emissive = vec3.mul(emissive, tex_emissive);
    }

    var metallic = std.math.clamp(tri.metallic, 0.0, 1.0);
    var roughness = std.math.clamp(tri.roughness, 0.04, 1.0);
    if (pathTraceTextureAt(textures, tri.metallic_roughness_texture_index)) |texture| {
        const mr = sampleTextureBilinearRaw(texture, hit_uv[0], hit_uv[1]);
        metallic = std.math.clamp(metallic * mr[2], 0.0, 1.0);
        roughness = std.math.clamp(roughness * mr[1], 0.04, 1.0);
    }

    var shading_normal = interpolated_normal;
    if (pathTraceTextureAt(textures, tri.normal_texture_index)) |texture| {
        const normal_sample = sampleTextureBilinearRaw(texture, hit_uv[0], hit_uv[1]);
        const tangent_space_normal = vec3.normalize(.{
            normal_sample[0] * 2.0 - 1.0,
            normal_sample[1] * 2.0 - 1.0,
            normal_sample[2] * 2.0 - 1.0,
        });
        const frame = buildTriangleTangentFrame(tri, interpolated_normal);
        const mapped_normal = frameToWorld(frame, tangent_space_normal);
        shading_normal = if (vec3.dot(mapped_normal, geometric_normal) > 0.0)
            mapped_normal
        else
            interpolated_normal;
    }

    return .{
        .albedo = albedo,
        .emissive = emissive,
        .metallic = metallic,
        .roughness = roughness,
        .shading_normal = shading_normal,
    };
}

pub fn samplePathTraceEmissiveRadiance(
    tri: PathTraceTriangle,
    textures: []const PathTraceTexture,
    hit_uv: [2]f32,
) [3]f32 {
    var emissive = tri.emissive;
    if (pathTraceTextureAt(textures, tri.emissive_texture_index)) |texture| {
        emissive = vec3.mul(emissive, sampleTextureBilinear(texture, hit_uv[0], hit_uv[1]));
    }
    return emissive;
}

pub fn frameToWorld(frame: TangentFrame, local: [3]f32) [3]f32 {
    return vec3.normalize(.{
        frame.tangent[0] * local[0] + frame.bitangent[0] * local[1] + frame.normal[0] * local[2],
        frame.tangent[1] * local[0] + frame.bitangent[1] * local[1] + frame.normal[1] * local[2],
        frame.tangent[2] * local[0] + frame.bitangent[2] * local[1] + frame.normal[2] * local[2],
    });
}

pub fn worldToFrame(frame: TangentFrame, world: [3]f32) [3]f32 {
    return .{
        vec3.dot(world, frame.tangent),
        vec3.dot(world, frame.bitangent),
        vec3.dot(world, frame.normal),
    };
}

pub fn sampleCosineHemisphere(normal: [3]f32, seed: u32) [3]f32 {
    const rand_u = hashUnitFloat(seed ^ 0x68bc21eb);
    const rand_v = hashUnitFloat(seed ^ 0x02e5be93);
    const r = std.math.sqrt(rand_u);
    const phi = std.math.tau * rand_v;
    const local = [3]f32{
        r * std.math.cos(phi),
        r * std.math.sin(phi),
        std.math.sqrt(@max(0.0, 1.0 - rand_u)),
    };
    return frameToWorld(buildTangentFrame(normal), local);
}

pub fn sampleGGXVisibleHalfVector(normal: [3]f32, view_dir: [3]f32, roughness: f32, seed: u32) [3]f32 {
    const frame = buildTangentFrame(normal);
    const local_view = worldToFrame(frame, view_dir);
    if (local_view[2] <= 0.0) return normal;

    const alpha = @max(roughness * roughness, 0.001);
    const rand_u = hashUnitFloat(seed ^ 0xa3d95fa1);
    const rand_v = hashUnitFloat(seed ^ 0x51c8e12d);

    const stretched_view = vec3.normalize(.{
        alpha * local_view[0],
        alpha * local_view[1],
        @max(local_view[2], 0.000001),
    });
    const lensq = stretched_view[0] * stretched_view[0] + stretched_view[1] * stretched_view[1];
    const tangent_1 = if (lensq > 0.0)
        [3]f32{
            -stretched_view[1] / std.math.sqrt(lensq),
            stretched_view[0] / std.math.sqrt(lensq),
            0.0,
        }
    else
        [3]f32{ 1.0, 0.0, 0.0 };
    const tangent_2 = vec3.cross(stretched_view, tangent_1);

    const r = std.math.sqrt(rand_u);
    const phi = std.math.tau * rand_v;
    const p1 = r * std.math.cos(phi);
    var p2 = r * std.math.sin(phi);
    const s = 0.5 * (1.0 + stretched_view[2]);
    p2 = (1.0 - s) * std.math.sqrt(@max(0.0, 1.0 - p1 * p1)) + s * p2;

    const micro_normal = vec3.normalize(.{
        tangent_1[0] * p1 + tangent_2[0] * p2 + stretched_view[0] * std.math.sqrt(@max(0.0, 1.0 - p1 * p1 - p2 * p2)),
        tangent_1[1] * p1 + tangent_2[1] * p2 + stretched_view[1] * std.math.sqrt(@max(0.0, 1.0 - p1 * p1 - p2 * p2)),
        tangent_1[2] * p1 + tangent_2[2] * p2 + stretched_view[2] * std.math.sqrt(@max(0.0, 1.0 - p1 * p1 - p2 * p2)),
    });
    const unstretched = [3]f32{
        alpha * micro_normal[0],
        alpha * micro_normal[1],
        @max(micro_normal[2], 0.0),
    };
    return frameToWorld(frame, unstretched);
}

pub fn distributionGGX(n_dot_h: f32, roughness: f32) f32 {
    const alpha = @max(roughness * roughness, 0.001);
    const alpha2 = alpha * alpha;
    const n_dot_h2 = n_dot_h * n_dot_h;
    const denom_term = n_dot_h2 * (alpha2 - 1.0) + 1.0;
    return alpha2 / @max(std.math.pi * denom_term * denom_term, 0.000001);
}

pub fn geometrySchlickGGX(n_dot_x: f32, roughness: f32) f32 {
    const r = roughness + 1.0;
    const k = (r * r) * 0.125;
    return n_dot_x / @max(n_dot_x * (1.0 - k) + k, 0.000001);
}

pub fn geometrySmithGGX(n_dot_v: f32, n_dot_l: f32, roughness: f32) f32 {
    return geometrySchlickGGX(n_dot_v, roughness) * geometrySchlickGGX(n_dot_l, roughness);
}

pub fn smithMaskingG1GGX(n_dot_x: f32, roughness: f32) f32 {
    if (n_dot_x <= 0.0) return 0.0;
    if (n_dot_x >= 1.0) return 1.0;

    const alpha = @max(roughness * roughness, 0.001);
    const alpha2 = alpha * alpha;
    const sin_theta2 = @max(0.0, 1.0 - n_dot_x * n_dot_x);
    const tan_theta2 = sin_theta2 / @max(n_dot_x * n_dot_x, 0.000001);
    return 2.0 / (1.0 + std.math.sqrt(1.0 + alpha2 * tan_theta2));
}

pub fn fresnelSchlick(cos_theta: f32, f0: [3]f32) [3]f32 {
    const factor = std.math.pow(f32, std.math.clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
    return .{
        f0[0] + (1.0 - f0[0]) * factor,
        f0[1] + (1.0 - f0[1]) * factor,
        f0[2] + (1.0 - f0[2]) * factor,
    };
}

pub fn computeOpaqueLobeProbabilities(
    albedo: [3]f32,
    metallic: f32,
    transmission: f32,
    fresnel_view: [3]f32,
) PathTraceBsdfProbabilities {
    const diffuse_weight = @max(
        0.0,
        maxComponent(albedo) * (1.0 - metallic) * (1.0 - transmission) * (1.0 - luminance(fresnel_view)),
    );
    const specular_weight = @max(0.0, luminance(fresnel_view) + metallic * 0.35 + 0.05);
    const total = diffuse_weight + specular_weight;
    if (total <= 0.000001) {
        return .{ .diffuse = 1.0, .specular = 0.0 };
    }
    return .{
        .diffuse = diffuse_weight / total,
        .specular = specular_weight / total,
    };
}

pub fn ggxSpecularPdf(normal: [3]f32, view_dir: [3]f32, light_dir: [3]f32, roughness: f32) f32 {
    const half_vector_raw = vec3.add(view_dir, light_dir);
    if (vec3.dot(half_vector_raw, half_vector_raw) <= 0.000001) return 0.0;
    const half_vector = vec3.normalize(half_vector_raw);
    const n_dot_v = std.math.clamp(vec3.dot(normal, view_dir), 0.0, 1.0);
    const n_dot_h = std.math.clamp(vec3.dot(normal, half_vector), 0.0, 1.0);
    const v_dot_h = std.math.clamp(vec3.dot(view_dir, half_vector), 0.0, 1.0);
    if (n_dot_v <= 0.0 or n_dot_h <= 0.0 or v_dot_h <= 0.0) return 0.0;

    const visible_masking = smithMaskingG1GGX(n_dot_v, roughness);
    return distributionGGX(n_dot_h, roughness) * visible_masking / @max(4.0 * n_dot_v, 0.000001);
}

pub fn evaluateOpaqueBsdf(
    albedo: [3]f32,
    metallic: f32,
    roughness: f32,
    transmission: f32,
    normal: [3]f32,
    view_dir: [3]f32,
    light_dir: [3]f32,
) PathTraceBsdfEval {
    const n_dot_v = std.math.clamp(vec3.dot(normal, view_dir), 0.0, 1.0);
    const n_dot_l = std.math.clamp(vec3.dot(normal, light_dir), 0.0, 1.0);
    if (n_dot_v <= 0.0 or n_dot_l <= 0.0) {
        return .{ .value = .{ 0.0, 0.0, 0.0 }, .pdf = 0.0 };
    }

    const half_vector = vec3.normalize(vec3.add(view_dir, light_dir));
    const n_dot_h = std.math.clamp(vec3.dot(normal, half_vector), 0.0, 1.0);
    const v_dot_h = std.math.clamp(vec3.dot(view_dir, half_vector), 0.0, 1.0);
    const opaque_weight = 1.0 - transmission;
    const dielectric_f0 = [3]f32{ 0.04, 0.04, 0.04 };
    const f0 = mixVec3(dielectric_f0, albedo, metallic);
    const fresnel = fresnelSchlick(v_dot_h, f0);
    const fresnel_view = fresnelSchlick(n_dot_v, f0);
    const probabilities = computeOpaqueLobeProbabilities(albedo, metallic, transmission, fresnel_view);
    const distribution = distributionGGX(n_dot_h, roughness);
    const geometry = geometrySmithGGX(n_dot_v, n_dot_l, roughness);
    const spec_scale = opaque_weight * distribution * geometry / @max(4.0 * n_dot_v * n_dot_l, 0.000001);
    const specular = .{
        fresnel[0] * spec_scale,
        fresnel[1] * spec_scale,
        fresnel[2] * spec_scale,
    };
    const diffuse_color = vec3.scale(albedo, (1.0 - metallic) * opaque_weight);
    const diffuse = vec3.scale(vec3.mul(diffuse_color, oneMinusVec3(fresnel)), 1.0 / std.math.pi);
    return .{
        .value = vec3.add(diffuse, specular),
        .pdf = probabilities.diffuse * (n_dot_l / std.math.pi) +
            probabilities.specular * ggxSpecularPdf(normal, view_dir, light_dir, roughness),
    };
}

pub fn directLightTypeCount(
    light_radiance: [3]f32,
    point_lights: []const PathTracePointLight,
    spot_lights: []const PathTraceSpotLight,
    environment_texture: ?PathTraceTexture,
    environment_importance: []const PathTraceEnvImportance,
    emissive_lights: []const PathTraceEmissiveLight,
    emissive_total_area: f32,
) u32 {
    var count: u32 = 0;
    if (maxComponent(light_radiance) > 0.0001) count += 1;
    for (point_lights) |light| {
        if (pathTracePointLightActive(light)) count += 1;
    }
    for (spot_lights) |light| {
        if (pathTraceSpotLightActive(light)) count += 1;
    }
    if (environment_texture != null and environment_importance.len > 0) count += 1;
    if (emissive_lights.len > 0 and emissive_total_area > 0.0) count += 1;
    return count;
}

pub fn pathTracePointLightActive(light: PathTracePointLight) bool {
    return light.intensity > 0.0001 and light.range > 0.001 and maxComponent(light.color) > 0.0001;
}

pub fn environmentDirectionPdf(
    environment_importance: []const PathTraceEnvImportance,
    table_width: u32,
    table_height: u32,
    direction: [3]f32,
) f32 {
    if (environment_importance.len == 0 or table_width == 0 or table_height == 0) return 0.0;
    const uv = directionToEnvironmentUv(direction);
    const x = @min(table_width - 1, @as(u32, @intFromFloat(uv[0] * @as(f32, @floatFromInt(table_width)))));
    const y = @min(table_height - 1, @as(u32, @intFromFloat(uv[1] * @as(f32, @floatFromInt(table_height)))));
    const cell_index: usize = @as(usize, y) * @as(usize, table_width) + @as(usize, x);
    const pmf = environment_importance[cell_index].pmf;
    const theta = std.math.clamp(uv[1], 0.0, 1.0) * std.math.pi;
    const sin_theta = @max(std.math.sin(theta), 0.0001);
    const solid_angle = (2.0 * std.math.pi / @as(f32, @floatFromInt(table_width))) *
        (std.math.pi / @as(f32, @floatFromInt(table_height))) * sin_theta;
    return pmf / @max(solid_angle, 0.000001);
}

pub fn sampleEnvironmentLight(
    environment_texture: PathTraceTexture,
    environment_importance: []const PathTraceEnvImportance,
    table_width: u32,
    table_height: u32,
    seed: u32,
) ?PathTraceDirectLightSample {
    if (environment_importance.len == 0 or table_width == 0 or table_height == 0) return null;
    const count_u32: u32 = @intCast(environment_importance.len);
    const select = @min(
        count_u32 - 1,
        @as(u32, @intFromFloat(hashUnitFloat(seed ^ 0x3c84ef95) * @as(f32, @floatFromInt(count_u32)))),
    );
    const entry = environment_importance[select];
    const resolved = if (hashUnitFloat(seed ^ 0x7e6b2f31) < entry.q) select else entry.alias;
    const cell_x = resolved % table_width;
    const cell_y = resolved / table_width;
    const u = (@as(f32, @floatFromInt(cell_x)) + hashUnitFloat(seed ^ 0x0f9d13c1)) /
        @as(f32, @floatFromInt(table_width));
    const v = (@as(f32, @floatFromInt(cell_y)) + hashUnitFloat(seed ^ 0x92c313f7)) /
        @as(f32, @floatFromInt(table_height));
    const direction = environmentUvToDirection(u, v);
    return .{
        .direction = direction,
        .radiance = sampleTextureBilinear(environment_texture, u, v),
        .pdf = environmentDirectionPdf(environment_importance, table_width, table_height, direction),
        .distance = 1.0e30,
        .delta = false,
    };
}

pub fn sampleEmissiveLight(
    hit_pos: [3]f32,
    current_tri_index: usize,
    triangles: []const PathTraceTriangle,
    textures: []const PathTraceTexture,
    emissive_lights: []const PathTraceEmissiveLight,
    emissive_total_area: f32,
    seed: u32,
) ?PathTraceDirectLightSample {
    if (emissive_lights.len == 0 or emissive_total_area <= 0.0) return null;
    const pick = hashUnitFloat(seed ^ 0xe18f0c7b);
    var chosen_index: usize = 0;
    var low: usize = 0;
    var high: usize = emissive_lights.len;
    while (low < high) {
        const mid = (low + high) / 2;
        if (pick <= emissive_lights[mid].cdf) {
            high = mid;
        } else {
            low = mid + 1;
        }
    }
    chosen_index = @min(low, emissive_lights.len - 1);
    const light = emissive_lights[chosen_index];
    if (light.triangle_index == current_tri_index) return null;
    const tri = triangles[light.triangle_index];
    const sqrt_r1 = std.math.sqrt(hashUnitFloat(seed ^ 0x1451ad37));
    const r2 = hashUnitFloat(seed ^ 0x45a18bc5);
    const b0 = 1.0 - sqrt_r1;
    const b1 = sqrt_r1 * (1.0 - r2);
    const b2 = sqrt_r1 * r2;
    const sample_pos = .{
        tri.v0[0] * b0 + tri.v1[0] * b1 + tri.v2[0] * b2,
        tri.v0[1] * b0 + tri.v1[1] * b1 + tri.v2[1] * b2,
        tri.v0[2] * b0 + tri.v1[2] * b1 + tri.v2[2] * b2,
    };
    const sample_uv = .{
        tri.uv0[0] * b0 + tri.uv1[0] * b1 + tri.uv2[0] * b2,
        tri.uv0[1] * b0 + tri.uv1[1] * b1 + tri.uv2[1] * b2,
    };
    const to_light = vec3.sub(sample_pos, hit_pos);
    const distance = vec3.length(to_light);
    if (distance <= 0.002) return null;
    const direction = vec3.scale(to_light, 1.0 / distance);
    const light_normal = triangleGeometricNormal(tri);
    const cos_light = @max(@abs(vec3.dot(vec3.scale(direction, -1.0), light_normal)), 0.0001);
    return .{
        .direction = direction,
        .radiance = samplePathTraceEmissiveRadiance(tri, textures, sample_uv),
        .pdf = (distance * distance) / @max(cos_light * emissive_total_area, 0.000001),
        .distance = distance,
        .delta = false,
    };
}

pub fn emissiveDirectionPdf(
    origin: [3]f32,
    hit_pos: [3]f32,
    tri: PathTraceTriangle,
    emissive_total_area: f32,
) f32 {
    if (emissive_total_area <= 0.0) return 0.0;
    const to_light = vec3.sub(hit_pos, origin);
    const distance_sq = vec3.dot(to_light, to_light);
    if (distance_sq <= 0.0) return 0.0;
    const direction = vec3.normalize(to_light);
    const light_normal = triangleGeometricNormal(tri);
    const cos_light = @max(@abs(vec3.dot(vec3.scale(direction, -1.0), light_normal)), 0.0001);
    return distance_sq / @max(cos_light * emissive_total_area, 0.000001);
}

pub fn samplePointLight(hit_pos: [3]f32, light: PathTracePointLight) ?PathTraceDirectLightSample {
    if (!pathTracePointLightActive(light)) return null;

    const to_light = vec3.sub(light.position, hit_pos);
    const distance = vec3.length(to_light);
    if (distance <= 0.002 or distance > light.range) return null;

    const falloff = std.math.clamp(1.0 - distance / @max(light.range, 0.001), 0.0, 1.0);
    const attenuation = falloff * falloff;
    if (attenuation <= 0.00001) return null;

    return .{
        .direction = vec3.scale(to_light, 1.0 / distance),
        .radiance = vec3.scale(light.color, light.intensity * attenuation),
        .pdf = 1.0,
        .distance = distance,
        .delta = true,
    };
}

pub fn pathTraceSpotLightActive(light: PathTraceSpotLight) bool {
    return light.intensity > 0.0001 and light.range > 0.001 and maxComponent(light.color) > 0.0001;
}

pub fn sampleSpotLight(hit_pos: [3]f32, light: PathTraceSpotLight) ?PathTraceDirectLightSample {
    if (!pathTraceSpotLightActive(light)) return null;

    const to_light = vec3.sub(light.position, hit_pos);
    const distance = vec3.length(to_light);
    if (distance <= 0.002 or distance > light.range) return null;

    const direction = vec3.scale(to_light, 1.0 / distance);
    const light_to_surface = vec3.scale(direction, -1.0);
    const light_forward = vec3.normalize(light.direction);
    const cone_cos = vec3.dot(light_forward, light_to_surface);
    if (cone_cos <= light.outer_angle_cos) return null;

    const falloff = std.math.clamp(1.0 - distance / @max(light.range, 0.001), 0.0, 1.0);
    const attenuation = falloff * falloff;
    const cone_factor = if (cone_cos >= light.inner_angle_cos)
        1.0
    else
        std.math.clamp(
            (cone_cos - light.outer_angle_cos) / @max(light.inner_angle_cos - light.outer_angle_cos, 0.0001),
            0.0,
            1.0,
        );
    const intensity = light.intensity * attenuation * cone_factor;
    if (intensity <= 0.00001) return null;

    return .{
        .direction = direction,
        .radiance = vec3.scale(light.color, intensity),
        .pdf = 1.0,
        .distance = distance,
        .delta = true,
    };
}

pub fn sampleDirectLight(
    hit_pos: [3]f32,
    current_tri_index: usize,
    triangles: []const PathTraceTriangle,
    textures: []const PathTraceTexture,
    point_lights: []const PathTracePointLight,
    spot_lights: []const PathTraceSpotLight,
    environment_texture: ?PathTraceTexture,
    environment_importance: []const PathTraceEnvImportance,
    environment_importance_width: u32,
    environment_importance_height: u32,
    emissive_lights: []const PathTraceEmissiveLight,
    emissive_total_area: f32,
    light_direction: [3]f32,
    light_radiance: [3]f32,
    seed: u32,
) ?PathTraceDirectLightSample {
    const light_type_count = directLightTypeCount(
        light_radiance,
        point_lights,
        spot_lights,
        environment_texture,
        environment_importance,
        emissive_lights,
        emissive_total_area,
    );
    if (light_type_count == 0) return null;

    const selection = @min(
        light_type_count - 1,
        @as(u32, @intFromFloat(hashUnitFloat(seed ^ 0xa241b3c1) * @as(f32, @floatFromInt(light_type_count)))),
    );
    var cursor: u32 = 0;

    if (maxComponent(light_radiance) > 0.0001) {
        if (selection == cursor) {
            return .{
                .direction = light_direction,
                .radiance = light_radiance,
                .pdf = 1.0 / @as(f32, @floatFromInt(light_type_count)),
                .distance = 1.0e30,
                .delta = true,
            };
        }
        cursor += 1;
    }

    for (point_lights) |point_light| {
        if (!pathTracePointLightActive(point_light)) continue;
        if (selection == cursor) {
            var sample = samplePointLight(hit_pos, point_light) orelse return null;
            sample.pdf = 1.0 / @as(f32, @floatFromInt(light_type_count));
            return sample;
        }
        cursor += 1;
    }

    for (spot_lights) |spot_light| {
        if (!pathTraceSpotLightActive(spot_light)) continue;
        if (selection == cursor) {
            var sample = sampleSpotLight(hit_pos, spot_light) orelse return null;
            sample.pdf = 1.0 / @as(f32, @floatFromInt(light_type_count));
            return sample;
        }
        cursor += 1;
    }

    if (environment_texture != null and environment_importance.len > 0) {
        if (selection == cursor) {
            var sample = sampleEnvironmentLight(
                environment_texture.?,
                environment_importance,
                environment_importance_width,
                environment_importance_height,
                seed ^ 0x6b84221f,
            ) orelse return null;
            sample.pdf *= 1.0 / @as(f32, @floatFromInt(light_type_count));
            return sample;
        }
        cursor += 1;
    }

    if (emissive_lights.len > 0 and emissive_total_area > 0.0 and selection == cursor) {
        var sample = sampleEmissiveLight(
            hit_pos,
            current_tri_index,
            triangles,
            textures,
            emissive_lights,
            emissive_total_area,
            seed ^ 0xb5297a4d,
        ) orelse return null;
        sample.pdf *= 1.0 / @as(f32, @floatFromInt(light_type_count));
        return sample;
    }

    return null;
}

pub fn pathTraceRussianRouletteSurvivalProbability(throughput: [3]f32) f32 {
    return @min(maxComponent(throughput), 0.95);
}

pub fn applyPathTraceRussianRoulette(throughput: *[3]f32, bounce: u32, seed: u32) bool {
    if (bounce < 2) return false;
    const survival_prob = pathTraceRussianRouletteSurvivalProbability(throughput.*);
    if (survival_prob <= 0.0) return true;
    if (hashUnitFloat(seed) > survival_prob) return true;
    throughput.* = vec3.scale(throughput.*, 1.0 / survival_prob);
    return false;
}

pub fn pathTraceAdaptiveMinSamples(max_samples: u32) u32 {
    if (max_samples <= 2) return max_samples;
    if (max_samples <= 4) return 2;
    return @min(max_samples, 4);
}

pub fn pathTraceAdaptiveNoiseMetric(sum: f32, sum_sq: f32, sample_count: u32) f32 {
    if (sample_count == 0) return 0.0;
    const sample_count_f = @as(f32, @floatFromInt(sample_count));
    const mean = sum / sample_count_f;
    const variance = @max(0.0, sum_sq / sample_count_f - mean * mean);
    return variance / @max(mean * mean, 0.0001);
}

pub fn pathTraceAdaptiveTargetSamples(max_samples: u32, tile_noise_metric: f32) u32 {
    const min_samples = pathTraceAdaptiveMinSamples(max_samples);
    if (max_samples <= min_samples) return max_samples;

    const remaining = max_samples - min_samples;
    const medium_samples = @min(max_samples, min_samples + @max(@as(u32, 1), (remaining + 1) / 2));
    if (tile_noise_metric <= 0.015) return min_samples;
    if (tile_noise_metric <= 0.06) return medium_samples;
    return max_samples;
}

pub fn pathTraceAdaptiveTileSpan(sample_step: u32) u32 {
    return @max(sample_step, sample_step * path_trace_adaptive_tile_dim);
}

pub fn advancePathTraceTileCursor(
    current_tile_x: *u32,
    current_tile_y: *u32,
    trace_width: u32,
    tile_span: u32,
) void {
    current_tile_x.* += tile_span;
    if (current_tile_x.* >= trace_width) {
        current_tile_x.* = 0;
        current_tile_y.* += tile_span;
    }
}

pub fn computePathTraceSampleStep(trace_width: u32, trace_height: u32) u32 {
    const pixel_budget: u32 = 960 * 540;
    const area = trace_width * trace_height;
    return if (area > pixel_budget * 4)
        4
    else if (area > pixel_budget * 2)
        3
    else if (area > pixel_budget)
        2
    else
        1;
}

pub fn buildPathTracePrimaryRay(
    pt: *const PathTraceProgressiveState,
    x: u32,
    y: u32,
    jitter_x: f32,
    jitter_y: f32,
) PathTracePrimaryRay {
    const uv_x = (@as(f32, @floatFromInt(x)) + 0.5 + jitter_x) /
        @as(f32, @floatFromInt(pt.trace_width));
    const uv_y = (@as(f32, @floatFromInt(y)) + 0.5 + jitter_y) /
        @as(f32, @floatFromInt(pt.trace_height));
    const ndc_x = uv_x * 2.0 - 1.0;
    const ndc_y = 1.0 - uv_y * 2.0;

    const world_near = unprojectNdc(pt.inv_view_projection, ndc_x, ndc_y, 0.0);
    const world_far = unprojectNdc(pt.inv_view_projection, ndc_x, ndc_y, 1.0);
    const ray_origin = pt.camera_origin;
    var ray_direction = vec3.normalize(vec3.sub(world_far, world_near));
    if (vec3.length(ray_direction) <= 0.0001) {
        ray_direction = vec3.normalize(vec3.sub(world_far, ray_origin));
    }

    return .{
        .origin = ray_origin,
        .direction = ray_direction,
    };
}

pub fn tracePathTracePixelSample(pt: *const PathTraceProgressiveState, x: u32, y: u32, sample_index: u32) [3]f32 {
    const triangles = pt.triangles orelse return .{ 0.0, 0.0, 0.0 };
    const meshes = pt.meshes orelse return .{ 0.0, 0.0, 0.0 };
    const textures = pt.textures orelse &[_]PathTraceTexture{};
    const environment_importance = pt.environment_importance orelse &[_]PathTraceEnvImportance{};
    const emissive_lights = pt.emissive_lights orelse &[_]PathTraceEmissiveLight{};
    const point_lights = pt.point_lights orelse &[_]PathTracePointLight{};
    const spot_lights = pt.spot_lights orelse &[_]PathTraceSpotLight{};
    const seed_base = hashU32(x ^ (y << 16) ^ 0x7f4a7c15);
    const jitter_seed = seed_base ^ (sample_index *% 0x45d9f3b);
    const jitter_x = hashUnitFloat(jitter_seed ^ 0x18f0e149) - 0.5;
    const jitter_y = hashUnitFloat(jitter_seed ^ 0x6c8e9cf5) - 0.5;
    const ray = buildPathTracePrimaryRay(pt, x, y, jitter_x, jitter_y);

    return pathTraceRay(
        ray.origin,
        ray.direction,
        triangles,
        meshes,
        textures,
        point_lights,
        spot_lights,
        pt.environment_texture,
        environment_importance,
        pt.environment_importance_width,
        pt.environment_importance_height,
        emissive_lights,
        pt.emissive_total_area,
        pt.light_direction,
        pt.light_radiance,
        jitter_seed,
        pt.cached_bounces,
    );
}

pub fn samplePathTraceGuidePixel(pt: *const PathTraceProgressiveState, x: u32, y: u32) PathTraceGuidePixel {
    const triangles = pt.triangles orelse return .{};
    const meshes = pt.meshes orelse return .{};
    const textures = pt.textures orelse &[_]PathTraceTexture{};
    const ray = buildPathTracePrimaryRay(pt, x, y, 0.0, 0.0);
    const scene_hit = tracePathTraceScene(ray.origin, ray.direction, triangles, meshes, 0.001, 1.0e30) orelse return .{};

    const tri = triangles[scene_hit.tri_index];
    const w0 = 1.0 - scene_hit.u - scene_hit.v;
    const hit_uv = [2]f32{
        w0 * tri.uv0[0] + scene_hit.u * tri.uv1[0] + scene_hit.v * tri.uv2[0],
        w0 * tri.uv0[1] + scene_hit.u * tri.uv1[1] + scene_hit.v * tri.uv2[1],
    };
    const interpolated_normal = vec3.normalize(.{
        w0 * tri.n0[0] + scene_hit.u * tri.n1[0] + scene_hit.v * tri.n2[0],
        w0 * tri.n0[1] + scene_hit.u * tri.n1[1] + scene_hit.v * tri.n2[1],
        w0 * tri.n0[2] + scene_hit.u * tri.n1[2] + scene_hit.v * tri.n2[2],
    });
    const geometric_normal_raw = triangleGeometricNormal(tri);
    const front_face = vec3.dot(ray.direction, geometric_normal_raw) < 0.0;
    const geometric_normal = if (front_face) geometric_normal_raw else vec3.scale(geometric_normal_raw, -1.0);
    const oriented_interpolated_normal = if (front_face) interpolated_normal else vec3.scale(interpolated_normal, -1.0);
    const material_sample = samplePathTraceMaterial(
        tri,
        textures,
        hit_uv,
        geometric_normal,
        oriented_interpolated_normal,
    );

    return .{
        .albedo = material_sample.albedo,
        .normal = vec3.normalize(material_sample.shading_normal),
    };
}

pub fn pathTraceRay(
    origin_start: [3]f32,
    direction_start: [3]f32,
    triangles: []const PathTraceTriangle,
    meshes: []const PathTraceMesh,
    textures: []const PathTraceTexture,
    point_lights: []const PathTracePointLight,
    spot_lights: []const PathTraceSpotLight,
    environment_texture: ?PathTraceTexture,
    environment_importance: []const PathTraceEnvImportance,
    environment_importance_width: u32,
    environment_importance_height: u32,
    emissive_lights: []const PathTraceEmissiveLight,
    emissive_total_area: f32,
    light_direction: [3]f32,
    light_radiance: [3]f32,
    seed_base: u32,
    max_bounces: u32,
) [3]f32 {
    var origin = origin_start;
    var direction = direction_start;
    var throughput = [3]f32{ 1.0, 1.0, 1.0 };
    var radiance = [3]f32{ 0.0, 0.0, 0.0 };
    var previous_bsdf_pdf: f32 = 0.0;
    var previous_was_delta = true;

    var bounce: u32 = 0;
    while (bounce < max_bounces) : (bounce += 1) {
        const scene_hit = tracePathTraceScene(origin, direction, triangles, meshes, 0.001, 1.0e30);
        if (scene_hit == null) {
            const sky = sampleSky(direction, environment_texture);
            if (bounce == 0 or previous_was_delta or environment_texture == null) {
                radiance = vec3.add(radiance, vec3.mul(throughput, sky));
            } else {
                const light_type_count = directLightTypeCount(
                    light_radiance,
                    point_lights,
                    spot_lights,
                    environment_texture,
                    environment_importance,
                    emissive_lights,
                    emissive_total_area,
                );
                const env_select_pdf = if (light_type_count > 0 and environment_texture != null and environment_importance.len > 0)
                    1.0 / @as(f32, @floatFromInt(light_type_count))
                else
                    0.0;
                const env_pdf = env_select_pdf * environmentDirectionPdf(
                    environment_importance,
                    environment_importance_width,
                    environment_importance_height,
                    direction,
                );
                const mis = powerHeuristic(previous_bsdf_pdf, env_pdf);
                radiance = vec3.add(radiance, vec3.scale(vec3.mul(throughput, sky), mis));
            }
            break;
        }

        const hit = scene_hit.?;
        const tri = triangles[hit.tri_index];
        const hit_pos = vec3.add(origin, vec3.scale(direction, hit.t));
        const w0 = 1.0 - hit.u - hit.v;
        const hit_uv = [2]f32{
            w0 * tri.uv0[0] + hit.u * tri.uv1[0] + hit.v * tri.uv2[0],
            w0 * tri.uv0[1] + hit.u * tri.uv1[1] + hit.v * tri.uv2[1],
        };
        const interpolated_normal = vec3.normalize(.{
            w0 * tri.n0[0] + hit.u * tri.n1[0] + hit.v * tri.n2[0],
            w0 * tri.n0[1] + hit.u * tri.n1[1] + hit.v * tri.n2[1],
            w0 * tri.n0[2] + hit.u * tri.n1[2] + hit.v * tri.n2[2],
        });
        const geometric_normal_raw = triangleGeometricNormal(tri);
        const front_face = vec3.dot(direction, geometric_normal_raw) < 0.0;
        const geometric_normal = if (front_face) geometric_normal_raw else vec3.scale(geometric_normal_raw, -1.0);
        const oriented_interpolated_normal = if (front_face) interpolated_normal else vec3.scale(interpolated_normal, -1.0);
        const material_sample = samplePathTraceMaterial(
            tri,
            textures,
            hit_uv,
            geometric_normal,
            oriented_interpolated_normal,
        );
        const shading_normal = material_sample.shading_normal;
        const view_dir = vec3.scale(direction, -1.0);
        const surface_albedo = material_sample.albedo;
        const surface_emissive = material_sample.emissive;
        const surface_metallic = material_sample.metallic;
        const surface_roughness = material_sample.roughness;
        const transmission = std.math.clamp(tri.transmission, 0.0, 0.98);

        const emissive_strength = maxComponent(surface_emissive);
        if (emissive_strength > 0.0001) {
            if (bounce == 0 or previous_was_delta) {
                radiance = vec3.add(radiance, vec3.mul(throughput, surface_emissive));
            } else {
                const light_type_count = directLightTypeCount(
                    light_radiance,
                    point_lights,
                    spot_lights,
                    environment_texture,
                    environment_importance,
                    emissive_lights,
                    emissive_total_area,
                );
                const emissive_select_pdf = if (light_type_count > 0 and emissive_lights.len > 0 and emissive_total_area > 0.0)
                    1.0 / @as(f32, @floatFromInt(light_type_count))
                else
                    0.0;
                const light_pdf = emissive_select_pdf * emissiveDirectionPdf(origin, hit_pos, tri, emissive_total_area);
                const mis = powerHeuristic(previous_bsdf_pdf, light_pdf);
                radiance = vec3.add(radiance, vec3.scale(vec3.mul(throughput, surface_emissive), mis));
            }
        }

        if (transmission < 0.995) {
            // NEE emits one explicit light sample per hit and balances it against the BRDF pdf.
            if (sampleDirectLight(
                hit_pos,
                hit.tri_index,
                triangles,
                textures,
                point_lights,
                spot_lights,
                environment_texture,
                environment_importance,
                environment_importance_width,
                environment_importance_height,
                emissive_lights,
                emissive_total_area,
                light_direction,
                light_radiance,
                seed_base ^ (bounce *% 0x9e3779b9),
            )) |light_sample| {
                const occlusion_distance = if (light_sample.distance >= 1.0e29) 1.0e30 else @max(light_sample.distance - 0.004, 0.001);
                const shadow_origin = vec3.add(hit_pos, vec3.scale(shading_normal, 0.002));
                if (!isPathTraceOccluded(shadow_origin, light_sample.direction, occlusion_distance, triangles, meshes)) {
                    const bsdf = evaluateOpaqueBsdf(
                        surface_albedo,
                        surface_metallic,
                        surface_roughness,
                        transmission,
                        shading_normal,
                        view_dir,
                        light_sample.direction,
                    );
                    if (bsdf.pdf > 0.0) {
                        const n_dot_l = std.math.clamp(vec3.dot(shading_normal, light_sample.direction), 0.0, 1.0);
                        const mis = if (light_sample.delta) 1.0 else powerHeuristic(light_sample.pdf, bsdf.pdf);
                        const direct = vec3.scale(
                            vec3.mul(vec3.mul(throughput, bsdf.value), light_sample.radiance),
                            (n_dot_l * mis) / @max(light_sample.pdf, 0.000001),
                        );
                        radiance = vec3.add(radiance, direct);
                    }
                }
            }
        }

        const transmission_branch_prob = std.math.clamp(transmission * (1.0 - surface_metallic), 0.0, 0.98);
        const opaque_branch_prob = 1.0 - transmission_branch_prob;
        const branch_seed = seed_base ^ (bounce *% 0x85ebca6b);
        if (transmission_branch_prob > 0.0 and hashUnitFloat(branch_seed ^ 0x1451ad37) < transmission_branch_prob) {
            const eta = if (front_face) 1.0 / @max(tri.ior, 1.01) else @max(tri.ior, 1.01);
            const dielectric_f0 = [3]f32{ 0.04, 0.04, 0.04 };
            const fresnel = fresnelSchlick(std.math.clamp(vec3.dot(shading_normal, view_dir), 0.0, 1.0), dielectric_f0);
            const reflect_prob = std.math.clamp(luminance(fresnel), 0.05, 0.95);
            const reflected = vec3.normalize(reflectVector(direction, shading_normal));
            const refracted = refractVector(direction, shading_normal, eta);

            if (refracted == null or hashUnitFloat(branch_seed ^ 0x45a18bc5) < reflect_prob) {
                throughput = vec3.scale(vec3.mul(throughput, fresnel), 1.0 / @max(transmission_branch_prob * reflect_prob, 0.000001));
                direction = reflected;
                origin = vec3.add(hit_pos, vec3.scale(shading_normal, 0.002));
            } else {
                const transmission_tint = mixVec3(.{ 1.0, 1.0, 1.0 }, surface_albedo, 0.18);
                throughput = vec3.scale(
                    vec3.mul(throughput, vec3.mul(transmission_tint, oneMinusVec3(fresnel))),
                    1.0 / @max(transmission_branch_prob * (1.0 - reflect_prob), 0.000001),
                );
                direction = vec3.normalize(refracted.?);
                if (tri.thickness > 0.0001) {
                    const ndot = @max(@abs(vec3.dot(direction, shading_normal)), 0.2);
                    const optical_distance = tri.thickness / ndot;
                    const sigma_a = .{
                        @max(0.0, 1.0 - surface_albedo[0]) * 2.2,
                        @max(0.0, 1.0 - surface_albedo[1]) * 2.2,
                        @max(0.0, 1.0 - surface_albedo[2]) * 2.2,
                    };
                    throughput = vec3.mul(throughput, .{
                        std.math.exp(-sigma_a[0] * optical_distance),
                        std.math.exp(-sigma_a[1] * optical_distance),
                        std.math.exp(-sigma_a[2] * optical_distance),
                    });
                }
                origin = vec3.add(hit_pos, vec3.scale(direction, 0.002));
            }
            previous_bsdf_pdf = 1.0;
            previous_was_delta = true;
        } else if (opaque_branch_prob > 0.0) {
            const dielectric_f0 = [3]f32{ 0.04, 0.04, 0.04 };
            const f0 = mixVec3(dielectric_f0, surface_albedo, surface_metallic);
            const fresnel_view = fresnelSchlick(std.math.clamp(vec3.dot(shading_normal, view_dir), 0.0, 1.0), f0);
            const lobe_probabilities = computeOpaqueLobeProbabilities(surface_albedo, surface_metallic, transmission, fresnel_view);
            const choose_specular = hashUnitFloat(branch_seed ^ 0x92c313f7) < lobe_probabilities.specular;
            var next_direction: [3]f32 = undefined;

            if (choose_specular) {
                const half_vector = sampleGGXVisibleHalfVector(shading_normal, view_dir, surface_roughness, branch_seed ^ 0x6b84221f);
                next_direction = vec3.normalize(reflectVector(vec3.scale(view_dir, -1.0), half_vector));
                if (vec3.dot(next_direction, shading_normal) <= 0.0) {
                    break;
                }
            } else {
                next_direction = sampleCosineHemisphere(shading_normal, branch_seed ^ 0xb5297a4d);
            }

            const bsdf = evaluateOpaqueBsdf(
                surface_albedo,
                surface_metallic,
                surface_roughness,
                transmission,
                shading_normal,
                view_dir,
                next_direction,
            );
            const n_dot_l = std.math.clamp(vec3.dot(shading_normal, next_direction), 0.0, 1.0);
            const overall_pdf = opaque_branch_prob * bsdf.pdf;
            if (overall_pdf <= 0.0 or n_dot_l <= 0.0) {
                break;
            }

            throughput = vec3.scale(vec3.mul(throughput, bsdf.value), n_dot_l / overall_pdf);
            direction = next_direction;
            origin = vec3.add(hit_pos, vec3.scale(shading_normal, 0.002));
            previous_bsdf_pdf = overall_pdf;
            previous_was_delta = false;
        } else {
            break;
        }

        if (applyPathTraceRussianRoulette(&throughput, bounce, seed_base ^ (bounce *% 0xc2b2ae35))) {
            break;
        }
    }

    return radiance;
}

pub const BuiltPathTraceEnvironmentImportance = struct {
    items: ?[]PathTraceEnvImportance = null,
    width: u32 = 0,
    height: u32 = 0,
};

pub fn buildPathTraceEnvironmentImportance(
    allocator: std.mem.Allocator,
    environment_texture: ?PathTraceTexture,
) !BuiltPathTraceEnvironmentImportance {
    const environment = environment_texture orelse return .{};
    const table_width = @min(environment.width, 256);
    const table_height = @min(environment.height, 128);
    if (table_width == 0 or table_height == 0) return .{};

    const entry_count: usize = @as(usize, table_width) * @as(usize, table_height);
    var weights = try allocator.alloc(f32, entry_count);
    defer allocator.free(weights);

    var total_weight: f64 = 0.0;
    var y: u32 = 0;
    while (y < table_height) : (y += 1) {
        var x: u32 = 0;
        while (x < table_width) : (x += 1) {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(table_width));
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(table_height));
            const theta = v * std.math.pi;
            const weight = @max(luminance(sampleTextureBilinear(environment, u, v)) * std.math.sin(theta), 0.000001);
            const index = @as(usize, y) * @as(usize, table_width) + @as(usize, x);
            weights[index] = weight;
            total_weight += weight;
        }
    }

    if (total_weight <= 0.0) return .{};

    var entries = try allocator.alloc(PathTraceEnvImportance, entry_count);
    errdefer allocator.free(entries);
    var scaled = try allocator.alloc(f32, entry_count);
    defer allocator.free(scaled);
    var small: std.ArrayListUnmanaged(usize) = .empty;
    defer small.deinit(allocator);
    var large: std.ArrayListUnmanaged(usize) = .empty;
    defer large.deinit(allocator);

    const count_f = @as(f32, @floatFromInt(entry_count));
    for (weights, 0..) |weight, index| {
        entries[index] = .{
            .q = 1.0,
            .pmf = @as(f32, @floatCast(weight / total_weight)),
            .alias = @intCast(index),
        };
        scaled[index] = entries[index].pmf * count_f;
        if (scaled[index] < 1.0) {
            try small.append(allocator, index);
        } else {
            try large.append(allocator, index);
        }
    }

    while (small.items.len > 0 and large.items.len > 0) {
        const small_index = small.pop().?;
        const large_index = large.pop().?;
        entries[small_index].q = std.math.clamp(scaled[small_index], 0.0, 1.0);
        entries[small_index].alias = @intCast(large_index);
        scaled[large_index] = (scaled[large_index] + scaled[small_index]) - 1.0;
        if (scaled[large_index] < 1.0) {
            try small.append(allocator, large_index);
        } else {
            try large.append(allocator, large_index);
        }
    }

    while (large.items.len > 0) {
        const index = large.pop().?;
        entries[index].q = 1.0;
        entries[index].alias = @intCast(index);
    }
    while (small.items.len > 0) {
        const index = small.pop().?;
        entries[index].q = 1.0;
        entries[index].alias = @intCast(index);
    }

    return .{
        .items = entries,
        .width = table_width,
        .height = table_height,
    };
}

pub const BuiltPathTraceEmissiveLights = struct {
    items: ?[]PathTraceEmissiveLight = null,
    total_area: f32 = 0.0,
};

pub fn appendPathTraceTextureIndex(
    allocator: std.mem.Allocator,
    texture_list: anytype,
    texture_index_map: *std.AutoHashMap(u32, i32),
    resources: *const assets_lib.ResourceLibrary,
    texture_handle: ?handles.TextureHandle,
) !i32 {
    const resolved_handle = texture_handle orelse return -1;
    const texture_key = @intFromEnum(resolved_handle);
    if (texture_index_map.get(texture_key)) |existing| return existing;

    const texture = resources.texture(resolved_handle) orelse return -1;
    if (texture.pixels.len == 0 or texture.width == 0 or texture.height == 0) return -1;

    const texture_index: i32 = @intCast(texture_list.items.len);
    try texture_list.append(allocator, .{
        .pixels = texture.pixels,
        .width = texture.width,
        .height = texture.height,
        .format = texture.format,
    });
    try texture_index_map.put(texture_key, texture_index);
    return texture_index;
}

pub fn resolvePathTraceTextureIndices(
    allocator: std.mem.Allocator,
    texture_list: anytype,
    texture_index_map: *std.AutoHashMap(u32, i32),
    resources: *const assets_lib.ResourceLibrary,
    material: ?*const material_resource_mod.MaterialResource,
    has_textures: [4]u32,
) !PathTraceTextureIndices {
    const resolved_material = material orelse return .{};
    const material_ast = material_ast_mod.MaterialAst.fromResource(resolved_material);
    return .{
        .base_color = if (has_textures[0] != 0)
            try appendPathTraceTextureIndex(allocator, texture_list, texture_index_map, resources, material_ast.textures.base_color)
        else
            -1,
        .metallic_roughness = if (has_textures[1] != 0)
            try appendPathTraceTextureIndex(allocator, texture_list, texture_index_map, resources, material_ast.textures.metallic_roughness)
        else
            -1,
        .normal = if (has_textures[2] != 0)
            try appendPathTraceTextureIndex(allocator, texture_list, texture_index_map, resources, material_ast.textures.normal)
        else
            -1,
        .occlusion = if (has_textures[3] != 0)
            try appendPathTraceTextureIndex(allocator, texture_list, texture_index_map, resources, material_ast.textures.occlusion)
        else
            -1,
        .emissive = try appendPathTraceTextureIndex(allocator, texture_list, texture_index_map, resources, material_ast.textures.emissive),
    };
}

pub fn buildPathTraceEmissiveLights(
    allocator: std.mem.Allocator,
    triangles: []const PathTraceTriangle,
) !BuiltPathTraceEmissiveLights {
    var list: std.ArrayListUnmanaged(PathTraceEmissiveLight) = .empty;
    defer list.deinit(allocator);

    var total_area: f32 = 0.0;
    for (triangles, 0..) |tri, tri_index| {
        if (maxComponent(tri.emissive) <= 0.0001) continue;
        const area = triangleArea(tri);
        if (area <= 0.000001) continue;
        total_area += area;
        try list.append(allocator, .{
            .triangle_index = @intCast(tri_index),
            .cdf = total_area,
        });
    }

    if (list.items.len == 0 or total_area <= 0.0) {
        return .{};
    }

    for (list.items) |*light| {
        light.cdf /= total_area;
    }

    return .{
        .items = try allocator.dupe(PathTraceEmissiveLight, list.items),
        .total_area = total_area,
    };
}

pub fn buildHwRtEmissiveLights(
    allocator: std.mem.Allocator,
    triangles: []const rt_backend.RtTriangle,
) !BuiltPathTraceEmissiveLights {
    var list: std.ArrayListUnmanaged(PathTraceEmissiveLight) = .empty;
    defer list.deinit(allocator);

    var total_area: f32 = 0.0;
    for (triangles, 0..) |tri, tri_index| {
        if (maxComponent(tri.emissive) <= 0.0001) continue;
        const edge_a = vec3.sub(tri.v1, tri.v0);
        const edge_b = vec3.sub(tri.v2, tri.v0);
        const area = 0.5 * vec3.length(vec3.cross(edge_a, edge_b));
        if (area <= 0.000001) continue;
        total_area += area;
        try list.append(allocator, .{
            .triangle_index = @intCast(tri_index),
            .cdf = total_area,
        });
    }

    if (list.items.len == 0 or total_area <= 0.0) {
        return .{};
    }

    for (list.items) |*light| {
        light.cdf /= total_area;
    }

    return .{
        .items = try allocator.dupe(PathTraceEmissiveLight, list.items),
        .total_area = total_area,
    };
}

pub fn sceneNeedsCpuPathTraceMaterialFallback(
    prepared_scene: *const mesh_pass_mod.PreparedScene,
    scene: *const scene_mod.Scene,
) bool {
    _ = prepared_scene;
    _ = scene;
    return false;
}

pub const BuiltHwRtSamplingTables = struct {
    data: ?[]u8 = null,
    meta: ?[]rt_backend.RtSamplingTableMeta = null,
};

pub fn buildHwRtSamplingTables(
    allocator: std.mem.Allocator,
    environment_importance: ?[]const PathTraceEnvImportance,
    emissive_lights: ?[]const PathTraceEmissiveLight,
) !BuiltHwRtSamplingTables {
    const env_items = environment_importance orelse &.{};
    const emissive_items = emissive_lights orelse &.{};
    var table_count: usize = 0;
    var total_bytes: usize = 0;
    if (env_items.len > 0) {
        table_count += 1;
        total_bytes += std.mem.sliceAsBytes(env_items).len;
    }
    if (emissive_items.len > 0) {
        table_count += 1;
        total_bytes += std.mem.sliceAsBytes(emissive_items).len;
    }
    if (table_count == 0 or total_bytes == 0) return .{};

    const data = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(data);
    const meta = try allocator.alloc(rt_backend.RtSamplingTableMeta, table_count);
    errdefer allocator.free(meta);

    var offset: usize = 0;
    var meta_index: usize = 0;
    if (env_items.len > 0) {
        const bytes = std.mem.sliceAsBytes(env_items);
        @memcpy(data[offset..][0..bytes.len], bytes);
        meta[meta_index] = .{
            .offset = @intCast(offset),
            .byte_size = @intCast(bytes.len),
            .kind = @intFromEnum(rt_backend.RtSamplingTableKind.environment_importance),
        };
        offset += bytes.len;
        meta_index += 1;
    }
    if (emissive_items.len > 0) {
        const bytes = std.mem.sliceAsBytes(emissive_items);
        @memcpy(data[offset..][0..bytes.len], bytes);
        meta[meta_index] = .{
            .offset = @intCast(offset),
            .byte_size = @intCast(bytes.len),
            .kind = @intFromEnum(rt_backend.RtSamplingTableKind.emissive_light),
        };
    }

    return .{
        .data = data,
        .meta = meta,
    };
}

pub fn renderCpuPathTraceTiles(pt: *PathTraceProgressiveState, use_progressive_budget: bool, budget_ns: i96) void {
    if (pt.complete) return;
    const trace_linear = pt.trace_linear_rgb orelse return;
    if (pt.trace_width == 0 or pt.trace_height == 0 or pt.cached_samples == 0) return;

    const start_time = std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds;
    const tile_span = pathTraceAdaptiveTileSpan(pt.sample_step);
    const use_adaptive_sampling = use_progressive_budget;
    const min_samples = if (use_adaptive_sampling)
        pathTraceAdaptiveMinSamples(pt.cached_samples)
    else
        pt.cached_samples;

    while (pt.current_tile_y < pt.trace_height) {
        var tile_blocks: [path_trace_adaptive_tile_capacity]PathTraceAdaptiveTileBlock = undefined;
        var tile_block_count: usize = 0;
        var tile_noise_metric_sum: f32 = 0.0;
        const tile_end_y = @min(pt.trace_height, pt.current_tile_y + tile_span);
        const tile_end_x = @min(pt.trace_width, pt.current_tile_x + tile_span);

        var y = pt.current_tile_y;
        while (y < tile_end_y) : (y += pt.sample_step) {
            var x = pt.current_tile_x;
            while (x < tile_end_x) : (x += pt.sample_step) {
                var block = PathTraceAdaptiveTileBlock{
                    .x = x,
                    .y = y,
                };
                var sample_index: u32 = 0;
                while (sample_index < min_samples) : (sample_index += 1) {
                    const sample_color = tracePathTracePixelSample(pt, x, y, sample_index);
                    block.color_sum = vec3.add(block.color_sum, sample_color);
                    const sample_luminance = luminance(sample_color);
                    block.luminance_sum += sample_luminance;
                    block.luminance_sum_sq += sample_luminance * sample_luminance;
                }

                tile_noise_metric_sum += pathTraceAdaptiveNoiseMetric(
                    block.luminance_sum,
                    block.luminance_sum_sq,
                    min_samples,
                );
                tile_blocks[tile_block_count] = block;
                tile_block_count += 1;
            }
        }

        const tile_noise_metric = if (tile_block_count > 0)
            tile_noise_metric_sum / @as(f32, @floatFromInt(tile_block_count))
        else
            0.0;
        const target_samples = if (use_adaptive_sampling)
            pathTraceAdaptiveTargetSamples(pt.cached_samples, tile_noise_metric)
        else
            pt.cached_samples;

        var block_index: usize = 0;
        while (block_index < tile_block_count) : (block_index += 1) {
            var block = tile_blocks[block_index];
            var sample_index = min_samples;
            while (sample_index < target_samples) : (sample_index += 1) {
                const sample_color = tracePathTracePixelSample(pt, block.x, block.y, sample_index);
                block.color_sum = vec3.add(block.color_sum, sample_color);
            }

            const hdr_rgb = vec3.scale(block.color_sum, 1.0 / @as(f32, @floatFromInt(target_samples)));
            var fy: u32 = 0;
            while (fy < pt.sample_step and block.y + fy < pt.trace_height) : (fy += 1) {
                var fx: u32 = 0;
                while (fx < pt.sample_step and block.x + fx < pt.trace_width) : (fx += 1) {
                    const out_x = block.x + fx;
                    const out_y = block.y + fy;
                    const pixel_index: usize = @as(usize, out_y) * @as(usize, pt.trace_width) + @as(usize, out_x);
                    const linear_index: usize = pixel_index * 3;
                    trace_linear[linear_index + 0] = hdr_rgb[0];
                    trace_linear[linear_index + 1] = hdr_rgb[1];
                    trace_linear[linear_index + 2] = hdr_rgb[2];
                }
            }
        }

        advancePathTraceTileCursor(&pt.current_tile_x, &pt.current_tile_y, pt.trace_width, tile_span);
        if (use_progressive_budget and std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds - start_time >= budget_ns) break;
    }

    if (pt.current_tile_y >= pt.trace_height) {
        pt.complete = true;
    }
}

pub fn resolvePathTraceDisplayPixels(pt: *PathTraceProgressiveState) void {
    const trace_linear = pt.trace_linear_rgb orelse return;
    const display_pixels = pt.display_pixels orelse return;
    if (pt.trace_width == 0 or pt.trace_height == 0 or pt.target_width == 0 or pt.target_height == 0) return;

    var out_y: u32 = 0;
    while (out_y < pt.target_height) : (out_y += 1) {
        const src_y_u64 = (@as(u64, out_y) * @as(u64, pt.trace_height)) / @as(u64, pt.target_height);
        const src_y: u32 = @min(pt.trace_height - 1, @as(u32, @intCast(src_y_u64)));
        var out_x: u32 = 0;
        while (out_x < pt.target_width) : (out_x += 1) {
            const src_x_u64 = (@as(u64, out_x) * @as(u64, pt.trace_width)) / @as(u64, pt.target_width);
            const src_x: u32 = @min(pt.trace_width - 1, @as(u32, @intCast(src_x_u64)));
            const src_index: usize = (@as(usize, src_y) * @as(usize, pt.trace_width) + @as(usize, src_x)) * 3;
            const dst_pixel: usize = @as(usize, out_y) * @as(usize, pt.target_width) + @as(usize, out_x);
            image_export.writeHdrPixelRgba16f(display_pixels, dst_pixel, .{
                trace_linear[src_index + 0],
                trace_linear[src_index + 1],
                trace_linear[src_index + 2],
            });
        }
    }
}
