//! Property row components for inspector-style layouts.
//!
//! Provides labeled rows for common widget types (text, input, checkbox,
//! drag-float, combo) with automatic table/stacked layout switching.

const std = @import("std");
const gui = @import("../gui.zig");
const theme = @import("../theme.zig");
const layout = @import("../layout.zig");

// ── Edit Result ──────────────────────────────────────────────────────────────

pub const EditResult = struct {
    changed: bool = false,
    committed: bool = false,
};

// ── Property Grid Mode ───────────────────────────────────────────────────────

pub const GridMode = enum { table, stacked };

const max_depth = 8;
var grid_modes: [max_depth]GridMode = undefined;
var grid_depth: usize = 0;

pub fn currentGridMode() GridMode {
    if (grid_depth == 0) return .table;
    return grid_modes[grid_depth - 1];
}

// ── Property Grid ────────────────────────────────────────────────────────────

/// Begin a property grid.  Returns `true` if the grid is valid.
pub fn beginGrid(id: []const u8, label_width_ratio: f32) bool {
    const available_width = gui.contentRegionAvail()[0];
    var mode: GridMode = .stacked;
    if (available_width >= theme.Size.stacked_grid_min_width and
        grid_depth < max_depth and
        layout.beginInspectorPropertyTable(id, label_width_ratio))
    {
        mode = .table;
    }
    if (grid_depth < max_depth) {
        grid_modes[grid_depth] = mode;
        grid_depth += 1;
    }

    const item_spacing: [2]f32 = if (mode == .table) theme.Spacing.inspector_item_spacing_table else theme.Spacing.inspector_item_spacing_stacked;
    gui.pushStyleVarVec2(.item_spacing, item_spacing);
    return true;
}

/// End the current property grid.
pub fn endGrid() void {
    if (grid_depth == 0) return;
    grid_depth -= 1;
    const mode = grid_modes[grid_depth];
    gui.popStyleVar(1);
    if (mode == .table) {
        layout.endInspectorPropertyTable();
    }
}

// ── Property Label ───────────────────────────────────────────────────────────

/// Draw a property label.  Handles table vs stacked layout internally.
pub fn drawLabel(label: []const u8, label_color: ?theme.Color) void {
    if (currentGridMode() == .table) {
        layout.drawInspectorPropertyRow(label, label_color);
        return;
    }

    if (label_color) |color| {
        gui.pushStyleColor(.text, color);
        defer gui.popStyleColor(1);
        gui.alignTextToFramePadding();
        gui.text(label);
    } else {
        gui.pushStyleColor(.text, theme.Palette.text_dimmed);
        defer gui.popStyleColor(1);
        gui.alignTextToFramePadding();
        gui.text(label);
    }
    gui.dummy(0.0, theme.Spacing.property_row_dummy_after_label);
    gui.setNextItemWidth(-1.0);
}

// ── Row Types ────────────────────────────────────────────────────────────────

/// Draw a read-only text row.
pub fn textRow(label: []const u8, value: []const u8) void {
    drawLabel(label, null);
    gui.textWrapped(value);
}

/// Draw an input-text row with hint.
pub fn inputTextRow(label: []const u8, widget_id: []const u8, hint: []const u8, buffer: []u8) bool {
    drawLabel(label, null);
    return gui.inputTextWithHint(widget_id, hint, buffer);
}

/// Draw a checkbox row.
pub fn checkboxRow(label: []const u8, widget_id: []const u8, value: *bool) bool {
    drawLabel(label, null);
    return gui.checkbox(widget_id, value);
}

/// Draw a drag-float row.
pub fn dragFloatRow(
    label: []const u8,
    widget_id: []const u8,
    value: *f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) bool {
    drawLabel(label, null);
    return gui.dragFloat(widget_id, value, speed, min_value, max_value);
}

/// Draw a drag-float3 row.
pub fn dragFloat3Row(
    label: []const u8,
    widget_id: []const u8,
    value: *[3]f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) bool {
    drawLabel(label, null);
    return gui.dragFloat3(widget_id, value, speed, min_value, max_value);
}

/// Begin a combo row.  Caller must call `gui.endCombo()` when true is returned.
pub fn beginComboRow(label: []const u8, widget_id: []const u8, preview: []const u8) bool {
    drawLabel(label, null);
    return gui.beginCombo(widget_id, preview);
}
