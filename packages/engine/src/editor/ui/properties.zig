const std = @import("std");
const gui = @import("gui.zig");
const layout = @import("layout.zig");

/// Auto-incrementing counter for generating unique widget IDs within a property grid session.
var g_property_counter: u16 = 0;
var g_id_buffer: [16]u8 = undefined;

/// Begin a property grid (2-column table: label + value).
/// Resets the auto-ID counter. Must pair with `endPropertyGrid`.
pub fn beginPropertyGrid(table_id: []const u8) bool {
    g_property_counter = 0;
    if (!layout.beginInspectorPropertyTable(table_id, 0.38)) {
        return false;
    }
    gui.pushStyleVarVec2(.item_spacing, .{ 10.0, 8.0 });
    return true;
}

pub fn endPropertyGrid() void {
    gui.popStyleVar(1);
    layout.endInspectorPropertyTable();
}

/// Generate the next auto-ID string "##p_0", "##p_1", etc.
fn nextId() []const u8 {
    const len = std.fmt.bufPrint(&g_id_buffer, "##p_{d}", .{g_property_counter}) catch return "##p_x";
    g_property_counter +%= 1;
    return len;
}

// --- Property row helpers ---
// Each function draws one label+widget row. Returns whether the value changed.

pub fn float(label: []const u8, value: *f32, speed: f32, min_value: f32, max_value: f32) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.dragFloat(nextId(), value, speed, min_value, max_value);
}

pub fn float3(label: []const u8, value: *[3]f32, speed: f32, min_value: f32, max_value: f32) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.dragFloat3(nextId(), value, speed, min_value, max_value);
}

pub fn float4(label: []const u8, value: *[4]f32, speed: f32, min_value: f32, max_value: f32) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.dragFloat4(nextId(), value, speed, min_value, max_value);
}

pub fn int(label: []const u8, value: *i32, speed: f32, min_value: i32, max_value: i32) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.dragInt(nextId(), value, speed, min_value, max_value);
}

pub fn boolean(label: []const u8, value: *bool) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.checkbox(nextId(), value);
}

pub fn text(label: []const u8, value: []const u8) void {
    layout.drawInspectorPropertyRow(label, null);
    gui.textWrapped(value);
}

pub fn inputText(label: []const u8, hint: []const u8, buffer: []u8) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.inputTextWithHint(nextId(), hint, buffer);
}

pub fn color3(label: []const u8, value: *[3]f32, flags: gui.ColorEditFlags) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.colorEdit3(nextId(), value, flags);
}

pub fn color4(label: []const u8, value: *[4]f32, flags: gui.ColorEditFlags) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.colorEdit4(nextId(), value, flags);
}

pub fn combo(label: []const u8, preview: []const u8) bool {
    layout.drawInspectorPropertyRow(label, null);
    return gui.beginCombo(nextId(), preview);
}
