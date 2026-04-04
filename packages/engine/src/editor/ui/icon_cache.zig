const std = @import("std");
const engine = @import("guava");

const state_mod = @import("../core/state.zig");

const EditorState = state_mod.EditorState;
const IconTextureEntry = state_mod.IconTextureEntry;

pub fn ensureIconTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    path: []const u8,
    width: u32,
    height: u32,
    tint: ?[4]u8,
) !*engine.rhi.Texture {
    const tint_value = tint orelse [4]u8{ 0, 0, 0, 0 };
    const has_tint = tint != null;

    for (state.icon_textures.items) |*entry| {
        if (entry.width != width or entry.height != height or entry.has_tint != has_tint) {
            continue;
        }
        if (!std.mem.eql(u8, entry.path, path)) {
            continue;
        }
        if (entry.has_tint and !std.mem.eql(u8, entry.tint[0..], tint_value[0..])) {
            continue;
        }
        return &entry.texture;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    var rasterized = try engine.assets.rasterizeSvgBgra8(allocator, path, .{
        .width = width,
        .height = height,
        .tint = tint,
    });
    defer rasterized.deinit();

    var texture = try layer_context.rhi().createTexture(.{
        .width = rasterized.width,
        .height = rasterized.height,
        .format = .bgra8_unorm,
        .usage = engine.rhi.TextureUsage.sampler,
    });
    errdefer layer_context.rhi().releaseTexture(&texture);

    try layer_context.rhi().uploadTextureData(&texture, rasterized.pixels, rasterized.width, rasterized.height);

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    try state.icon_textures.append(allocator, .{
        .path = owned_path,
        .width = rasterized.width,
        .height = rasterized.height,
        .tint = tint_value,
        .has_tint = has_tint,
        .texture = texture,
    });

    state.icon_device = layer_context.rhi();
    return &state.icon_textures.items[state.icon_textures.items.len - 1].texture;
}

pub fn clearIconCache(state: *EditorState) void {
    const allocator = state.allocator orelse return;

    if (state.icon_device) |device| {
        for (state.icon_textures.items) |*entry| {
            device.releaseTexture(&entry.texture);
            allocator.free(entry.path);
        }
    } else {
        for (state.icon_textures.items) |entry| {
            allocator.free(entry.path);
        }
    }

    state.icon_textures.deinit(allocator);
    state.icon_textures = .empty;
    state.icon_device = null;
}
