const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const environment_map_import_mod = @import("../assets/environment_map_import.zig");
const texture_import_mod = @import("../assets/texture_import.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const path_trace_common = @import("path_trace/path_trace_common.zig");
const rhi_mod = @import("../rhi/device.zig");
const scene_mod = @import("../scene/scene.zig");

const render_log = std.log.scoped(.viewport_render);

var g_logged_environment_status: bool = false;

pub const PathTraceEnvironment = path_trace_common.PathTraceEnvironment;

pub const CachedEnvironmentTextures = struct {
    resolved: bool = false,
    selection_fingerprint: u64 = 0,
    environment_map: ?*const rhi_mod.Texture = null,
    irradiance_map: ?*const rhi_mod.Texture = null,
    prefiltered_env_map: ?*const rhi_mod.Texture = null,
    brdf_lut: ?*const rhi_mod.Texture = null,
};

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

pub fn resolveEnvironmentTextures(
    self: anytype,
    scene: *scene_mod.Scene,
    prepared_scene: *mesh_pass_mod.PreparedScene,
) !void {
    const selection_fingerprint = environmentSelectionFingerprint(&scene.resources);

    if (self.cached_env_textures.resolved and self.cached_env_textures.selection_fingerprint == selection_fingerprint) {
        prepared_scene.environment_map = self.cached_env_textures.environment_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.irradiance_map = self.cached_env_textures.irradiance_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.prefiltered_env_map = self.cached_env_textures.prefiltered_env_map orelse &self.scene_cache.fallback_texture.?;
        prepared_scene.brdf_lut = self.cached_env_textures.brdf_lut orelse if (self.gpu_brdf_lut) |*lut| lut else self.scene_cache.fallbackBrdfLut();
        return;
    }

    prepared_scene.environment_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.irradiance_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.prefiltered_env_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.brdf_lut = if (self.gpu_brdf_lut) |*lut| lut else self.scene_cache.fallbackBrdfLut();

    self.cached_env_textures = .{
        .resolved = true,
        .selection_fingerprint = selection_fingerprint,
        .environment_map = null,
        .irradiance_map = null,
        .prefiltered_env_map = null,
        .brdf_lut = null,
    };

    const borrowed_id = findSceneEnvironmentAssetId(&scene.resources) orelse {
        if (!g_logged_environment_status) {
            render_log.warn("no HDR environment asset found; using fallback environment textures", .{});
            g_logged_environment_status = true;
        }
        return;
    };

    const environment_asset_id = self.allocator.dupe(u8, borrowed_id) catch return;
    defer self.allocator.free(environment_asset_id);

    if (!g_logged_environment_status) {
        render_log.info("environment asset selected: {s}", .{environment_asset_id});
        g_logged_environment_status = true;
    }
    _ = texture_import_mod.loadTextureAsset(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load environment texture asset '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        return;
    };

    var environment = environment_map_import_mod.loadIBLData(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load IBL data for '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        return;
    };
    defer environment.deinit(self.allocator);

    if (environment.environment_map_handle) |handle| {
        prepared_scene.environment_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.irradiance_map_handle) |handle| {
        prepared_scene.irradiance_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.prefiltered_map_handle) |handle| {
        prepared_scene.prefiltered_env_map = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }
    if (environment.brdf_lut_handle) |handle| {
        prepared_scene.brdf_lut = try self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle);
    }

    if (self.gpu_brdf_lut) |*lut| {
        prepared_scene.brdf_lut = lut;
    }

    self.cached_env_textures = .{
        .resolved = true,
        .selection_fingerprint = selection_fingerprint,
        .environment_map = prepared_scene.environment_map,
        .irradiance_map = prepared_scene.irradiance_map,
        .prefiltered_env_map = prepared_scene.prefiltered_env_map,
        .brdf_lut = prepared_scene.brdf_lut,
    };
}

pub fn environmentSelectionFingerprint(resources: *const assets_lib.ResourceLibrary) u64 {
    const asset_id = findSceneEnvironmentAssetId(resources) orelse return 0;
    const record = resources.asset_registry.recordById(asset_id) orelse return 0;

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(record.id);
    hasher.update(record.source_path);
    hasher.update(record.source_hash);
    hasher.update(record.import_settings_hash);
    var import_version = record.resolvedImportVersion();
    hasher.update(std.mem.asBytes(&import_version));
    return hasher.final();
}

pub fn findSceneEnvironmentAssetId(resources: *const assets_lib.ResourceLibrary) ?[]const u8 {
    const environment_asset_id = resources.sceneEnvironmentAssetId() orelse return null;
    const record = resources.asset_registry.recordById(environment_asset_id) orelse return null;
    if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
        return null;
    }
    std.fs.cwd().access(record.source_path, .{}) catch return null;
    return record.id;
}
