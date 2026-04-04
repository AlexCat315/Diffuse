//! Reusable icon-button component.
//!
//! Wraps `gui.imageButton` with theme-aware styling so callers never need to
//! push/pop style colors or vars directly.

const std = @import("std");
const engine = @import("guava");
const gui = @import("../gui.zig");
const theme = @import("../theme.zig");
const icons = @import("../icons.zig");

const EditorState = @import("../../core/state.zig").EditorState;

// ── Configuration ────────────────────────────────────────────────────────────

pub const Config = struct {
    id: []const u8,
    icon_path: []const u8,
    size: f32 = theme.Size.hierarchy_icon,
    tint: theme.IconTint,
    palette: theme.ButtonPalette = theme.Palette.status.off,
    tooltip: ?[]const u8 = null,
};

// ── Draw ─────────────────────────────────────────────────────────────────────

/// Draw an icon button.  Returns `true` when clicked.
pub fn draw(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    config: Config,
) !bool {
    const texture = try icons.ensureTintedIconTexture(
        state,
        layer_context,
        config.icon_path,
        config.size,
        config.tint,
    );

    gui.pushStyleColor(.button, config.palette.bg);
    gui.pushStyleColor(.button_hovered, config.palette.hovered);
    gui.pushStyleColor(.button_active, config.palette.active);
    gui.pushStyleVarVec2(.frame_padding, theme.iconPadding(config.size));
    gui.pushStyleVarFloat(.frame_rounding, theme.iconRounding(config.size));
    defer {
        gui.popStyleVar(2);
        gui.popStyleColor(3);
    }

    const clicked = gui.imageButton(
        config.id,
        texture,
        config.size,
        config.size,
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 1.0, 1.0 },
    );

    if (config.tooltip) |tip| {
        if (gui.isItemHovered()) {
            gui.setTooltip(tip);
        }
    }

    return clicked;
}
