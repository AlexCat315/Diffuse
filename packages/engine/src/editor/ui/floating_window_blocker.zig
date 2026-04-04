const std = @import("std");
const gui = @import("gui.zig");

const max_tracked_windows: usize = 32;

const TrackedWindow = struct {
    id: u64 = 0,
    last_seen_frame: u64 = 0,
    pos: [2]f32 = .{ 0.0, 0.0 },
    size: [2]f32 = .{ 0.0, 0.0 },
};

var g_frame_index: u64 = 0;
var g_tracked_windows: [max_tracked_windows]TrackedWindow = [_]TrackedWindow{.{}} ** max_tracked_windows;

fn hashedWindowId(window_id: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x7f4a7c15);
    hasher.update(window_id);
    return hasher.final();
}

fn pointInRect(point: [2]f32, min: [2]f32, max: [2]f32) bool {
    return point[0] >= min[0] and point[0] <= max[0] and
        point[1] >= min[1] and point[1] <= max[1];
}

fn isEntryLive(entry: TrackedWindow) bool {
    if (entry.id == 0 or entry.last_seen_frame == 0 or g_frame_index == 0) return false;
    return g_frame_index >= entry.last_seen_frame and g_frame_index - entry.last_seen_frame <= 1;
}

fn entryForWindow(window_id: []const u8) *TrackedWindow {
    const id = hashedWindowId(window_id);
    var first_stale: ?usize = null;

    for (&g_tracked_windows, 0..) |*entry, index| {
        if (entry.id == id) return entry;
        if (first_stale == null and !isEntryLive(entry.*)) {
            first_stale = index;
        }
    }

    return &g_tracked_windows[first_stale orelse 0];
}

pub fn beginFrame() void {
    g_frame_index +%= 1;
    if (g_frame_index == 0) {
        g_frame_index = 1;
    }
}

pub fn registerCurrentWindow(window_id: []const u8) void {
    const entry = entryForWindow(window_id);
    entry.id = hashedWindowId(window_id);
    entry.last_seen_frame = g_frame_index;
    entry.pos = gui.windowPos();
    entry.size = gui.windowSize();
}

pub fn anyContainsPoint(point: [2]f32) bool {
    for (g_tracked_windows) |entry| {
        if (!isEntryLive(entry)) continue;
        if (entry.size[0] <= 0.0 or entry.size[1] <= 0.0) continue;
        if (pointInRect(point, entry.pos, .{
            entry.pos[0] + entry.size[0],
            entry.pos[1] + entry.size[1],
        })) {
            return true;
        }
    }
    return false;
}
