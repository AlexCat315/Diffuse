const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

pub const CameraBookmark = struct {
    name: [64]u8,
    name_len: usize,
    position: [3]f32,
    target: [3]f32,
    pitch: f32,
    yaw: f32,
    distance: f32,
    fov: f32,
    orthographic: bool,
    timestamp: i64,

    pub fn init(name: []const u8, position: [3]f32, target: [3]f32, pitch: f32, yaw: f32, distance: f32, fov: f32, orthographic: bool) CameraBookmark {
        var bookmark = CameraBookmark{
            .name = [_]u8{0} ** 64,
            .name_len = @min(name.len, 63),
            .position = position,
            .target = target,
            .pitch = pitch,
            .yaw = yaw,
            .distance = distance,
            .fov = fov,
            .orthographic = orthographic,
            .timestamp = std.time.timestamp(),
        };
        @memcpy(bookmark.name[0..name.len], name.ptr);
        return bookmark;
    }

    pub fn getName(self: *const CameraBookmark) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn clone(self: *const CameraBookmark) CameraBookmark {
        return self.*;
    }
};

pub const CameraBookmarkManager = struct {
    allocator: std.mem.Allocator,
    bookmarks: std.ArrayList(CameraBookmark),
    selected_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) CameraBookmarkManager {
        return .{
            .allocator = allocator,
            .bookmarks = .empty,
        };
    }

    pub fn deinit(self: *CameraBookmarkManager) void {
        self.bookmarks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addBookmark(self: *CameraBookmarkManager, bookmark: CameraBookmark) !usize {
        try self.bookmarks.append(self.allocator, bookmark);
        return self.bookmarks.items.len - 1;
    }

    pub fn removeBookmark(self: *CameraBookmarkManager, index: usize) bool {
        if (index >= self.bookmarks.items.len) return false;
        _ = self.bookmarks.orderedRemove(index);
        // Note: orderedRemove doesn't take allocator in Zig 0.15
        if (self.selected_index) |si| {
            if (si == index) {
                self.selected_index = null;
            } else if (si > index) {
                self.selected_index = si - 1;
            }
        }
        return true;
    }

    pub fn getBookmark(self: *const CameraBookmarkManager, index: usize) ?*const CameraBookmark {
        if (index >= self.bookmarks.items.len) return null;
        return &self.bookmarks.items[index];
    }

    pub fn renameBookmark(self: *CameraBookmarkManager, index: usize, new_name: []const u8) bool {
        if (index >= self.bookmarks.items.len) return false;
        const bookmark = &self.bookmarks.items[index];
        bookmark.name_len = @min(new_name.len, 63);
        @memcpy(bookmark.name[0..new_name.len], new_name.ptr);
        return true;
    }

    pub fn bookmarkCount(self: *const CameraBookmarkManager) usize {
        return self.bookmarks.items.len;
    }
};

pub fn drawCameraBookmarkWindow(state: *EditorState, layer_context: *engine.core.LayerContext, manager: *CameraBookmarkManager) !void {
    _ = layer_context;

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .camera_bookmarks, "camera_bookmarks_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("camera_bookmarks_panel");

    // Derive current camera state from EditorState for saving bookmarks.
    const vec3 = engine.math.vec3;
    const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
    const current_position = vec3.sub(state.focus_pivot, vec3.scale(forward, state.orbit_distance));

    if (gui.button("Add Current View")) {
        const bookmark = CameraBookmark.init(
            "Bookmark",
            current_position,
            state.focus_pivot,
            state.pitch,
            state.yaw,
            state.orbit_distance,
            60.0,
            false,
        );
        _ = manager.addBookmark(bookmark) catch {};
    }

    gui.separator();

    if (manager.bookmarks.items.len == 0) {
        gui.text("No bookmarks saved");
    } else {
        var i: usize = 0;
        while (i < manager.bookmarks.items.len) : (i += 1) {
            const bookmark = &manager.bookmarks.items[i];

            const is_selected = manager.selected_index != null and manager.selected_index.? == i;

            var name_buf: [128]u8 = undefined;
            const display_name = std.fmt.bufPrint(&name_buf, "{s}##{}", .{ bookmark.getName(), i }) catch continue;

            if (gui.selectable(display_name, is_selected, false, 0.0, 0.0)) {
                manager.selected_index = i;
            }

            if (gui.beginPopupContextItem(null)) {
                if (gui.selectable("Apply", false, false, 0.0, 0.0)) {
                    applyBookmark(state, bookmark);
                }
                if (gui.selectable("Rename", false, false, 0.0, 0.0)) {}
                if (gui.selectable("Delete", false, false, 0.0, 0.0)) {
                    _ = manager.removeBookmark(i);
                    if (i > 0) i -= 1;
                }
                gui.endPopup();
            }

            if (gui.isItemHovered() and gui.isMouseDoubleClicked(.left)) {
                applyBookmark(state, bookmark);
            }
        }
    }
}

fn applyBookmark(state: *EditorState, bookmark: *const CameraBookmark) void {
    state.pitch = bookmark.pitch;
    state.yaw = bookmark.yaw;
    state.orbit_distance = bookmark.distance;
    state.focus_pivot = bookmark.target;
}
