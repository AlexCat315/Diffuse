const std = @import("std");
const EditorState = @import("../../../core/state.zig").EditorState;

pub fn buildStatusMetricsText(
    writer: anytype,
    state: *const EditorState,
    selection_count: usize,
    fps: f32,
    save_status: []const u8,
    backend_text: []const u8,
    memory_text: []const u8,
    available_width: f32,
) !void {
    var first = true;
    var remaining_budget = estimatedStatusCharBudget(available_width);

    var selection_buffer: [24]u8 = undefined;
    const selection_text = try std.fmt.bufPrint(&selection_buffer, "{d}", .{selection_count});
    try appendStatusSegment(writer, &first, state.text(.selection_count), selection_text);
    remaining_budget = subtractBudget(remaining_budget, segmentCost(state.text(.selection_count), selection_text));

    if (state.fps_display_mode == .status_bar) {
        var fps_buffer: [32]u8 = undefined;
        const fps_text = try std.fmt.bufPrint(&fps_buffer, "{d:.1}", .{fps});
        try appendStatusSegment(writer, &first, state.text(.fps), fps_text);
        remaining_budget = subtractBudget(remaining_budget, segmentCost(state.text(.fps), fps_text));
    }

    try appendStatusSegment(writer, &first, state.text(.save_status), save_status);
    remaining_budget = subtractBudget(remaining_budget, segmentCost(state.text(.save_status), save_status));

    try appendStatusSegmentIfFits(writer, &first, &remaining_budget, state.text(.backend), backend_text);
    try appendStatusSegmentIfFits(writer, &first, &remaining_budget, state.text(.memory), memory_text);
}

pub fn buildStatusContextText(
    writer: anytype,
    state: *const EditorState,
    selected_path: []const u8,
    camera_text: []const u8,
    mode_text: []const u8,
    space_text: []const u8,
    available_width: f32,
) !void {
    var first = true;
    var remaining_budget = estimatedStatusCharBudget(available_width);
    try appendStatusSegment(writer, &first, state.text(.selected_path), selected_path);
    remaining_budget = subtractBudget(remaining_budget, segmentCost(state.text(.selected_path), selected_path));

    try appendStatusSegmentIfFits(writer, &first, &remaining_budget, state.text(.camera), camera_text);
    try appendStatusSegmentIfFits(writer, &first, &remaining_budget, state.text(.mode), mode_text);
    try appendStatusSegmentIfFits(writer, &first, &remaining_budget, state.text(.coordinate_space), space_text);
}

pub fn statusBarContextRatio(window_width: f32) f32 {
    const t = std.math.clamp((window_width - 900.0) / 560.0, 0.0, 1.0);
    const eased = t * t * (3.0 - 2.0 * t);
    return 0.56 + (0.62 - 0.56) * eased;
}

pub fn statusPathCharacterBudget(available_width: f32) usize {
    const t = std.math.clamp((available_width - 240.0) / 760.0, 0.0, 1.0);
    const eased = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(18.0 + (60.0 - 18.0) * eased));
}

pub fn compactStatusPath(buffer: []u8, path: []const u8, max_chars: usize) []const u8 {
    if (path.len <= max_chars or buffer.len == 0) {
        return path;
    }

    const clamped_chars = @max(max_chars, 4);
    const tail_len = @min(path.len, clamped_chars - 3);
    const written = std.fmt.bufPrint(buffer, "...{s}", .{path[path.len - tail_len ..]}) catch return path;
    return written;
}

fn appendStatusSegment(writer: anytype, first: *bool, label: []const u8, value: []const u8) !void {
    if (!first.*) {
        try writer.writeAll("  |  ");
    }
    first.* = false;
    try writer.print("{s}: {s}", .{ label, value });
}

fn appendStatusSegmentIfFits(
    writer: anytype,
    first: *bool,
    remaining_budget: *usize,
    label: []const u8,
    value: []const u8,
) !void {
    const cost = segmentCost(label, value);
    if (cost > remaining_budget.*) {
        return;
    }
    try appendStatusSegment(writer, first, label, value);
    remaining_budget.* = remaining_budget.* - cost;
}

fn estimatedStatusCharBudget(available_width: f32) usize {
    const budget: usize = @intFromFloat(@floor(available_width / 7.0));
    return @max(@as(usize, 16), budget);
}

fn segmentCost(label: []const u8, value: []const u8) usize {
    return label.len + value.len + 4;
}

fn subtractBudget(current: usize, cost: usize) usize {
    return if (current > cost) current - cost else 0;
}
