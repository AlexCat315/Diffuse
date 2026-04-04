const builtin = @import("builtin");
const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const history = @import("../actions/history.zig");
const asset_preview = @import("preview.zig");
const console = @import("../ui/panels/debug/console.zig");
const command_timeline = @import("../ui/panels/debug/command_timeline.zig");
const ui_icons = @import("../ui/icons.zig");
const layout = @import("../ui/layout.zig");
const theme = @import("../ui/theme.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;
const BottomWorkspaceTab = state_mod.BottomWorkspaceTab;
const asset_drag_preview_icon_size: f32 = 24.0;
const drawer_corner_radius: f32 = 0.0;
const drawer_side_margin: f32 = 0.0;
const drawer_bottom_margin: f32 = 0.0;
const drawer_bar_height: f32 = 38.0;
const drawer_content_margin: f32 = 10.0;
const drawer_resize_grip_width: f32 = 44.0;
const drawer_resize_grip_height: f32 = 4.0;
const drawer_min_height: f32 = 136.0;
const drawer_top_clearance: f32 = 72.0;

pub fn drawProjectBrowserWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .project, "project_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    try drawProjectPanel(state, layer_context);
}

pub fn drawBottomDrawer(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const vp_origin = state.viewport_origin;
    const vp_extent = state.viewport_extent;
    const raw_drawer_width = @max(vp_extent[0] - drawer_side_margin * 2.0, 180.0);
    const drawer_width = @min(raw_drawer_width, @max(vp_extent[0], 1.0));
    const height_bounds = drawerHeightBounds(state);
    if (state.bottom_drawer_open) {
        state.bottom_drawer_height = std.math.clamp(state.bottom_drawer_height, height_bounds.min, height_bounds.max);
    }

    const drawer_height = if (state.bottom_drawer_open) state.bottom_drawer_height else 0.0;
    const total_height = drawer_bar_height + drawer_height;
    const drawer_x = vp_origin[0] + @max((vp_extent[0] - drawer_width) * 0.5, 0.0);
    const drawer_y = vp_origin[1] + vp_extent[1] - drawer_bottom_margin - total_height;

    gui.setNextWindowPos(.{ drawer_x, drawer_y });
    gui.setNextWindowSize(.{ drawer_width, total_height });
    gui.setNextWindowBgAlpha(0.0);

    var title_buffer: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buffer, "##bottom_drawer", .{});
    gui.pushStyleVarVec2(.window_padding, theme.Spacing.content_browser_window_padding);
    defer gui.popStyleVar(1);
    _ = gui.beginWindowFlags(
        title,
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_collapse |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_move |
            gui.WindowFlags.no_saved_settings |
            gui.WindowFlags.no_docking,
    );
    defer gui.endWindow();

    drawDrawerChrome(state, drawer_width, total_height);
    try drawDrawerTabBar(state, layer_context, drawer_width, drawer_bar_height);

    if (gui.isWindowHovered()) {
        state.viewport_overlay_hovered = true;
        if (layer_context.input.wasMousePressed(.left)) {
            state.manipulation_started_from_ui = true;
        }
    }

    if (state.bottom_drawer_open) {
        const window_pos = gui.windowPos();
        const content_width = @max(drawer_width - drawer_content_margin * 2.0, 1.0);
        const content_height = @max(drawer_height - drawer_content_margin, 1.0);
        gui.setCursorScreenPos(.{
            window_pos[0] + drawer_content_margin,
            window_pos[1] + drawer_bar_height + drawer_content_margin * 0.5,
        });
        gui.pushStyleColor(.child_bg, theme.Palette.content_browser.drawer_child_bg);
        gui.pushStyleVarVec2(.window_padding, theme.Spacing.content_browser_drawer_content_padding);
        _ = gui.beginChild("##drawer_content", content_width, content_height, false);
        gui.popStyleVar(1);
        gui.popStyleColor(1);
        defer gui.endChild();
        if (gui.isWindowHovered()) {
            state.viewport_overlay_hovered = true;
            if (layer_context.input.wasMousePressed(.left)) {
                state.manipulation_started_from_ui = true;
            }
        }

        switch (state.bottom_workspace_tab) {
            .content_browser => try drawProjectPanel(state, layer_context),
            .console => try console.drawConsolePanel(state),
            .command_timeline => try command_timeline.drawCommandTimelinePanel(state, layer_context),
            .ai_assistant => try drawAiAssistantTab(state),
        }
    }
}

fn drawDrawerChrome(state: *EditorState, width: f32, total_height: f32) void {
    _ = state;
    const draw_list = gui.getWindowDrawList();
    const window_pos = gui.windowPos();
    const window_max = .{
        window_pos[0] + width,
        window_pos[1] + total_height,
    };

    draw_list.addRectFilled(
        window_pos,
        window_max,
        gui.getColorU32(theme.Palette.content_browser.drawer_bg),
        drawer_corner_radius,
        0,
    );
    draw_list.addRectFilled(
        window_pos,
        .{ window_max[0], window_pos[1] + drawer_bar_height },
        gui.getColorU32(theme.Palette.content_browser.drawer_header_bg),
        drawer_corner_radius,
        0,
    );
    draw_list.addLine(
        .{ window_pos[0] + 1.0, window_pos[1] + 1.0 },
        .{ window_max[0] - 1.0, window_pos[1] + 1.0 },
        gui.getColorU32(theme.Palette.content_browser.drawer_header_highlight),
        1.0,
    );
    if (total_height > drawer_bar_height + 1.0) {
        draw_list.addLine(
            .{ window_pos[0] + 12.0, window_pos[1] + drawer_bar_height },
            .{ window_max[0] - 12.0, window_pos[1] + drawer_bar_height },
            gui.getColorU32(theme.Palette.content_browser.drawer_separator),
            1.0,
        );
    }
}

const DrawerHeightBounds = struct {
    min: f32,
    max: f32,
};

fn drawerHeightBounds(state: *const EditorState) DrawerHeightBounds {
    const hard_max_height = @max(state.viewport_extent[1] - drawer_bar_height - drawer_bottom_margin - 8.0, 48.0);
    const preferred_max_height = state.viewport_extent[1] - drawer_bar_height - drawer_bottom_margin - drawer_top_clearance;
    const max_height = std.math.clamp(preferred_max_height, 48.0, hard_max_height);
    return .{
        .min = @min(drawer_min_height, max_height),
        .max = max_height,
    };
}

fn drawDrawerTabBar(state: *EditorState, layer_context: *engine.core.LayerContext, width: f32, tab_bar_height: f32) !void {
    gui.dummy(width, tab_bar_height);
    const item_min = gui.getItemRectMin();
    const draw_list = gui.getWindowDrawList();
    const button_height: f32 = 26.0;
    const header_padding_x: f32 = 12.0;
    const button_gap: f32 = 6.0;
    const tab_labels = [_]struct { tab: @import("../core/state.zig").BottomWorkspaceTab, label: []const u8 }{
        .{ .tab = .content_browser, .label = "Content" },
        .{ .tab = .console, .label = "Console" },
        .{ .tab = .command_timeline, .label = "Timeline" },
    };
    const available_tabs_width = @max(
        width - header_padding_x * 2.0,
        180.0,
    );
    const tab_count: f32 = @floatFromInt(tab_labels.len);
    const tab_width = std.math.clamp((available_tabs_width - button_gap * (tab_count - 1.0)) / tab_count, 56.0, 120.0);
    const button_y = item_min[1] + (tab_bar_height - button_height) * 0.5;
    const tabs_start_x = item_min[0] + header_padding_x;

    for (tab_labels, 0..) |t, i| {
        const tx = tabs_start_x + @as(f32, @floatFromInt(i)) * (tab_width + button_gap);
        gui.setCursorScreenPos(.{ tx, button_y });
        if (drawTabButton(state, t.tab, t.label, tab_width)) {
            if (!state.bottom_drawer_open) {
                state.bottom_workspace_tab = t.tab;
                state.bottom_drawer_open = true;
            } else if (state.bottom_workspace_tab == t.tab) {
                state.bottom_drawer_open = false;
            } else {
                state.bottom_workspace_tab = t.tab;
            }
        }
    }

    if (state.bottom_drawer_open) {
        const grip_x = item_min[0] + (width - drawer_resize_grip_width) * 0.5;
        const grip_y = item_min[1] - 10.0;
        draw_list.addRectFilled(
            .{ grip_x, grip_y },
            .{ grip_x + drawer_resize_grip_width, grip_y + drawer_resize_grip_height },
            gui.getColorU32(theme.Palette.content_browser.drawer_resize_grip),
            drawer_resize_grip_height * 0.5,
            0,
        );

        gui.setCursorScreenPos(.{ item_min[0], item_min[1] - 18.0 });
        _ = gui.invisibleButton("##drawer_resize", width, 20.0);
        if (gui.isItemHovered() or gui.isItemActive()) {
            state.viewport_overlay_hovered = true;
            if (layer_context.input.wasMousePressed(.left)) {
                state.manipulation_started_from_ui = true;
            }
        }
        if (gui.isItemActive()) {
            const mouse = gui.mousePos();
            const height_bounds = drawerHeightBounds(state);
            const drawer_bottom = state.viewport_origin[1] + state.viewport_extent[1] - drawer_bottom_margin;
            state.bottom_drawer_height = std.math.clamp(
                drawer_bottom - mouse[1] - tab_bar_height,
                height_bounds.min,
                height_bounds.max,
            );
        }
    }
}

fn drawAiAssistantTab(state: *EditorState) !void {
    _ = state;
    gui.dummy(0.0, 8.0);
    gui.pushStyleColor(.text, theme.Palette.ai.accent);
    gui.text("Jarvis AI Assistant");
    gui.popStyleColor(1);
    gui.dummy(0.0, 4.0);
    gui.pushStyleColor(.text, theme.Palette.content_browser.drawer_assistant_body_text);
    gui.textWrapped("AI terminal is docked in the right sidebar. Use the Jarvis Terminal panel for chat, or open it via Window > Jarvis Terminal.");
    gui.popStyleColor(1);
}

fn drawWorkspaceShellHeader(state: *EditorState) !void {
    gui.pushStyleVarVec2(.item_spacing, theme.Spacing.content_browser_header_item_spacing);
    defer gui.popStyleVar(1);

    gui.pushStyleColor(.text, theme.Palette.content_browser.drawer_workspace_title_text);
    gui.text("Workspace");
    gui.popStyleColor(1);

    const available_width = gui.contentRegionAvail()[0];
    const stacked = available_width < 388.0;
    const tab_total_width = if (stacked)
        available_width
    else
        std.math.clamp(available_width * 0.58, 268.0, 456.0);

    if (!stacked) {
        gui.sameLine();
        const trailing_width = gui.contentRegionAvail()[0] - tab_total_width;
        if (trailing_width > 8.0) {
            gui.dummy(trailing_width, 1.0);
            gui.sameLine();
        }
    } else {
        gui.dummy(0.0, 4.0);
    }

    try drawBottomTabs(state, tab_total_width);
}

fn drawBottomTabs(state: *EditorState, total_width: f32) !void {
    const available_width = total_width;
    // 2 tabs: need at least 2*84 + 1*8 = 176 px for horizontal layout
    const stacked = available_width < 176.0;
    const tab_width = if (stacked)
        available_width
    else
        std.math.clamp((available_width - 8.0) / 2.0, 84.0, 140.0);
    if (drawTabButton(state, .console, "Console", tab_width)) {
        state.bottom_workspace_tab = .console;
    }
    if (!stacked) {
        gui.sameLine();
    } else {
        gui.dummy(0.0, 4.0);
    }
    if (drawTabButton(state, .command_timeline, "Timeline", tab_width)) {
        state.bottom_workspace_tab = .command_timeline;
    }
}

fn drawAssetDragPreview(
    state: *EditorState,
    entry: AssetEntry,
    payload_type: []const u8,
    payload_value: u64,
    preview_texture: *const engine.rhi.Texture,
) void {
    if (!gui.beginDragDropSourceU64(payload_type, payload_value)) {
        return;
    }
    defer gui.endDragDropSource();

    state.active_drag_payload = .{
        .kind = if (std.mem.eql(u8, payload_type, state_mod.asset_model_drag_payload))
            .asset_model
        else if (std.mem.eql(u8, payload_type, state_mod.asset_material_drag_payload))
            .asset_material
        else
            .asset_texture,
        .asset_index = @intCast(payload_value),
    };

    var preview_buffer: [384]u8 = undefined;
    const preview_text = std.fmt.bufPrint(
        &preview_buffer,
        "{s}\n{s}",
        .{ entry.name, utils.assetKindLabel(state, entry.kind) },
    ) catch entry.name;

    gui.image(preview_texture, asset_drag_preview_icon_size, asset_drag_preview_icon_size);
    gui.sameLine();
    gui.text(preview_text);
}

fn drawAssetDragSource(state: *EditorState, entry: AssetEntry, index: usize, preview_texture: *const engine.rhi.Texture) void {
    switch (entry.kind) {
        .model => drawAssetDragPreview(state, entry, state_mod.asset_model_drag_payload, @intCast(index), preview_texture),
        .material => drawAssetDragPreview(state, entry, state_mod.asset_material_drag_payload, @intCast(index), preview_texture),
        .texture => drawAssetDragPreview(state, entry, state_mod.asset_texture_drag_payload, @intCast(index), preview_texture),
        else => {},
    }
}

fn drawTabButton(state: *EditorState, tab: BottomWorkspaceTab, label: []const u8, width: f32) bool {
    const active = state.bottom_drawer_open and state.bottom_workspace_tab == tab;
    const palette = theme.Palette.content_browser.bottom_tab;

    gui.pushStyleColor(.button, palette.bg);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleColor(.text, if (active)
        theme.Palette.toolbar.active_text
    else
        theme.Palette.toolbar.idle_text);
    gui.pushStyleVarVec2(.frame_padding, theme.Spacing.content_browser_tab_padding);
    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.badge);
    const clicked = gui.buttonEx(label, width, 26.0);
    gui.popStyleVar(2);
    gui.popStyleColor(4);
    if (active) {
        const pos_min = gui.getItemRectMin();
        const pos_max = gui.getItemRectMax();
        gui.getWindowDrawList().addLine(
            .{ pos_min[0] + 8.0, pos_max[1] - 2.0 },
            .{ pos_max[0] - 8.0, pos_max[1] - 2.0 },
            gui.getColorU32(theme.Palette.toolbar.active_text),
            2.0,
        );
    }
    return clicked;
}

fn drawThumbnailPresetButton(state: *EditorState, label: []const u8, size: f32) void {
    const active = @abs(state.asset_thumbnail_size - size) < 0.5;
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.compact_icon_button_rounding);
    defer {
        gui.popStyleVar(1);
        gui.popStyleColor(3);
    }

    if (gui.buttonEx(label, 32.0, 30.0)) {
        state.asset_thumbnail_size = size;
    }
}

fn drawBreadcrumbButton(label: []const u8, active: bool, width: f32) bool {
    const palette = if (active) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, palette.button);
    gui.pushStyleColor(.button_hovered, palette.hovered);
    gui.pushStyleColor(.button_active, palette.active);

    if (active) {
        gui.pushStyleColor(.text, theme.Palette.toolbar.active_text);
    }

    gui.pushStyleVarVec2(.frame_padding, ui_icons.compact_icon_button_padding);
    gui.pushStyleVarFloat(.frame_rounding, ui_icons.compact_icon_button_rounding);

    const clicked = gui.buttonEx(label, width, 0.0);

    if (active) {
        gui.popStyleColor(1);
    }

    gui.popStyleVar(2);
    gui.popStyleColor(3);
    return clicked;
}

fn drawProjectPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    ensureSelectedAssetDirectory(state);
    try drawProjectPanelHeader(state, layer_context);

    const avail = gui.contentRegionAvail();
    const panel_width = avail[0];

    // Responsive layout based on available width
    if (panel_width < 450.0) {
        // Narrow: single column — grid/list only, no tree sidebar
        _ = gui.beginChild("project_assets_grid", 0.0, 0.0, false);
        defer gui.endChild();
        try drawAssetGrid(state, layer_context);
    } else {
        const has_selection = selectedAsset(state) != null and panel_width >= 720.0;
        const col_count: i32 = if (has_selection) 3 else 2;

        if (!gui.beginTable("project_browser_layout", col_count)) {
            return;
        }
        defer gui.endTable();

        const tree_width = std.math.clamp(panel_width * 0.22, 120.0, 220.0);
        gui.tableSetupColumn("##tree", false, tree_width);
        gui.tableSetupColumn("##grid", true, 1.0);
        if (has_selection) {
            const inspector_width = std.math.clamp(panel_width * 0.28, 200.0, 340.0);
            gui.tableSetupColumn("##inspector", false, inspector_width);
        }

        gui.tableNextRow();

        // Column 1: Folder tree
        gui.tableNextColumn();
        {
            gui.pushStyleColor(.child_bg, .{ 0.10, 0.11, 0.13, 1.0 });
            gui.pushStyleColor(.text, theme.Palette.text_primary);
            _ = gui.beginChild("project_folders_tree", 0.0, 0.0, false);
            defer {
                gui.endChild();
                gui.popStyleColor(2);
            }
            gui.spacing();
            try drawFolderTree(state, layer_context);
        }

        // Column 2: Grid/List view
        gui.tableNextColumn();
        {
            _ = gui.beginChild("project_assets_grid", 0.0, 0.0, false);
            defer gui.endChild();
            try drawAssetGrid(state, layer_context);
        }

        // Column 3: Inspector (only when wide + asset selected)
        if (has_selection) {
            gui.tableNextColumn();
            {
                gui.pushStyleColor(.child_bg, .{ 0.09, 0.10, 0.12, 1.0 });
                _ = gui.beginChild("project_inspector", 0.0, 0.0, true);
                defer {
                    gui.endChild();
                    gui.popStyleColor(1);
                }
                try drawInspectorPanel(state, layer_context);
            }
        }
    }
}

fn drawFolderTree(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selected_dir = selectedDirectory(state);
    const is_root_selected = std.mem.eql(u8, selected_dir, "/");
    const root_label = assetBrowserRootLabel(state);

    var root_label_buffer: [320]u8 = undefined;
    const root_display = std.fmt.bufPrint(&root_label_buffer, "{s}##dir_/", .{root_label}) catch root_label;

    if (is_root_selected) {
        gui.pushStyleColor(.text, .{ 0.55, 0.78, 1.0, 1.0 });
    }
    const root_open = gui.treeNodeEx(root_display, is_root_selected, false, true);
    if (is_root_selected) {
        gui.popStyleColor(1);
    }
    if (gui.isItemClicked()) {
        setSelectedAssetDirectory(state, "/");
    }
    try drawFolderContextMenu(state, layer_context, "/");

    if (root_open) {
        try drawFolderTreeRecursive(state, layer_context, "/");
        gui.treePop();
    }
}

/// Check if `child` is a direct subdirectory of `parent` in the flat directory list.
fn isDirectChildDir(child: []const u8, parent: []const u8) bool {
    if (std.mem.eql(u8, child, parent)) return false;
    if (std.mem.eql(u8, parent, "/")) {
        // Direct child of root: starts with "/" and has no more "/"
        if (child.len <= 1) return false;
        return std.mem.indexOfScalar(u8, child[1..], '/') == null;
    }
    if (!std.mem.startsWith(u8, child, parent)) return false;
    if (child.len <= parent.len or child[parent.len] != '/') return false;
    // No more "/" after parent+"/"
    return std.mem.indexOfScalar(u8, child[parent.len + 1 ..], '/') == null;
}

fn drawFolderTreeRecursive(state: *EditorState, layer_context: *engine.core.LayerContext, parent: []const u8) !void {
    const selected_dir = selectedDirectory(state);

    // Collect direct children
    for (state.asset_directories.items) |directory| {
        if (!isDirectChildDir(directory, parent)) continue;

        const label_name = directoryName(directory);
        const is_selected = std.mem.eql(u8, selected_dir, directory);

        // Folder rename inline edit
        if (state.folder_rename_active and std.mem.eql(u8, std.mem.sliceTo(state.folder_rename_original[0..], 0), directory)) {
            gui.setNextItemWidth(gui.contentRegionAvail()[0]);
            if (state.folder_rename_focus_pending) {
                gui.setKeyboardFocusHere(0);
                state.folder_rename_focus_pending = false;
            }
            if (gui.inputTextWithHintFlags("##folder_rename", "", state.folder_rename_buffer[0..], gui.InputTextFlags.enter_returns_true)) {
                try commitFolderRename(state, layer_context);
            }
            if (!gui.isItemActive() and !state.folder_rename_focus_pending) {
                state.folder_rename_active = false;
            }
            continue;
        }

        // Check if has children
        const has_children = blk: {
            for (state.asset_directories.items) |other| {
                if (isDirectChildDir(other, directory)) break :blk true;
            }
            break :blk false;
        };

        var label_buffer: [320]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "{s}##dir_{s}", .{ label_name, directory }) catch label_name;

        if (is_selected) {
            gui.pushStyleColor(.text, .{ 0.55, 0.78, 1.0, 1.0 });
        }

        const node_open = gui.treeNodeEx(label, is_selected, !has_children, false);

        if (is_selected) {
            gui.popStyleColor(1);
        }

        if (gui.isItemClicked()) {
            setSelectedAssetDirectory(state, directory);
        }

        try drawFolderContextMenu(state, layer_context, directory);

        if (node_open) {
            // Inline new-folder input when pending in this directory
            if (state.new_folder_pending and std.mem.eql(u8, selectedDirectory(state), directory)) {
                gui.setNextItemWidth(gui.contentRegionAvail()[0]);
                if (state.new_folder_focus_pending) {
                    gui.setKeyboardFocusHere(0);
                    state.new_folder_focus_pending = false;
                }
                if (gui.inputTextWithHintFlags("##new_folder_name", "", state.new_folder_name_buffer[0..], gui.InputTextFlags.enter_returns_true)) {
                    try commitNewFolder(state, layer_context);
                }
                if (!gui.isItemActive() and !state.new_folder_focus_pending) {
                    state.new_folder_pending = false;
                }
            }

            if (has_children) {
                try drawFolderTreeRecursive(state, layer_context, directory);
            }
            gui.treePop();
        }
    }
}

fn drawAssetGrid(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    switch (state.browser_view_mode) {
        .grid => try drawAssetGridView(state, layer_context),
        .list => try drawAssetListView(state, layer_context),
    }
}

fn drawAssetGridView(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const available = gui.contentRegionAvail();
    const tile_size = std.math.clamp(state.asset_thumbnail_size, 48.0, 160.0);
    const card_width = tile_size + 8.0;
    const stride = card_width + 6.0;
    const column_count = @as(i32, @intFromFloat(@max(@floor(available[0] / stride), 1.0)));

    if (!gui.beginTable("project_assets_table", column_count)) {
        return;
    }
    defer gui.endTable();

    var shown: usize = 0;
    for (state.asset_entries.items, 0..) |entry, index| {
        if (!assetVisibleInDirectory(state, entry)) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }
        if (state.asset_kind_filter) |kind_filter| {
            if (entry.kind != kind_filter) continue;
        }
        shown += 1;
        gui.tableNextColumn();
        try drawAssetCard(state, layer_context, entry, index, tile_size);
    }

    // Show empty state message if no assets
    if (shown == 0) {
        gui.tableNextColumn();
        gui.pushStyleColor(.text, theme.Palette.content_browser.drawer_empty_text);
        const selected_dir = selectedDirectory(state);
        if (std.mem.eql(u8, selected_dir, "/")) {
            gui.text("No assets in the current project content root.");
        } else {
            gui.text("Drop assets here or use Import to add files");
        }
        gui.popStyleColor(1);
    }

    // Status bar: item count
    if (shown > 0) {
        gui.separator();
        gui.pushStyleColor(.text, theme.Palette.content_browser.drawer_empty_text);
        var count_buffer: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buffer, "{d} items", .{shown}) catch "items";
        gui.text(count_text);
        gui.popStyleColor(1);
    }
}

fn drawAssetListView(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const row_height: f32 = 26.0;

    for (state.asset_entries.items, 0..) |entry, index| {
        if (!assetVisibleInDirectory(state, entry)) {
            continue;
        }
        if (!utils.assetMatchesFilter(state, entry)) {
            continue;
        }
        if (state.asset_kind_filter) |kind_filter| {
            if (entry.kind != kind_filter) continue;
        }

        var button_id_buffer: [64]u8 = undefined;
        const button_id = try std.fmt.bufPrint(&button_id_buffer, "asset_list_{d}", .{index});

        const icon_size: f32 = 18.0;
        const icon_path = assetIconPath(entry.kind);

        const selected = isAssetSelected(state, index);
        const icon_tint: [4]u8 = assetIconTint(entry.kind);
        const icon_texture = try ui_icons.ensureTintedIconTexture(
            state,
            layer_context,
            icon_path,
            icon_size,
            icon_tint,
        );
        const row_texture = if (entry.kind == .material)
            (try queueAndResolveMaterialThumbnailTexture(state, layer_context, &entry) orelse icon_texture)
        else
            icon_texture;

        if (gui.selectable(button_id, selected, false, 0.0, row_height)) {
            handleAssetSelection(state, index);
        }
        if (entry.is_directory and gui.isItemHovered() and gui.isMouseDoubleClicked(.left)) {
            setSelectedAssetDirectory(state, entry.display_path);
        }
        drawAssetDragSource(state, entry, index, row_texture);
        try drawAssetContextMenu(state, layer_context, entry, index);

        // Icon
        gui.sameLine();
        gui.image(row_texture, icon_size, icon_size);

        // Name
        gui.sameLine();
        if (state.asset_rename_index == index) {
            gui.setNextItemWidth(gui.contentRegionAvail()[0]);
            if (state.asset_rename_focus_pending) {
                gui.setKeyboardFocusHere(0);
                state.asset_rename_focus_pending = false;
            }
            if (gui.inputTextWithHintFlags("##asset_rename_list", "", state.asset_rename_buffer[0..], gui.InputTextFlags.enter_returns_true)) {
                try commitAssetRename(state, layer_context, index);
                state.asset_rename_index = null;
            }
            if (!gui.isItemActive() and !state.asset_rename_focus_pending) {
                state.asset_rename_index = null;
            }
        } else {
            if (selected) {
                gui.pushStyleColor(.text, .{ 1.0, 1.0, 1.0, 1.0 });
            }
            gui.text(entry.name);
            if (selected) {
                gui.popStyleColor(1);
            }
        }
    }
}

fn drawAssetCard(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: AssetEntry,
    index: usize,
    tile_size: f32,
) !void {
    var child_id_buffer: [64]u8 = undefined;
    const child_id = std.fmt.bufPrint(&child_id_buffer, "asset_card_{d}", .{index}) catch "card";
    const card_padding: f32 = 3.0;
    const card_width = tile_size + card_padding * 2.0;
    const name_height: f32 = 20.0;
    const card_height = tile_size + name_height + card_padding * 2.0;
    const selected = isAssetSelected(state, index);

    // ── Card background ──
    const card_bg: [4]f32 = if (selected) .{ 0.17, 0.28, 0.45, 1.0 } else .{ 0.0, 0.0, 0.0, 0.0 };
    const card_border: [4]f32 = if (selected) .{ 0.30, 0.55, 0.90, 0.9 } else .{ 0.0, 0.0, 0.0, 0.0 };
    gui.pushStyleColor(.child_bg, card_bg);
    gui.pushStyleColor(.border, card_border);
    _ = gui.beginChild(child_id, card_width, card_height, true);
    defer {
        gui.endChild();
        gui.popStyleColor(2);
    }

    const draw_list = gui.getWindowDrawList();
    const wmin = gui.windowPos();

    // ── Hover effect (subtle highlight like Unity) ──
    const win_hovered = gui.isWindowHovered();
    if (win_hovered and !selected) {
        draw_list.addRectFilled(
            wmin,
            .{ wmin[0] + card_width, wmin[1] + card_height },
            gui.getColorU32(.{ 0.20, 0.22, 0.26, 0.50 }),
            3.0,
            0,
        );
    }

    // ── Thumbnail square ──
    const thumb_x = wmin[0] + card_padding;
    const thumb_y = wmin[1] + 2.0;
    draw_list.addRectFilled(
        .{ thumb_x, thumb_y },
        .{ thumb_x + tile_size, thumb_y + tile_size },
        gui.getColorU32(.{ 0.12, 0.13, 0.15, 1.0 }),
        3.0,
        0,
    );

    // ── Resolve texture ──
    const icon_size = tile_size * 0.58;
    const icon_path = assetIconPath(entry.kind);
    const icon_tint = assetIconTint(entry.kind);
    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        icon_path,
        icon_size,
        icon_tint,
    );
    const card_texture = if (entry.kind == .material)
        (try queueAndResolveMaterialThumbnailTexture(state, layer_context, &entry) orelse icon_texture)
    else if (entry.kind == .texture and !entry.is_directory)
        (ensureImageThumbnailTexture(state, layer_context, entry.path) catch null) orelse icon_texture
    else if (entry.kind == .model and !entry.is_directory)
        (try queueAndResolveModelThumbnailTexture(state, layer_context, &entry) orelse icon_texture)
    else
        icon_texture;

    const has_thumbnail = card_texture != icon_texture;
    const display_size = if (has_thumbnail) tile_size else icon_size;
    const img_x = card_padding + @max((tile_size - display_size) * 0.5, 0.0);
    const img_y = 2.0 + @max((tile_size - display_size) * 0.5, 0.0);
    gui.setCursorPos(.{ img_x, img_y });

    var button_id_buffer: [64]u8 = undefined;
    const button_id = std.fmt.bufPrint(&button_id_buffer, "asset_thumb_{d}", .{index}) catch "thumb";

    gui.pushStyleColor(.button, .{ 0.0, 0.0, 0.0, 0.0 });
    gui.pushStyleColor(.button_hovered, .{ 0.0, 0.0, 0.0, 0.0 });
    gui.pushStyleColor(.button_active, .{ 0.0, 0.0, 0.0, 0.0 });
    if (gui.imageButton(
        button_id,
        card_texture,
        display_size,
        display_size,
        .{ 0.0, 0.0, 0.0, 0.0 },
        .{ 1.0, 1.0, 1.0, 1.0 },
    )) {
        handleAssetSelection(state, index);
    }
    gui.popStyleColor(3);

    if (entry.is_directory and gui.isItemHovered() and gui.isMouseDoubleClicked(.left)) {
        setSelectedAssetDirectory(state, entry.display_path);
    }
    if (gui.isItemHovered()) {
        var tooltip_buf: [256]u8 = undefined;
        const tooltip = std.fmt.bufPrint(&tooltip_buf, "{s}  ({s})", .{
            entry.name,
            assetKindShortLabel(entry.kind),
        }) catch entry.name;
        gui.setTooltip(tooltip);
    }
    drawAssetDragSource(state, entry, index, card_texture);
    try drawAssetContextMenu(state, layer_context, entry, index);

    // ── Small type color dot in bottom-right of thumbnail area ──
    if (!entry.is_directory and !has_thumbnail) {
        const tint = assetIconTint(entry.kind);
        const dot_color = gui.getColorU32(.{
            @as(f32, @floatFromInt(tint[0])) / 255.0,
            @as(f32, @floatFromInt(tint[1])) / 255.0,
            @as(f32, @floatFromInt(tint[2])) / 255.0,
            0.8,
        });
        const dot_x = thumb_x + tile_size - 8.0;
        const dot_y = thumb_y + tile_size - 8.0;
        draw_list.addCircleFilled(.{ dot_x, dot_y }, 4.0, dot_color, 12);
    }

    // ── Name label (centered) ──
    const label_y = tile_size + 4.0;
    if (state.asset_rename_index == index) {
        gui.setCursorPos(.{ card_padding, label_y });
        gui.setNextItemWidth(tile_size);
        if (state.asset_rename_focus_pending) {
            gui.setKeyboardFocusHere(0);
            state.asset_rename_focus_pending = false;
        }
        if (gui.inputTextWithHintFlags("##asset_rename", "", state.asset_rename_buffer[0..], gui.InputTextFlags.enter_returns_true)) {
            try commitAssetRename(state, layer_context, index);
            state.asset_rename_index = null;
        }
        if (!gui.isItemActive() and !state.asset_rename_focus_pending) {
            state.asset_rename_index = null;
        }
    } else {
        gui.setCursorPos(.{ card_padding, label_y });
        const name_color: [4]f32 = if (selected)
            .{ 1.0, 1.0, 1.0, 1.0 }
        else
            .{ 0.78, 0.80, 0.84, 1.0 };
        gui.pushStyleColor(.text, name_color);
        gui.textWrapped(entry.name);
        gui.popStyleColor(1);
    }
}

/// Inspector panel (right column): shows properties and actions for the selected asset.
fn drawInspectorPanel(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entry = selectedAsset(state) orelse return;
    const full_width = gui.contentRegionAvail()[0];

    // Ensure light text on the dark inspector background
    gui.pushStyleColor(.text, .{ 0.88, 0.90, 0.94, 1.0 });
    defer gui.popStyleColor(1);

    // ── Header: type badge + name ──
    {
        const tint = assetIconTint(entry.kind);
        const badge_color: [4]f32 = .{
            @as(f32, @floatFromInt(tint[0])) / 255.0,
            @as(f32, @floatFromInt(tint[1])) / 255.0,
            @as(f32, @floatFromInt(tint[2])) / 255.0,
            1.0,
        };
        gui.pushStyleColor(.text, badge_color);
        gui.text(utils.assetKindLabel(state, entry.kind));
        gui.popStyleColor(1);
        gui.sameLine();
        gui.text(entry.name);
    }

    gui.separator();

    // ── Properties section ──
    gui.spacing();
    gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
    gui.text("Properties");
    gui.popStyleColor(1);

    gui.labelText("Name", entry.name);
    gui.labelText("Path", entry.display_path);
    gui.labelText("Type", utils.assetKindLabel(state, entry.kind));

    gui.separator();
    gui.spacing();

    // ── Type-specific content ──
    switch (entry.kind) {
        .texture => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Preview");
            gui.popStyleColor(1);
            {
                _ = gui.beginChild("inspector_thumbnail", 0.0, 96.0, true);
                defer gui.endChild();
                try asset_preview.ensurePreviewTextureForAssetPath(state, layer_context, entry.path);
                asset_preview.drawCurrentPreviewImage(state);
            }
            gui.spacing();
            gui.textWrapped(state.text(.use_this_texture_from_details_gt_material));
        },
        .scene => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Actions");
            gui.popStyleColor(1);
            if (gui.buttonEx(state.text(.load_selected_scene), full_width, 0.0)) {
                try history.loadScenePath(state, layer_context, entry.path);
                return;
            }
            if (gui.buttonEx(state.text(.save_over_selected_scene), full_width, 0.0)) {
                history.saveScenePath(state, layer_context, entry.path);
            }
            gui.spacing();
            gui.textWrapped(state.text(.scenes_can_be_loaded_directly_or_overwritten_from_the_current_world));
        },
        .model => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Actions");
            gui.popStyleColor(1);
            if (gui.buttonEx(state.text(.instantiate_selected_model), full_width, 0.0)) {
                try history.importModelPath(state, layer_context, entry.path);
            }
            gui.spacing();
            gui.textWrapped(state.text(.models_are_imported_as_grouped_instances_with_a_movable_root_entity));
        },
        .material => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Preview");
            gui.popStyleColor(1);
            try drawMaterialAssetPreview(state, layer_context, entry);
        },
        .shader => {
            gui.textWrapped(state.text(.shader_source_preview_is_currently_metadata_only));
        },
        .script => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Actions");
            gui.popStyleColor(1);
            if (gui.buttonEx(state.text(.open_in_script_editor), full_width, 0.0)) {
                state.pending_script_open_path = entry.path;
                state.script_editor_open = true;
            }
        },
        .directory => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("Folder");
            gui.popStyleColor(1);
            if (gui.buttonEx("Open", full_width, 0.0)) {
                setSelectedAssetDirectory(state, entry.display_path);
            }
        },
        .unknown => {
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text("File");
            gui.popStyleColor(1);
            gui.textWrapped("Unknown file type. Will be included when packaging.");
        },
    }

    gui.separator();
    gui.spacing();

    // ── Common actions ──
    gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
    gui.text("Quick Actions");
    gui.popStyleColor(1);
    if (gui.buttonEx("Show in Finder", full_width, 0.0)) {
        revealInFinder(entry.path);
    }
}

// Responsive header: adapts to panel width
fn drawProjectPanelHeader(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const current = selectedDirectory(state);
    const header_width = gui.contentRegionAvail()[0];
    const compact = header_width < 400.0;

    // Ensure toolbar controls have readable light text on dark backgrounds
    gui.pushStyleColor(.text, .{ 0.88, 0.90, 0.94, 1.0 });
    defer gui.popStyleColor(1);

    // ── Row 1: [← Back] [breadcrumb...] [Search] [⊞/≡] [+] ──
    {
        const btn_h: f32 = 24.0;

        // Back button
        const at_root = std.mem.eql(u8, current, "/");
        if (at_root) {
            gui.pushStyleColor(.text, theme.Palette.content_browser.drawer_empty_text);
        }
        if (gui.buttonEx("<##nav_back", 24.0, btn_h) and !at_root) {
            const parent = directoryPath(current);
            setSelectedAssetDirectory(state, if (parent.len == 0) "/" else parent);
        }
        if (at_root) gui.popStyleColor(1);

        // Breadcrumb path
        gui.sameLine();
        gui.pushStyleColor(.button, theme.Palette.content_browser.path_bar_bg);
        defer gui.popStyleColor(1);

        const root_label = assetBrowserRootLabel(state);
        var bc_buf: [128]u8 = undefined;
        const root_bc = std.fmt.bufPrint(&bc_buf, "{s}##bc_root", .{root_label}) catch root_label;
        if (gui.buttonEx(root_bc, 0.0, btn_h)) {
            setSelectedAssetDirectory(state, "/");
        }

        var path_buffer: [256]u8 = undefined;
        var path_pos: usize = if (current.len > 0 and current[0] == '/') 1 else 0;
        while (path_pos < current.len) {
            const next_slash = std.mem.indexOfScalarPos(u8, current, path_pos, '/') orelse current.len;
            const segment = current[path_pos..next_slash];
            if (segment.len > 0) {
                gui.sameLine();
                gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
                gui.text("/");
                gui.popStyleColor(1);
                gui.sameLine();
                const segment_label = std.fmt.bufPrint(&path_buffer, "{s}##bc_{d}", .{ segment, path_pos }) catch segment;
                if (gui.buttonEx(segment_label, 0.0, btn_h)) {
                    setSelectedAssetDirectory(state, current[0..next_slash]);
                }
            }
            path_pos = next_slash + 1;
        }

        // Right-side controls: search + view toggle + import
        gui.sameLine();
        const right_remaining = gui.contentRegionAvail()[0];

        if (compact) {
            // Narrow: small search + icon-only buttons
            const search_w = @max(right_remaining - 80.0, 40.0);
            gui.setNextItemWidth(search_w);
            _ = gui.inputTextWithHint("##asset_filter", "...", state.asset_filter_buffer[0..]);
            gui.sameLine();
            const v_icon = if (state.browser_view_mode == .grid) "G" else "L";
            if (gui.buttonEx(v_icon, 24.0, btn_h)) {
                state.browser_view_mode = switch (state.browser_view_mode) {
                    .grid => .list,
                    .list => .grid,
                };
            }
            gui.sameLine();
            if (gui.buttonEx("+##import_menu", 24.0, btn_h)) {
                importFromFinder(state, layer_context);
            }
        } else {
            // Wide: full controls
            const search_w = std.math.clamp(right_remaining - 180.0, 80.0, 240.0);
            gui.setNextItemWidth(search_w);
            _ = gui.inputTextWithHint("##asset_filter", state.text(.search_assets), state.asset_filter_buffer[0..]);

            gui.sameLine();
            const view_icon = if (state.browser_view_mode == .grid) "##grid_view" else "##list_view";
            const view_short = if (state.browser_view_mode == .grid) "G" else "L";
            var view_buf: [32]u8 = undefined;
            const view_label = std.fmt.bufPrint(&view_buf, "{s}{s}", .{ view_short, view_icon }) catch "V";
            if (gui.buttonEx(view_label, 24.0, btn_h)) {
                state.browser_view_mode = switch (state.browser_view_mode) {
                    .grid => .list,
                    .list => .grid,
                };
            }

            gui.sameLine();
            if (gui.buttonEx("+##import_btn", 24.0, btn_h)) {
                importFromFinder(state, layer_context);
            }
        }
    }

    // ── Row 2: filters (collapsed into popup when narrow) ──
    if (compact) {
        // Narrow: single row with type filter + sort in one line
        const filter_label = if (state.asset_kind_filter) |kind|
            utils.assetKindLabel(state, kind)
        else
            "All";
        gui.setNextItemWidth(70.0);
        if (gui.beginCombo("##type_f", filter_label)) {
            if (gui.selectable(state.text(.all_types), state.asset_kind_filter == null, false, 0.0, 0.0)) {
                state.asset_kind_filter = null;
            }
            const kinds = [_]state_mod.AssetKind{ .scene, .model, .material, .texture, .shader, .script };
            for (kinds) |kind| {
                if (gui.selectable(utils.assetKindLabel(state, kind), state.asset_kind_filter != null and state.asset_kind_filter.? == kind, false, 0.0, 0.0)) {
                    state.asset_kind_filter = kind;
                }
            }
            gui.endCombo();
        }

        gui.sameLine();
        const sort_short: []const u8 = switch (state.asset_sort_mode) {
            .name_asc => "A-Z",
            .name_desc => "Z-A",
            .kind_asc => "Type",
            .kind_desc => "Type-",
        };
        gui.setNextItemWidth(60.0);
        if (gui.beginCombo("##sort_f", sort_short)) {
            const modes = [_]state_mod.AssetSortMode{ .name_asc, .name_desc, .kind_asc, .kind_desc };
            const labels = [_][]const u8{
                state.text(.sort_name_asc),
                state.text(.sort_name_desc),
                state.text(.sort_kind_asc),
                state.text(.sort_kind_desc),
            };
            for (modes, labels) |mode, mode_label| {
                if (gui.selectable(mode_label, state.asset_sort_mode == mode, false, 0.0, 0.0)) {
                    state.asset_sort_mode = mode;
                    sortAssetEntries(state);
                }
            }
            gui.endCombo();
        }

        gui.sameLine();
        gui.setNextItemWidth(@max(gui.contentRegionAvail()[0] - 4.0, 30.0));
        var thumb_int: i32 = @intFromFloat(state.asset_thumbnail_size);
        if (gui.sliderInt("##thumb", &thumb_int, 48, 160)) {
            state.asset_thumbnail_size = @floatFromInt(std.math.clamp(thumb_int, 48, 160));
        }
    } else {
        // Wide: full filter row
        const filter_label = if (state.asset_kind_filter) |kind|
            utils.assetKindLabel(state, kind)
        else
            state.text(.all_types);
        gui.setNextItemWidth(100.0);
        if (gui.beginCombo("##asset_type_filter", filter_label)) {
            if (gui.selectable(state.text(.all_types), state.asset_kind_filter == null, false, 0.0, 0.0)) {
                state.asset_kind_filter = null;
            }
            const kinds = [_]state_mod.AssetKind{ .scene, .model, .material, .texture, .shader, .script };
            for (kinds) |kind| {
                const kind_label = utils.assetKindLabel(state, kind);
                if (gui.selectable(kind_label, state.asset_kind_filter != null and state.asset_kind_filter.? == kind, false, 0.0, 0.0)) {
                    state.asset_kind_filter = kind;
                }
            }
            gui.endCombo();
        }

        gui.sameLine();
        const sort_label: []const u8 = switch (state.asset_sort_mode) {
            .name_asc => state.text(.sort_name_asc),
            .name_desc => state.text(.sort_name_desc),
            .kind_asc => state.text(.sort_kind_asc),
            .kind_desc => state.text(.sort_kind_desc),
        };
        gui.setNextItemWidth(100.0);
        if (gui.beginCombo("##asset_sort_mode", sort_label)) {
            const modes = [_]state_mod.AssetSortMode{ .name_asc, .name_desc, .kind_asc, .kind_desc };
            const labels = [_][]const u8{
                state.text(.sort_name_asc),
                state.text(.sort_name_desc),
                state.text(.sort_kind_asc),
                state.text(.sort_kind_desc),
            };
            for (modes, labels) |mode, mode_label| {
                if (gui.selectable(mode_label, state.asset_sort_mode == mode, false, 0.0, 0.0)) {
                    state.asset_sort_mode = mode;
                    sortAssetEntries(state);
                }
            }
            gui.endCombo();
        }

        gui.sameLine();
        gui.setNextItemWidth(std.math.clamp(gui.contentRegionAvail()[0] - 8.0, 60.0, 120.0));
        var thumb_int: i32 = @intFromFloat(state.asset_thumbnail_size);
        if (gui.sliderInt("##asset_thumb_size", &thumb_int, 48, 160)) {
            state.asset_thumbnail_size = @floatFromInt(std.math.clamp(thumb_int, 48, 160));
        }
    }

    gui.separator();
}

fn drawProjectToolbar(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const width = gui.contentRegionAvail()[0];
    const stacked_primary = width < 232.0;
    const primary_button_width = if (stacked_primary)
        width
    else if (width >= 680.0)
        116.0
    else
        @max((width - 8.0) * 0.5, 100.0);

    if (gui.buttonEx(state.text(.refresh), primary_button_width, 30.0)) {
        try refreshAssetBrowser(state, layer_context);
    }
    if (!stacked_primary) {
        gui.sameLine();
    } else {
        gui.dummy(0.0, 6.0);
    }
    if (gui.buttonEx(state.text(.quick_save), primary_button_width, 30.0)) {
        history.saveScene(state, layer_context);
    }

    gui.dummy(0.0, 8.0);
    const thumb_columns = layout.responsiveButtonColumns(3, 32.0);
    drawThumbnailPresetButton(state, "S", 84.0);
    layout.advanceResponsiveRow(1, thumb_columns);
    drawThumbnailPresetButton(state, "M", 104.0);
    layout.advanceResponsiveRow(2, thumb_columns);
    drawThumbnailPresetButton(state, "L", 132.0);

    gui.dummy(0.0, 6.0);
    const compact_thumbnails = width < 320.0;
    _ = layout.drawResponsivePropertyLabel(state.text(.thumbnails), if (compact_thumbnails) width else 108.0);
    var thumbnail_size = state.asset_thumbnail_size;
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat("##asset_thumbnail_size", &thumbnail_size, 1.0, 72.0, 160.0)) {
        state.asset_thumbnail_size = std.math.clamp(thumbnail_size, 72.0, 160.0);
    }

    // View mode toggle (Grid / List)
    gui.dummy(0.0, 8.0);
    const view_mode_palette_grid = if (state.browser_view_mode == .grid) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    const view_mode_palette_list = if (state.browser_view_mode == .list) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;

    gui.pushStyleColor(.button, view_mode_palette_grid.button);
    gui.pushStyleColor(.button_hovered, view_mode_palette_grid.hovered);
    gui.pushStyleColor(.button_active, view_mode_palette_grid.active);
    if (gui.buttonEx(state.text(.grid_view), 54.0, 30.0)) {
        state.browser_view_mode = .grid;
    }
    gui.popStyleColor(3);

    gui.pushStyleColor(.button, view_mode_palette_list.button);
    gui.pushStyleColor(.button_hovered, view_mode_palette_list.hovered);
    gui.pushStyleColor(.button_active, view_mode_palette_list.active);
    if (gui.buttonEx(state.text(.list_view), 54.0, 30.0)) {
        state.browser_view_mode = .list;
    }
    gui.popStyleColor(3);
}

fn drawBreadcrumbs(state: *EditorState) !void {
    const current = selectedDirectory(state);
    const stacked = gui.contentRegionAvail()[0] < 360.0;
    var start: usize = 0;
    var crumb_index: usize = 0;

    while (start <= current.len) {
        const next_slash = std.mem.indexOfScalarPos(u8, current, start, '/') orelse current.len;
        const crumb_path = current[0..next_slash];
        const crumb_label = if (crumb_index == 0)
            (if (std.mem.eql(u8, current, "/")) "/" else state.text(.assets_menu))
        else
            directoryName(crumb_path);
        const is_current = next_slash == current.len;
        var stacked_label_buffer: [160]u8 = undefined;
        const button_label = if (stacked and crumb_index > 0)
            try std.fmt.bufPrint(&stacked_label_buffer, "> {s}", .{crumb_label})
        else
            crumb_label;
        if (drawBreadcrumbButton(button_label, is_current, if (stacked) gui.contentRegionAvail()[0] else 0.0)) {
            setSelectedAssetDirectory(state, crumb_path);
        }

        if (next_slash == current.len) {
            break;
        }
        if (!stacked) {
            gui.sameLine();
            gui.pushStyleColor(.text, theme.Palette.content_browser.breadcrumb_separator_text);
            gui.text(">");
            gui.popStyleColor(1);
            gui.sameLine();
        } else {
            gui.dummy(0.0, 4.0);
        }

        start = next_slash + 1;
        crumb_index += 1;
    }
}

fn sortAssetEntries(state: *EditorState) void {
    switch (state.asset_sort_mode) {
        .name_asc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                // Directories always sort first
                if (a.is_directory != b.is_directory) return a.is_directory;
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
        .name_desc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                return std.mem.lessThan(u8, b.name, a.name);
            }
        }.f),
        .kind_asc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                if (@intFromEnum(a.kind) != @intFromEnum(b.kind))
                    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
        .kind_desc => std.sort.heap(AssetEntry, state.asset_entries.items, {}, struct {
            fn f(_: void, a: AssetEntry, b: AssetEntry) bool {
                if (a.is_directory != b.is_directory) return a.is_directory;
                if (@intFromEnum(a.kind) != @intFromEnum(b.kind))
                    return @intFromEnum(a.kind) > @intFromEnum(b.kind);
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.f),
    }
}

fn handleAssetSelection(state: *EditorState, index: usize) void {
    const shift = gui.keyShift();
    const ctrl = gui.keyCtrl(); // Cmd on macOS

    if (shift and state.asset_last_selected_index != null) {
        // Range select
        const from = state.asset_last_selected_index.?;
        const lo = @min(from, index);
        const hi = @min(@max(from, index), 4095);
        if (!ctrl) {
            // Clear previous selection if not holding Ctrl/Cmd
            state.asset_selected_set = std.StaticBitSet(4096).initEmpty();
        }
        var i: usize = lo;
        while (i <= hi) : (i += 1) {
            state.asset_selected_set.set(i);
        }
    } else if (ctrl) {
        // Toggle individual
        state.asset_selected_set.toggle(index);
    } else {
        // Plain click — select only this
        state.asset_selected_set = std.StaticBitSet(4096).initEmpty();
        state.asset_selected_set.set(index);
    }

    state.selected_asset_index = index;
    state.asset_last_selected_index = index;
}

fn isAssetSelected(state: *const EditorState, index: usize) bool {
    if (index >= 4096) return state.selected_asset_index == index;
    return state.asset_selected_set.isSet(index);
}

fn assetIconPath(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => ui_icons.paths.asset.scene,
        .model => ui_icons.paths.asset.model,
        .material => ui_icons.paths.asset.material,
        .texture => ui_icons.paths.asset.texture,
        .shader => ui_icons.paths.asset.shader,
        .script => ui_icons.paths.asset.script,
        .directory => ui_icons.paths.asset.directory,
        .unknown => ui_icons.paths.asset.unknown,
    };
}

fn assetIconTint(kind: AssetKind) [4]u8 {
    return switch (kind) {
        .scene => .{ 100, 160, 255, 255 }, // Unity-style blue (prefab/scene)
        .model => .{ 180, 220, 255, 255 }, // Light blue (3D model)
        .material => .{ 186, 228, 196, 255 }, // Mint green
        .texture => .{ 255, 214, 150, 255 }, // Light orange
        .shader => .{ 214, 176, 255, 255 }, // Lavender
        .script => .{ 120, 200, 80, 255 }, // Unity C# green
        .directory => .{ 255, 210, 100, 255 }, // Golden yellow
        .unknown => .{ 180, 180, 180, 255 }, // Gray
    };
}

fn assetKindShortLabel(kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => "Scene",
        .model => "Model",
        .material => "Material",
        .texture => "Texture",
        .shader => "Shader",
        .script => "Script",
        .directory => "Folder",
        .unknown => "File",
    };
}

fn assetKindForRecordType(record_type: engine.assets.AssetType) ?AssetKind {
    return switch (record_type) {
        .scene => .scene,
        .model => .model,
        .material => .material,
        .texture => .texture,
        .shader => .shader,
        .script => .script,
        else => null,
    };
}

fn selectedDirectory(state: *const EditorState) []const u8 {
    const value = utils.zeroTerminatedSlice(state.asset_directory_buffer[0..]);
    return if (value.len == 0) "/" else value;
}

fn ensureSelectedAssetDirectory(state: *EditorState) void {
    if (selectedDirectory(state).len == 0 or state.asset_directories.items.len == 0) {
        setSelectedAssetDirectory(state, "/");
        return;
    }
    for (state.asset_directories.items) |directory| {
        if (std.mem.eql(u8, directory, selectedDirectory(state))) {
            return;
        }
    }
    setSelectedAssetDirectory(state, "/");
}

fn setSelectedAssetDirectory(state: *EditorState, path: []const u8) void {
    @memset(state.asset_directory_buffer[0..], 0);
    const copy_len = @min(path.len, state.asset_directory_buffer.len - 1);
    @memcpy(state.asset_directory_buffer[0..copy_len], path[0..copy_len]);
}

fn assetVisibleInDirectory(state: *const EditorState, entry: AssetEntry) bool {
    const selected_dir = selectedDirectory(state);
    const parent_dir = directoryPath(entry.display_path);
    // Show only direct children of the selected directory (Godot/Unity-style).
    if (std.mem.eql(u8, selected_dir, "/")) {
        return parent_dir.len == 0;
    }
    return std.mem.eql(u8, selected_dir, parent_dir);
}

fn directoryPath(path: []const u8) []const u8 {
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return path[0..slash_index];
}

fn directoryName(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) {
        return "/";
    }
    const slash_index = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash_index + 1 ..];
}

fn directoryDepth(path: []const u8) usize {
    if (std.mem.eql(u8, path, "/")) {
        return 0;
    }
    var depth: usize = 0;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            depth += 1;
        }
    }
    return depth;
}

fn assetBrowserRootPath(state: *const EditorState) []const u8 {
    const project_content_path = state.projectContentPath();
    return if (project_content_path.len != 0) project_content_path else "assets";
}

fn assetBrowserRootLabel(state: *const EditorState) []const u8 {
    return if (state.projectContentPath().len != 0) "Content" else state.text(.assets_menu);
}

fn assetBrowserSnapshotPathAlloc(allocator: std.mem.Allocator, state: *const EditorState) ![]u8 {
    const project_root_path = state.projectPath();
    if (project_root_path.len != 0) {
        return std.fs.path.join(allocator, &.{ project_root_path, "Derived", "asset_registry.json" });
    }
    return allocator.dupe(u8, "assets/derived/asset_registry.json");
}

fn assetDisplayPathAlloc(allocator: std.mem.Allocator, state: *const EditorState, source_path: []const u8) ![]u8 {
    const root_path = assetBrowserRootPath(state);
    if (std.mem.startsWith(u8, source_path, root_path)) {
        var relative = source_path[root_path.len..];
        while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) {
            relative = relative[1..];
        }
        return allocator.dupe(u8, relative);
    }

    if (std.mem.startsWith(u8, source_path, "assets/")) {
        return allocator.dupe(u8, source_path[7..]);
    }
    if (std.mem.eql(u8, source_path, "assets")) {
        return allocator.dupe(u8, "/");
    }

    return allocator.dupe(u8, source_path);
}

pub fn selectedAssetCanUseAsTexture(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .texture;
}

fn materialHandleForAssetEntryInResources(
    resources: *const engine.assets.ResourceLibrary,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    if (entry.kind != .material) {
        return null;
    }
    return resources.materialHandleByAssetId(entry.id);
}

pub fn materialHandleForAssetEntry(
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) ?engine.assets.MaterialHandle {
    return materialHandleForAssetEntryInResources(layer_context.world.assets(), entry);
}

fn syncEntityMaterialFromResource(
    entity: *engine.scene.Entity,
    material_handle: engine.assets.MaterialHandle,
    material_resource: *const engine.assets.MaterialResource,
) bool {
    if (entity.material) |*material_component| {
        var changed = false;
        if (material_component.handle != material_handle) {
            material_component.handle = material_handle;
            changed = true;
        }
        if (material_component.shading != material_resource.shading) {
            material_component.shading = material_resource.shading;
            changed = true;
        }
        if (!std.meta.eql(material_component.base_color_factor, material_resource.base_color_factor)) {
            material_component.base_color_factor = material_resource.base_color_factor;
            changed = true;
        }
        return changed;
    }

    entity.material = .{
        .handle = material_handle,
        .shading = material_resource.shading,
        .base_color_factor = material_resource.base_color_factor,
    };
    return true;
}

fn drawMaterialAssetPreview(state: *EditorState, layer_context: *engine.core.LayerContext, entry: *const AssetEntry) !void {
    const preview_texture = try queueAndResolveMaterialThumbnailTexture(state, layer_context, entry);
    try drawMaterialThumbnailPreview(state, layer_context, preview_texture);

    const material_handle = materialHandleForAssetEntry(layer_context, entry);

    if (material_handle) |handle| {
        // Material is loaded - show preview info
        if (layer_context.world.assets().material(handle)) |material_resource| {
            // Show shading model
            const shading_label = switch (material_resource.shading) {
                .unlit => "Unlit",
                .lambert => "Lambert",
                .pbr_metallic_roughness => "PBR Metallic",
            };
            gui.labelText("Shading", shading_label);

            // Show base color
            const color = material_resource.base_color_factor;
            var color_text: [32]u8 = undefined;
            const color_str = try std.fmt.bufPrint(&color_text, "R:{d:.2} G:{d:.2} B:{d:.2}", .{ color[0], color[1], color[2] });
            gui.labelText("Base Color", color_str);

            // Show texture info
            if (material_resource.base_color_texture != null) {
                gui.labelText("Texture", "Assigned");
            } else {
                gui.labelText("Texture", "None");
            }
        }

        // Show apply button if entity is selected
        if (layer_context.renderer.selectedEntity()) |entity_id| {
            gui.dummy(0.0, 8.0);
            if (gui.buttonEx(state.text(.apply_material), gui.contentRegionAvail()[0], 0.0)) {
                _ = try applyMaterialAssetToEntity(state, layer_context, entry, entity_id);
            }
        }
    } else {
        // Material not loaded - show placeholder
        gui.textWrapped(state.text(.material_asset_not_loaded_in_current_world));
    }

    gui.textWrapped(state.text(.drop_material_here));
}

fn drawMaterialThumbnailPreview(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    texture: ?*const engine.rhi.Texture,
) !void {
    _ = gui.beginChild("project_material_thumbnail", 0.0, 116.0, true);
    defer gui.endChild();

    const available = gui.contentRegionAvail();
    const preview_size = std.math.clamp(@min(available[0], available[1]) - 8.0, 72.0, 104.0);
    const offset_x = @max((available[0] - preview_size) * 0.5, 0.0);
    const offset_y = @max((available[1] - preview_size) * 0.5, 0.0);
    gui.setCursorPos(.{ offset_x, offset_y });

    if (texture) |resolved| {
        gui.image(resolved, preview_size, preview_size);
        return;
    }

    const fallback_size = preview_size * 0.62;
    const fallback_offset_x = @max((available[0] - fallback_size) * 0.5, 0.0);
    const fallback_offset_y = @max((available[1] - fallback_size) * 0.5, 0.0);
    gui.setCursorPos(.{ fallback_offset_x, fallback_offset_y });
    const fallback_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.toolbar.material,
        fallback_size,
        assetIconTint(.material),
    );
    gui.image(fallback_texture, fallback_size, fallback_size);
}

pub fn applyMaterialAssetToEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
    entity_id: engine.scene.EntityId,
) !bool {
    const material_handle = materialHandleForAssetEntry(layer_context, entry) orelse {
        if (!builtin.is_test and entry.kind == .material) {
            std.log.warn("material asset '{s}' is not loaded into the current world", .{entry.path});
        }
        return false;
    };
    if (state.editor_camera != null and entity_id == state.editor_camera.?) {
        return false;
    }
    if (utils.isEntityFrozen(state, entity_id) or utils.isEntitySelectionLocked(state, entity_id)) {
        return false;
    }

    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const material_resource = layer_context.world.assets().material(material_handle) orelse return false;
    if (!syncEntityMaterialFromResource(entity, material_handle, material_resource)) {
        return false;
    }

    try history.captureSnapshot(state, layer_context);
    return true;
}

pub fn refreshAssetBrowser(state: *EditorState, _: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    clearAssetBrowser(state);

    // Also refresh the asset registry in the background for cooked-model lookups.
    if (state.asset_registry) |*registry| {
        const root_path = assetBrowserRootPath(state);
        registry.refreshProject(root_path) catch |err| {
            std.log.warn("failed to refresh asset registry: {s}", .{@errorName(err)});
        };
        const snapshot_path = assetBrowserSnapshotPathAlloc(allocator, state) catch null;
        if (snapshot_path) |sp| {
            defer allocator.free(sp);
            registry.writeSnapshotToPath(sp) catch {};
        }
    }

    // Scan actual file system for Godot/Unity-style browsing.
    const root_path = assetBrowserRootPath(state);
    try scanFileSystemEntries(state, allocator, root_path);

    sortAssetEntries(state);
    try rebuildAssetDirectories(state);

    if (state.selected_asset_index) |selected_index| {
        if (selected_index >= state.asset_entries.items.len) {
            state.selected_asset_index = null;
        }
    }
}

/// Scan the actual file system and populate asset_entries with ALL files and directories.
fn scanFileSystemEntries(state: *EditorState, allocator: std.mem.Allocator, root_path: []const u8) !void {
    var root_dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer root_dir.close();

    var walker = try root_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        // Skip hidden files, .meta files, and derived/ directory.
        if (std.mem.startsWith(u8, entry.path, ".")) continue;
        if (entry.basename.len > 0 and entry.basename[0] == '.') continue;
        if (std.mem.startsWith(u8, entry.path, "derived/") or std.mem.startsWith(u8, entry.path, "Derived/")) continue;
        if (std.mem.endsWith(u8, entry.path, ".meta")) continue;

        const is_dir = (entry.kind == .directory);
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        errdefer allocator.free(full_path);

        const display_path = try std.fmt.allocPrint(allocator, "/{s}", .{entry.path});
        errdefer allocator.free(display_path);

        const name = try allocator.dupe(u8, entry.basename);
        errdefer allocator.free(name);

        const kind: state_mod.AssetKind = if (is_dir)
            .directory
        else
            assetKindFromPath(entry.path);

        try state.asset_entries.append(allocator, .{
            .id = try allocator.dupe(u8, ""),
            .path = full_path,
            .display_path = display_path,
            .name = name,
            .kind = kind,
            .is_directory = is_dir,
        });
    }
}

/// Classify a file path into an AssetKind based on its extension.
fn assetKindFromPath(path: []const u8) state_mod.AssetKind {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return .unknown;
    if (std.mem.eql(u8, ext, ".gltf") or std.mem.eql(u8, ext, ".glb") or std.mem.eql(u8, ext, ".obj") or std.mem.eql(u8, ext, ".fbx")) return .model;
    if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg") or std.mem.eql(u8, ext, ".hdr") or std.mem.eql(u8, ext, ".svg") or std.mem.eql(u8, ext, ".exr")) return .texture;
    if (std.mem.eql(u8, ext, ".guava_scene") or std.mem.eql(u8, ext, ".json")) return .scene;
    if (std.mem.eql(u8, ext, ".glsl") or std.mem.eql(u8, ext, ".spv") or std.mem.eql(u8, ext, ".msl")) return .shader;
    if (std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".cs")) return .script;
    if (std.mem.eql(u8, ext, ".guava_material")) return .material;
    return .unknown;
}

fn rebuildAssetDirectories(state: *EditorState) !void {
    const allocator = state.allocator orelse return;
    try appendDirectoryIfMissing(state, "/");
    for (state.asset_entries.items) |entry| {
        try addDirectoryPath(state, directoryPath(entry.display_path));
        // Also add directories themselves (not just parent paths)
        if (entry.is_directory) {
            try addDirectoryPath(state, entry.display_path);
        }
    }

    std.sort.heap([]u8, state.asset_directories.items, {}, lessThanDirectory);
    if (state.asset_directories.items.len == 0) {
        const root_directory = try allocator.dupe(u8, "/");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
    }
    ensureSelectedAssetDirectory(state);
}

fn addDirectoryPath(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    var cursor: usize = 0;
    while (cursor < path.len) : (cursor += 1) {
        if (path[cursor] != '/') {
            continue;
        }
        if (cursor == 0) {
            continue;
        }
        try appendDirectoryIfMissing(state, path[0..cursor]);
    }
    try appendDirectoryIfMissing(state, path);
    if (state.asset_directories.items.len == 0) {
        const root_directory = try allocator.dupe(u8, "/");
        errdefer allocator.free(root_directory);
        try state.asset_directories.append(allocator, root_directory);
    }
}

fn appendDirectoryIfMissing(state: *EditorState, path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.asset_directories.items) |existing| {
        if (std.mem.eql(u8, existing, path)) {
            return;
        }
    }
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try state.asset_directories.append(allocator, owned_path);
}

fn lessThanDirectory(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Load an image file (PNG/JPG) and cache as a GPU thumbnail texture.
fn ensureImageThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    file_path: []const u8,
) !*const engine.rhi.Texture {
    // Check cache for existing thumbnail
    for (state.image_thumbnail_textures.items) |*entry| {
        if (std.mem.eql(u8, entry.path, file_path)) {
            return &entry.texture;
        }
    }
    // Check if this path previously failed (don't retry)
    for (state.image_thumbnail_failed.items) |failed_path| {
        if (std.mem.eql(u8, failed_path, file_path)) {
            return error.ThumbnailLoadFailed;
        }
    }

    const allocator = state.allocator orelse return error.NoAllocator;

    // Read file from disk (limit to 8MB to avoid loading huge textures)
    const encoded = std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024 * 1024) catch |err| {
        const owned_path = try allocator.dupe(u8, file_path);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer allocator.free(encoded);

    // Decode with stb_image
    var decoded = engine.assets.decodeImageRgba8(allocator, encoded) catch |err| {
        const owned_path = try allocator.dupe(u8, file_path);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer decoded.deinit();

    // Downscale to max 256px for thumbnail (simple 2x2 box filter)
    const max_thumb_dim: u32 = 256;
    var thumb_w = decoded.width;
    var thumb_h = decoded.height;
    var thumb_pixels = decoded.pixels;
    var downscaled_buf: ?[]u8 = null;
    defer if (downscaled_buf) |buf| allocator.free(buf);

    while (thumb_w > max_thumb_dim or thumb_h > max_thumb_dim) {
        const new_w = @max(thumb_w / 2, 1);
        const new_h = @max(thumb_h / 2, 1);
        if (new_w == 0 or new_h == 0) break;
        const new_buf = try allocator.alloc(u8, new_w * new_h * 4);
        var y: u32 = 0;
        while (y < new_h) : (y += 1) {
            var x: u32 = 0;
            while (x < new_w) : (x += 1) {
                const dst = (y * new_w + x) * 4;
                const sy = @min(y * 2, thumb_h - 1);
                const sx = @min(x * 2, thumb_w - 1);
                const sy1 = @min(sy + 1, thumb_h - 1);
                const sx1 = @min(sx + 1, thumb_w - 1);
                const s00 = (sy * thumb_w + sx) * 4;
                const s10 = (sy * thumb_w + sx1) * 4;
                const s01 = (sy1 * thumb_w + sx) * 4;
                const s11 = (sy1 * thumb_w + sx1) * 4;
                var c: u32 = 0;
                while (c < 4) : (c += 1) {
                    const avg = (@as(u32, thumb_pixels[s00 + c]) +
                        @as(u32, thumb_pixels[s10 + c]) +
                        @as(u32, thumb_pixels[s01 + c]) +
                        @as(u32, thumb_pixels[s11 + c]) + 2) / 4;
                    new_buf[dst + c] = @intCast(avg);
                }
            }
        }
        if (downscaled_buf) |old| allocator.free(old);
        downscaled_buf = new_buf;
        thumb_pixels = new_buf;
        thumb_w = new_w;
        thumb_h = new_h;
    }

    // Create GPU texture
    var texture = try layer_context.rhi().createTexture(.{
        .width = thumb_w,
        .height = thumb_h,
        .format = .rgba8_unorm,
        .usage = engine.rhi.TextureUsage.sampler,
    });
    errdefer layer_context.rhi().releaseTexture(&texture);

    try layer_context.rhi().uploadTextureData(&texture, thumb_pixels, thumb_w, thumb_h);

    // Cache it
    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);

    try state.image_thumbnail_textures.append(allocator, .{
        .path = owned_path,
        .texture = texture,
    });
    state.image_thumbnail_device = layer_context.rhi();

    return &state.image_thumbnail_textures.items[state.image_thumbnail_textures.items.len - 1].texture;
}

/// For a GLTF model file, extract the first material's baseColorTexture image URI,
/// resolve the full path, and load it as a thumbnail via ensureImageThumbnailTexture.
fn queueAndResolveModelThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) !?*const engine.rhi.Texture {
    if (entry.kind != .model or entry.is_directory) return null;
    try queueModelThumbnailRequest(state, entry.path);
    return layer_context.renderer.modelThumbnailTexture(entry.path);
}

fn queueModelThumbnailRequest(state: *EditorState, model_path: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.model_thumbnail_queue.items) |existing| {
        if (std.mem.eql(u8, existing, model_path)) return;
    }
    const queued = try allocator.dupe(u8, model_path);
    errdefer allocator.free(queued);
    try state.model_thumbnail_queue.append(allocator, queued);
}

pub fn flushModelThumbnailRequests(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    for (state.model_thumbnail_queue.items) |model_path| {
        defer allocator.free(model_path);
        try layer_context.renderer.requestModelThumbnail(model_path, layer_context.frame_index);
    }
    state.model_thumbnail_queue.clearRetainingCapacity();
}

/// Like ensureImageThumbnailTexture but caches under a different key than the actual image path.
fn ensureImageThumbnailTextureAs(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    file_path: []const u8,
    cache_key: []const u8,
) !*const engine.rhi.Texture {
    // Check cache under cache_key
    for (state.image_thumbnail_textures.items) |*entry| {
        if (std.mem.eql(u8, entry.path, cache_key)) {
            return &entry.texture;
        }
    }

    const allocator = state.allocator orelse return error.NoAllocator;

    const encoded = std.fs.cwd().readFileAlloc(allocator, file_path, 32 * 1024 * 1024) catch |err| {
        const owned_path = try allocator.dupe(u8, cache_key);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer allocator.free(encoded);

    var decoded = engine.assets.decodeImageRgba8(allocator, encoded) catch |err| {
        const owned_path = try allocator.dupe(u8, cache_key);
        try state.image_thumbnail_failed.append(allocator, owned_path);
        return err;
    };
    defer decoded.deinit();

    const max_thumb_dim: u32 = 256;
    var thumb_w = decoded.width;
    var thumb_h = decoded.height;
    var thumb_pixels = decoded.pixels;
    var downscaled_buf: ?[]u8 = null;
    defer if (downscaled_buf) |buf| allocator.free(buf);

    while (thumb_w > max_thumb_dim or thumb_h > max_thumb_dim) {
        const new_w = @max(thumb_w / 2, 1);
        const new_h = @max(thumb_h / 2, 1);
        if (new_w == 0 or new_h == 0) break;
        const new_buf = try allocator.alloc(u8, new_w * new_h * 4);
        var y: u32 = 0;
        while (y < new_h) : (y += 1) {
            var x: u32 = 0;
            while (x < new_w) : (x += 1) {
                const dst = (y * new_w + x) * 4;
                const sy = @min(y * 2, thumb_h - 1);
                const sx = @min(x * 2, thumb_w - 1);
                const sy1 = @min(sy + 1, thumb_h - 1);
                const sx1 = @min(sx + 1, thumb_w - 1);
                const s00 = (sy * thumb_w + sx) * 4;
                const s10 = (sy * thumb_w + sx1) * 4;
                const s01 = (sy1 * thumb_w + sx) * 4;
                const s11 = (sy1 * thumb_w + sx1) * 4;
                var c: u32 = 0;
                while (c < 4) : (c += 1) {
                    const avg = (@as(u32, thumb_pixels[s00 + c]) +
                        @as(u32, thumb_pixels[s10 + c]) +
                        @as(u32, thumb_pixels[s01 + c]) +
                        @as(u32, thumb_pixels[s11 + c]) + 2) / 4;
                    new_buf[dst + c] = @intCast(avg);
                }
            }
        }
        if (downscaled_buf) |old| allocator.free(old);
        downscaled_buf = new_buf;
        thumb_pixels = new_buf;
        thumb_w = new_w;
        thumb_h = new_h;
    }

    var texture = try layer_context.rhi().createTexture(.{
        .width = thumb_w,
        .height = thumb_h,
        .format = .rgba8_unorm,
        .usage = engine.rhi.TextureUsage.sampler,
    });
    errdefer layer_context.rhi().releaseTexture(&texture);

    try layer_context.rhi().uploadTextureData(&texture, thumb_pixels, thumb_w, thumb_h);

    const owned_path = try allocator.dupe(u8, cache_key);
    errdefer allocator.free(owned_path);

    try state.image_thumbnail_textures.append(allocator, .{
        .path = owned_path,
        .texture = texture,
    });
    state.image_thumbnail_device = layer_context.rhi();

    return &state.image_thumbnail_textures.items[state.image_thumbnail_textures.items.len - 1].texture;
}

pub fn clearAssetBrowser(state: *EditorState) void {
    clearMaterialThumbnailRequestQueue(state);
    const allocator = state.allocator orelse return;
    for (state.asset_entries.items) |entry| {
        allocator.free(entry.id);
        allocator.free(entry.path);
        allocator.free(entry.display_path);
        allocator.free(entry.name);
    }
    state.asset_entries.deinit(allocator);
    state.asset_entries = .empty;

    for (state.asset_directories.items) |directory| {
        allocator.free(directory);
    }
    state.asset_directories.deinit(allocator);
    state.asset_directories = .empty;

    state.selected_asset_index = null;
    state.asset_selected_set = std.StaticBitSet(4096).initEmpty();
    state.asset_last_selected_index = null;
}

pub fn selectedAsset(state: *EditorState) ?*const AssetEntry {
    const index = state.selected_asset_index orelse return null;
    if (index >= state.asset_entries.items.len) {
        state.selected_asset_index = null;
        return null;
    }
    return &state.asset_entries.items[index];
}

pub fn selectedAssetCanLoadScene(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .scene;
}

pub fn selectedAssetCanImportModel(state: *EditorState) bool {
    const entry = selectedAsset(state) orelse return false;
    return entry.kind == .model;
}

pub fn instantiateSelectedAsset(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entry = selectedAsset(state) orelse return;
    switch (entry.kind) {
        .scene => try history.loadScenePath(state, layer_context, entry.path),
        .model => try history.importModelPath(state, layer_context, entry.path),
        else => {},
    }
}

fn queueAndResolveMaterialThumbnailTexture(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entry: *const AssetEntry,
) !?*const engine.rhi.Texture {
    if (entry.kind != .material) {
        return null;
    }
    try queueMaterialThumbnailRequest(state, entry.id);
    return layer_context.renderer.materialThumbnailTexture(entry.id);
}

fn queueMaterialThumbnailRequest(state: *EditorState, asset_id: []const u8) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |existing| {
        if (std.mem.eql(u8, existing, asset_id)) {
            return;
        }
    }
    const queued_asset_id = try allocator.dupe(u8, asset_id);
    errdefer allocator.free(queued_asset_id);
    try state.material_thumbnail_queue.append(allocator, queued_asset_id);
}

pub fn flushMaterialThumbnailRequests(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        defer allocator.free(asset_id);
        try layer_context.renderer.requestMaterialThumbnail(layer_context.scene, asset_id, layer_context.frame_index);
    }
    state.material_thumbnail_queue.clearRetainingCapacity();
}

pub fn clearMaterialThumbnailRequestQueue(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.material_thumbnail_queue.items) |asset_id| {
        allocator.free(asset_id);
    }
    state.material_thumbnail_queue.deinit(allocator);
    state.material_thumbnail_queue = .empty;
}

// ---------------------------------------------------------------------------
// Context menus and file operations
// ---------------------------------------------------------------------------

fn drawAssetContextMenu(state: *EditorState, layer_context: *engine.core.LayerContext, entry: AssetEntry, index: usize) !void {
    var popup_id_buffer: [64]u8 = undefined;
    const popup_id = try std.fmt.bufPrint(&popup_id_buffer, "##asset_ctx_{d}", .{index});
    if (gui.beginPopupContextItem(popup_id)) {
        defer gui.endPopup();

        // ── Type-specific primary actions ──
        switch (entry.kind) {
            .scene => {
                if (gui.menuItem("Load Scene", null, false, true)) {
                    try history.loadScenePath(state, layer_context, entry.path);
                }
                if (gui.menuItem("Save Over Scene", null, false, true)) {
                    history.saveScenePath(state, layer_context, entry.path);
                }
                gui.separator();
            },
            .model => {
                if (gui.menuItem("Instantiate Model", null, false, true)) {
                    try history.importModelPath(state, layer_context, entry.path);
                }
                gui.separator();
            },
            .script => {
                if (gui.menuItem(state.text(.open_in_script_editor), null, false, true)) {
                    state.pending_script_open_path = entry.path;
                    state.script_editor_open = true;
                }
                gui.separator();
            },
            .directory => {
                if (gui.menuItem("Open Folder", null, false, true)) {
                    setSelectedAssetDirectory(state, entry.display_path);
                }
                gui.separator();
            },
            else => {},
        }

        // ── Create submenu ──
        if (gui.beginMenu("Create")) {
            defer gui.endMenu();
            const current_dir = selectedDirectory(state);
            if (gui.menuItem(state.text(.new_folder), null, false, true)) {
                state.new_folder_pending = true;
                @memset(state.new_folder_name_buffer[0..], 0);
                const default_name = "New Folder";
                @memcpy(state.new_folder_name_buffer[0..default_name.len], default_name);
                state.new_folder_focus_pending = true;
            }
            gui.separator();
            if (gui.menuItem("Script (.zig)", null, false, true)) {
                createNewScriptInDirectory(state, current_dir, ".zig");
            }
            if (gui.menuItem("Script (.cs)", null, false, true)) {
                createNewScriptInDirectory(state, current_dir, ".cs");
            }
        }

        // ── Import ──
        if (gui.menuItem("Import...", null, false, true)) {
            importFromFinder(state, layer_context);
        }

        gui.separator();

        // ── Edit operations ──
        if (gui.menuItem(state.text(.rename), null, false, true)) {
            state.asset_rename_index = index;
            @memset(state.asset_rename_buffer[0..], 0);
            const name_len = @min(entry.name.len, state.asset_rename_buffer.len - 1);
            @memcpy(state.asset_rename_buffer[0..name_len], entry.name[0..name_len]);
            state.asset_rename_focus_pending = true;
        }

        if (gui.menuItem(state.text(.duplicate_asset), null, false, !entry.is_directory)) {
            duplicateAssetFile(state, layer_context, entry);
        }

        if (gui.menuItem(state.text(.delete), null, false, true)) {
            try deleteAssetFile(state, layer_context, entry);
        }

        gui.separator();

        // ── Clipboard ──
        if (gui.menuItem(state.text(.asset_copy), null, false, true)) {
            copySelectedAssetsToClipboard(state, false);
        }

        if (gui.menuItem(state.text(.asset_cut), null, false, true)) {
            copySelectedAssetsToClipboard(state, true);
        }

        const has_clipboard = state.asset_clipboard_paths.items.len > 0;
        if (gui.menuItem(state.text(.asset_paste), null, false, has_clipboard)) {
            pasteAssetsFromClipboard(state, layer_context);
        }

        gui.separator();

        // ── System ──
        if (gui.menuItem(state.text(.show_in_finder), null, false, true)) {
            revealInFinder(entry.path);
        }

        if (gui.menuItem("Refresh", null, false, true)) {
            try refreshAssetBrowser(state, layer_context);
        }
    }
}

fn drawFolderContextMenu(state: *EditorState, layer_context: *engine.core.LayerContext, directory: []const u8) !void {
    var popup_id_buffer: [64]u8 = undefined;
    const popup_id = try std.fmt.bufPrint(&popup_id_buffer, "##folder_ctx_{s}", .{directory});
    if (gui.beginPopupContextItem(popup_id)) {
        defer gui.endPopup();

        if (gui.menuItem(state.text(.new_folder), null, false, true)) {
            state.new_folder_pending = true;
            @memset(state.new_folder_name_buffer[0..], 0);
            const default_name = "New Folder";
            @memcpy(state.new_folder_name_buffer[0..default_name.len], default_name);
            state.new_folder_focus_pending = true;
            setSelectedAssetDirectory(state, directory);
        }

        // New Script sub-items
        if (gui.menuItem(state.text(.new_cs_script), null, false, true)) {
            createNewScriptInDirectory(state, directory, ".cs");
        }
        if (gui.menuItem(state.text(.new_zig_script), null, false, true)) {
            createNewScriptInDirectory(state, directory, ".zig");
        }

        gui.separator();

        const has_clipboard = state.asset_clipboard_paths.items.len > 0;
        if (gui.menuItem(state.text(.paste), null, false, has_clipboard)) {
            setSelectedAssetDirectory(state, directory);
            pasteAssetsFromClipboard(state, layer_context);
        }

        // Only allow rename/delete on non-root directories
        if (!std.mem.eql(u8, directory, "/")) {
            if (gui.menuItem(state.text(.rename), null, false, true)) {
                state.folder_rename_active = true;
                @memset(state.folder_rename_original[0..], 0);
                @memset(state.folder_rename_buffer[0..], 0);
                const dir_len = @min(directory.len, state.folder_rename_original.len - 1);
                @memcpy(state.folder_rename_original[0..dir_len], directory[0..dir_len]);
                const name = directoryName(directory);
                const name_len = @min(name.len, state.folder_rename_buffer.len - 1);
                @memcpy(state.folder_rename_buffer[0..name_len], name[0..name_len]);
                state.folder_rename_focus_pending = true;
            }

            if (gui.menuItem(state.text(.delete), null, false, true)) {
                deleteFolderOnDisk(state, directory);
            }

            gui.separator();

            if (gui.menuItem(state.text(.show_in_finder), null, false, true)) {
                const root_path = assetBrowserRootPath(state);
                var path_buffer: [512]u8 = undefined;
                const full = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ root_path, directory }) catch return;
                revealInFinder(full);
            }
        }
    }
}

fn commitAssetRename(state: *EditorState, layer_context: *engine.core.LayerContext, index: usize) !void {
    if (index >= state.asset_entries.items.len) return;
    const entry = &state.asset_entries.items[index];
    const new_name = std.mem.sliceTo(state.asset_rename_buffer[0..], 0);
    if (new_name.len == 0) return;

    // Build old and new filesystem paths
    const old_path = entry.path;
    const dir = if (std.mem.lastIndexOfScalar(u8, old_path, '/')) |idx| old_path[0..idx] else "";
    const old_ext = if (std.mem.lastIndexOfScalar(u8, entry.name, '.')) |_|
        (if (std.mem.lastIndexOfScalar(u8, old_path, '.')) |idx| old_path[idx..] else "")
    else
        (if (std.mem.lastIndexOfScalar(u8, old_path, '.')) |idx| old_path[idx..] else "");

    var new_path_buffer: [512]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_path_buffer, "{s}/{s}{s}", .{ dir, new_name, old_ext }) catch return;

    // Do the filesystem rename
    std.fs.cwd().rename(old_path, new_path) catch |err| {
        std.log.warn("asset rename failed: {}", .{err});
        return;
    };

    // Also rename the .meta file if it exists
    var old_meta_buf: [520]u8 = undefined;
    var new_meta_buf: [520]u8 = undefined;
    const old_meta = std.fmt.bufPrint(&old_meta_buf, "{s}.meta", .{old_path}) catch return;
    const new_meta = std.fmt.bufPrint(&new_meta_buf, "{s}.meta", .{new_path}) catch return;
    std.fs.cwd().rename(old_meta, new_meta) catch {};

    // Refresh browser to reflect changes
    try refreshAssetBrowser(state, layer_context);
}

fn commitFolderRename(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const new_name = std.mem.sliceTo(state.folder_rename_buffer[0..], 0);
    if (new_name.len == 0) {
        state.folder_rename_active = false;
        return;
    }
    const original = std.mem.sliceTo(state.folder_rename_original[0..], 0);
    if (original.len == 0) {
        state.folder_rename_active = false;
        return;
    }
    // Build the old filesystem path and new path
    const root_path = assetBrowserRootPath(state);
    var old_fs_buf: [512]u8 = undefined;
    const old_fs = std.fmt.bufPrint(&old_fs_buf, "{s}{s}", .{ root_path, original }) catch return;

    // Parent of original directory
    const parent = if (std.mem.lastIndexOfScalar(u8, original, '/')) |idx| original[0..idx] else "/";
    var new_fs_buf: [512]u8 = undefined;
    const new_fs = if (std.mem.eql(u8, parent, "/"))
        std.fmt.bufPrint(&new_fs_buf, "{s}/{s}", .{ root_path, new_name }) catch return
    else
        std.fmt.bufPrint(&new_fs_buf, "{s}{s}/{s}", .{ root_path, parent, new_name }) catch return;

    std.fs.cwd().rename(old_fs, new_fs) catch |err| {
        std.log.warn("folder rename failed: {}", .{err});
        state.folder_rename_active = false;
        return;
    };

    state.folder_rename_active = false;
    try refreshAssetBrowser(state, layer_context);
}

fn commitNewFolder(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const name = std.mem.sliceTo(state.new_folder_name_buffer[0..], 0);
    if (name.len == 0) {
        state.new_folder_pending = false;
        return;
    }
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var path_buffer: [512]u8 = undefined;
    const full_path = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root_path, name }) catch return
    else
        std.fmt.bufPrint(&path_buffer, "{s}{s}/{s}", .{ root_path, current_dir, name }) catch return;

    std.fs.cwd().makePath(full_path) catch |err| {
        std.log.warn("create folder failed: {}", .{err});
        state.new_folder_pending = false;
        return;
    };

    state.new_folder_pending = false;
    try refreshAssetBrowser(state, layer_context);
}

fn deleteAssetFile(state: *EditorState, layer_context: *engine.core.LayerContext, entry: AssetEntry) !void {
    // Delete the asset file
    std.fs.cwd().deleteFile(entry.path) catch |err| {
        std.log.warn("asset delete failed: {}", .{err});
        return;
    };
    // Also try to delete the .meta file
    var meta_buf: [520]u8 = undefined;
    const meta_path = std.fmt.bufPrint(&meta_buf, "{s}.meta", .{entry.path}) catch return;
    std.fs.cwd().deleteFile(meta_path) catch {};

    try refreshAssetBrowser(state, layer_context);
}

fn deleteFolderOnDisk(state: *EditorState, directory: []const u8) void {
    const root_path = assetBrowserRootPath(state);
    var path_buffer: [512]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ root_path, directory }) catch return;
    std.fs.cwd().deleteTree(full_path) catch |err| {
        std.log.warn("folder delete failed: {}", .{err});
    };
    // Note: caller should refreshAssetBrowser after
}

fn revealInFinder(path: []const u8) void {
    // Use macOS 'open' command to reveal in Finder
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[0..idx] else path;
    var child = std.process.Child.init(
        &.{ "/usr/bin/open", dir },
        std.heap.page_allocator,
    );
    _ = child.spawnAndWait() catch {};
}

fn createNewScriptInDirectory(state: *EditorState, directory: []const u8, ext: []const u8) void {
    const root_path = assetBrowserRootPath(state);
    var dir_buf: [512]u8 = undefined;
    const full_dir = if (std.mem.eql(u8, directory, "/"))
        std.fmt.bufPrint(&dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ root_path, directory }) catch return;

    const filename = if (std.mem.eql(u8, ext, ".cs")) "NewScript.cs" else "new_script.zig";
    const template = if (std.mem.eql(u8, ext, ".cs"))
        "using System;\n\nnamespace Game\n{\n    public class NewScript\n    {\n        public void Update(float deltaTime)\n        {\n        }\n    }\n}\n"
    else
        "const std = @import(\"std\");\nconst engine = @import(\"guava\");\n\npub fn update(delta_time: f32) void {\n    _ = delta_time;\n}\n";

    var path_buf: [768]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ full_dir, filename }) catch return;

    // Set pending fields – the layer will create the file and open it in the Script Editor
    state.pending_new_script_path = full_path;
    state.pending_new_script_template = template;
    state.script_editor_open = true;
}

/// Unified import: opens a macOS NSOpenPanel that allows selecting both files and folders.
fn importFromFinder(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const allocator = state.allocator orelse return;

    // Build destination directory path
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var dest_dir_buf: [512]u8 = undefined;
    const dest_dir = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&dest_dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dest_dir_buf, "{s}{s}", .{ root_path, current_dir }) catch return;

    // Use NSOpenPanel via osascript — allows choosing both files and folders
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "/usr/bin/osascript",
            "-e",
            \\set thePanel to current application's NSOpenPanel's openPanel()
            \\thePanel's setCanChooseFiles:true
            \\thePanel's setCanChooseDirectories:true
            \\thePanel's setAllowsMultipleSelection:true
            \\thePanel's setPrompt:"Import"
            \\thePanel's setMessage:"Select files or folders to import into the project"
            \\set theResult to thePanel's runModal() as integer
            \\if theResult is 1 then
            \\  set output to ""
            \\  set theURLs to thePanel's URLs() as list
            \\  repeat with u in theURLs
            \\    set output to output & (u's |path|() as text) & linefeed
            \\  end repeat
            \\  return output
            \\else
            \\  error number -128
            \\end if
            ,
        },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return; // User cancelled

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    var imported: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Strip trailing slash
        const source = if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/')
            trimmed[0 .. trimmed.len - 1]
        else
            trimmed;

        // Extract basename
        const basename = if (std.mem.lastIndexOfScalar(u8, source, '/')) |idx| source[idx + 1 ..] else source;
        if (basename.len == 0) continue;

        var dest_path_buf: [768]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ dest_dir, basename }) catch continue;

        // Check if source is a directory
        const stat = std.fs.cwd().statFile(source) catch {
            // statFile fails on directories, treat as directory (use -R)
            var cp = std.process.Child.init(
                &.{ "/bin/cp", "-R", source, dest_path },
                allocator,
            );
            _ = cp.spawnAndWait() catch continue;
            imported += 1;
            continue;
        };
        _ = stat;

        // Regular file copy
        var cp = std.process.Child.init(
            &.{ "/bin/cp", source, dest_path },
            allocator,
        );
        _ = cp.spawnAndWait() catch continue;
        imported += 1;
    }

    if (imported > 0) {
        refreshAssetBrowser(state, layer_context) catch {};
    }
}

fn copySelectedAssetsToClipboard(state: *EditorState, is_cut: bool) void {
    const allocator = state.allocator orelse return;

    // Free previous clipboard entries
    for (state.asset_clipboard_paths.items) |path| {
        allocator.free(path);
    }
    state.asset_clipboard_paths.clearRetainingCapacity();

    // Collect paths of all selected assets
    const entries = state.asset_entries.items;
    for (0..entries.len) |i| {
        if (state.asset_selected_set.isSet(i)) {
            const duped = allocator.dupe(u8, entries[i].path) catch continue;
            state.asset_clipboard_paths.append(allocator, duped) catch {
                allocator.free(duped);
                continue;
            };
        }
    }

    state.asset_clipboard_is_cut = is_cut;
}

fn pasteAssetsFromClipboard(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const allocator = state.allocator orelse return;
    if (state.asset_clipboard_paths.items.len == 0) return;

    // Build destination directory
    const root_path = assetBrowserRootPath(state);
    const current_dir = selectedDirectory(state);
    var dest_dir_buf: [512]u8 = undefined;
    const dest_dir = if (std.mem.eql(u8, current_dir, "/"))
        std.fmt.bufPrint(&dest_dir_buf, "{s}", .{root_path}) catch return
    else
        std.fmt.bufPrint(&dest_dir_buf, "{s}{s}", .{ root_path, current_dir }) catch return;

    for (state.asset_clipboard_paths.items) |src_path| {
        // Extract filename from source path
        const filename = if (std.mem.lastIndexOfScalar(u8, src_path, '/')) |idx| src_path[idx + 1 ..] else src_path;
        if (filename.len == 0) continue;

        var dest_path_buf: [768]u8 = undefined;
        const dest_path = std.fmt.bufPrint(&dest_path_buf, "{s}/{s}", .{ dest_dir, filename }) catch continue;

        if (state.asset_clipboard_is_cut) {
            // Move: rename source to destination
            std.fs.cwd().rename(src_path, dest_path) catch |err| {
                std.log.warn("paste (move) failed: {}", .{err});
                continue;
            };
            // Also move .meta file if it exists
            var src_meta_buf: [520]u8 = undefined;
            var dest_meta_buf: [776]u8 = undefined;
            const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{src_path}) catch continue;
            const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{dest_path}) catch continue;
            std.fs.cwd().rename(src_meta, dest_meta) catch {};
        } else {
            // Copy: use /bin/cp
            var cp = std.process.Child.init(
                &.{ "/bin/cp", src_path, dest_path },
                allocator,
            );
            _ = cp.spawnAndWait() catch continue;
            // Also copy .meta file if it exists
            var src_meta_buf: [520]u8 = undefined;
            var dest_meta_buf: [776]u8 = undefined;
            const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{src_path}) catch continue;
            const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{dest_path}) catch continue;
            var cp_meta = std.process.Child.init(
                &.{ "/bin/cp", src_meta, dest_meta },
                allocator,
            );
            _ = cp_meta.spawnAndWait() catch {};
        }
    }

    // If cut, clear clipboard after paste
    if (state.asset_clipboard_is_cut) {
        for (state.asset_clipboard_paths.items) |path| {
            allocator.free(path);
        }
        state.asset_clipboard_paths.clearRetainingCapacity();
        state.asset_clipboard_is_cut = false;
    }

    refreshAssetBrowser(state, layer_context) catch {};
}

fn duplicateAssetFile(state: *EditorState, layer_context: *engine.core.LayerContext, entry: AssetEntry) void {
    const allocator = state.allocator orelse return;

    // Build a new name with "_copy" inserted before the extension
    const name = entry.name;
    const path = entry.path;

    // Find extension in name
    const ext_start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| idx else name.len;
    const base_name = name[0..ext_start];

    // Find the directory part of the full path
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[0 .. idx + 1] else "";
    const ext = if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| name[idx..] else "";

    var new_path_buf: [768]u8 = undefined;
    const new_path = std.fmt.bufPrint(&new_path_buf, "{s}{s}_copy{s}", .{ dir, base_name, ext }) catch return;

    // Copy using /bin/cp
    var cp = std.process.Child.init(
        &.{ "/bin/cp", path, new_path },
        allocator,
    );
    _ = cp.spawnAndWait() catch return;

    // Also copy .meta file if it exists
    var src_meta_buf: [520]u8 = undefined;
    var dest_meta_buf: [776]u8 = undefined;
    const src_meta = std.fmt.bufPrint(&src_meta_buf, "{s}.meta", .{path}) catch return;
    const dest_meta = std.fmt.bufPrint(&dest_meta_buf, "{s}.meta", .{new_path}) catch return;
    var cp_meta = std.process.Child.init(
        &.{ "/bin/cp", src_meta, dest_meta },
        allocator,
    );
    _ = cp_meta.spawnAndWait() catch {};

    refreshAssetBrowser(state, layer_context) catch {};
}

test "material assets map to browser visuals and kinds" {
    try std.testing.expectEqual(AssetKind.material, assetKindForRecordType(.material).?);
    try std.testing.expectEqualStrings(ui_icons.paths.toolbar.material, assetIconPath(.material));
    try std.testing.expectEqual([4]u8{ 186, 228, 196, 255 }, assetIconTint(.material));
}

test "material thumbnail request queue deduplicates asset ids" {
    var state = EditorState{
        .allocator = std.testing.allocator,
    };
    defer clearMaterialThumbnailRequestQueue(&state);

    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://brick");
    try queueMaterialThumbnailRequest(&state, "material://stone");

    try std.testing.expectEqual(@as(usize, 2), state.material_thumbnail_queue.items.len);
    try std.testing.expectEqualStrings("material://brick", state.material_thumbnail_queue.items[0]);
    try std.testing.expectEqualStrings("material://stone", state.material_thumbnail_queue.items[1]);
}

fn makeOwnedMaterialRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !engine.assets.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = .material,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "test-source-hash"),
        .import_settings_hash = try allocator.dupe(u8, "test-import-settings"),
        .import_version = engine.assets.AssetType.material.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(engine.assets.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, engine.assets.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ".guava_material"),
        },
    };
}

test "applyMaterialAssetToEntity assigns loaded material assets to entities" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const material_handle = try world.assets().createMaterial(.{
        .name = "Brick Material",
        .shading = .lambert,
        .base_color_factor = .{ 0.22, 0.41, 0.63, 1.0 },
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedMaterialRecord(std.testing.allocator, "material://brick", "assets/materials/brick.guava_material", "Brick"),
    );

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://brick"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/brick.guava_material"),
        .display_path = try std.testing.allocator.dupe(u8, "materials/brick.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Brick"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.display_path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id));
    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expect(entity.material != null);
    try std.testing.expectEqual(material_handle, entity.material.?.handle.?);
    try std.testing.expectEqual(engine.scene.ShadingModel.lambert, entity.material.?.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.22, 0.41, 0.63, 1.0 }, entity.material.?.base_color_factor);
}

test "applyMaterialAssetToEntity rejects unloaded material assets" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{ .name = "Cube" });

    var entry = AssetEntry{
        .id = try std.testing.allocator.dupe(u8, "material://missing"),
        .path = try std.testing.allocator.dupe(u8, "assets/materials/missing.guava_material"),
        .display_path = try std.testing.allocator.dupe(u8, "materials/missing.guava_material"),
        .name = try std.testing.allocator.dupe(u8, "Missing"),
        .kind = .material,
    };
    defer {
        std.testing.allocator.free(entry.id);
        std.testing.allocator.free(entry.path);
        std.testing.allocator.free(entry.display_path);
        std.testing.allocator.free(entry.name);
    }

    var state = EditorState{};
    var scene: engine.scene.Scene = undefined;
    var renderer: engine.render.Renderer = undefined;
    var input: engine.core.InputState = undefined;
    var window: engine.platform.Window = undefined;
    var playback_controller = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &scene,
        .renderer = &renderer,
        .input = &input,
        .window = &window,
        .playback_controller = &playback_controller,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 0.0,
    };

    try std.testing.expect(!(try applyMaterialAssetToEntity(&state, &layer_context, &entry, entity_id)));
    try std.testing.expect(world.getEntityConst(entity_id).?.material == null);
}
