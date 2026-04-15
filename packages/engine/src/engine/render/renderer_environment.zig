const std = @import("std");
const io_globals = @import("io_globals");
const assets_lib = @import("../assets/library.zig");
const handles = @import("../assets/handles.zig");
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
    environment_map_handle: ?handles.TextureHandle = null,
    irradiance_map_handle: ?handles.TextureHandle = null,
    prefiltered_env_map_handle: ?handles.TextureHandle = null,
    brdf_lut_handle: ?handles.TextureHandle = null,
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
        // Cache hit — re-resolve handles to fresh pointers each frame; the GPU texture ArrayList
        // may have been reallocated since last frame due to other texture uploads.
        prepared_scene.environment_map = if (self.cached_env_textures.environment_map_handle) |h|
            self.scene_cache.ensureTextureHandle(&self.rhi, scene, h) catch |err| blk: {
                render_log.warn("cache-hit ensureTextureHandle(env_map) failed: {s}", .{@errorName(err)});
                break :blk &self.scene_cache.fallback_texture.?;
            }
        else
            &self.scene_cache.fallback_texture.?;
        prepared_scene.irradiance_map = if (self.cached_env_textures.irradiance_map_handle) |h|
            self.scene_cache.ensureTextureHandle(&self.rhi, scene, h) catch &self.scene_cache.fallback_texture.?
        else
            &self.scene_cache.fallback_texture.?;
        prepared_scene.prefiltered_env_map = if (self.cached_env_textures.prefiltered_env_map_handle) |h|
            self.scene_cache.ensureTextureHandle(&self.rhi, scene, h) catch &self.scene_cache.fallback_texture.?
        else
            &self.scene_cache.fallback_texture.?;
        prepared_scene.brdf_lut = if (self.cached_env_textures.brdf_lut_handle) |h|
            self.scene_cache.ensureTextureHandle(&self.rhi, scene, h) catch self.scene_cache.fallbackBrdfLut()
        else
            self.scene_cache.fallbackBrdfLut();
        if (self.gpu_brdf_lut) |*lut| {
            prepared_scene.brdf_lut = lut;
        }
        return;
    }

    prepared_scene.environment_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.irradiance_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.prefiltered_env_map = &self.scene_cache.fallback_texture.?;
    prepared_scene.brdf_lut = if (self.gpu_brdf_lut) |*lut| lut else self.scene_cache.fallbackBrdfLut();

    // Cache miss — log fingerprint transition
    render_log.info("resolveEnv: cache miss — old_fp={x}, new_fp={x}", .{
        self.cached_env_textures.selection_fingerprint, selection_fingerprint,
    });
    // Reset skybox log flag so we see the new texture dimensions
    self.skybox_logged = false;
    self.skybox_log_count = 0;

    self.cached_env_textures = .{
        .resolved = true,
        .selection_fingerprint = selection_fingerprint,
        .environment_map_handle = null,
        .irradiance_map_handle = null,
        .prefiltered_env_map_handle = null,
        .brdf_lut_handle = null,
    };

    const borrowed_id = findSceneEnvironmentAssetId(&scene.resources) orelse {
        if (!g_logged_environment_status) {
            render_log.warn("no HDR environment asset found; using fallback environment textures", .{});
            g_logged_environment_status = true;
        }
        return;
    };

    // Always log when we detect a new environment (fingerprint changed)
    render_log.info("resolveEnv: asset_id='{s}', loading...", .{borrowed_id});

    const environment_asset_id = self.allocator.dupe(u8, borrowed_id) catch return;
    defer self.allocator.free(environment_asset_id);

    if (!g_logged_environment_status) {
        render_log.info("environment asset selected: {s}", .{environment_asset_id});
    }
    _ = texture_import_mod.loadTextureAsset(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load environment texture asset '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        g_logged_environment_status = true;
        return;
    };

    if (!g_logged_environment_status) {
        render_log.info("environment texture loaded OK, loading IBL data...", .{});
    }
    var environment = environment_map_import_mod.loadIBLData(
        self.allocator,
        &scene.resources,
        &scene.resources.asset_registry,
        environment_asset_id,
    ) catch |err| {
        render_log.warn("failed to load IBL data for '{s}': {s}; using fallback", .{ environment_asset_id, @errorName(err) });
        g_logged_environment_status = true;
        return;
    };
    defer environment.deinit(self.allocator);

    render_log.info("IBL loaded: env_map={}, irr={}, pref={}, brdf={}", .{
        environment.environment_map_handle != null,
        environment.irradiance_map_handle != null,
        environment.prefiltered_map_handle != null,
        environment.brdf_lut_handle != null,
    });

    // Phase 1: Ensure all IBL textures are cached in the GPU texture array.
    // This may cause ArrayList reallocations, so we must NOT hold pointers yet.
    if (environment.environment_map_handle) |handle| {
        _ = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle failed for environment_map: {s}; using fallback", .{@errorName(err)});
            return;
        };
    }
    if (environment.irradiance_map_handle) |handle| {
        _ = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle failed for irradiance_map: {s}; using fallback", .{@errorName(err)});
            return;
        };
    }
    if (environment.prefiltered_map_handle) |handle| {
        _ = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle failed for prefiltered_env_map: {s}; using fallback", .{@errorName(err)});
            return;
        };
    }
    if (environment.brdf_lut_handle) |handle| {
        _ = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle failed for brdf_lut: {s}; using fallback", .{@errorName(err)});
            return;
        };
    }

    // Phase 2: All textures are now cached — re-fetch stable pointers
    // (no more ArrayList appends, so these pointers remain valid).
    if (environment.environment_map_handle) |handle| {
        prepared_scene.environment_map = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle (phase2) failed for environment_map: {s}", .{@errorName(err)});
            return;
        };
    }
    if (environment.irradiance_map_handle) |handle| {
        prepared_scene.irradiance_map = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle (phase2) failed for irradiance_map: {s}", .{@errorName(err)});
            return;
        };
    }
    if (environment.prefiltered_map_handle) |handle| {
        prepared_scene.prefiltered_env_map = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle (phase2) failed for prefiltered_env_map: {s}", .{@errorName(err)});
            return;
        };
    }
    if (environment.brdf_lut_handle) |handle| {
        prepared_scene.brdf_lut = self.scene_cache.ensureTextureHandle(&self.rhi, scene, handle) catch |err| {
            render_log.warn("ensureTextureHandle (phase2) failed for brdf_lut: {s}", .{@errorName(err)});
            return;
        };
    }

    if (self.gpu_brdf_lut) |*lut| {
        prepared_scene.brdf_lut = lut;
    }

    self.cached_env_textures = .{
        .resolved = true,
        .selection_fingerprint = selection_fingerprint,
        .environment_map_handle = environment.environment_map_handle,
        .irradiance_map_handle = environment.irradiance_map_handle,
        .prefiltered_env_map_handle = environment.prefiltered_map_handle,
        .brdf_lut_handle = environment.brdf_lut_handle,
    };

    render_log.info("resolveEnv: cache updated — env={}, irr={}, pref={}, brdf={}", .{
        self.cached_env_textures.environment_map_handle != null,
        self.cached_env_textures.irradiance_map_handle != null,
        self.cached_env_textures.prefiltered_env_map_handle != null,
        self.cached_env_textures.brdf_lut_handle != null,
    });
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

var g_find_env_log_count: u32 = 0;

pub fn findSceneEnvironmentAssetId(resources: *const assets_lib.ResourceLibrary) ?[]const u8 {
    const environment_asset_id = resources.sceneEnvironmentAssetId() orelse {
        return null;
    };
    const record = resources.asset_registry.recordById(environment_asset_id) orelse {
        render_log.warn("findSceneEnvAssetId: no registry record for '{s}'", .{environment_asset_id});
        return null;
    };
    if (record.type != .texture or !std.mem.endsWith(u8, record.source_path, ".hdr")) {
        render_log.warn("findSceneEnvAssetId: record type={} source_path='{s}' — not .texture or not .hdr", .{ @intFromEnum(record.type), record.source_path });
        return null;
    }
    std.Io.Dir.cwd().access(io_globals.global_io, record.source_path, .{}) catch |err| {
        render_log.warn("findSceneEnvAssetId: access('{s}') failed: {s}", .{ record.source_path, @errorName(err) });
        return null;
    };
    return record.id;
}
