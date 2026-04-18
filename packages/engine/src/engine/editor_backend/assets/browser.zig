const builtin = @import("builtin");
const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const asset_preview = @import("preview.zig");
const io_globals = @import("io_globals");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;
const BottomWorkspaceTab = state_mod.BottomWorkspaceTab;
const asset_drag_preview_icon_size: f32 = 24.0;
const drawer_corner_radius: f32 = 0.0;
const drawer_side_margin: f32 = 0.0;
const drawer_bottom_margin: f32 = 0.0;
const drawer_bar_height: f32 = 38.0;
const drawer_content_margin: f32 = 10.0;
const drawer_resize_grip_width: f32 = 44.0;
const drawer_resize_grip_height: f32 = 4.0;
const drawer_min_height: f32 = 136.0;
const drawer_top_clearance: f32 = 72.0;

pub fn drawProjectBrowserWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    _ = layer_context;
}

pub fn drawBottomDrawer(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    _ = layer_context;
}

const DrawerHeightBounds = struct {
    min: f32,
    max: f32,
};

fn drawerHeightBounds(state: *const EditorState) DrawerHeightBounds {
    const hard_max_height = @max(state.viewport_extent[1] - drawer_bar_height - drawer_bottom_margin - 8.0, 48.0);
    const preferred_max_height = state.viewport_extent[1] - drawer_bar_height - drawer_bottom_margin - drawer_top_clearance;
    const max_height = std.math.clamp(preferred_max_height, 48.0, hard_max_height);
    return .{
        .min = @min(drawer_min_height, max_height),
        .max = max_height,
    };
}

/// Check if `child` is a direct subdirectory of `parent` in the flat directory list.
fn isDirectChildDir(child: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, child, parent)) return false;
    if (std.mem.eql(u8, parent, "/")) {
        // Direct child of root: starts with "/" and has no more "/"
        if (child.len <= 1) return false;
        return std.mem.indexOfScalar(u8, child[1..], '/') == null;
    }
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len <= parent.len or child[parent.len] != '/') return false;
    // No more "/" after parent+"/"
    return std.mem.indexOfScalar(u8, child[parent.len + 1 ..], '/') == null;
}

/// Inspector panel (right column): shows properties and actions for the selected asset.

// Responsive header: adapts to panel width

fn sortAssetEntries(state: *EditorState) void {
    switch (state.asset_sort_mode) {
        .name_asc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                // Directories always sort first
                if (a.is_directory != b.is_directory) return a.is_directory;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
        .name_desc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                return std.mem.lessThan(u8, b.name, a.name);
            }
        }.f),
        .kind_asc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                if (@intFromEnum(a.kind) != @intFromEnum(b.kind))
                    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
        .kind_desc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                if (@intFromEnum(a.kind) != @intFromEnum(b.kind))
                    return @intFromEnum(a.kind) > @intFromEnum(b.kind);
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
    }
}

fn isAssetSelected(state: *const EditorState, index: usize) bool {
    if (index >= 4096) return state.selected_asset_index == index;
    return state.asset_selected_set.isSet(index);
}

fn assetIconTint(kind: AssetKind) [4]u8 {
    return switch (kind) {
        .scene => .{ 100, 160, 255, 255 }, // Unity-style blue (prefab/scene)
        .model => .{ 180, 220, 255, 255 }, // Light blue (3D model)
        .material => .{ 186, 228, 196, 255 }, // Mint green
        .texture => .{ 255, 214, 150, 255 }, // Light orange
        .shader => .{ 214, 176, 255, 255 }, // Lavender
        .script => .{ 120, 200, 80, 255 }, // Unity C# green
        .directory => .{ 255, 210, 100, 255 }, // Golden yellow
        .unknown => .{ 180, 180, 180, 255 }, // Gray
    };
}

fn assetKindShortLabel(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => "Scene",
        .model => "Model",
        .material => "Material",
        .texture => "Texture",
        .shader => "Shader",
        .script => "Script",
        .directory => "Folder",
        .unknown => "File",
    };
}

fn assetKindForRecordType(record_type: engine.assets.AssetType) ?AssetKind {
    return switch (record_type) {
        .scene => .scene,
        .model => .model,
        .material => .material,
        .texture => .texture,
        .shader => .shader,
        .script => .script,
        else => null,
    };
}

fn selectedDirectory(state: *const EditorState) []const u8 {
    const value = utils.zeroTerminatedSlice(state.asset_directory_buffer[0..]);
    return if (value.len == 0) "/" else value;
}

fn ensureSelectedAssetDirectory(state: *EditorState) void {
    if (selectedDirectory(state).len == 0 or state.asset_directories.items.len == 0) {
        setSelectedAssetDirectory(state, "/");
        return;
    }
    for (state.asset_directories.items) |directory| {
        if (std.mem.eql(u8, directory, selectedDirectory(state))) {
            return;
        }
    }
    setSelectedAssetDirectory(state, "/");
}

fn setSelectedAssetDirectory(state: *EditorState, path: []const u8) void {
    @memset(state.asset_directory_buffer[0..], 0);
    const copy_len = @min(path.len, state.asset_directory_buffer.len - 1);
    @memcpy(state.asset_directory_buffer[0..copy_len], path[0..copy_len]);
}

fn assetVisibleInDirectory(state: *const EditorState, entry: AssetEntry) bool {
    const selected_dir = selectedDirectory(state);
    const parent_dir = directoryPath(entry.display_path);
    // Show only direct children of the selected directory (Godot/Unity-style).
    if (std.mem.eql(u8, selected_dir, "/")) {
        return parent_dir.len == 0;
    }
    return std.mem.eql(u8, selected_dir, parent_dir);
}

fn directoryPath(path: []const u8) []const u8 {
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return path[0..slash_index];
}

fn directoryName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) {
        return "/";
    }
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash_index + 1 ..];
}

fn directoryDepth(path: []const u8) usize {
    if (std.mem.eql(u8, path, "/")) {
        return 0;
    }
    var depth: usize = 0;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            depth += 1;
        }
    }
    return depth;
}

fn assetBrowserRootPath(state: *const EditorState) []const u8 {
    const project_content_path = state.projectContentPath();
    return if (project_content_path.len != 0) project_content_path else "assets";
}

fn assetBrowserRootLabel(state: *const EditorState) []const u8 {
    return if (state.projectContentPath().len != 0) "Content" else state.text(.assets_menu);
}

fn assetBrowserSnapshotPathAlloc(allocator: std.mem.Allocator, state: *const EditorState) ![]u8 {
    const project_root_path = state.projectPath();
    if (project_root_path.len != 0) {
        return std.fs.path.join(allocator, &.{ project_root_path, "Derived", "asset_registry.json" });
    }
    return allocator.dupe(u8, "assets/derived/asset_registry.json");
}

fn assetDisplayPathAlloc(allocator: std.mem.Allocator, state: *const EditorState, source_path: []const u8) ![]u8 {
    const root_path = assetBrowserRootPath(state);
    if (std.mem.startsWith(u8, source_path, root_path)) {
        var relative = source_path[root_path.len..];
        while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
            relative = relative[1..];
        }
        return allocator.dupe(u8, relative);
    }

    if (std.mem.startsWith(u8, source_path, "assets/")) {
        return allocator.dupe(u8, source_path[7..]);
    }
    if (std.mem.eql(u8, source_path, "assets")) {
        return allocator.dupe(u8, "/");
    }

    return allocator.dupe(u8, source_path);
}

pub fn selectedAssetCanUseAsTexture(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .texture;
}

fn materialHandleForAssetEntryInResources(
    resources: *const engine.assets.ResourceLibrary,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    if (entry.kind != .material) {
        return null;
    }
    return resources.materialHandleByAssetId(entry.id);
}

pub fn materialHandleForAssetEntry(
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    return materialHandleForAssetEntryInResources(layer_context.world.assets(), entry);
}

fn syncEntityMaterialFromResource(
    entity: *engine.scene.Entity,
    material_handle: engine.assets.MaterialHandle,
    material_resource: *const engine.assets.MaterialResource,
) bool {
    if (entity.material) |*material_component| {
        var changed = false;
        if (material_component.handle != material_handle) {
            material_component.handle = material_handle;
            changed = true;
        }
        if (material_component.shading != material_resource.shading) {
            material_component.shading = material_resource.shading;
            changed = true;
        }
        if (!std.meta.eql(material_component.base_color_factor, material_resource.base_color_factor)) {
            material_component.base_color_factor = material_resource.base_color_factor;
            changed = true;
        }
        return changed;
    }

    entity.material = .{
        .handle = material_handle,
        .shading = material_resource.shading,
        .base_color_factor = material_resource.base_color_factor,
    };
    return true;
}

pub fn applyMaterialAssetToEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
    entity_id: engine.scene.EntityId,
) !bool {
    const material_handle = materialHandleForAssetEntry(layer_context, entry) orelse {
        if (!builtin.is_test and entry.kind == .material) {
            std.log.warn("material asset '{s}' is not loaded into the current world", .{entry.path});
        }
        return false;
    };
    if (state.editor_camera != null and entity_id == state.editor_camera.?) {
        return false;
    }
    if (utils.isEntityFrozen(state, entity_id) or utils.isEntitySelectionLocked(state, entity_id)) {
        return false;
    }

    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const material_resource = layer_context.world.assets().material(material_handle) orelse return false;
    if (!syncEntityMaterialFromResource(entity, material_handle, material_resource)) {
        return false;
    }

    try history.captureSnapshot(state, layer_context);
    return true;
}

pub fn refreshAssetBrowser(state: *EditorState, _: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    clearAssetBrowser(state);

    // Also refresh the asset registry in the background for cooked-model lookups.
    if (state.asset_registry) |*registry| {
        const root_path = assetBrowserRootPath(state);
        registry.refreshProject(root_path) catch |err| {
            std.log.warn("failed to refresh asset registry: {s}", .{@errorName(err)});
        };
        const snapshot_path = assetBrowserSnapshotPathAlloc(allocator, state) catch null;
        if (snapshot_path) |sp| {
            defer allocator.free(sp);
            registry.writeSnapshotToPath(sp) catch {};
        }
    }

    // Scan actual file system for Godot/Unity-style browsing.
    const root_path = assetBrowserRootPath(state);
    try scanFileSystemEntries(state, allocator, root_path);

    sortAssetEntries(state);
    try rebuildAssetDirectories(state);

    if (state.selected_asset_index) |selected_index| {
        if (selected_index >= state.asset_entries.items.len) {
            state.selected_asset_index = null;
        }
    }
}

/// Scan the actual file system and populate asset_entries with ALL files and directories.
fn scanFileSystemEntries(state: *EditorState, allocator: std.mem.Allocator, root_path: []const u8) !void {
    var root_dir = std.Io.Dir.cwd().openDir(io_globals.global_io, root_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer root_dir.close(io_globals.global_io);

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io_globals.global_io)) |entry| {
        // Skip hidden files, .meta files, and derived/ directory.
        if (std.mem.startsWith(u8, entry.path, ".")) continue;
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        if (std.mem.startsWith(u8, entry.path, "derived/") or std.mem.startsWith(u8, entry.path, "Derived/")) continue;
        if (std.mem.endsWith(u8, entry.path, ".meta")) continue;

        const is_dir = (entry.kind == .directory);
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);

        const display_path = try std.fmt.allocPrint(allocator, "/{s}", .{entry.path});
        errdefer allocator.free(display_path);

        const name = try allocator.dupe(u8, entry.basename);
        errdefer allocator.free(name);

        const kind: state_mod.AssetKind = if (is_dir)
            .directory
        else
            assetKindFromPath(entry.path);

        try state.asset_entries.append(allocator, .{
            .id = try allocator.dupe(u8, ""),
            .path = full_path,
            .display_path = display_path,
            .name = name,
            .kind = kind,
            .is_directory = is_dir,
        });
    }
}

/// Classify a file path into an AssetKind based on its extension.
fn assetKindFromPath(path: []const u8) state_mod.AssetKind {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return .unknown;
    if (std.mem.eql(u8, ext, ".gltf") or std.mem.eql(u8, ext, ".glb") or std.mem.eql(u8, ext, ".obj") or std.mem.eql(u8, ext, ".fbx")) return .model;
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg") or std.mem.eql(u8, ext, ".hdr") or std.mem.eql(u8, ext, ".svg") or std.mem.eql(u8, ext, ".exr")) return .texture;
    if (std.mem.eql(u8, ext, ".guava_scene") or std.mem.eql(u8, ext, ".json")) return .scene;
    if (std.mem.eql(u8, ext, ".glsl") or std.mem.eql(u8, ext, ".spv") or std.mem.eql(u8, ext, ".msl")) return .shader;
    if (std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".cs")) return .script;
    if (std.mem.eql(u8, ext, ".guava_material")) return .material;
    return .unknown;
}

fn rebuildAssetDirectories(state: *EditorState) !void {
    const allocator = state.allocator orelse return;
    try appendDirectoryIfMissing(state, "/");
    for (state.asset_entries.items) |entry| {
        try addDirectoryPath(state, directoryPath(entry.display_path));
        // Also add directories themselves (not just parent paths)
        if (entry.is_directory) {
            try addDirectoryPath(state, entry.display_path);
        }
    }

    std.sort.heap([]u8, state.asset_directories.items, {}, lessThanDirectory);
    if (state.asset_directories.items.len == 0) {
        const root_directory = try allocator.dupe(u8, "/");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
    }
    ensureSelectedAssetDirectory(state);
}

fn addDirectoryPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    var cursor: usize = 0;
    while (cursor < path.len) : (cursor += 1) {
        if (path[cursor] != '/') {
            continue;
        }
        if (cursor == 0) {
            continue;
        }
        try appendDirectoryIfMissing(state, path[0..cursor]);
    }
    try appendDirectoryIfMissing(state, path);
    if (state.asset_directories.items.len == 0) {
        const root_directory = try allocator.dupe(u8, "/");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
    }
}

fn appendDirectoryIfMissing(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.asset_directories.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            return;
        }
    }
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try state.asset_directories.append(allocator, owned_path);
}

fn lessThanDirectory(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Load an image file (PNG/JPG) and cache as a GPU thumbnail texture.
fn ensureImageThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    file_path: []const u8,
) !*const engine.render.Texture {
    // Check cache for existing thumbnail
    for (state.image_thumbnail_textures.items) |*entry| {
        if (std.mem.eql(u8, entry.path, file_path)) {
            return &entry.texture;
        }
    }
    // Check if this path previously failed (don't retry)
    for (state.image_thumbnail_failed.items) |failed_path| {
        if (std.mem.eql(u8, failed_path, file_path)) {
            return error.ThumbnailLoadFailed;
        }
    }

    const allocator = state.allocator orelse return error.NoAllocator;

    // Read file from disk (limit to 8MB to avoid loading huge textures)
    const encoded = std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024 * 1024) catch |err| {
        const owned_path = try allocator.dupe(u8, file_path);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer allocator.free(encoded);

    // Decode with stb_image
    var decoded = engine.assets.decodeImageRgba8(allocator, encoded) catch |err| {
        const owned_path = try allocator.dupe(u8, file_path);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer decoded.deinit();

    // Downscale to max 256px for thumbnail (simple 2x2 box filter)
    const max_thumb_dim: u32 = 256;
    var thumb_w = decoded.width;
    var thumb_h = decoded.height;
    var thumb_pixels = decoded.pixels;
    var downscaled_buf: ?[]u8 = null;
    defer if (downscaled_buf) |buf| allocator.free(buf);

    while (thumb_w > max_thumb_dim or thumb_h > max_thumb_dim) {
        const new_w = @max(thumb_w / 2, 1);
        const new_h = @max(thumb_h / 2, 1);
        if (new_w == 0 or new_h == 0) break;
        const new_buf = try allocator.alloc(u8, new_w * new_h * 4);
        var y: u32 = 0;
        while (y < new_h) : (y += 1) {
            var x: u32 = 0;
            while (x < new_w) : (x += 1) {
                const dst = (y * new_w + x) * 4;
                const sy = @min(y * 2, thumb_h - 1);
                const sx = @min(x * 2, thumb_w - 1);
                const sy1 = @min(sy + 1, thumb_h - 1);
                const sx1 = @min(sx + 1, thumb_w - 1);
                const s00 = (sy * thumb_w + sx) * 4;
                const s10 = (sy * thumb_w + sx1) * 4;
                const s01 = (sy1 * thumb_w + sx) * 4;
                const s11 = (sy1 * thumb_w + sx1) * 4;
                var c: u32 = 0;
                while (c < 4) : (c += 1) {
                    const avg = (@as(u32, thumb_pixels[s00 + c]) +
                        @as(u32, thumb_pixels[s10 + c]) +
                        @as(u32, thumb_pixels[s01 + c]) +
                        @as(u32, thumb_pixels[s11 + c]) + 2) / 4;
                    new_buf[dst + c] = @intCast(avg);
                }
            }
        }
        if (downscaled_buf) |old| allocator.free(old);
        downscaled_buf = new_buf;
        thumb_pixels = new_buf;
        thumb_w = new_w;
        thumb_h = new_h;
    }

    // Create GPU texture
    var texture = try layer_context.gfx().createTexture(.{
        .width = thumb_w,
        .height = thumb_h,
        .format = .rgba8_unorm,
        .usage = engine.gfx.TextureUsage.sampler,
    });
    errdefer layer_context.gfx().releaseTexture(&texture);

    try layer_context.gfx().uploadTextureData(&texture, thumb_pixels, thumb_w, thumb_h);

    // Cache it
    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);

    try state.image_thumbnail_textures.append(allocator, .{
        .path = owned_path,
        .texture = texture,
    });
    state.image_thumbnail_device = layer_context.gfx();

    return &state.image_thumbnail_textures.items[state.image_thumbnail_textures.items.len - 1].texture;
}

/// For a GLTF model file, extract the first material's baseColorTexture image URI,
/// resolve the full path, and load it as a thumbnail via ensureImageThumbnailTexture.
fn queueAndResolveModelThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) !?*const engine.render.Texture {
    if (entry.kind != .model or entry.is_directory) return null;
    try queueModelThumbnailRequest(state, entry.path);
    return layer_context.renderer.modelThumbnailTexture(entry.path);
}

fn queueModelThumbnailRequest(state: *EditorState, model_path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.model_thumbnail_queue.items) |existing| {
        if (std.mem.eql(u8, existing, model_path)) return;
    }
    const queued = try allocator.dupe(u8, model_path);
    errdefer allocator.free(queued);
    try state.model_thumbnail_queue.append(allocator, queued);
}

pub fn flushModelThumbnailRequests(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    for (state.model_thumbnail_queue.items) |model_path| {
        defer allocator.free(model_path);
        try layer_context.renderer.requestModelThumbnail(model_path, layer_context.frame_index);
    }
    state.model_thumbnail_queue.clearRetainingCapacity();
}

/// Like ensureImageThumbnailTexture but caches under a different key than the actual image path.
fn ensureImageThumbnailTextureAs(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    file_path: []const u8,
    cache_key: []const u8,
) !*const engine.render.Texture {
    // Check cache under cache_key
    for (state.image_thumbnail_textures.items) |*entry| {
        if (std.mem.eql(u8, entry.path, cache_key)) {
            return &entry.texture;
        }
    }

    const allocator = state.allocator orelse return error.NoAllocator;

    const encoded = std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024 * 1024) catch |err| {
        const owned_path = try allocator.dupe(u8, cache_key);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer allocator.free(encoded);

    var decoded = engine.assets.decodeImageRgba8(allocator, encoded) catch |err| {
        const owned_path = try allocator.dupe(u8, cache_key);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer decoded.deinit();

    const max_thumb_dim: u32 = 256;
    var thumb_w = decoded.width;
    var thumb_h = decoded.height;
    var thumb_pixels = decoded.pixels;
    var downscaled_buf: ?[]u8 = null;
    defer if (downscaled_buf) |buf| allocator.free(buf);

    while (thumb_w > max_thumb_dim or thumb_h > max_thumb_dim) {
        const new_w = @max(thumb_w / 2, 1);
        const new_h = @max(thumb_h / 2, 1);
        if (new_w == 0 or new_h == 0) break;
        const new_buf = try allocator.alloc(u8, new_w * new_h * 4);
        var y: u32 = 0;
        while (y < new_h) : (y += 1) {
            var x: u32 = 0;
            while (x < new_w) : (x += 1) {
                const dst = (y * new_w + x) * 4;
                const sy = @min(y * 2, thumb_h - 1);
                const sx = @min(x * 2, thumb_w - 1);
                const sy1 = @min(sy + 1, thumb_h - 1);
                const sx1 = @min(sx + 1, thumb_w - 1);
                const s00 = (sy * thumb_w + sx) * 4;
                const s10 = (sy * thumb_w + sx1) * 4;
                const s01 = (sy1 * thumb_w + sx) * 4;
                const s11 = (sy1 * thumb_w + sx1) * 4;
                var c: u32 = 0;
                while (c < 4) : (c += 1) {
                    const avg = (@as(u32, thumb_pixels[s00 + c]) +
                        @as(u32, thumb_pixels[s10 + c]) +
                        @as(u32, thumb_pixels[s01 + c]) +
                        @as(u32, thumb_pixels[s11 + c]) + 2) / 4;
                    new_buf[dst + c] = @intCast(avg);
                }
            }
        }
        if (downscaled_buf) |old| allocator.free(old);
        downscaled_buf = new_buf;
        thumb_pixels = new_buf;
        thumb_w = new_w;
        thumb_h = new_h;
    }

    var texture = try layer_context.gfx().createTexture(.{
        .width = thumb_w,
        .height = thumb_h,
        .format = .rgba8_unorm,
        .usage = engine.gfx.TextureUsage.sampler,
    });
    errdefer layer_context.gfx().releaseTexture(&texture);

    try layer_context.gfx().uploadTextureData(&texture, thumb_pixels, thumb_w, thumb_h);

    const owned_path = try allocator.dupe(u8, cache_key);
    errdefer allocator.free(owned_path);

    try state.image_thumbnail_textures.append(allocator, .{
        .path = owned_path,
        .texture = texture,
    });
    state.image_thumbnail_device = layer_context.gfx();

    return &state.image_thumbnail_textures.items[state.image_thumbnail_textures.items.len - 1].texture;
}

pub fn clearAssetBrowser(state: *EditorState) void {
    clearMaterialThumbnailRequestQueue(state);
    const allocator = state.allocator orelse return;
    for (state.asset_entries.items) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.path);
        allocator.free(entry.display_path);
        allocator.free(entry.name);
    }
    state.asset_entries.deinit(allocator);
    state.asset_entries = .empty;

    for (state.asset_directories.items) |directory| {
        allocator.free(directory);
    }
    state.asset_directories.deinit(allocator);
    state.asset_directories = .empty;

    state.selected_asset_index = null;
    state.asset_selected_set = std.StaticBitSet(4096).initEmpty();
    state.asset_last_selected_index = null;
}

pub fn selectedAsset(state: *EditorState) ?*const AssetEntry {
    const index = state.selected_asset_index orelse return null;
    if (index >= state.asset_entries.items.len) {
        state.selected_asset_index = null;
        return null;
    }
    return &state.asset_entries.items[index];
}

pub fn selectedAssetCanLoadScene(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .scene;
}

pub fn selectedAssetCanImportModel(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .model;
}

pub fn instantiateSelectedAsset(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entry = selectedAsset(state) orelse return;
    switch (entry.kind) {
        .scene => try history.loadScenePath(state, layer_context, entry.path),
        .model => try history.importModelPath(state, layer_context, entry.path),
        else => {},
    }
}

fn queueAndResolveMaterialThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) !?*const engine.render.Texture {
    if (entry.kind != .material) {
        return null;
    }
    try queueMaterialThumbnailRequest(state, entry.id);
    return layer_context.renderer.materialThumbnailTexture(entry.id);
}

fn queueMaterialThumbnailRequest(state: *EditorState, asset_id: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |existing| {
        if (std.mem.eql(u8, existing, asset_id)) {
            return;
        }
    }
    const queued_asset_id = try allocator.dupe(u8, asset_id);
    errdefer allocator.free(queued_asset_id);
    try state.material_thumbnail_queue.append(allocator, queued_asset_id);
}

pub fn flushMaterialThumbnailRequests(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        defer allocator.free(asset_id);
        try layer_context.renderer.requestMaterialThumbnail(layer_context.scene, asset_id, layer_context.frame_index);
    }
    state.material_thumbnail_queue.clearRetainingCapacity();
}

pub fn clearMaterialThumbnailRequestQueue(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        allocator.free(asset_id);
    }
    state.material_thumbnail_queue.deinit(allocator);
    state.material_thumbnail_queue = .empty;
}

// ---------------------------------------------------------------------------
// Context menus and file operations
// ---------------------------------------------------------------------------

fn commitAssetRename(state: *EditorState, layer_context: *engine.core.LayerContext, index: usize) !void {
    if (index >= state.asset_entries.items.len) return;
    const entry = &state.asset_entries.items[index];
    const new_name = std.mem.sliceTo(state.asset_rename_buffer[0..], 0);
    if (new_name.len == 0) return;

    // Build old and new filesystem paths
    const old_path = entry.path;
    const dir = if (std.mem.lastIndexOfScalar(u8, old_path, '/')) |idx| old_path[0..idx] else "";
    const old_ext = if (std.mem.lastIndexOfScalar(u8, entry.name, '.')) |_|
        (if (std.mem.lastIndexOfScalar(u8, old_path, '.')) |idx| old_path[idx..] else "")
    else
        (if (std.mem.lastIndexOfScalar(u8, old_path, '.')) |idx| old_path[idx..] else "");

    var new_path_buffer: [512]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_path_buffer, "{s}/{s}{s}", .{ dir, new_name, old_ext }) catch return;

    // Do the filesystem rename
    std.fs.cwd().rename(old_path, new_path) catch |err| {
        std.log.warn("asset rename failed: {}", .{err});
        return;
    };

    // Also rename the .meta file if it exists
    var old_meta_buf: [520]u8 = undefined;
    var new_meta_buf: [520]u8 = undefined;
    const old_meta = std.fmt.bufPrint(&old_meta_buf, "{s}.meta", .{old_path}) catch return;
    const new_meta = std.fmt.bufPrint(&new_meta_buf, "{s}.meta", .{new_path}) catch return;
    std.fs.cwd().rename(old_meta, new_meta) catch {};

    // Refresh browser to reflect changes
    try refreshAssetBrowser(state, layer_context);
}

fn commitFolderRename(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const new_name = std.mem.sliceTo(state.folder_rename_buffer[0..], 0);
    if (new_name.len == 0) {
        state.folder_rename_active = false;
        return;
    }
    const original = std.mem.sliceTo(state.folder_rename_original[0..], 0);
    if (original.len == 0) {
        state.folder_rename_active = false;
        return;
    }
    // Build the old filesystem path and new path
    const root_path = assetBrowserRootPath(state);
    var old_fs_buf: [512]u8 = undefined;
    const old_fs = std.fmt.bufPrint(&old_fs_buf, "{s}{s}", .{ root_path, original }) catch return;

    // Parent of original directory
    const parent = if (std.mem.lastIndexOfScalar(u8, original, '/')) |idx| original[0..idx] else "/";
    var new_fs_buf: [512]u8 = undefined;
    const new_fs = if (std.mem.eql(u8, parent, "/"))
        std.fmt.bufPrint(&new_fs_buf, "{s}/{s}", .{ root_path, new_name }) catch return
    else
        std.fmt.bufPrint(&new_fs_buf, "{s}{s}/{s}", .{ root_path, parent, new_name }) catch return;

    std.fs.cwd().rename(old_fs, new_fs) catch |err| {
        std.log.warn("folder rename failed: {}", .{err});
        state.folder_rename_active = false;
        return;
    };

    state.folder_rename_active = false;
    try refreshAssetBrowser(state, layer_context);
}

fn commitNewFolder(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const name = std.mem.sliceTo(state.new_folder_name_buffer[0..], 0);
    if (name.len == 0) {
        state.new_folder_pending = false;
        return;
    }
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var path_buffer: [512]u8 = undefined;
    const full_path = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root_path, name }) catch return
    else
        std.fmt.bufPrint(&path_buffer, "{s}{s}/{s}", .{ root_path, current_dir, name }) catch return;

    std.fs.cwd().makePath(full_path) catch |err| {
        std.log.warn("create folder failed: {}", .{err});
        state.new_folder_pending = false;
        return;
    };

    state.new_folder_pending = false;
    try refreshAssetBrowser(state, layer_context);
}

fn deleteAssetFile(state: *EditorState, layer_context: *engine.core.LayerContext, entry: AssetEntry) !void {
    // Delete the asset file
    std.fs.cwd().deleteFile(entry.path) catch |err| {
        std.log.warn("asset delete failed: {}", .{err});
        return;
    };
    // Also try to delete the .meta file
    var meta_buf: [520]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}.meta", .{entry.path}) catch return;
    std.fs.cwd().deleteFile(meta_path) catch {};

    try refreshAssetBrowser(state, layer_context);
}

fn deleteFolderOnDisk(state: *EditorState, directory: []const u8) void {
    const root_path = assetBrowserRootPath(state);
    var path_buffer: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ root_path, directory }) catch return;
    std.fs.cwd().deleteTree(full_path) catch |err| {
        std.log.warn("folder delete failed: {}", .{err});
    };
    // Note: caller should refreshAssetBrowser after
}

fn revealInFinder(path: []const u8) void {
    // Use macOS 'open' command to reveal in Finder
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[0..idx] else path;
    var child = std.process.Child.init(
        &.{ "/usr/bin/open", dir },
        std.heap.page_allocator,
    );
    _ = child.spawnAndWait() catch {};
}

fn createNewScriptInDirectory(state: *EditorState, directory: []const u8, ext: []const u8) void {
    const root_path = assetBrowserRootPath(state);
    var dir_buf: [512]u8 = undefined;
    const full_dir = if (std.mem.eql(u8, directory, "/"))
        std.fmt.bufPrint(&dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ root_path, directory }) catch return;

    const filename = if (std.mem.eql(u8, ext, ".cs")) "NewScript.cs" else "new_script.zig";
    const template = if (std.mem.eql(u8, ext, ".cs"))
        "using System;\n\nnamespace Game\n{\n    public class NewScript\n    {\n        public void Update(float deltaTime)\n        {\n        }\n    }\n}\n"
    else
        "const std = @import(\"std\");\nconst engine = @import(\"guava\");\n\npub fn update(delta_time: f32) void {\n    _ = delta_time;\n}\n";

    var path_buf: [768]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ full_dir, filename }) catch return;

    // Set pending fields – the layer will create the file and open it in the Script Editor
    state.pending_new_script_path = full_path;
    state.pending_new_script_template = template;
    state.script_editor_open = true;
}

/// Unified import: opens a macOS NSOpenPanel that allows selecting both files and folders.
fn importFromFinder(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const allocator = state.allocator orelse return;

    // Build destination directory path
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var dest_dir_buf: [512]u8 = undefined;
    const dest_dir = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&dest_dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dest_dir_buf, "{s}{s}", .{ root_path, current_dir }) catch return;

    // Use NSOpenPanel via osascript — allows choosing both files and folders
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "/usr/bin/osascript",
            "-e",
            \\set thePanel to current application's NSOpenPanel's openPanel()
            \\thePanel's setCanChooseFiles:true
            \\thePanel's setCanChooseDirectories:true
            \\thePanel's setAllowsMultipleSelection:true
            \\thePanel's setPrompt:"Import"
            \\thePanel's setMessage:"Select files or folders to import into the project"
            \\set theResult to thePanel's runModal() as integer
            \\if theResult is 1 then
            \\  set output to ""
            \\  set theURLs to thePanel's URLs() as list
            \\  repeat with u in theURLs
            \\    set output to output & (u's |path|() as text) & linefeed
            \\  end repeat
            \\  return output
            \\else
            \\  error number -128
            \\end if
            ,
        },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return; // User cancelled

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var imported: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Strip trailing slash
        const source = if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/')
            trimmed[0 .. trimmed.len - 1]
        else
            trimmed;

        // Extract basename
        const basename = if (std.mem.lastIndexOfScalar(u8, source, '/')) |idx| source[idx + 1 ..] else source;
        if (basename.len == 0) continue;

        var dest_path_buf: [768]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ dest_dir, basename }) catch continue;

        // Check if source is a directory
        const stat = std.fs.cwd().statFile(source) catch {
            // statFile fails on directories, treat as directory (use -R)
            var cp = std.process.Child.init(
                &.{ "/bin/cp", "-R", source, dest_path },
                allocator,
            );
            _ = cp.spawnAndWait() catch continue;
            imported += 1;
            continue;
        };
        _ = stat;

        // Regular file copy
        var cp = std.process.Child.init(
            &.{ "/bin/cp", source, dest_path },
            allocator,
        );
        _ = cp.spawnAndWait() catch continue;
        imported += 1;
    }

    if (imported > 0) {
        refreshAssetBrowser(state, layer_context) catch {};
    }
}

fn copySelectedAssetsToClipboard(state: *EditorState, is_cut: bool) void {
    const allocator = state.allocator orelse return;

    // Free previous clipboard entries
    for (state.asset_clipboard_paths.items) |path| {
        allocator.free(path);
    }
    state.asset_clipboard_paths.clearRetainingCapacity();

    // Collect paths of all selected assets
    const entries = state.asset_entries.items;
    for (0..entries.len) |i| {
        if (state.asset_selected_set.isSet(i)) {
            const duped = allocator.dupe(u8, entries[i].path) catch continue;
            state.asset_clipboard_paths.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    state.asset_clipboard_is_cut = is_cut;
}

fn pasteAssetsFromClipboard(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const allocator = state.allocator orelse return;
    if (state.asset_clipboard_paths.items.len == 0) return;

    // Build destination directory
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var dest_dir_buf: [512]u8 = undefined;
    const dest_dir = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&dest_dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dest_dir_buf, "{s}{s}", .{ root_path, current_dir }) catch return;

    for (state.asset_clipboard_paths.items) |src_path| {
        // Extract filename from source path
        const filename = if (std.mem.lastIndexOfScalar(u8, src_path, '/')) |idx| src_path[idx + 1 ..] else src_path;
        if (filename.len == 0) continue;

        var dest_path_buf: [768]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ dest_dir, filename }) catch continue;

        if (state.asset_clipboard_is_cut) {
            // Move: rename source to destination
            std.fs.cwd().rename(src_path, dest_path) catch |err| {
                std.log.warn("paste (move) failed: {}", .{err});
                continue;
            };
            // Also move .meta file if it exists
            var src_meta_buf: [520]u8 = undefined;
            var dest_meta_buf: [776]u8 = undefined;
            const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{src_path}) catch continue;
            const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{dest_path}) catch continue;
            std.fs.cwd().rename(src_meta, dest_meta) catch {};
        } else {
            // Copy: use /bin/cp
            var cp = std.process.Child.init(
                &.{ "/bin/cp", src_path, dest_path },
                allocator,
            );
            _ = cp.spawnAndWait() catch continue;
            // Also copy .meta file if it exists
            var src_meta_buf: [520]u8 = undefined;
            var dest_meta_buf: [776]u8 = undefined;
            const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{src_path}) catch continue;
            const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{dest_path}) catch continue;
            var cp_meta = std.process.Child.init(
                &.{ "/bin/cp", src_meta, dest_meta },
                allocator,
            );
            _ = cp_meta.spawnAndWait() catch {};
        }
    }

    // If cut, clear clipboard after paste
    if (state.asset_clipboard_is_cut) {
        for (state.asset_clipboard_paths.items) |path| {
            allocator.free(path);
        }
        state.asset_clipboard_paths.clearRetainingCapacity();
        state.asset_clipboard_is_cut = false;
    }

    refreshAssetBrowser(state, layer_context) catch {};
}

fn duplicateAssetFile(state: *EditorState, layer_context: *engine.core.LayerContext, entry: AssetEntry) void {
    const allocator = state.allocator orelse return;

    // Build a new name with "_copy" inserted before the extension
    const name = entry.name;
    const path = entry.path;

    // Find extension in name
    const ext_start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| idx else name.len;
    const base_name = name[0..ext_start];

    // Find the directory part of the full path
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[0 .. idx + 1] else "";
    const ext = if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| name[idx..] else "";

    var new_path_buf: [768]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_path_buf, "{s}{s}_copy{s}", .{ dir, base_name, ext }) catch return;

    // Copy using /bin/cp
    var cp = std.process.Child.init(
        &.{ "/bin/cp", path, new_path },
        allocator,
    );
    _ = cp.spawnAndWait() catch return;

    // Also copy .meta file if it exists
    var src_meta_buf: [520]u8 = undefined;
    var dest_meta_buf: [776]u8 = undefined;
    const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{path}) catch return;
    const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{new_path}) catch return;
    var cp_meta = std.process.Child.init(
        &.{ "/bin/cp", src_meta, dest_meta },
        allocator,
    );
    _ = cp_meta.spawnAndWait() catch {};

    refreshAssetBrowser(state, layer_context) catch {};
}

test "material thumbnail request queue deduplicates asset ids" {
    var state = EditorState{
        .allocator = std.testing.allocator,
    };
    defer clearMaterialThumbnailRequestQueue(&state);

    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://stone");

    try std.testing.expectEqual(@as(usize, 2), state.material_thumbnail_queue.items.len);
    try std.testing.expectEqualStrings("material://brick", state.material_thumbnail_queue.items[0]);
    try std.testing.expectEqualStrings("material://stone", state.material_thumbnail_queue.items[1]);
}

fn makeOwnedMaterialRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !engine.assets.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = .material,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "test-source-hash"),
        .import_settings_hash = try allocator.dupe(u8, "test-import-settings"),
        .import_version = engine.assets.AssetType.material.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(engine.assets.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, engine.assets.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ".guava_material"),
        },
    };
}

test "applyMaterialAssetToEntity assigns loaded material assets to entities" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const material_handle = try world.assets().createMaterial(.{
        .name = "Brick Material",
        .shading = .lambert,
        .base_color_factor = .{ 0.22, 0.41, 0.63, 1.0 },
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedMaterialRecord(std.testing.allocator, "material://brick", "assets/materials/brick.guava_material", "Brick"),
    );

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://brick"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/brick.guava_material"),
        .display_path = try std.testing.allocator.dupe(u8, "materials/brick.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Brick"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.display_path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id));
    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expect(entity.material != null);
    try std.testing.expectEqual(material_handle, entity.material.?.handle.?);
    try std.testing.expectEqual(engine.scene.ShadingModel.lambert, entity.material.?.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.22, 0.41, 0.63, 1.0 }, entity.material.?.base_color_factor);
}

test "applyMaterialAssetToEntity rejects unloaded material assets" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://missing"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/missing.guava_material"),
        .display_path = try std.testing.allocator.dupe(u8, "materials/missing.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Missing"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.display_path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(!(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id)));
    try std.testing.expect(world.getEntityConst(entity_id).?.material == null);
}
