const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const SettingsCategory = @import("../../../core/state.zig").SettingsCategory;
const SettingsTab = @import("../../../core/state.zig").SettingsTab;
const FpsDisplayMode = @import("../../../core/state.zig").FpsDisplayMode;
const MeshShortcutBinding = @import("../../../core/state.zig").MeshShortcutBinding;
const MeshEditShortcutConfig = @import("../../../core/state.zig").MeshEditShortcutConfig;
const preferences = @import("../../../core/preferences.zig");
const i18n = @import("../../../i18n/mod.zig");
const icon_cache = @import("../../icon_cache.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const theme = @import("../../theme.zig");

const debug_icon_path = ui_icons.paths.hierarchy.mesh;
const debug_icon_tint = [4]u8{ 196, 224, 255, 255 };

const settings_filter_buffer_size = @import("../../../core/state.zig").settings_filter_buffer_size;

// ── Sidebar: Collapsible section header ──────────────────────────────

fn drawSectionHeader(label: []const u8, is_open: *bool) void {
    const row_height: f32 = 24.0;
    const draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    const row_top = cursor[1];
    const avail = gui.contentRegionAvail();
    const row_width = @max(avail[0], 100.0);

    gui.dummy(row_width, row_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();
    const hovered = gui.isItemHovered();

    if (hovered) {
        draw_list.addRectFilled(
            .{ item_min[0], item_min[1] },
            .{ item_max[0], item_max[1] },
            gui.getColorU32(theme.Palette.settings.section_hover_bg),
            0.0,
            0,
        );
    }

    // Arrow ▼ or ▶
    const arrow_x = item_min[0] + 8.0;
    const arrow_y = row_top + (row_height - 12.0) * 0.5;
    const arrow_text: []const u8 = if (is_open.*) "\xE2\x96\xBC" else "\xE2\x96\xB6";
    const arrow_color = gui.getColorU32(theme.Palette.settings.section_arrow_text);
    draw_list.addText(.{ arrow_x, arrow_y }, arrow_color, arrow_text);

    // Section label (bold appearance via brighter color)
    const text_x = arrow_x + 16.0;
    const text_y = row_top + (row_height - 14.0) * 0.5;
    const text_color = gui.getColorU32(theme.Palette.settings.section_title_text);
    draw_list.addText(.{ text_x, text_y }, text_color, label);

    if (hovered and gui.isItemClicked()) {
        is_open.* = !is_open.*;
    }
}

// ── Sidebar: Child category item (indented) ──────────────────────────

fn drawCategoryChildItem(label: []const u8, is_selected: bool) bool {
    const row_height: f32 = 26.0;
    const rounding: f32 = 4.0;
    const draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    const row_top = cursor[1];
    const avail = gui.contentRegionAvail();
    const row_width = @max(avail[0], 100.0);

    gui.dummy(row_width, row_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();
    const hovered = gui.isItemHovered();

    if (is_selected) {
        draw_list.addRectFilled(
            .{ item_min[0] + 4.0, item_min[1] + 1.0 },
            .{ item_max[0] - 4.0, item_max[1] - 1.0 },
            gui.getColorU32(theme.Palette.settings.category_selected_bg),
            rounding,
            0,
        );
    } else if (hovered) {
        draw_list.addRectFilled(
            .{ item_min[0] + 4.0, item_min[1] + 1.0 },
            .{ item_max[0] - 4.0, item_max[1] - 1.0 },
            gui.getColorU32(theme.Palette.settings.category_hover_bg),
            rounding,
            0,
        );
    }

    const indent: f32 = 28.0;
    const text_y = row_top + (row_height - 14.0) * 0.5;
    const text_color = if (is_selected)
        gui.getColorU32(theme.Palette.settings.category_selected_text)
    else if (hovered)
        gui.getColorU32(theme.Palette.settings.category_hover_text)
    else
        gui.getColorU32(theme.Palette.settings.category_idle_text);
    draw_list.addText(.{ item_min[0] + indent, text_y }, text_color, label);

    return hovered and gui.isItemClicked();
}

// ── Sidebar: Full tree layout ────────────────────────────────────────

fn drawSettingsCategoryTree(state: *EditorState) void {
    // Section: 常规 (General)
    drawSectionHeader(state.text(.settings_section_general), &state.settings_section_general_open);
    if (state.settings_section_general_open) {
        if (drawCategoryChildItem(state.text(.settings_general), state.settings_category == .general)) {
            state.settings_category = .general;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: 界面 (Interface)
    drawSectionHeader(state.text(.settings_section_interface), &state.settings_section_interface_open);
    if (state.settings_section_interface_open) {
        if (drawCategoryChildItem(state.text(.settings_editor), state.settings_category == .editor)) {
            state.settings_category = .editor;
        }
        if (drawCategoryChildItem(state.text(.settings_inspector), state.settings_category == .inspector)) {
            state.settings_category = .inspector;
        }
        if (drawCategoryChildItem(state.text(.settings_theme), state.settings_category == .theme)) {
            state.settings_category = .theme;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: 视口 (Viewport)
    drawSectionHeader(state.text(.settings_section_viewport), &state.settings_section_viewport_open);
    if (state.settings_section_viewport_open) {
        if (drawCategoryChildItem(state.text(.settings_rendering), state.settings_category == .rendering)) {
            state.settings_category = .rendering;
        }
        if (drawCategoryChildItem(state.text(.settings_camera), state.settings_category == .camera)) {
            state.settings_category = .camera;
        }
    }

    gui.dummy(0.0, 2.0);

    // Section: AI
    drawSectionHeader(state.text(.settings_section_ai), &state.settings_section_ai_open);
    if (state.settings_section_ai_open) {
        if (drawCategoryChildItem(state.text(.settings_assistant), state.settings_category == .assistant)) {
            state.settings_category = .assistant;
        }
    }
}

// ── Content: per-category settings ───────────────────────────────────

fn drawSettingsContentGeneral(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    gui.labelText(state.text(.language), state.languageInfo().native_name);
    const content_width = gui.contentRegionAvail()[0];
    const language_count = i18n.available_languages.len;
    const language_columns: usize = if (content_width >= 88.0 * @as(f32, @floatFromInt(language_count)) + 8.0 * @as(f32, @floatFromInt(language_count -| 1)))
        language_count
    else if (content_width >= 184.0)
        @min(language_count, 2)
    else
        1;
    const language_button_width = @max(
        (content_width - 8.0 * @as(f32, @floatFromInt(language_columns -| 1))) / @as(f32, @floatFromInt(language_columns)),
        1.0,
    );
    for (i18n.available_languages, 0..) |language, index| {
        const locale_info = i18n.locale(language);
        if (index > 0) {
            layout.advanceResponsiveRow(index, language_columns);
        }
        if (gui.buttonEx(locale_info.native_name, language_button_width, 0.0)) {
            state.language = language;
            preferences.saveEditorPreferences(state) catch |err| {
                std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
            };
        }
    }

    gui.dummy(0.0, 6.0);
    gui.separator();
    gui.dummy(0.0, 6.0);
    gui.text(state.text(.fps));
    const fps_options = [_]struct {
        label: []const u8,
        mode: FpsDisplayMode,
    }{
        .{ .label = state.text(.viewport), .mode = .viewport },
        .{ .label = state.text(.none), .mode = .none },
    };
    const fps_columns = layout.responsiveButtonColumns(fps_options.len, 92.0);
    const fps_button_width = layout.responsiveButtonWidth(fps_columns);
    for (fps_options, 0..) |option, index| {
        if (index > 0) {
            layout.advanceResponsiveRow(index, fps_columns);
        }
        if (drawSettingsChoiceButton(option.label, state.fps_display_mode == option.mode, fps_button_width)) {
            state.fps_display_mode = option.mode;
            state.fps_overlay_last_sample_time = -1.0;
            preferences.saveEditorPreferences(state) catch |err| {
                std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
            };
        }
    }

    gui.dummy(0.0, 6.0);
    var vsync_enabled = state.vsync_enabled;
    if (gui.checkbox(state.text(.vsync), &vsync_enabled)) {
        try layer_context.renderer.setVSyncEnabled(vsync_enabled);
        state.vsync_enabled = layer_context.renderer.vsyncEnabled();
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }
}

fn drawSettingsChoiceButton(label: []const u8, active: bool, width: f32) bool {
    const palette = if (active) theme.Palette.settings.choice_active else theme.Palette.settings.choice_idle;
    gui.pushStyleColor(.button, palette.bg);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    defer gui.popStyleColor(3);
    return gui.buttonEx(label, width, 0.0);
}

fn drawSettingsContentEditor(_: *EditorState) void {
    gui.text("Editor settings coming soon...");
}

fn drawSettingsContentInspector(_: *EditorState) void {
    gui.text("Inspector settings coming soon...");
}

fn drawSettingsContentTheme(_: *EditorState) void {
    gui.text("Theme settings coming soon...");
}

fn drawSettingsContentRendering(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] }) catch unreachable;
    gui.labelText(state.text(.viewport_size), viewport_text);

    gui.dummy(0.0, 6.0);
    gui.separator();
    gui.dummy(0.0, 6.0);

    const debug_icon = icon_cache.ensureIconTexture(state, layer_context, debug_icon_path, 28, 28, debug_icon_tint) catch return;
    gui.text("SVG icon preview");
    gui.image(debug_icon, 28.0, 28.0);
}

fn drawSettingsContentCamera(_: *EditorState) void {
    gui.text("Camera settings coming soon...");
}

const ShortcutSlot = enum(u8) {
    extrude,
    inset,
    bevel,
    loop_cut,
    merge,
    duplicate,
    separate,
    recalc_normals,
    pivot_to_selection,
};

var active_record_slot: ?ShortcutSlot = null;
var last_conflict_text: [128]u8 = [_]u8{0} ** 128;

const mesh_shortcut_keys = [_]engine.core.InputKey{
    .a,
    .e,
    .i,
    .b,
    .r,
    .m,
    .d,
    .p,
    .n,
    .period,
    .f,
    .q,
    .w,
    .s,
    .g,
    .t,
    .x,
    .y,
    .z,
    .one,
    .two,
    .three,
    .tab,
    .delete,
    .backspace,
};

fn shortcutKeyLabel(key: engine.core.InputKey) []const u8 {
    return switch (key) {
        .tab => "Tab",
        .delete => "Delete",
        .backspace => "Backspace",
        .one => "1",
        .two => "2",
        .three => "3",
        .period => ".",
        else => @tagName(key),
    };
}

fn shortcutSlotLabel(slot: ShortcutSlot) []const u8 {
    return switch (slot) {
        .extrude => "Extrude",
        .inset => "Inset",
        .bevel => "Bevel",
        .loop_cut => "Loop Cut",
        .merge => "Merge",
        .duplicate => "Duplicate Faces",
        .separate => "Separate Faces",
        .recalc_normals => "Recalculate Normals",
        .pivot_to_selection => "Pivot To Selection",
    };
}

fn shortcutSlotIdSuffix(slot: ShortcutSlot) []const u8 {
    return switch (slot) {
        .extrude => "extrude",
        .inset => "inset",
        .bevel => "bevel",
        .loop_cut => "loop_cut",
        .merge => "merge",
        .duplicate => "duplicate",
        .separate => "separate",
        .recalc_normals => "recalc_normals",
        .pivot_to_selection => "pivot_to_selection",
    };
}

fn shortcutBindingPtr(state: *EditorState, slot: ShortcutSlot) *MeshShortcutBinding {
    return switch (slot) {
        .extrude => &state.mesh_edit_shortcuts.extrude,
        .inset => &state.mesh_edit_shortcuts.inset,
        .bevel => &state.mesh_edit_shortcuts.bevel,
        .loop_cut => &state.mesh_edit_shortcuts.loop_cut,
        .merge => &state.mesh_edit_shortcuts.merge,
        .duplicate => &state.mesh_edit_shortcuts.duplicate,
        .separate => &state.mesh_edit_shortcuts.separate,
        .recalc_normals => &state.mesh_edit_shortcuts.recalc_normals,
        .pivot_to_selection => &state.mesh_edit_shortcuts.pivot_to_selection,
    };
}

fn shortcutsEqual(a: MeshShortcutBinding, b: MeshShortcutBinding) bool {
    return a.key == b.key and a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt;
}

fn findShortcutConflict(state: *const EditorState, slot: ShortcutSlot, binding: MeshShortcutBinding) ?ShortcutSlot {
    const total = std.meta.fields(ShortcutSlot).len;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const candidate: ShortcutSlot = @enumFromInt(i);
        if (candidate == slot) continue;
        const candidate_binding = switch (candidate) {
            .extrude => state.mesh_edit_shortcuts.extrude,
            .inset => state.mesh_edit_shortcuts.inset,
            .bevel => state.mesh_edit_shortcuts.bevel,
            .loop_cut => state.mesh_edit_shortcuts.loop_cut,
            .merge => state.mesh_edit_shortcuts.merge,
            .duplicate => state.mesh_edit_shortcuts.duplicate,
            .separate => state.mesh_edit_shortcuts.separate,
            .recalc_normals => state.mesh_edit_shortcuts.recalc_normals,
            .pivot_to_selection => state.mesh_edit_shortcuts.pivot_to_selection,
        };
        if (shortcutsEqual(binding, candidate_binding)) {
            return candidate;
        }
    }
    return null;
}

fn setConflictMessage(slot: ShortcutSlot, conflict: ShortcutSlot) void {
    @memset(last_conflict_text[0..], 0);
    const msg = std.fmt.bufPrint(
        last_conflict_text[0..],
        "Conflict: {s} duplicates {s}",
        .{ shortcutSlotLabel(slot), shortcutSlotLabel(conflict) },
    ) catch return;
    _ = msg;
}

fn applyBindingWithConflictCheck(state: *EditorState, slot: ShortcutSlot, new_binding: MeshShortcutBinding) bool {
    if (findShortcutConflict(state, slot, new_binding)) |conflict_slot| {
        setConflictMessage(slot, conflict_slot);
        return false;
    }
    shortcutBindingPtr(state, slot).* = new_binding;
    @memset(last_conflict_text[0..], 0);
    return true;
}

fn drawShortcutBindingControl(id: []const u8, state: *EditorState, slot: ShortcutSlot, binding: *MeshShortcutBinding) bool {
    var changed = false;
    if (gui.beginCombo(id, shortcutKeyLabel(binding.key))) {
        defer gui.endCombo();
        for (mesh_shortcut_keys) |candidate| {
            const selected = binding.key == candidate;
            if (gui.selectable(shortcutKeyLabel(candidate), selected, false, 0.0, 0.0)) {
                var next = binding.*;
                next.key = candidate;
                changed = applyBindingWithConflictCheck(state, slot, next) or changed;
            }
        }
    }
    return changed;
}

fn drawShortcutModifierToggle(id: []const u8, state: *EditorState, slot: ShortcutSlot, binding: *MeshShortcutBinding, field: enum { ctrl, shift, alt }) bool {
    var value = switch (field) {
        .ctrl => binding.ctrl,
        .shift => binding.shift,
        .alt => binding.alt,
    };
    if (!gui.checkbox(id, &value)) {
        return false;
    }
    var next = binding.*;
    switch (field) {
        .ctrl => next.ctrl = value,
        .shift => next.shift = value,
        .alt => next.alt = value,
    }
    return applyBindingWithConflictCheck(state, slot, next);
}

fn drawShortcutRow(state: *EditorState, slot: ShortcutSlot, binding: *MeshShortcutBinding) bool {
    const action_label = shortcutSlotLabel(slot);
    const id_suffix = shortcutSlotIdSuffix(slot);
    var changed = false;
    const has_conflict = findShortcutConflict(state, slot, binding.*) != null;
    gui.tableNextRow();

    gui.tableNextColumn();
    if (has_conflict) {
        gui.pushStyleColor(.text, theme.Palette.settings.error_text);
        defer gui.popStyleColor(1);
    }
    gui.text(action_label);

    gui.tableNextColumn();
    var key_id_buf: [64]u8 = undefined;
    const key_id = std.fmt.bufPrint(&key_id_buf, "##key_{s}", .{id_suffix}) catch "##key_fallback";
    changed = drawShortcutBindingControl(key_id, state, slot, binding) or changed;

    gui.tableNextColumn();
    var ctrl_id_buf: [64]u8 = undefined;
    const ctrl_id = std.fmt.bufPrint(&ctrl_id_buf, "##ctrl_{s}", .{id_suffix}) catch "##ctrl_fallback";
    changed = drawShortcutModifierToggle(ctrl_id, state, slot, binding, .ctrl) or changed;

    gui.tableNextColumn();
    var shift_id_buf: [64]u8 = undefined;
    const shift_id = std.fmt.bufPrint(&shift_id_buf, "##shift_{s}", .{id_suffix}) catch "##shift_fallback";
    changed = drawShortcutModifierToggle(shift_id, state, slot, binding, .shift) or changed;

    gui.tableNextColumn();
    var alt_id_buf: [64]u8 = undefined;
    const alt_id = std.fmt.bufPrint(&alt_id_buf, "##alt_{s}", .{id_suffix}) catch "##alt_fallback";
    changed = drawShortcutModifierToggle(alt_id, state, slot, binding, .alt) or changed;

    gui.tableNextColumn();
    var rec_label_buf: [96]u8 = undefined;
    const rec_text = if (active_record_slot == slot) "Recording..." else "Record";
    const rec_label = std.fmt.bufPrint(&rec_label_buf, "{s}##rec_{s}", .{ rec_text, id_suffix }) catch rec_text;
    if (gui.buttonEx(rec_label, 0.0, 0.0)) {
        if (active_record_slot == slot) {
            active_record_slot = null;
        } else {
            active_record_slot = slot;
            @memset(last_conflict_text[0..], 0);
        }
    }

    return changed;
}

fn handleShortcutRecording(state: *EditorState, layer_context: *engine.core.LayerContext) bool {
    const slot = active_record_slot orelse return false;
    const input = layer_context.input;
    if (input.wasKeyPressed(.escape)) {
        active_record_slot = null;
        return false;
    }

    for (mesh_shortcut_keys) |candidate| {
        if (!input.wasKeyPressed(candidate)) continue;
        const next = MeshShortcutBinding{
            .key = candidate,
            .ctrl = input.modifiers.ctrl,
            .shift = input.modifiers.shift,
            .alt = input.modifiers.alt,
        };
        const applied = applyBindingWithConflictCheck(state, slot, next);
        active_record_slot = null;
        return applied;
    }
    return false;
}

fn drawSettingsContentShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    gui.text("Mesh Edit Modal Controls");
    gui.dummy(0.0, 4.0);

    var drag_sensitivity = state.mesh_modal_drag_sensitivity;
    if (gui.sliderFloat("Mouse Drag Sensitivity", &drag_sensitivity, 0.0005, 0.05)) {
        state.mesh_modal_drag_sensitivity = drag_sensitivity;
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    var fine_scale = state.mesh_modal_fine_scale;
    if (gui.sliderFloat("Shift Fine Scale", &fine_scale, 0.05, 1.0)) {
        state.mesh_modal_fine_scale = fine_scale;
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);

    gui.text("Mesh Edit Shortcuts");
    gui.textWrapped("These bindings are live. Changes are applied immediately and persisted to editor preferences.");
    gui.dummy(0.0, 6.0);

    var changed = handleShortcutRecording(state, layer_context);
    if (active_record_slot != null) {
        gui.pushStyleColor(.text, theme.Palette.settings.warning_text);
        gui.text("Recording shortcut: press a key combo, Esc to cancel");
        gui.popStyleColor(1);
        gui.dummy(0.0, 4.0);
    }
    if (last_conflict_text[0] != 0) {
        const end = std.mem.indexOfScalar(u8, last_conflict_text[0..], 0) orelse last_conflict_text.len;
        gui.pushStyleColor(.text, theme.Palette.settings.error_text);
        gui.text(last_conflict_text[0..end]);
        gui.popStyleColor(1);
        gui.dummy(0.0, 4.0);
    }

    if (gui.beginTable("##mesh_edit_shortcuts_table", 6)) {
        defer gui.endTable();
        gui.tableSetupColumn("Action", true, 0.0);
        gui.tableSetupColumn("Key", false, 120.0);
        gui.tableSetupColumn("Ctrl", false, 56.0);
        gui.tableSetupColumn("Shift", false, 56.0);
        gui.tableSetupColumn("Alt", false, 56.0);
        gui.tableSetupColumn("Record", false, 110.0);
        gui.tableHeadersRow();

        const total = std.meta.fields(ShortcutSlot).len;
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const slot: ShortcutSlot = @enumFromInt(i);
            changed = drawShortcutRow(state, slot, shortcutBindingPtr(state, slot)) or changed;
        }
    }

    gui.dummy(0.0, 6.0);
    if (gui.buttonEx("Reset Mesh Edit Shortcuts", 0.0, 0.0)) {
        state.mesh_edit_shortcuts = MeshEditShortcutConfig{};
        active_record_slot = null;
        @memset(last_conflict_text[0..], 0);
        changed = true;
    }

    if (changed) {
        preferences.saveEditorPreferences(state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
    }

    gui.dummy(0.0, 8.0);
    gui.separator();
    gui.dummy(0.0, 8.0);
    gui.text("Modal Controls");
    gui.labelText("Mouse", "Adjust value (Loop Cut: cursor position maps to slide factor)");
    gui.labelText("Shift", "Fine adjustment while dragging");
    gui.labelText("LMB", "Confirm modal operation");
    gui.labelText("RMB / Esc", "Cancel and revert modal operation");

    // ── Game Input Actions ───────────────────────────────────────────
    gui.dummy(0.0, 12.0);
    gui.separator();
    gui.dummy(0.0, 8.0);
    gui.text("Game Input Actions");
    gui.textWrapped("Configure game action bindings (keyboard/mouse). Changes are saved to assets/input_actions.json.");
    gui.dummy(0.0, 6.0);

    drawGameInputActions(layer_context);
}

// ── Game Input Actions: rebinding panel ──────────────────────────────

const input_actions_path = "assets/input_actions.json";
const max_action_name_len = 64;

/// Recording state for game action rebinding
var action_record_target: ?[max_action_name_len]u8 = null;
var action_record_target_len: usize = 0;
var new_action_name_buf: [max_action_name_len]u8 = [_]u8{0} ** max_action_name_len;

/// All keys available for game action binding (superset of mesh_shortcut_keys)
const game_bindable_keys = blk: {
    const fields = std.meta.fields(engine.core.InputKey);
    var keys: [fields.len]engine.core.InputKey = undefined;
    for (fields, 0..) |f, idx| {
        keys[idx] = @enumFromInt(f.value);
    }
    break :blk keys;
};

fn saveActionMapToFile(action_map: *const engine.core.ActionMap) void {
    const json = action_map.saveToJsonAlloc(std.heap.page_allocator) catch return;
    defer std.heap.page_allocator.free(json);

    const file = std.fs.cwd().createFile(input_actions_path, .{}) catch return;
    defer file.close();
    file.writeAll(json) catch return;
}

fn isRecordingAction(name: []const u8) bool {
    if (action_record_target) |buf| {
        return action_record_target_len <= name.len and
            std.mem.eql(u8, buf[0..action_record_target_len], name[0..action_record_target_len]) and
            action_record_target_len == name.len;
    }
    return false;
}

fn startRecordingAction(name: []const u8) void {
    const len = @min(name.len, max_action_name_len);
    var buf: [max_action_name_len]u8 = [_]u8{0} ** max_action_name_len;
    @memcpy(buf[0..len], name[0..len]);
    action_record_target = buf;
    action_record_target_len = len;
}

fn stopRecordingAction() void {
    action_record_target = null;
    action_record_target_len = 0;
}

fn handleActionRecording(action_map: *engine.core.ActionMap, input: *const engine.core.InputState) bool {
    if (action_record_target == null) return false;
    const target_name = action_record_target.?[0..action_record_target_len];

    if (input.wasKeyPressed(.escape)) {
        stopRecordingAction();
        return false;
    }

    // Check mouse buttons
    const mouse_buttons = [_]engine.core.MouseButton{ .left, .right, .middle };
    for (mouse_buttons) |btn| {
        if (input.wasMousePressed(btn)) {
            action_map.bindMouseButton(target_name, btn, 1.0) catch {};
            stopRecordingAction();
            return true;
        }
    }

    // Check all keys
    for (game_bindable_keys) |key| {
        // Skip modifiers as standalone bindings
        if (key == .shift or key == .ctrl or key == .alt or key == .escape) continue;
        if (input.wasKeyPressed(key)) {
            action_map.bindKey(target_name, key, 1.0) catch {};
            stopRecordingAction();
            return true;
        }
    }
    return false;
}

fn bindingLabel(buf: []u8, binding: engine.core.ActionBinding) []const u8 {
    return switch (binding.kind) {
        .key => std.fmt.bufPrint(buf, "{s} ({d:.0})", .{
            shortcutKeyLabel(binding.key),
            binding.axis_scale,
        }) catch "?",
        .mouse_button => std.fmt.bufPrint(buf, "Mouse {s} ({d:.0})", .{
            @tagName(binding.mouse_button),
            binding.axis_scale,
        }) catch "?",
    };
}

fn drawGameInputActions(layer_context: *engine.core.LayerContext) void {
    const action_map = layer_context.action_map orelse {
        gui.textWrapped("ActionMap not available.");
        return;
    };

    var dirty = handleActionRecording(action_map, layer_context.input);

    if (action_record_target != null) {
        gui.pushStyleColor(.text, theme.Palette.settings.warning_text);
        gui.text("Recording: press a key or mouse button, Esc to cancel");
        gui.popStyleColor(1);
        gui.dummy(0.0, 4.0);
    }

    // ── New action registration ──────────────────────────────────────
    gui.setNextItemWidth(200.0);
    _ = gui.inputTextWithHint("##new_action_name", "New action name...", new_action_name_buf[0..max_action_name_len]);
    gui.sameLineEx(0.0, 8.0);
    if (gui.buttonEx("Add Action##add_game_action", 0.0, 0.0)) {
        const end = std.mem.indexOfScalar(u8, new_action_name_buf[0..], 0) orelse max_action_name_len;
        if (end > 0) {
            action_map.registerAction(new_action_name_buf[0..end]) catch {};
            @memset(new_action_name_buf[0..], 0);
            dirty = true;
        }
    }
    gui.dummy(0.0, 4.0);

    // ── Action table ─────────────────────────────────────────────────
    if (gui.beginTable("##game_input_actions_table", 4)) {
        defer gui.endTable();
        gui.tableSetupColumn("Action", true, 0.0);
        gui.tableSetupColumn("Bindings", true, 0.0);
        gui.tableSetupColumn("Add", false, 60.0);
        gui.tableSetupColumn("Remove", false, 80.0);
        gui.tableHeadersRow();

        // Collect action names for stable iteration
        var name_ptrs: [128][]const u8 = undefined;
        var action_count: usize = 0;
        {
            var it = action_map.entries.iterator();
            while (it.next()) |kv| {
                if (action_count >= 128) break;
                name_ptrs[action_count] = kv.key_ptr.*;
                action_count += 1;
            }
        }

        var remove_action: ?[]const u8 = null;
        var remove_binding: ?struct { action: []const u8, index: usize } = null;

        var idx: usize = 0;
        while (idx < action_count) : (idx += 1) {
            const name = name_ptrs[idx];
            const entry = action_map.entries.getPtr(name) orelse continue;

            gui.tableNextRow();

            // Column: Action name
            gui.tableNextColumn();
            gui.text(name);

            // Column: Current bindings list
            gui.tableNextColumn();
            if (entry.bindings.items.len == 0) {
                gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "(none)");
            } else {
                for (entry.bindings.items, 0..) |binding, bi| {
                    var lbl_buf: [80]u8 = undefined;
                    const label = bindingLabel(&lbl_buf, binding);
                    if (bi > 0) {
                        gui.sameLineEx(0.0, 4.0);
                        gui.text(",");
                        gui.sameLineEx(0.0, 4.0);
                    }
                    gui.text(label);
                }
            }

            // Column: Add binding button (record)
            gui.tableNextColumn();
            {
                var btn_buf: [96]u8 = undefined;
                const btn_text = if (isRecordingAction(name)) "..." else "+";
                const btn_label = std.fmt.bufPrint(&btn_buf, "{s}##add_{s}", .{ btn_text, name }) catch btn_text;
                if (gui.buttonEx(btn_label, 0.0, 0.0)) {
                    if (isRecordingAction(name)) {
                        stopRecordingAction();
                    } else {
                        startRecordingAction(name);
                    }
                }
            }

            // Column: Remove last binding / remove action
            gui.tableNextColumn();
            {
                if (entry.bindings.items.len > 0) {
                    var rm_buf: [96]u8 = undefined;
                    const rm_label = std.fmt.bufPrint(&rm_buf, "- Last##rmlast_{s}", .{name}) catch "- Last";
                    if (gui.buttonEx(rm_label, 0.0, 0.0)) {
                        remove_binding = .{ .action = name, .index = entry.bindings.items.len - 1 };
                    }
                }
                gui.sameLineEx(0.0, 4.0);
                {
                    var del_buf: [96]u8 = undefined;
                    const del_label = std.fmt.bufPrint(&del_buf, "X##del_{s}", .{name}) catch "X";
                    if (gui.buttonEx(del_label, 0.0, 0.0)) {
                        remove_action = name;
                    }
                }
            }
        }

        // Deferred mutations (avoid modifying hashmap during iteration)
        if (remove_binding) |rb| {
            if (action_map.entries.getPtr(rb.action)) |entry| {
                _ = entry.bindings.orderedRemove(rb.index);
                dirty = true;
            }
        }
        if (remove_action) |ra| {
            action_map.removeAction(ra);
            dirty = true;
        }
    }

    // ── Load / Save buttons ──────────────────────────────────────────
    gui.dummy(0.0, 6.0);
    if (gui.buttonEx("Save to File##save_actions", 0.0, 0.0)) {
        saveActionMapToFile(action_map);
    }
    gui.sameLineEx(0.0, 8.0);
    if (gui.buttonEx("Load from File##load_actions", 0.0, 0.0)) {
        if (std.fs.cwd().readFileAlloc(std.heap.page_allocator, input_actions_path, 4 * 1024 * 1024)) |json| {
            defer std.heap.page_allocator.free(json);
            action_map.loadFromJson(json) catch {};
        } else |_| {}
    }

    if (dirty) {
        saveActionMapToFile(action_map);
    }
}

fn drawSettingsContentAssistant(_: *EditorState) void {
    gui.text("AI Assistant settings coming soon...");
}

fn drawSettingsContentForCategory(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    switch (state.settings_category) {
        .general => try drawSettingsContentGeneral(state, layer_context),
        .interface => drawSettingsContentEditor(state),
        .editor => drawSettingsContentEditor(state),
        .inspector => drawSettingsContentInspector(state),
        .theme => drawSettingsContentTheme(state),
        .viewport => drawSettingsContentRendering(state, layer_context),
        .rendering => drawSettingsContentRendering(state, layer_context),
        .camera => drawSettingsContentCamera(state),
        .shortcuts => drawSettingsContentShortcuts(state, layer_context),
        .ai => drawSettingsContentAssistant(state),
        .assistant => drawSettingsContentAssistant(state),
        .advanced => {
            if (state.settings_advanced_mode) {
                gui.text("Advanced settings enabled.");
            } else {
                gui.text("Enable advanced mode to see more settings.");
            }
        },
    }
}

// ── Main window ──────────────────────────────────────────────────────

pub fn drawSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .settings, "settings_popup");
    var open = state.settings_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.settings_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("settings_popup");

    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.popup);
    gui.pushStyleVarVec2(.item_spacing, theme.Spacing.settings_window_item_spacing);
    defer gui.popStyleVar(2);

    // ── Top tabs: 常规 | 快捷键 ──────────────────────────────────────
    if (gui.beginTabBar("##settings_tabs")) {
        defer gui.endTabBar();

        if (gui.beginTabItem(state.text(.settings_general))) {
            state.settings_tab = .general;
            gui.endTabItem();
        }
        if (gui.beginTabItem(state.text(.settings_shortcuts))) {
            state.settings_tab = .shortcuts;
            gui.endTabItem();
        }
    }

    // ── Search bar + advanced toggle (full width) ────────────────────
    {
        const search_avail = gui.contentRegionAvail()[0];
        const toggle_width: f32 = 120.0;
        const search_width = @max(search_avail - toggle_width - 16.0, 100.0);
        gui.pushStyleColor(.frame_bg, theme.Palette.settings.search_bg);
        gui.setNextItemWidth(search_width);
        _ = gui.inputTextWithHint("##settings_filter", state.text(.settings_filter), state.settings_filter_buffer[0..settings_filter_buffer_size]);
        gui.popStyleColor(1);
        gui.sameLineEx(0.0, 8.0);
        _ = gui.checkbox(state.text(.settings_advanced), &state.settings_advanced_mode);
    }

    gui.dummy(0.0, 2.0);

    if (state.settings_tab == .shortcuts) {
        // Shortcuts tab: direct content, no sidebar
        layout.beginSectionBody();
        defer layout.endSectionBody();
        drawSettingsContentShortcuts(state, layer_context);
        return;
    }

    // ── Body: sidebar tree + separator + content ─────────────────────
    const avail = gui.contentRegionAvail();
    const sidebar_width: f32 = 180.0;
    const separator_width: f32 = 1.0;
    const content_width = @max(avail[0] - sidebar_width - separator_width - 16.0, 100.0);
    const body_height = @max(avail[1], 100.0);

    // Left sidebar (scrollable collapsible tree)
    gui.pushStyleColor(.child_bg, theme.Palette.settings.sidebar_bg);
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.settings_sidebar_padding);
    _ = gui.beginChild("##settings_sidebar", sidebar_width, body_height, false);
    gui.popStyleVar(1);
    gui.popStyleColor(1);
    drawSettingsCategoryTree(state);
    gui.endChild();

    gui.sameLineEx(0.0, 0.0);

    // Vertical separator line
    {
        const draw_list = gui.getWindowDrawList();
        const cursor = gui.cursorScreenPos();
        draw_list.addLine(
            .{ cursor[0], cursor[1] },
            .{ cursor[0], cursor[1] + body_height },
            gui.getColorU32(theme.Palette.settings.separator),
            separator_width,
        );
    }
    gui.dummy(separator_width + 8.0, body_height);
    gui.sameLineEx(0.0, 8.0);

    // Right content area (scrollable)
    _ = gui.beginChild("##settings_content", content_width, body_height, false);
    layout.beginSectionBody();
    defer layout.endSectionBody();
    defer gui.endChild();

    try drawSettingsContentForCategory(state, layer_context);
}
