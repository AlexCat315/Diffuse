const std = @import("std");
const rhi_types = @import("guava_rhi").types;
const mat4_mod = @import("../../math/mat4.zig");
const AABB = @import("../../math/aabb.zig").AABB;

pub const PathTraceTriangle = struct {
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
    n0: [3]f32,
    n1: [3]f32,
    n2: [3]f32,
    uv0: [2]f32,
    uv1: [2]f32,
    uv2: [2]f32,
    albedo: [3]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    transmission: f32,
    ior: f32,
    thickness: f32,
    base_color_texture_index: i32 = -1,
    metallic_roughness_texture_index: i32 = -1,
    normal_texture_index: i32 = -1,
    occlusion_texture_index: i32 = -1,
    emissive_texture_index: i32 = -1,
};

pub const PathTraceTexture = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
};

pub const PathTraceEnvironment = struct {
    handle: u32 = 0,
    texture: ?PathTraceTexture = null,
};

pub const PathTraceTextureIndices = struct {
    base_color: i32 = -1,
    metallic_roughness: i32 = -1,
    normal: i32 = -1,
    occlusion: i32 = -1,
    emissive: i32 = -1,
};

pub const PathTraceMaterialSample = struct {
    albedo: [3]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    shading_normal: [3]f32,
};

pub const PathTracePrimaryRay = struct {
    origin: [3]f32,
    direction: [3]f32,
};

pub const PathTraceGuidePixel = struct {
    albedo: [3]f32 = .{ 0.0, 0.0, 0.0 },
    normal: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const PathTraceGuideBuffers = struct {
    albedo: []f32,
    normal: []f32,
    width: u32,
    height: u32,

    pub fn deinit(self: *PathTraceGuideBuffers, allocator: std.mem.Allocator) void {
        allocator.free(self.albedo);
        allocator.free(self.normal);
        self.* = undefined;
    }
};

pub const PathTraceEnvImportance = extern struct {
    q: f32,
    pmf: f32,
    alias: u32,
};

pub const PathTraceEmissiveLight = extern struct {
    triangle_index: u32,
    cdf: f32,
};

pub const PathTracePointLight = extern struct {
    position: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
};

pub const PathTraceSpotLight = extern struct {
    position: [3]f32,
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
    inner_angle_cos: f32,
    outer_angle_cos: f32,
};

pub const PathTraceMesh = struct {
    aabb: AABB,
    tri_start: u32,
    tri_count: u32,
};

pub const PathTraceProgressiveState = struct {
    current_tile_x: u32 = 0,
    current_tile_y: u32 = 0,
    complete: bool = false,
    trace_linear_rgb: ?[]f32 = null,
    display_pixels: ?[]u8 = null,
    trace_width: u32 = 0,
    trace_height: u32 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    triangles: ?[]PathTraceTriangle = null,
    meshes: ?[]PathTraceMesh = null,
    textures: ?[]PathTraceTexture = null,
    environment_texture: ?PathTraceTexture = null,
    environment_importance: ?[]PathTraceEnvImportance = null,
    environment_importance_width: u32 = 0,
    environment_importance_height: u32 = 0,
    emissive_lights: ?[]PathTraceEmissiveLight = null,
    point_lights: ?[]PathTracePointLight = null,
    spot_lights: ?[]PathTraceSpotLight = null,
    emissive_total_area: f32 = 0.0,
    inv_view_projection: [16]f32 = mat4_mod.identity(),
    camera_origin: [3]f32 = .{ 0, 0, 0 },
    light_direction: [3]f32 = .{ 0, 1, 0 },
    light_radiance: [3]f32 = .{ 0, 0, 0 },
    sample_step: u32 = 1,
    cached_samples: u32 = 0,
    cached_bounces: u32 = 0,
    last_view_projection: [16]f32 = mat4_mod.identity(),
    last_samples: u32 = 0,
    last_bounces: u32 = 0,
    last_resolution_scale: f32 = 0.0,
    last_environment_texture_handle: u32 = 0,
    last_scene_signature: u64 = 0,

    pub fn reset(self: *PathTraceProgressiveState, allocator: std.mem.Allocator) void {
        self.current_tile_x = 0;
        self.current_tile_y = 0;
        self.complete = false;
        self.environment_texture = null;
        if (self.triangles) |triangles| {
            allocator.free(triangles);
            self.triangles = null;
        }
        if (self.meshes) |meshes| {
            allocator.free(meshes);
            self.meshes = null;
        }
        if (self.textures) |textures| {
            allocator.free(textures);
            self.textures = null;
        }
        if (self.environment_importance) |items| {
            allocator.free(items);
            self.environment_importance = null;
        }
        if (self.emissive_lights) |items| {
            allocator.free(items);
            self.emissive_lights = null;
        }
        if (self.point_lights) |items| {
            allocator.free(items);
            self.point_lights = null;
        }
        if (self.spot_lights) |items| {
            allocator.free(items);
            self.spot_lights = null;
        }
        self.environment_importance_width = 0;
        self.environment_importance_height = 0;
        self.emissive_total_area = 0.0;
    }

    pub fn deinit(self: *PathTraceProgressiveState, allocator: std.mem.Allocator) void {
        if (self.trace_linear_rgb) |rgb| allocator.free(rgb);
        if (self.display_pixels) |pixels| allocator.free(pixels);
        if (self.triangles) |triangles| allocator.free(triangles);
        if (self.meshes) |meshes| allocator.free(meshes);
        if (self.textures) |textures| allocator.free(textures);
        if (self.environment_importance) |items| allocator.free(items);
        if (self.emissive_lights) |items| allocator.free(items);
        if (self.point_lights) |items| allocator.free(items);
        if (self.spot_lights) |items| allocator.free(items);
        self.* = .{};
    }
};

pub const path_trace_adaptive_tile_dim: u32 = 8;
pub const path_trace_adaptive_tile_capacity: usize = path_trace_adaptive_tile_dim * path_trace_adaptive_tile_dim;

pub const PathTraceAdaptiveTileBlock = struct {
    x: u32 = 0,
    y: u32 = 0,
    color_sum: [3]f32 = .{ 0.0, 0.0, 0.0 },
    luminance_sum: f32 = 0.0,
    luminance_sum_sq: f32 = 0.0,
};
