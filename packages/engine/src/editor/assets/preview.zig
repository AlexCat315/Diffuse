const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const layout = @import("../ui/layout.zig");

const AssetEntry = state_mod.AssetEntry;

pub fn drawAssetPreviewWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [96]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .asset_preview, "asset_preview_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    layout.beginSectionBody();
    defer layout.endSectionBody();

    if (selectedAsset(state)) |entry| {
        gui.labelText(state.text(.name), entry.name);
        gui.labelText(state.text(.type), utils.assetKindLabel(state, entry.kind));
        gui.labelText(state.text(.path), entry.display_path);

        switch (entry.kind) {
            .texture => {
                try ensurePreviewTextureForAssetPath(state, layer_context, entry.path);
                drawCurrentPreviewImage(state);
                gui.textWrapped(state.text(.use_this_texture_from_details_gt_material));
            },
            .model => {
                gui.textWrapped(state.text(.models_are_imported_as_grouped_instances_with_a_movable_root_entity));
                if (gui.buttonEx(state.text(.instantiate_model), gui.contentRegionAvail()[0], 0.0)) {
                    try history.importModelPath(state, layer_context, entry.path);
                }
            },
            .material => {
                gui.textWrapped(state.text(.drop_material_here));
            },
            .scene => {
                gui.textWrapped(state.text(.scenes_can_be_loaded_directly_or_overwritten_from_the_current_world));
                if (gui.buttonEx(state.text(.load_scene), gui.contentRegionAvail()[0], 0.0)) {
                    try history.loadScenePath(state, layer_context, entry.path);
                }
                if (gui.buttonEx(state.text(.save_over), gui.contentRegionAvail()[0], 0.0)) {
                    history.saveScenePath(state, layer_context, entry.path);
                }
            },
            .shader => {
                gui.textWrapped(state.text(.shader_source_preview_is_currently_metadata_only));
            },
            .script, .directory, .unknown => {},
        }
        return;
    }

    if (layer_context.renderer.selectedEntity()) |selected| {
        if (layer_context.world.getEntityConst(selected)) |entity| {
            if (entity.material) |material_component| {
                if (material_component.handle) |material_handle| {
                    if (layer_context.world.assets().material(material_handle)) |material_resource| {
                        if (material_resource.base_color_texture) |texture_handle| {
                            if (layer_context.world.assets().texture(texture_handle)) |texture_resource| {
                                try ensurePreviewTextureForResource(
                                    state,
                                    layer_context,
                                    texture_resource.name,
                                    texture_resource.width,
                                    texture_resource.height,
                                    texture_resource.pixels,
                                );
                                gui.labelText(state.text(.previewing), texture_resource.name);
                                drawCurrentPreviewImage(state);
                                return;
                            }
                        }
                    }
                }
            }
        }
    }

    gui.textWrapped(state.text(.select_a_texture_asset_or_an_entity_with_a_textured_material_to_preview_it));
}

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

pub fn drawCurrentPreviewImage(state: *EditorState) void {
    const texture = if (state.preview_texture) |*value| value else return;
    const available = gui.contentRegionAvail();
    if (available[0] <= 1.0 or available[1] <= 1.0 or state.preview_texture_size[0] == 0 or state.preview_texture_size[1] == 0) {
        return;
    }

    const width_f = @as(f32, @floatFromInt(state.preview_texture_size[0]));
    const height_f = @as(f32, @floatFromInt(state.preview_texture_size[1]));
    const scale = @min(available[0] / width_f, available[1] / height_f);
    const display_width = @max(width_f * scale, 1.0);
    const display_height = @max(height_f * scale, 1.0);
    gui.image(texture, display_width, display_height);
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
