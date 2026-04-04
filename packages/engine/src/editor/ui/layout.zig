const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const theme = @import("theme.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const layout_template_extension = ".ini";

pub fn beginSectionBody() void {
    gui.indent(theme.Spacing.section_padding);
}

pub fn endSectionBody() void {
    gui.unindent(theme.Spacing.section_padding);
}

pub fn drawSidebarSectionDivider() void {
    gui.dummy(0.0, theme.Spacing.layout_divider_spacing);
    gui.separator();
    gui.dummy(0.0, theme.Spacing.layout_divider_spacing);
}

pub fn drawSidebarSectionGap() void {
    gui.dummy(0.0, theme.Spacing.layout_divider_spacing);
}

pub fn responsiveButtonColumns(button_count: usize, min_button_width: f32) usize {
    var columns = button_count;
    while (columns > 1) : (columns -= 1) {
        const required_width =
            min_button_width * @as(f32, @floatFromInt(columns)) +
            theme.Spacing.item_spacing * @as(f32, @floatFromInt(columns - 1));
        if (gui.contentRegionAvail()[0] >= required_width) {
            return columns;
        }
    }
    return 1;
}

pub fn responsiveButtonWidth(columns: usize) f32 {
    const total_spacing = theme.Spacing.item_spacing * @as(f32, @floatFromInt(columns -| 1));
    return @max(
        (gui.contentRegionAvail()[0] - total_spacing) / @as(f32, @floatFromInt(columns)),
        1.0,
    );
}

pub fn advanceResponsiveRow(index: usize, columns: usize) void {
    if (columns == 0 or index == 0) {
        return;
    }
    if (index % columns == 0) {
        gui.dummy(0.0, theme.Spacing.row_spacing);
    } else {
        gui.sameLine();
    }
}

pub fn drawResponsivePropertyLabel(label: []const u8, min_control_width: f32) bool {
    const total_width = gui.contentRegionAvail()[0];
    const label_width = std.math.clamp(total_width * theme.Spacing.layout_label_width_ratio, theme.Spacing.layout_label_width_min, theme.Spacing.layout_label_width_max);
    gui.alignTextToFramePadding();
    gui.text(label);
    if (total_width < label_width + min_control_width) {
        return false;
    }
    gui.sameLineEx(label_width, theme.Spacing.item_spacing);
    return true;
}

pub fn beginInspectorPropertyTable(id: []const u8, label_width_ratio: f32) bool {
    const available_width = gui.contentRegionAvail()[0];
    const label_width = available_width * label_width_ratio;
    if (gui.beginTable(id, 2)) {
        gui.tableSetupColumn("##property_label", false, label_width);
        gui.tableSetupColumn("##property_value", true, 1.0);
        return true;
    }
    return false;
}

pub fn endInspectorPropertyTable() void {
    gui.endTable();
}

pub fn drawInspectorPropertyRow(label: []const u8, label_color: ?[4]f32) void {
    gui.tableNextRow();
    gui.tableNextColumn();
    const default_dimmed = theme.Spacing.layout_property_label_dimmed; // Slightly brighter dimmed label
    if (label_color) |color| {
        gui.pushStyleColor(.text, color);
        defer gui.popStyleColor(1);
    } else {
        gui.pushStyleColor(.text, default_dimmed);
        defer gui.popStyleColor(1);
    }
    gui.alignTextToFramePadding();
    gui.text(label);
    gui.tableNextColumn();
    gui.setNextItemWidth(-1.0);
}

pub fn resetDockLayout(state: *EditorState) void {
    // DockBuilder ops (RemoveNode/AddNode/SplitNode/DockWindow) must happen
    // immediately AFTER DockSpaceOverViewport() in the same frame, not scattered
    // mid-frame after panels have already been rendered.  Setting this flag to
    // false defers the actual rebuild to the top of the next frame in layer.zig.
    state.dock_layout_initialized = false;
}

pub fn loadAnimationDockLayout(state: *EditorState) void {
    gui.loadAnimationLayout();
    state.dock_layout_initialized = true;
}

pub fn ensureLayoutTemplatesLoaded(state: *EditorState) !void {
    if (state.layout_templates_loaded) {
        return;
    }
    try refreshLayoutTemplates(state);
}

pub fn refreshLayoutTemplates(state: *EditorState) !void {
    const allocator = state.allocator orelse return;
    clearLayoutTemplates(state);

    const directory = try layoutTemplatesDirectoryAlloc(allocator);
    defer allocator.free(directory);
    std.fs.makeDirAbsolute(directory) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.fs.openDirAbsolute(directory, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, layout_template_extension)) {
            continue;
        }

        const stem = entry.name[0 .. entry.name.len - layout_template_extension.len];
        const full_path = try std.fs.path.join(allocator, &.{ directory, entry.name });
        try state.layout_templates.append(allocator, .{
            .name = try allocator.dupe(u8, stem),
            .path = full_path,
        });
    }

    std.sort.heap(state_mod.LayoutTemplateEntry, state.layout_templates.items, {}, lessThanLayoutTemplateEntry);
    state.layout_templates_loaded = true;
}

pub fn releaseLayoutTemplates(state: *EditorState) void {
    clearLayoutTemplates(state);
}

pub fn saveUserLayoutTemplate(state: *EditorState, raw_name: []const u8) !bool {
    const allocator = state.allocator orelse return false;
    const stem = try sanitizeTemplateStemAlloc(allocator, raw_name);
    defer allocator.free(stem);
    if (stem.len == 0) {
        return false;
    }

    const path = try layoutTemplatePathAlloc(allocator, stem);
    defer allocator.free(path);
    if (!gui.saveLayoutToPath(path)) {
        return false;
    }
    try refreshLayoutTemplates(state);
    return true;
}

pub fn loadUserLayoutTemplate(state: *EditorState, path: []const u8) bool {
    if (!gui.loadLayoutFromPath(path)) {
        return false;
    }
    gui.saveLayout();
    state.dock_layout_initialized = true;
    return true;
}

pub fn deleteUserLayoutTemplate(state: *EditorState, index: usize) !bool {
    if (index >= state.layout_templates.items.len) {
        return false;
    }
    const path = state.layout_templates.items[index].path;
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try refreshLayoutTemplates(state);
    return true;
}

fn clearLayoutTemplates(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    for (state.layout_templates.items) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.path);
    }
    state.layout_templates.deinit(allocator);
    state.layout_templates = .empty;
    state.layout_templates_loaded = false;
}

fn layoutTemplatesDirectoryAlloc(allocator: std.mem.Allocator) ![]u8 {
    const pref_path = try gui.editorPrefPathAlloc(allocator);
    defer allocator.free(pref_path);
    return std.fs.path.join(allocator, &.{ pref_path, "layouts" });
}

fn layoutTemplatePathAlloc(allocator: std.mem.Allocator, stem: []const u8) ![]u8 {
    const directory = try layoutTemplatesDirectoryAlloc(allocator);
    defer allocator.free(directory);
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, layout_template_extension });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ directory, filename });
}

fn sanitizeTemplateStemAlloc(allocator: std.mem.Allocator, raw_name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_name, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return allocator.alloc(u8, 0);
    }

    var sanitized = std.ArrayList(u8).empty;
    defer sanitized.deinit(allocator);

    var previous_separator = false;
    for (trimmed) |char| {
        const is_reserved = char < 0x20 or char == '/' or char == '\\' or char == ':' or char == '*' or char == '?' or char == '"' or char == '<' or char == '>' or char == '|';
        if (is_reserved) {
            continue;
        }
        const is_separator = char == ' ' or char == '\t';
        if (is_separator) {
            if (sanitized.items.len == 0 or previous_separator) {
                continue;
            }
            try sanitized.append(allocator, '-');
            previous_separator = true;
            continue;
        }
        try sanitized.append(allocator, char);
        previous_separator = false;
    }

    while (sanitized.items.len > 0 and sanitized.items[sanitized.items.len - 1] == '-') {
        _ = sanitized.pop();
    }

    return sanitized.toOwnedSlice(allocator);
}

fn lessThanLayoutTemplateEntry(_: void, lhs: state_mod.LayoutTemplateEntry, rhs: state_mod.LayoutTemplateEntry) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

test "sanitizeTemplateStemAlloc strips reserved characters and normalizes spaces" {
    const allocator = std.testing.allocator;
    const sanitized = try sanitizeTemplateStemAlloc(allocator, "  动画 Layout : v2  ");
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings("动画-Layout-v2", sanitized);
}
