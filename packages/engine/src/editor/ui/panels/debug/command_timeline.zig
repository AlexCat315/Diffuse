const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const theme = @import("../../theme.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const command_mod = @import("../../../actions/command.zig");
const history = @import("../../../actions/history.zig");
const i18n = @import("../../../i18n/mod.zig");

fn timelineSourceText(state: *const EditorState, source: command_mod.TimelineSource) []const u8 {
    return switch (source) {
        .human => state.text(.command_timeline_source_human),
        .ai => state.text(.command_timeline_source_ai),
    };
}

fn setEntryTooltip(state: *const EditorState, entry: *const command_mod.TimelineEntry) void {
    var source_buffer: [96]u8 = undefined;
    const source_text = i18n.bufPrintMessage(
        &source_buffer,
        .command_timeline_source_fmt,
        state.language,
        .{timelineSourceText(state, entry.source)},
    ) catch timelineSourceText(state, entry.source);

    const trimmed_detail = std.mem.trim(u8, entry.detail, " \t\r\n");
    var tooltip_buffer: [512]u8 = undefined;
    const tooltip = if (trimmed_detail.len != 0 and !std.mem.eql(u8, trimmed_detail, entry.label))
        i18n.bufPrintMessage(
            &tooltip_buffer,
            .command_timeline_tooltip_with_detail_fmt,
            state.language,
            .{ source_text, entry.label, trimmed_detail },
        ) catch entry.label
    else
        i18n.bufPrintMessage(
            &tooltip_buffer,
            .command_timeline_tooltip_label_only_fmt,
            state.language,
            .{ source_text, entry.label },
        ) catch entry.label;

    gui.setTooltip(tooltip);
}

/// 在底部面板内绘制命令时间线内容（无窗口边框）
pub fn drawCommandTimelinePanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const total_history_commands = state.undo_stack.items.len + state.redo_stack.items.len;
    const available_entries = @min(total_history_commands, state.timeline_entries.items.len);
    const timeline_start_index = state.timeline_entries.items.len -| available_entries;
    const current_cursor = state.undo_stack.items.len;

    // 顶部工具栏：统计信息 + Hover Preview 开关
    {
        const available_w = gui.contentRegionAvail()[0];

        var summary_buffer: [160]u8 = undefined;
        const summary = i18n.bufPrintMessage(
            &summary_buffer,
            .command_timeline_summary_fmt,
            state.language,
            .{ state.timeline_entries.items.len, current_cursor, total_history_commands },
        ) catch state.text(.command_timeline);
        gui.pushStyleColor(.text, theme.Palette.timeline.summary_text);
        gui.text(summary);
        gui.popStyleColor(1);

        if (available_w > 440.0) {
            gui.sameLine();
            gui.dummy(available_w - 440.0, 1.0);
            gui.sameLine();
        } else {
            gui.dummy(0.0, 2.0);
        }

        var hover_toggle_buffer: [160]u8 = undefined;
        const hover_toggle_label = std.fmt.bufPrint(
            &hover_toggle_buffer,
            "{s}##timeline_hover",
            .{state.text(.command_timeline_hover_preview_confirm)},
        ) catch "##timeline_hover";
        if (gui.checkbox(hover_toggle_label, &state.timeline_hover_preview_confirm_mode)) {
            if (!state.timeline_hover_preview_confirm_mode) {
                state.timeline_preview_sequence = null;
                state.timeline_preview_target_cursor = null;
            }
        }
    }

    // 若有悬停目标：显示确认条
    if (state.timeline_hover_preview_confirm_mode) {
        const preview_cursor_opt = state.timeline_preview_target_cursor;
        const has_valid_preview = preview_cursor_opt != null and
            preview_cursor_opt.? > 0 and
            preview_cursor_opt.? <= available_entries and
            preview_cursor_opt.? != current_cursor;
        if (has_valid_preview) {
            const preview_cursor = preview_cursor_opt.?;
            const preview_entry = state.timeline_entries.items[timeline_start_index + preview_cursor - 1];
            var preview_buffer: [224]u8 = undefined;
            const preview_text = i18n.bufPrintMessage(
                &preview_buffer,
                .command_timeline_preview_fmt,
                state.language,
                .{ preview_entry.sequence, preview_entry.label },
            ) catch state.text(.command_timeline_preview_pending);
            gui.pushStyleColor(.text, theme.Palette.timeline.preview_text);
            gui.text(preview_text);
            gui.popStyleColor(1);
            gui.sameLine();
            gui.pushStyleColor(.button, theme.Palette.timeline.confirm_button.bg);
            gui.pushStyleColor(.button_hovered, theme.Palette.timeline.confirm_button.hovered);
            gui.pushStyleColor(.button_active, theme.Palette.timeline.confirm_button.active);
            var confirm_button_buffer: [160]u8 = undefined;
            const confirm_button_label = std.fmt.bufPrint(
                &confirm_button_buffer,
                "{s}##timeline_confirm",
                .{state.text(.command_timeline_confirm_time_travel)},
            ) catch "##timeline_confirm";
            if (gui.buttonEx(confirm_button_label, 140.0, 0.0)) {
                try history.timeTravelToCursor(state, layer_context, preview_cursor);
                state.timeline_preview_sequence = null;
                state.timeline_preview_target_cursor = null;
            }
            gui.popStyleColor(3);
        } else {
            gui.pushStyleColor(.text, theme.Palette.timeline.hint_text);
            gui.text(state.text(.command_timeline_hover_hint));
            gui.popStyleColor(1);
        }
    }

    gui.separator();

    if (available_entries == 0) {
        gui.dummy(0.0, 6.0);
        gui.pushStyleColor(.text, theme.Palette.timeline.empty_text);
        gui.text(state.text(.command_timeline_empty));
        gui.popStyleColor(1);
        return;
    }

    // 横向节点轨道：填充剩余高度
    const lane_height = gui.contentRegionAvail()[1] - 2.0;
    if (!gui.beginChild("command_timeline_lane##bottom", 0.0, lane_height, true)) {
        return;
    }
    defer gui.endChild();

    gui.pushStyleVarVec2(.item_spacing, theme.Spacing.timeline_item_spacing);
    defer gui.popStyleVar(1);

    for (state.timeline_entries.items[timeline_start_index..], 0..) |entry, index| {
        if (index > 0) {
            gui.sameLine();
            gui.pushStyleColor(.text, theme.Palette.timeline.connector_text);
            gui.text("→");
            gui.popStyleColor(1);
            gui.sameLine();
        }

        const palette = switch (entry.source) {
            .human => theme.Palette.timeline.human_node,
            .ai => theme.Palette.timeline.ai_node,
        };

        const node_cursor = index + 1;
        const is_current = node_cursor == current_cursor;
        const is_preview = state.timeline_hover_preview_confirm_mode and
            state.timeline_preview_target_cursor != null and
            state.timeline_preview_target_cursor.? == node_cursor and
            node_cursor != current_cursor;

        var node_label_buffer: [192]u8 = undefined;
        const node_label = std.fmt.bufPrint(
            &node_label_buffer,
            "#{d} {s}",
            .{ entry.sequence, entry.label },
        ) catch entry.label;

        gui.pushStyleColor(.button, palette.bg);
        gui.pushStyleColor(.button_hovered, palette.hovered);
        gui.pushStyleColor(.button_active, palette.active);
        if (is_current) {
            gui.pushStyleColor(.text, theme.Palette.timeline.current_text);
        } else if (is_preview) {
            gui.pushStyleColor(.text, theme.Palette.timeline.preview_node_text);
        }
        gui.pushStyleVarVec2(.frame_padding, theme.Spacing.timeline_node_padding);
        gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.timeline_node);
        defer {
            gui.popStyleVar(2);
            gui.popStyleColor(if (is_current or is_preview) 4 else 3);
        }

        const clicked = gui.buttonEx(node_label, 0.0, 0.0);
        if (state.timeline_hover_preview_confirm_mode and gui.isItemHovered() and node_cursor != current_cursor) {
            state.timeline_preview_sequence = entry.sequence;
            state.timeline_preview_target_cursor = node_cursor;
        }

        if (clicked) {
            if (state.timeline_hover_preview_confirm_mode) {
                if (node_cursor == current_cursor) {
                    state.timeline_preview_sequence = null;
                    state.timeline_preview_target_cursor = null;
                } else {
                    state.timeline_preview_sequence = entry.sequence;
                    state.timeline_preview_target_cursor = node_cursor;
                }
            } else {
                try history.timeTravelToCursor(state, layer_context, node_cursor);
            }
        }

        if (gui.isItemHovered()) {
            setEntryTooltip(state, &entry);
        }
    }
}
