const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");

const AssetEntry = state_mod.AssetEntry;

fn selectedAsset(state: *EditorState) ?*const AssetEntry {
    const index = state.selected_asset_index orelse return null;
    if (index >= state.asset_entries.items.len) {
        state.selected_asset_index = null;
        return null;
    }
    return &state.asset_entries.items[index];
}

pub fn ensurePreviewTextureForAssetPath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) !void {
    if (state.preview_texture_key) |existing_key| {
        if (state.preview_texture != null and std.mem.eql(u8, existing_key, path)) {
            return;
        }
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    if (std.mem.endsWith(u8, path, ".svg")) {
        var rasterized = try engine.assets.rasterizeSvgBgra8(allocator, path, .{
            .tint = .{ 220, 224, 231, 255 },
        });
        defer rasterized.deinit();
        try ensurePreviewTextureForResource(state, layer_context, path, rasterized.width, rasterized.height, rasterized.pixels);
        return;
    }

    const encoded = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var decoded = try engine.assets.decodeImageRgba8(allocator, encoded);
    defer decoded.deinit();
    utils.swizzleRgbaToBgra(decoded.pixels);

    try ensurePreviewTextureForResource(state, layer_context, path, decoded.width, decoded.height, decoded.pixels);
}

pub fn ensurePreviewTextureForResource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    cache_key: []const u8,
    width: u32,
    height: u32,
    pixels: []const u8,
) !void {
    if (state.preview_texture_key) |existing_key| {
        if (state.preview_texture != null and state.preview_texture_size[0] == width and state.preview_texture_size[1] == height and std.mem.eql(u8, existing_key, cache_key)) {
            return;
        }
    }

    clearPreviewTexture(state);

    var texture = try layer_context.rhi().createTexture(.{
        .width = width,
        .height = height,
        .format = .bgra8_unorm,
        .usage = engine.rhi.TextureUsage.sampler,
    });
    errdefer layer_context.rhi().releaseTexture(&texture);

    try layer_context.rhi().uploadTextureData(&texture, pixels, width, height);

    const allocator = state.allocator orelse layer_context.world.allocator;
    state.preview_texture = texture;
    state.preview_texture_key = try allocator.dupe(u8, cache_key);
    state.preview_texture_size = .{ width, height };
    state.preview_device = layer_context.rhi();
}

pub fn clearPreviewTexture(state: *EditorState) void {
    if (state.preview_texture) |*texture| {
        if (state.preview_device) |device| {
            device.releaseTexture(texture);
        }
        state.preview_texture = null;
    }
    if (state.preview_texture_key) |key| {
        if (state.allocator) |allocator| {
            allocator.free(key);
        }
        state.preview_texture_key = null;
    }
    state.preview_texture_size = .{ 0, 0 };
}
