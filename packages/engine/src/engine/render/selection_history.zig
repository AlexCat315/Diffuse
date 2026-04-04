const std = @import("std");
const scene_mod = @import("../scene/scene.zig");

pub const SelectionUpdateMode = enum {
    replace,
    toggle,
};

const Snapshot = struct {
    ids: []scene_mod.EntityId,
};

const empty_selection = [_]scene_mod.EntityId{};

pub const SelectionHistory = struct {
    allocator: std.mem.Allocator,
    max_snapshots: usize,
    snapshots: std.ArrayList(Snapshot) = .empty,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, max_snapshots: usize) SelectionHistory {
        return .{
            .allocator = allocator,
            .max_snapshots = @max(max_snapshots, 1),
        };
    }

    pub fn deinit(self: *SelectionHistory) void {
        for (self.snapshots.items) |snapshot| {
            self.allocator.free(snapshot.ids);
        }
        self.snapshots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isEmpty(self: *const SelectionHistory) bool {
        return self.currentSelection().len == 0;
    }

    pub fn currentSelection(self: *const SelectionHistory) []const scene_mod.EntityId {
        if (self.snapshots.items.len == 0) {
            return empty_selection[0..];
        }
        return self.snapshots.items[self.cursor].ids;
    }

    pub fn primarySelection(self: *const SelectionHistory) ?scene_mod.EntityId {
        const selection = self.currentSelection();
        if (selection.len == 0) {
            return null;
        }
        return selection[selection.len - 1];
    }

    pub fn canUndo(self: *const SelectionHistory) bool {
        return self.snapshots.items.len > 0 and self.cursor > 0;
    }

    pub fn canRedo(self: *const SelectionHistory) bool {
        return self.snapshots.items.len > 0 and self.cursor + 1 < self.snapshots.items.len;
    }

    pub fn undo(self: *SelectionHistory) bool {
        if (!self.canUndo()) {
            return false;
        }
        self.cursor -= 1;
        return true;
    }

    pub fn redo(self: *SelectionHistory) bool {
        if (!self.canRedo()) {
            return false;
        }
        self.cursor += 1;
        return true;
    }

    pub fn applyPick(
        self: *SelectionHistory,
        entity: ?scene_mod.EntityId,
        mode: SelectionUpdateMode,
    ) !bool {
        return switch (mode) {
            .replace => self.commitSelection(if (entity) |selected| &.{selected} else empty_selection[0..]),
            .toggle => self.toggleSelection(entity),
        };
    }

    pub fn replaceSelection(self: *SelectionHistory, ids: []const scene_mod.EntityId) !bool {
        return self.commitSelection(ids);
    }

    fn toggleSelection(self: *SelectionHistory, entity: ?scene_mod.EntityId) !bool {
        const selected = entity orelse return false;
        const current = self.currentSelection();
        var next = std.ArrayList(scene_mod.EntityId).empty;
        defer next.deinit(self.allocator);

        var removed = false;
        for (current) |current_id| {
            if (current_id == selected) {
                removed = true;
                continue;
            }
            try next.append(self.allocator, current_id);
        }

        if (!removed) {
            try next.append(self.allocator, selected);
        }

        return self.commitSelection(next.items);
    }

    fn commitSelection(self: *SelectionHistory, ids: []const scene_mod.EntityId) !bool {
        const current = self.currentSelection();
        if (std.mem.eql(scene_mod.EntityId, current, ids)) {
            return false;
        }

        try self.discardRedoHistory();

        const owned_ids = try self.allocator.dupe(scene_mod.EntityId, ids);
        try self.snapshots.append(self.allocator, .{ .ids = owned_ids });
        self.cursor = self.snapshots.items.len - 1;

        while (self.snapshots.items.len > self.max_snapshots) {
            const removed = self.snapshots.orderedRemove(0);
            self.allocator.free(removed.ids);
            if (self.cursor > 0) {
                self.cursor -= 1;
            }
        }

        return true;
    }

    fn discardRedoHistory(self: *SelectionHistory) !void {
        if (self.snapshots.items.len == 0 or self.cursor + 1 >= self.snapshots.items.len) {
            return;
        }

        var index = self.cursor + 1;
        while (index < self.snapshots.items.len) : (index += 1) {
            self.allocator.free(self.snapshots.items[index].ids);
        }
        try self.snapshots.resize(self.allocator, self.cursor + 1);
    }
};

test "SelectionHistory replace, clear, and primary selection" {
    var history = SelectionHistory.init(std.testing.allocator, 8);
    defer history.deinit();

    try std.testing.expect(history.isEmpty());
    try std.testing.expectEqual(@as(?scene_mod.EntityId, null), history.primarySelection());

    try std.testing.expect(try history.applyPick(7, .replace));
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{7}, history.currentSelection());
    try std.testing.expectEqual(@as(?scene_mod.EntityId, 7), history.primarySelection());

    try std.testing.expect(try history.applyPick(null, .replace));
    try std.testing.expectEqual(@as(usize, 0), history.currentSelection().len);
    try std.testing.expectEqual(@as(?scene_mod.EntityId, null), history.primarySelection());
}

test "SelectionHistory toggle supports additive multi-select" {
    var history = SelectionHistory.init(std.testing.allocator, 8);
    defer history.deinit();

    try std.testing.expect(try history.applyPick(3, .replace));
    try std.testing.expect(try history.applyPick(8, .toggle));
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{ 3, 8 }, history.currentSelection());
    try std.testing.expectEqual(@as(?scene_mod.EntityId, 8), history.primarySelection());

    try std.testing.expect(try history.applyPick(3, .toggle));
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{8}, history.currentSelection());

    try std.testing.expect(!try history.applyPick(null, .toggle));
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{8}, history.currentSelection());
}

test "SelectionHistory keeps undo and redo snapshots" {
    var history = SelectionHistory.init(std.testing.allocator, 8);
    defer history.deinit();

    try std.testing.expect(try history.applyPick(1, .replace));
    try std.testing.expect(try history.applyPick(2, .toggle));
    try std.testing.expect(try history.applyPick(4, .toggle));
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{ 1, 2, 4 }, history.currentSelection());

    try std.testing.expect(history.undo());
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{ 1, 2 }, history.currentSelection());

    try std.testing.expect(history.undo());
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{1}, history.currentSelection());

    try std.testing.expect(history.redo());
    try std.testing.expectEqualSlices(scene_mod.EntityId, &.{ 1, 2 }, history.currentSelection());
}
