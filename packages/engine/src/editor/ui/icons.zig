const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const theme = @import("theme.zig");

const EditorState = @import("../core/state.zig").EditorState;
const icon_cache = @import("icon_cache.zig");

pub const paths = struct {
    pub const toolbar = struct {
        pub const select = "assets/ui/icons/svg/cursor-arrow-rays.svg";
        pub const move = "assets/ui/icons/svg/arrows-up-down.svg";
        pub const rotate = "assets/ui/icons/svg/arrow-path.svg";
        pub const scale = "assets/ui/icons/svg/arrows-pointing-out.svg";
        pub const camera = "assets/ui/icons/svg/camera.svg";
        pub const material = "assets/ui/icons/svg/cube.svg";
        pub const overlay = "assets/ui/icons/svg/eye.svg";
        pub const snap = "assets/ui/icons/svg/grid-pattern.svg";
        pub const snap_translate = "assets/ui/icons/svg/direction-arrows.svg";
        pub const snap_rotate = "assets/ui/icons/svg/clock.svg";
        pub const snap_scale = "assets/ui/icons/svg/arrow-big-up.svg";
        pub const folder = "assets/ui/icons/svg/squares-2x2.svg";
        pub const play = "assets/ui/icons/svg/play.svg";
        pub const pause = "assets/ui/icons/svg/pause.svg";
        pub const stop = "assets/ui/icons/svg/squares-2x2.svg";
        pub const step = "assets/ui/icons/svg/forward.svg";
        pub const settings = "assets/ui/icons/svg/cog-6-tooth.svg";
        pub const transform_global = "assets/ui/icons/svg/globe.svg";
        pub const transform_local = "assets/ui/icons/svg/cube.svg";
        pub const cursor_3d = "assets/ui/icons/svg/crosshair.svg";
        pub const ai_chat = "assets/ui/icons/svg/sparkle.svg";
        pub const chevron_down = "assets/ui/icons/svg/chevron-down.svg";
        pub const plus = "assets/ui/icons/svg/plus.svg";
        pub const x_mark = "assets/ui/icons/svg/delete.svg";
        pub const build = "assets/ui/icons/svg/package.svg";
        pub const launch = "assets/ui/icons/svg/arrows-pointing-out.svg";
    };

    pub const viewport = struct {
        pub const perspective = "assets/ui/icons/svg/cube.svg";
        pub const top = "assets/ui/icons/svg/arrows-up-down.svg";
        pub const side = "assets/ui/icons/svg/cursor-arrow-rays.svg";
        pub const solid = "assets/ui/icons/svg/cube.svg";
        pub const material = "assets/ui/icons/svg/squares-2x2.svg";
        pub const rendered = "assets/ui/icons/svg/sparkle.svg";
        pub const textured = "assets/ui/icons/svg/squares-2x2.svg";
        pub const wireframe = "assets/ui/icons/svg/squares-2x2.svg";
        pub const unlit = "assets/ui/icons/svg/eye.svg";
        pub const grid = "assets/ui/icons/svg/squares-2x2.svg";
    };

    pub const viewport_entities = struct {
        pub const camera = "assets/ui/icons/svg/camera.svg";
        pub const directional_light = "assets/ui/icons/svg/light_sun.svg";
        pub const point_light = "assets/ui/icons/svg/light_point.svg";
        pub const spot_light = "assets/ui/icons/svg/light_spot.svg";
    };

    pub const place_actors = struct {
        pub const empty = "assets/ui/icons/svg/squares-2x2.svg";
        pub const camera = "assets/ui/icons/svg/camera.svg";
        pub const cube = "assets/ui/icons/svg/cube.svg";
        pub const sphere = "assets/ui/icons/svg/cube.svg";
        pub const plane = "assets/ui/icons/svg/squares-2x2.svg";
        pub const point_light = "assets/ui/icons/svg/light-bulb.svg";
        pub const spot_light = "assets/ui/icons/svg/light-bulb.svg";
        pub const directional_light = "assets/ui/icons/svg/light-bulb.svg";
        pub const vfx_fountain = "assets/ui/icons/svg/play.svg";
        pub const vfx_orbit = "assets/ui/icons/svg/arrow-path.svg";
    };

    pub const hierarchy = struct {
        pub const camera = "assets/ui/icons/svg/camera.svg";
        pub const light = "assets/ui/icons/svg/light-bulb.svg";
        pub const vfx = "assets/ui/icons/svg/play.svg";
        pub const mesh = "assets/ui/icons/svg/cube.svg";
        pub const object = "assets/ui/icons/svg/squares-2x2.svg";
        pub const folder = "assets/ui/icons/svg/squares-2x2.svg";
        pub const folder_filled = "assets/ui/icons/svg/folder-f.svg";
        pub const folder_open = "assets/ui/icons/svg/folder.svg";
        pub const document = "assets/ui/icons/svg/data.svg";
        pub const eye = "assets/ui/icons/svg/eye.svg";
        pub const eye_off = "assets/ui/icons/svg/eye-slash.svg";
        pub const lock = "assets/ui/icons/svg/lock-closed.svg";
        pub const unlock = "assets/ui/icons/svg/lock-open.svg";
        pub const chevron_down = "assets/ui/icons/svg/chevron-down.svg";
        pub const chevron_right = "assets/ui/icons/svg/chevron-right.svg";
    };

    pub const asset = struct {
        pub const scene = "assets/ui/icons/svg/film.svg";
        pub const model = "assets/ui/icons/svg/models.svg";
        pub const material = "assets/ui/icons/svg/paint-brush.svg";
        pub const texture = "assets/ui/icons/svg/photo.svg";
        pub const shader = "assets/ui/icons/svg/code-bracket.svg";
        pub const script = "assets/ui/icons/svg/csharp.svg";
        pub const directory = "assets/ui/icons/svg/folder-f.svg";
        pub const unknown = "assets/ui/icons/svg/document-text.svg";
    };
};

pub const ButtonPalette = struct {
    button: [4]f32,
    hovered: [4]f32,
    active: [4]f32,
};

pub const compact_icon_button_padding = theme.Size.compact_icon_padding;
pub const regular_icon_button_padding = theme.Size.regular_icon_padding;
pub const compact_icon_button_rounding: f32 = theme.BorderRadius.compact_icon_rounding;
pub const regular_icon_button_rounding: f32 = theme.BorderRadius.regular_icon_rounding;

pub const palettes = struct {
    pub const toolbar_idle = ButtonPalette{
        .button = theme.Palette.toolbar.idle.bg,
        .hovered = theme.Palette.toolbar.idle.hovered,
        .active = theme.Palette.toolbar.idle.active,
    };
    pub const toolbar_active = ButtonPalette{
        .button = theme.Palette.toolbar.active.bg,
        .hovered = theme.Palette.toolbar.active.hovered,
        .active = theme.Palette.toolbar.active.active,
    };
    pub const toolbar_accent = ButtonPalette{
        .button = theme.Palette.toolbar.accent.bg,
        .hovered = theme.Palette.toolbar.accent.hovered,
        .active = theme.Palette.toolbar.accent.active,
    };
    pub const status_on = ButtonPalette{
        .button = theme.Palette.status.on.bg,
        .hovered = theme.Palette.status.on.hovered,
        .active = theme.Palette.status.on.active,
    };
    pub const status_off = ButtonPalette{
        .button = theme.Palette.status.off.bg,
        .hovered = theme.Palette.status.off.hovered,
        .active = theme.Palette.status.off.active,
    };
};

pub fn entityIconPath(entity: *const engine.scene.Entity) []const u8 {
    if (entity.is_folder) {
        return paths.hierarchy.folder;
    }
    if (entity.camera != null) {
        return paths.hierarchy.camera;
    }
    if (entity.light != null) {
        return paths.hierarchy.light;
    }
    if (entity.vfx != null) {
        return paths.hierarchy.vfx;
    }
    if (entity.mesh != null) {
        return paths.hierarchy.mesh;
    }
    return paths.hierarchy.object;
}

pub fn ensureTintedIconTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    path: []const u8,
    size: f32,
    tint: [4]u8,
) !*engine.rhi.Texture {
    const window = layer_context.window;
    const drawable_scale = blk: {
        if (window.logical_width == 0 or window.logical_height == 0 or window.drawable_width == 0 or window.drawable_height == 0) {
            break :blk 1.0;
        }
        const scale_x = @as(f32, @floatFromInt(window.drawable_width)) / @as(f32, @floatFromInt(window.logical_width));
        const scale_y = @as(f32, @floatFromInt(window.drawable_height)) / @as(f32, @floatFromInt(window.logical_height));
        break :blk std.math.clamp(@max(scale_x, scale_y), 1.0, 4.0);
    };
    const oversample: f32 = if (size <= 20.0) 1.8 else 1.5;
    const pixel_size = @max(@as(u32, @intFromFloat(std.math.ceil(@max(size, @as(f32, 1.0)) * drawable_scale * oversample))), 1);
    return icon_cache.ensureIconTexture(state, layer_context, path, pixel_size, pixel_size, tint);
}

pub fn drawIconButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    size: f32,
    tint: [4]u8,
    palette: ButtonPalette,
) !bool {
    const texture = try ensureTintedIconTexture(state, layer_context, path, size, tint);
    const padding = if (size >= 28.0) regular_icon_button_padding else compact_icon_button_padding;
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarVec2(.frame_padding, padding);
    gui.pushStyleVarFloat(.frame_rounding, if (size >= 28.0) regular_icon_button_rounding else compact_icon_button_rounding);
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }
    return gui.imageButton(id, texture, size, size, .{ 0.0, 0.0, 0.0, 0.0 }, .{ 1.0, 1.0, 1.0, 1.0 });
}

// Test whether the icon file exists and can be loaded as a texture
test "Test whether the icon file exists and can be loaded as a texture" {
    const state = EditorState{
        .icon_cache = icon_cache.init(),
    };
    const layer_context = engine.core.LayerContext{
        .window = null, // This test doesn't require a window
    };
    const path = paths.toolbar.select;
    const result = ensureTintedIconTexture(&state, &layer_context, path, 24.0, .{ 255, 255, 255, 255 });
    std.testing.expect(result != null);
}
