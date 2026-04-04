//! Toggle button component (text-based, active/inactive).
//!
//! Used for inspector coordinate-space switches (Local / World) and similar
//! binary state buttons.

const gui = @import("../gui.zig");
const theme = @import("../theme.zig");

// ── Configuration ────────────────────────────────────────────────────────────

pub const Config = struct {
    label: []const u8,
    active: bool = false,
    width: f32 = 0.0,
    palette: Palette = .inspector,
};

pub const Palette = enum {
    inspector,
    freeze,
};

// ── Draw ─────────────────────────────────────────────────────────────────────

/// Draw a text toggle button.  Returns `true` when clicked.
pub fn draw(config: Config) bool {
    const palette = resolvePalette(config.active, config.palette);

    gui.pushStyleColor(.button, palette.bg);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    defer gui.popStyleColor(3);

    return gui.buttonEx(config.label, config.width, 0.0);
}

// ── Internal ─────────────────────────────────────────────────────────────────

fn resolvePalette(active: bool, kind: Palette) theme.ButtonPalette {
    if (active) {
        return switch (kind) {
            .inspector => .{
                .bg = .{ 0.18, 0.56, 0.33, 0.92 },
                .hovered = .{ 0.22, 0.65, 0.38, 0.98 },
                .active = .{ 0.15, 0.48, 0.28, 1.0 },
            },
            .freeze => theme.Palette.freeze.bg_active,
        };
    }
    return switch (kind) {
        .inspector => .{
            .bg = .{ 0.18, 0.20, 0.24, 0.90 },
            .hovered = .{ 0.24, 0.27, 0.32, 0.96 },
            .active = .{ 0.20, 0.23, 0.28, 1.0 },
        },
        .freeze => theme.Palette.freeze.bg_inactive,
    };
}
