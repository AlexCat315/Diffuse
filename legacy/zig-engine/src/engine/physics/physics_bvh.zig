const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const vec3 = @import("../math/vec3.zig");
const EntityId = @import("../scene/scene.zig").EntityId;

pub const PhysicsBvhItem = struct {
    id: EntityId,
    bounds: AABB,
    is_dynamic: bool,
};

pub const PhysicsBvhNode = struct {
    bounds: AABB,
    left: ?u32,
    right: ?u32,
    parent: ?u32,
    start: u32,
    count: u32,

    fn isLeaf(self: PhysicsBvhNode) bool {
        return self.left == null and self.right == null;
    }
};

pub const PhysicsBvh = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(PhysicsBvhItem) = .empty,
    nodes: std.ArrayList(PhysicsBvhNode) = .empty,
    root_index: ?u32 = null,
    item_indices: std.AutoHashMap(EntityId, usize),
    item_leaf_nodes: std.AutoHashMap(EntityId, u32),

    const max_leaf_items: usize = 8;

    pub fn init(allocator: std.mem.Allocator) PhysicsBvh {
        return .{
            .allocator = allocator,
            .item_indices = std.AutoHashMap(EntityId, usize).init(allocator),
            .item_leaf_nodes = std.AutoHashMap(EntityId, u32).init(allocator),
        };
    }

    pub fn deinit(self: *PhysicsBvh) void {
        self.items.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.item_indices.deinit();
        self.item_leaf_nodes.deinit();
    }

    pub fn rebuild(self: *PhysicsBvh, source_items: []const PhysicsBvhItem) !void {
        self.items.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.item_indices.clearRetainingCapacity();
        self.item_leaf_nodes.clearRetainingCapacity();

        if (source_items.len == 0) {
            self.root_index = null;
            return;
        }

        try self.items.appendSlice(self.allocator, source_items);
        self.root_index = try self.buildNode(0, self.items.items.len, null);
    }

    pub fn insertItem(self: *PhysicsBvh, item: PhysicsBvhItem) bool {
        if (self.root_index == null) {
            self.items.append(self.allocator, item) catch return false;
            errdefer _ = self.items.pop();
            self.item_indices.put(item.id, 0) catch return false;
            errdefer _ = self.item_indices.remove(item.id);
            self.item_leaf_nodes.put(item.id, 0) catch return false;
            errdefer _ = self.item_leaf_nodes.remove(item.id);
            self.nodes.append(self.allocator, .{
                .bounds = item.bounds,
                .left = null,
                .right = null,
                .parent = null,
                .start = 0,
                .count = 1,
            }) catch return false;
            self.root_index = 0;
            return true;
        }

        const leaf_index = self.findBestLeafForBounds(item.bounds) orelse return false;
        const insert_pos: usize = self.nodes.items[leaf_index].start + self.nodes.items[leaf_index].count;
        self.items.insert(self.allocator, insert_pos, item) catch return false;
        self.item_indices.put(item.id, insert_pos) catch return false;
        self.item_leaf_nodes.put(item.id, leaf_index) catch return false;
        self.nodes.items[leaf_index].count += 1;
        self.refitFromNode(leaf_index);

        if (self.nodes.items[leaf_index].count > max_leaf_items) {
            self.splitLeafNode(leaf_index);
        }

        return true;
    }

    pub fn removeItem(self: *PhysicsBvh, id: EntityId) bool {
        const item_index = self.item_indices.get(id) orelse return false;
        const leaf_node_index = self.item_leaf_nodes.get(id) orelse return false;

        _ = self.items.orderedRemove(item_index);
        _ = self.item_indices.remove(id);
        _ = self.item_leaf_nodes.remove(id);

        self.nodes.items[leaf_node_index].count -|= 1;
        self.refitFromNode(leaf_node_index);
        return true;
    }

    pub fn queryAabbCandidates(
        self: *const PhysicsBvh,
        allocator: std.mem.Allocator,
        query_bounds: AABB,
    ) ![]EntityId {
        var candidates = std.ArrayList(EntityId).empty;
        errdefer candidates.deinit(allocator);

        if (self.root_index) |root_index| {
            try self.collectAabbCandidatesRecursive(allocator, root_index, query_bounds, &candidates);
        }
        return try candidates.toOwnedSlice(allocator);
    }

    fn buildNode(self: *PhysicsBvh, start: usize, end: usize, parent: ?u32) !u32 {
        var node_bounds = AABB.empty();
        for (self.items.items[start..end]) |item| {
            node_bounds.expandAABB(item.bounds);
        }

        const node_index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .bounds = node_bounds,
            .left = null,
            .right = null,
            .parent = parent,
            .start = @intCast(start),
            .count = @intCast(end - start),
        });

        const item_count = end - start;
        if (item_count <= max_leaf_items) {
            for (self.items.items[start..end], start..) |item, item_index| {
                self.item_indices.put(item.id, item_index) catch return error.OutOfMemory;
                self.item_leaf_nodes.put(item.id, node_index) catch return error.OutOfMemory;
            }
            return node_index;
        }

        const axis = longestAxis(node_bounds);
        std.sort.heap(PhysicsBvhItem, self.items.items[start..end], axis, lessThanCentroid);
        const mid = start + item_count / 2;

        const left_index = try self.buildNode(start, mid, node_index);
        const right_index = try self.buildNode(mid, end, node_index);
        self.nodes.items[node_index] = .{
            .bounds = node_bounds,
            .left = left_index,
            .right = right_index,
            .parent = parent,
            .start = @intCast(start),
            .count = 0,
        };
        return node_index;
    }

    fn longestAxis(_: *PhysicsBvh, bounds: AABB) usize {
        const extent = bounds.extent();
        if (extent[1] > extent[0] and extent[1] >= extent[2]) {
            return 1;
        }
        if (extent[2] > extent[0] and extent[2] >= extent[1]) {
            return 2;
        }
        return 0;
    }

    fn refitFromNode(self: *PhysicsBvh, start_node_index: u32) void {
        var current: ?u32 = start_node_index;
        while (current) |node_index| {
            self.refitSingleNode(node_index);
            current = self.nodes.items[node_index].parent;
        }
    }

    fn refitSingleNode(self: *PhysicsBvh, node_index: u32) void {
        const node = self.nodes.items[node_index];
        var bounds = AABB.empty();
        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                bounds.expandAABB(item.bounds);
            }
        } else {
            bounds.expandAABB(self.nodes.items[node.left.?].bounds);
            bounds.expandAABB(self.nodes.items[node.right.?].bounds);
        }
        self.nodes.items[node_index].bounds = bounds;
    }

    fn findBestLeafForBounds(self: *const PhysicsBvh, bounds: AABB) ?u32 {
        if (self.root_index == null) return null;

        var current: u32 = self.root_index.?;
        while (!self.nodes.items[current].isLeaf()) {
            const node = self.nodes.items[current];
            const left_index = node.left.?;
            const right_index = node.right.?;
            current = if (self.insertionCost(self.nodes.items[left_index].bounds, bounds) <=
                self.insertionCost(self.nodes.items[right_index].bounds, bounds))
                left_index
            else
                right_index;
        }
        return current;
    }

    fn insertionCost(_: *const PhysicsBvh, existing: AABB, incoming: AABB) f32 {
        const combined = AABB{
            .min = vec3.min(existing.min, incoming.min),
            .max = vec3.max(existing.max, incoming.max),
        };
        const extent = combined.extent();
        return extent[0] * extent[1] * extent[2];
    }

    fn splitLeafNode(self: *PhysicsBvh, leaf_node_index: u32) void {
        const leaf = self.nodes.items[leaf_node_index];
        if (!leaf.isLeaf() or leaf.count <= max_leaf_items) return;

        const start: usize = leaf.start;
        const end = start + leaf.count;
        const split_bounds = self.computeBoundsForRange(start, end);
        const axis = longestAxis(split_bounds);
        std.sort.heap(PhysicsBvhItem, self.items.items[start..end], axis, lessThanCentroid);

        const mid = start + (end - start) / 2;
        const left_index: u32 = @intCast(self.nodes.items.len);
        const right_index: u32 = left_index + 1;
        const left_bounds = self.computeBoundsForRange(start, mid);
        const right_bounds = self.computeBoundsForRange(mid, end);

        self.nodes.appendAssumeCapacity(.{
            .bounds = left_bounds,
            .left = null,
            .right = null,
            .parent = leaf_node_index,
            .start = @intCast(start),
            .count = @intCast(mid - start),
        });
        self.nodes.appendAssumeCapacity(.{
            .bounds = right_bounds,
            .left = null,
            .right = null,
            .parent = leaf_node_index,
            .start = @intCast(mid),
            .count = @intCast(end - mid),
        });

        self.nodes.items[leaf_node_index] = .{
            .bounds = split_bounds,
            .left = left_index,
            .right = right_index,
            .parent = leaf.parent,
            .start = @intCast(start),
            .count = 0,
        };
        self.setLeafMappingsForRange(start, mid, left_index);
        self.setLeafMappingsForRange(mid, end, right_index);
        self.refitFromNode(leaf_node_index);
    }

    fn computeBoundsForRange(self: *const PhysicsBvh, start: usize, end: usize) AABB {
        var bounds = AABB.empty();
        for (self.items.items[start..end]) |item| {
            bounds.expandAABB(item.bounds);
        }
        return bounds;
    }

    fn setLeafMappingsForRange(self: *PhysicsBvh, start: usize, end: usize, leaf_node_index: u32) void {
        for (self.items.items[start..end], start..) |item, item_index| {
            self.item_indices.put(item.id, item_index) catch {};
            self.item_leaf_nodes.put(item.id, leaf_node_index) catch {};
        }
    }

    fn collectAabbCandidatesRecursive(
        self: *const PhysicsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        query_bounds: AABB,
        candidates: *std.ArrayList(EntityId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (!node.bounds.intersects(query_bounds)) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (item.bounds.intersects(query_bounds)) {
                    try candidates.append(allocator, item.id);
                }
            }
            return;
        }

        try self.collectAabbCandidatesRecursive(allocator, node.left.?, query_bounds, candidates);
        try self.collectAabbCandidatesRecursive(allocator, node.right.?, query_bounds, candidates);
    }

    pub fn getNodeCount(self: *const PhysicsBvh) usize {
        return self.nodes.items.len;
    }

    pub fn getLeafNode(self: *const PhysicsBvh, node_index: u32) ?PhysicsBvhNode {
        if (node_index >= self.nodes.items.len) return null;
        return self.nodes.items[node_index];
    }
};

fn lessThanCentroid(axis: usize, lhs: PhysicsBvhItem, rhs: PhysicsBvhItem) bool {
    const lhs_centroid = lhs.bounds.centroid();
    const rhs_centroid = rhs.bounds.centroid();
    return lhs_centroid[axis] < rhs_centroid[axis];
}

test "PhysicsBvh basic rebuild and query" {
    var bvh = PhysicsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .is_dynamic = false,
        },
        .{
            .id = 2,
            .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
            .is_dynamic = true,
        },
    });

    try std.testing.expect(bvh.getNodeCount() > 0);

    const candidates = try bvh.queryAabbCandidates(std.testing.allocator, .{
        .min = .{ 0.0, 0.0, 0.0 },
        .max = .{ 8.0, 2.0, 2.0 },
    });
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
}

test "PhysicsBvh insert and remove" {
    var bvh = PhysicsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .is_dynamic = false,
        },
    });

    try std.testing.expect(bvh.insertItem(.{
        .id = 2,
        .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
        .is_dynamic = true,
    }));

    const candidates = try bvh.queryAabbCandidates(std.testing.allocator, .{
        .min = .{ 0.0, 0.0, 0.0 },
        .max = .{ 8.0, 2.0, 2.0 },
    });
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);

    try std.testing.expect(bvh.removeItem(1));

    const after_remove = try bvh.queryAabbCandidates(std.testing.allocator, .{
        .min = .{ 0.0, 0.0, 0.0 },
        .max = .{ 8.0, 2.0, 2.0 },
    });
    defer std.testing.allocator.free(after_remove);
    try std.testing.expectEqual(@as(usize, 1), after_remove.len);
    try std.testing.expectEqual(@as(u64, 2), after_remove[0]);
}

test "PhysicsBvh non-overlapping query returns empty" {
    var bvh = PhysicsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
            .is_dynamic = false,
        },
        .{
            .id = 2,
            .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
            .is_dynamic = true,
        },
    });

    const candidates = try bvh.queryAabbCandidates(std.testing.allocator, .{
        .min = .{ 10.0, 0.0, 0.0 },
        .max = .{ 12.0, 2.0, 2.0 },
    });
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 0), candidates.len);
}
