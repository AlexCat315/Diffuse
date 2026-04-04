const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

/// Draw the Render Style Inspector panel.
/// Shows the active style name, its properties, and editable config_schema parameters.
pub fn drawStyleInspectorWindow(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var open = state.style_inspector_open;
    const open_window = gui.beginWindowOpen("Render Style Inspector###style_inspector_panel", &open);
    floating_window_blocker.registerCurrentWindow("style_inspector_panel");
    if (!open_window) {
        gui.endWindow();
        state.style_inspector_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.style_inspector_open = open;
    }

    const style_reg = layer_context.renderer.styleRegistry();
    const active = style_reg.getActiveStyle();

    // ── Active Style Info ────────────────────────────────
    const display = if (active.display_name.len > 0) active.display_name else active.name;
    gui.labelText("Active Style", display);
    gui.labelText("Mesh Program", active.mesh_program);
    if (active.shadow_program) |sp| {
        gui.labelText("Shadow Program", sp);
    } else {
        gui.labelText("Shadow Program", "(none)");
    }

    if (active.source != .builtin) {
        if (active.path) |p| {
            gui.labelText("Path", p);
        }
    }

    // ── Disabled Passes ──────────────────────────────────
    if (active.disabled_passes.len > 0) {
        gui.separator();
        gui.text("Disabled Passes:");
        for (active.disabled_passes) |pass_name| {
            var buf: [128]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "  • {s}", .{pass_name}) catch pass_name;
            gui.text(line);
        }
    }

    // ── Config Parameters ────────────────────────────────
    if (active.config_schema.len > 0) {
        gui.separator();
        gui.text("Parameters:");
        gui.dummy(0.0, 4.0);

        const param_values = style_reg.getParamValues(active.name) catch return;

        for (active.config_schema) |param| {
            const label = if (param.display_name.len > 0) param.display_name else param.name;
            switch (param.param_type) {
                .float => {
                    var value = param_values.get(param.name, param.default_value);
                    if (gui.sliderFloat(label, &value, param.min_value, param.max_value)) {
                        param_values.set(param.name, value) catch {};
                    }
                },
                .int => {
                    gui.labelText(label, "int (editor TODO)");
                },
                .boolean => {
                    const raw = param_values.get(param.name, param.default_value);
                    var checked: bool = raw >= 0.5;
                    if (gui.checkbox(label, &checked)) {
                        param_values.set(param.name, if (checked) 1.0 else 0.0) catch {};
                    }
                },
                .color3 => {
                    gui.labelText(label, "color3 (editor TODO)");
                },
            }
        }
    }
}
