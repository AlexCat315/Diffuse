const std = @import("std");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const spatial_log = std.log.scoped(.spatial_index);

pub const ItemId = u64;

pub const BoundsItem = struct {
    id: ItemId,
    bounds: AABB,
};

pub const RayCandidate = struct {
    id: ItemId,
    enter_distance: f32,
};

const Node = struct {
    bounds: AABB,
    left: ?u32,
    right: ?u32,
    parent: ?u32,
    start: u32,
    count: u32,

    fn isLeaf(self: Node) bool {
        return self.left == null and self.right == null;
    }
};

pub const StaticBoundsBvh = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(BoundsItem) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    root_index: ?u32 = null,
    item_indices: std.AutoHashMap(ItemId, usize),
    item_leaf_nodes: std.AutoHashMap(ItemId, u32),
    pending_additions: std.ArrayList(BoundsItem) = .empty,
    pending_addition_indices: std.AutoHashMap(ItemId, usize),
    pending_removals: std.AutoHashMap(ItemId, void),
    dirty: bool = true,

    const max_leaf_items: usize = 4;
    const max_incremental_overlay_items: usize = 24;
    const rebalance_ratio_threshold: usize = 3;
    const rebalance_min_items: usize = 8;

    pub fn init(allocator: std.mem.Allocator) StaticBoundsBvh {
        return .{
            .allocator = allocator,
            .item_indices = std.AutoHashMap(ItemId, usize).init(allocator),
            .item_leaf_nodes = std.AutoHashMap(ItemId, u32).init(allocator),
            .pending_addition_indices = std.AutoHashMap(ItemId, usize).init(allocator),
            .pending_removals = std.AutoHashMap(ItemId, void).init(allocator),
        };
    }

    pub fn deinit(self: *StaticBoundsBvh) void {
        self.items.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.item_indices.deinit();
        self.item_leaf_nodes.deinit();
        self.pending_additions.deinit(self.allocator);
        self.pending_addition_indices.deinit();
        self.pending_removals.deinit();
        self.* = undefined;
    }

    pub fn markDirty(self: *StaticBoundsBvh) void {
        self.dirty = true;
    }

    pub fn itemCount(self: *const StaticBoundsBvh) usize {
        return (self.items.items.len -| self.pending_removals.count()) + self.pending_additions.items.len;
    }

    pub fn nodeCount(self: *const StaticBoundsBvh) usize {
        return if (self.root_index) |root_index| self.activeNodeCountRecursive(root_index) else 0;
    }

    pub fn rebuild(self: *StaticBoundsBvh, source_items: []const BoundsItem) !void {
        self.items.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.item_indices.clearRetainingCapacity();
        self.item_leaf_nodes.clearRetainingCapacity();
        self.pending_additions.clearRetainingCapacity();
        self.pending_addition_indices.clearRetainingCapacity();
        self.pending_removals.clearRetainingCapacity();

        if (source_items.len == 0) {
            self.root_index = null;
            self.dirty = false;
            return;
        }

        try self.items.appendSlice(self.allocator, source_items);
        self.root_index = try self.buildNode(0, self.items.items.len, null);
        self.dirty = false;
    }

    pub fn updateItemBounds(self: *StaticBoundsBvh, id: ItemId, bounds: AABB) bool {
        if (self.pending_addition_indices.get(id)) |item_index| {
            self.pending_additions.items[item_index].bounds = bounds;
            return true;
        }
        if (self.pending_removals.contains(id)) {
            return false;
        }
        const item_index = self.item_indices.get(id) orelse return false;
        const leaf_node_index = self.item_leaf_nodes.get(id) orelse return false;
        self.items.items[item_index].bounds = bounds;
        self.refitFromNode(leaf_node_index);
        self.dirty = false;
        return true;
    }

    pub fn insertItem(self: *StaticBoundsBvh, item: BoundsItem) bool {
        if (self.dirty) {
            return false;
        }

        if (self.pending_addition_indices.get(item.id)) |item_index| {
            self.pending_additions.items[item_index] = item;
            return true;
        }

        if (self.pending_removals.remove(item.id)) {
            return self.updateItemBounds(item.id, item.bounds);
        }

        if (self.item_indices.contains(item.id)) {
            return self.updateItemBounds(item.id, item.bounds);
        }

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

        self.item_indices.ensureTotalCapacity(self.item_indices.count() + 1) catch return false;
        self.item_leaf_nodes.ensureTotalCapacity(self.item_leaf_nodes.count() + 1) catch return false;

        const leaf_index = self.findBestLeafForBounds(item.bounds) orelse return false;
        const insert_pos: usize = self.nodes.items[leaf_index].start + self.nodes.items[leaf_index].count;
        self.items.insert(self.allocator, insert_pos, item) catch return false;
        self.shiftItemIndicesAfterInsert(insert_pos);
        self.shiftNodeStartsAfterInsert(insert_pos, leaf_index);
        self.item_indices.put(item.id, insert_pos) catch return false;
        self.item_leaf_nodes.put(item.id, leaf_index) catch return false;
        self.nodes.items[leaf_index].count += 1;
        self.refitFromNode(leaf_index);

        if (self.nodes.items[leaf_index].count > max_leaf_items and !self.splitLeafNode(leaf_index)) {
            self.dirty = true;
            return false;
        }
        self.rebalanceFromNode(leaf_index);

        return true;
    }

    pub fn removeItem(self: *StaticBoundsBvh, id: ItemId) bool {
        if (self.dirty) {
            return false;
        }

        if (self.pending_addition_indices.get(id)) |item_index| {
            self.removePendingAdditionAt(item_index);
            return true;
        }

        if (!self.item_indices.contains(id) or self.pending_removals.contains(id)) {
            return false;
        }

        const item_index = self.item_indices.get(id) orelse return false;
        const leaf_node_index = self.item_leaf_nodes.get(id) orelse return false;
        _ = self.items.orderedRemove(item_index);
        _ = self.item_indices.remove(id);
        _ = self.item_leaf_nodes.remove(id);
        self.shiftItemIndicesAfterRemove(item_index);
        self.shiftNodeStartsAfterRemove(item_index, leaf_node_index);

        if (self.nodes.items[leaf_node_index].count > 0) {
            self.nodes.items[leaf_node_index].count -= 1;
        }

        if (self.nodes.items[leaf_node_index].count == 0) {
            if (!self.collapseEmptyLeaf(leaf_node_index)) {
                self.dirty = true;
                return false;
            }
            if (self.items.items.len == 0) {
                self.nodes.clearRetainingCapacity();
                self.root_index = null;
            }
            return true;
        }

        if (!self.tryMergeLeafWithSibling(leaf_node_index)) {
            self.refitFromNode(leaf_node_index);
        }
        self.rebalanceFromNode(leaf_node_index);
        return true;
    }

    pub fn queryRayCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]ItemId {
        var candidates = std.ArrayList(ItemId).empty;
        errdefer candidates.deinit(allocator);

        if (self.root_index) |root_index| {
            try self.collectRayCandidatesRecursive(allocator, root_index, ray_origin, ray_direction, max_distance, &candidates);
        }
        try self.collectPendingRayCandidates(allocator, ray_origin, ray_direction, max_distance, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRayCandidatesDetailed(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]RayCandidate {
        var candidates = std.ArrayList(RayCandidate).empty;
        errdefer candidates.deinit(allocator);

        if (self.root_index) |root_index| {
            try self.collectRayCandidateDetailsRecursive(allocator, root_index, ray_origin, ray_direction, max_distance, &candidates);
        }
        try self.collectPendingRayCandidateDetails(allocator, ray_origin, ray_direction, max_distance, &candidates);
        std.sort.heap(RayCandidate, candidates.items, {}, lessThanRayCandidateDistance);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryFrustumCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]ItemId {
        var candidates = std.ArrayList(ItemId).empty;
        errdefer candidates.deinit(allocator);

        if (self.root_index) |root_index| {
            try self.collectFrustumCandidatesRecursive(allocator, root_index, frustum, &candidates);
        }
        try self.collectPendingFrustumCandidates(allocator, frustum, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryAabbCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        query_bounds: AABB,
    ) ![]ItemId {
        var candidates = std.ArrayList(ItemId).empty;
        errdefer candidates.deinit(allocator);

        if (self.root_index) |root_index| {
            try self.collectAabbCandidatesRecursive(allocator, root_index, query_bounds, &candidates);
        }
        try self.collectPendingAabbCandidates(allocator, query_bounds, &candidates);
        return try candidates.toOwnedSlice(allocator);
    }

    fn buildNode(self: *StaticBoundsBvh, start: usize, end: usize, parent: ?u32) !u32 {
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
        std.sort.heap(BoundsItem, self.items.items[start..end], axis, lessThanCentroid);
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

    fn refitFromNode(self: *StaticBoundsBvh, start_node_index: u32) void {
        var current: ?u32 = start_node_index;
        while (current) |node_index| {
            self.refitSingleNode(node_index);
            current = self.nodes.items[node_index].parent;
        }
    }

    fn refitSingleNode(self: *StaticBoundsBvh, node_index: u32) void {
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

    fn activeNodeCountRecursive(self: *const StaticBoundsBvh, node_index: u32) usize {
        const node = self.nodes.items[node_index];
        if (node.isLeaf()) {
            return 1;
        }
        return 1 +
            self.activeNodeCountRecursive(node.left.?) +
            self.activeNodeCountRecursive(node.right.?);
    }

    fn findBestLeafForBounds(self: *const StaticBoundsBvh, bounds: AABB) ?u32 {
        if (self.root_index == null) {
            return null;
        }

        var current: u32 = self.root_index.?;
        while (!self.nodes.items[current].isLeaf()) {
            const node = self.nodes.items[current];
            const left_index = node.left.?;
            const right_index = node.right.?;
            current = if (insertionCost(self.nodes.items[left_index].bounds, bounds) <= insertionCost(self.nodes.items[right_index].bounds, bounds))
                left_index
            else
                right_index;
        }
        return current;
    }

    fn splitLeafNode(self: *StaticBoundsBvh, leaf_node_index: u32) bool {
        const leaf = self.nodes.items[leaf_node_index];
        if (!leaf.isLeaf() or leaf.count <= max_leaf_items) {
            return true;
        }

        self.nodes.ensureUnusedCapacity(self.allocator, 2) catch return false;

        const start: usize = leaf.start;
        const end = start + leaf.count;
        const split_bounds = computeBoundsForRange(self.items.items, start, end);
        const axis = longestAxis(split_bounds);
        std.sort.heap(BoundsItem, self.items.items[start..end], axis, lessThanCentroid);

        const mid = start + (end - start) / 2;
        const left_index: u32 = @intCast(self.nodes.items.len);
        const right_index: u32 = left_index + 1;
        const left_bounds = computeBoundsForRange(self.items.items, start, mid);
        const right_bounds = computeBoundsForRange(self.items.items, mid, end);

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
        return true;
    }

    fn collapseEmptyLeaf(self: *StaticBoundsBvh, leaf_node_index: u32) bool {
        if (self.items.items.len == 0) {
            self.nodes.clearRetainingCapacity();
            self.root_index = null;
            return true;
        }

        const leaf = self.nodes.items[leaf_node_index];
        const parent_index = leaf.parent orelse return false;
        const sibling_index = siblingNodeIndex(self.nodes.items[parent_index], leaf_node_index) orelse return false;
        return self.collapseParentIntoSibling(parent_index, sibling_index);
    }

    fn tryMergeLeafWithSibling(self: *StaticBoundsBvh, leaf_node_index: u32) bool {
        const leaf = self.nodes.items[leaf_node_index];
        const parent_index = leaf.parent orelse return false;
        const sibling_index = siblingNodeIndex(self.nodes.items[parent_index], leaf_node_index) orelse return false;
        const sibling = self.nodes.items[sibling_index];
        if (!sibling.isLeaf()) {
            return false;
        }

        const combined_count = leaf.count + sibling.count;
        if (combined_count > max_leaf_items) {
            return false;
        }

        const merged_start = @min(leaf.start, sibling.start);
        const merged_end = merged_start + combined_count;
        self.nodes.items[parent_index] = .{
            .bounds = computeBoundsForRange(self.items.items, merged_start, merged_end),
            .left = null,
            .right = null,
            .parent = self.nodes.items[parent_index].parent,
            .start = merged_start,
            .count = combined_count,
        };
        self.setLeafMappingsForRange(merged_start, merged_end, parent_index);
        self.refitFromNode(parent_index);
        return true;
    }

    fn rebalanceFromNode(self: *StaticBoundsBvh, start_node_index: u32) void {
        var current: ?u32 = start_node_index;
        while (current) |node_index| {
            const rotated_root = self.rebalanceSingleNode(node_index) orelse {
                self.dirty = true;
                return;
            };
            current = self.nodes.items[rotated_root].parent;
        }
    }

    fn rebalanceSingleNode(self: *StaticBoundsBvh, node_index: u32) ?u32 {
        var current = node_index;
        while (true) {
            const node = self.nodes.items[current];
            if (node.isLeaf()) {
                return current;
            }

            const left_index = node.left.?;
            const right_index = node.right.?;
            const left_count = self.subtreeItemCount(left_index);
            const right_count = self.subtreeItemCount(right_index);

            if (isImbalanced(left_count, right_count)) {
                if (left_count > right_count) {
                    if (!self.nodes.items[left_index].isLeaf()) {
                        const left_left_count = self.subtreeItemCount(self.nodes.items[left_index].left.?);
                        const left_right_count = self.subtreeItemCount(self.nodes.items[left_index].right.?);
                        if (left_right_count > left_left_count) {
                            _ = self.rotateLeft(left_index) orelse return null;
                        }
                        current = self.rotateRight(current) orelse return null;
                        spatial_log.debug("local bvh rotation direction=right active_nodes={}", .{self.nodeCount()});
                        continue;
                    }
                } else {
                    if (!self.nodes.items[right_index].isLeaf()) {
                        const right_left_count = self.subtreeItemCount(self.nodes.items[right_index].left.?);
                        const right_right_count = self.subtreeItemCount(self.nodes.items[right_index].right.?);
                        if (right_left_count > right_right_count) {
                            _ = self.rotateRight(right_index) orelse return null;
                        }
                        current = self.rotateLeft(current) orelse return null;
                        spatial_log.debug("local bvh rotation direction=left active_nodes={}", .{self.nodeCount()});
                        continue;
                    }
                }
            }

            self.refitSingleNode(current);
            return current;
        }
    }

    fn rotateLeft(self: *StaticBoundsBvh, pivot_index: u32) ?u32 {
        const pivot = self.nodes.items[pivot_index];
        const right_index = pivot.right orelse return null;
        const right = self.nodes.items[right_index];
        const transfer_index = right.left orelse return null;
        const parent_index = pivot.parent;

        self.nodes.items[pivot_index].right = transfer_index;
        self.nodes.items[transfer_index].parent = pivot_index;

        self.nodes.items[right_index].left = pivot_index;
        self.nodes.items[right_index].parent = parent_index;
        self.nodes.items[pivot_index].parent = right_index;

        self.replaceParentChildLink(parent_index, pivot_index, right_index);
        self.refitSingleNode(pivot_index);
        self.refitSingleNode(right_index);
        return right_index;
    }

    fn rotateRight(self: *StaticBoundsBvh, pivot_index: u32) ?u32 {
        const pivot = self.nodes.items[pivot_index];
        const left_index = pivot.left orelse return null;
        const left = self.nodes.items[left_index];
        const transfer_index = left.right orelse return null;
        const parent_index = pivot.parent;

        self.nodes.items[pivot_index].left = transfer_index;
        self.nodes.items[transfer_index].parent = pivot_index;

        self.nodes.items[left_index].right = pivot_index;
        self.nodes.items[left_index].parent = parent_index;
        self.nodes.items[pivot_index].parent = left_index;

        self.replaceParentChildLink(parent_index, pivot_index, left_index);
        self.refitSingleNode(pivot_index);
        self.refitSingleNode(left_index);
        return left_index;
    }

    fn replaceParentChildLink(self: *StaticBoundsBvh, parent_index: ?u32, old_child: u32, new_child: u32) void {
        if (parent_index) |resolved_parent_index| {
            if (self.nodes.items[resolved_parent_index].left == old_child) {
                self.nodes.items[resolved_parent_index].left = new_child;
            } else if (self.nodes.items[resolved_parent_index].right == old_child) {
                self.nodes.items[resolved_parent_index].right = new_child;
            }
        } else {
            self.root_index = new_child;
        }
    }

    fn subtreeItemCount(self: *const StaticBoundsBvh, node_index: u32) usize {
        const node = self.nodes.items[node_index];
        if (node.isLeaf()) {
            return @intCast(node.count);
        }
        return self.subtreeItemCount(node.left.?) + self.subtreeItemCount(node.right.?);
    }

    fn collapseParentIntoSibling(self: *StaticBoundsBvh, parent_index: u32, sibling_index: u32) bool {
        const parent_parent = self.nodes.items[parent_index].parent;
        const sibling = self.nodes.items[sibling_index];
        if (sibling.isLeaf()) {
            const start: usize = sibling.start;
            const end = start + sibling.count;
            self.nodes.items[parent_index] = .{
                .bounds = computeBoundsForRange(self.items.items, start, end),
                .left = null,
                .right = null,
                .parent = parent_parent,
                .start = sibling.start,
                .count = sibling.count,
            };
            self.setLeafMappingsForRange(start, end, parent_index);
        } else {
            self.nodes.items[parent_index] = sibling;
            self.nodes.items[parent_index].parent = parent_parent;
            if (sibling.left) |left_index| {
                self.nodes.items[left_index].parent = parent_index;
            }
            if (sibling.right) |right_index| {
                self.nodes.items[right_index].parent = parent_index;
            }
        }
        self.refitFromNode(parent_index);
        return true;
    }

    fn setLeafMappingsForRange(self: *StaticBoundsBvh, start: usize, end: usize, leaf_node_index: u32) void {
        for (self.items.items[start..end], start..) |item, item_index| {
            self.item_indices.put(item.id, item_index) catch {};
            self.item_leaf_nodes.put(item.id, leaf_node_index) catch {};
        }
    }

    fn shiftItemIndicesAfterInsert(self: *StaticBoundsBvh, insert_index: usize) void {
        var item_index = insert_index + 1;
        while (item_index < self.items.items.len) : (item_index += 1) {
            self.item_indices.put(self.items.items[item_index].id, item_index) catch {};
        }
    }

    fn shiftItemIndicesAfterRemove(self: *StaticBoundsBvh, removed_index: usize) void {
        var item_index = removed_index;
        while (item_index < self.items.items.len) : (item_index += 1) {
            self.item_indices.put(self.items.items[item_index].id, item_index) catch {};
        }
    }

    fn shiftNodeStartsAfterInsert(self: *StaticBoundsBvh, insert_index: usize, inserted_leaf: u32) void {
        for (self.nodes.items, 0..) |*node, node_index| {
            if (node_index == inserted_leaf) {
                continue;
            }
            if (node.start >= insert_index) {
                node.start += 1;
            }
        }
    }

    fn shiftNodeStartsAfterRemove(self: *StaticBoundsBvh, removed_index: usize, removed_leaf: u32) void {
        for (self.nodes.items, 0..) |*node, node_index| {
            if (node_index == removed_leaf) {
                continue;
            }
            if (node.start > removed_index) {
                node.start -= 1;
            }
        }
    }

    fn collectRayCandidatesRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (node.bounds.rayIntersection(ray_origin, ray_direction, max_distance) == null) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
                if (item.bounds.rayIntersection(ray_origin, ray_direction, max_distance) != null) {
                    try candidates.append(allocator, item.id);
                }
            }
            return;
        }

        const left_index = node.left.?;
        const right_index = node.right.?;
        const left_hit = self.nodes.items[left_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);
        const right_hit = self.nodes.items[right_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);

        if (left_hit != null and right_hit != null) {
            if (left_hit.?.enter_distance <= right_hit.?.enter_distance) {
                try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
            } else {
                try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
            }
            return;
        }

        if (left_hit != null) {
            try self.collectRayCandidatesRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
        }
        if (right_hit != null) {
            try self.collectRayCandidatesRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
        }
    }

    fn collectFrustumCandidatesRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        frustum: frustum_mod.Frustum,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (!frustum.intersectsAABB(node.bounds)) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
                if (frustum.intersectsAABB(item.bounds)) {
                    try candidates.append(allocator, item.id);
                }
            }
            return;
        }

        try self.collectFrustumCandidatesRecursive(allocator, node.left.?, frustum, candidates);
        try self.collectFrustumCandidatesRecursive(allocator, node.right.?, frustum, candidates);
    }

    fn collectPendingRayCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        for (self.pending_additions.items) |item| {
            if (item.bounds.rayIntersection(ray_origin, ray_direction, max_distance) != null) {
                try candidates.append(allocator, item.id);
            }
        }
    }

    fn collectRayCandidateDetailsRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(RayCandidate),
    ) !void {
        const node = self.nodes.items[node_index];
        if (node.bounds.rayIntersection(ray_origin, ray_direction, max_distance) == null) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
                const hit = item.bounds.rayIntersection(ray_origin, ray_direction, max_distance) orelse continue;
                try candidates.append(allocator, .{
                    .id = item.id,
                    .enter_distance = hit.enter_distance,
                });
            }
            return;
        }

        const left_index = node.left.?;
        const right_index = node.right.?;
        const left_hit = self.nodes.items[left_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);
        const right_hit = self.nodes.items[right_index].bounds.rayIntersection(ray_origin, ray_direction, max_distance);

        if (left_hit != null and right_hit != null) {
            if (left_hit.?.enter_distance <= right_hit.?.enter_distance) {
                try self.collectRayCandidateDetailsRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidateDetailsRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
            } else {
                try self.collectRayCandidateDetailsRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
                try self.collectRayCandidateDetailsRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
            }
            return;
        }

        if (left_hit != null) {
            try self.collectRayCandidateDetailsRecursive(allocator, left_index, ray_origin, ray_direction, max_distance, candidates);
        }
        if (right_hit != null) {
            try self.collectRayCandidateDetailsRecursive(allocator, right_index, ray_origin, ray_direction, max_distance, candidates);
        }
    }

    fn collectPendingRayCandidateDetails(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
        candidates: *std.ArrayList(RayCandidate),
    ) !void {
        for (self.pending_additions.items) |item| {
            const hit = item.bounds.rayIntersection(ray_origin, ray_direction, max_distance) orelse continue;
            try candidates.append(allocator, .{
                .id = item.id,
                .enter_distance = hit.enter_distance,
            });
        }
    }

    fn collectPendingFrustumCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        for (self.pending_additions.items) |item| {
            if (frustum.intersectsAABB(item.bounds)) {
                try candidates.append(allocator, item.id);
            }
        }
    }

    fn collectAabbCandidatesRecursive(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        node_index: u32,
        query_bounds: AABB,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        const node = self.nodes.items[node_index];
        if (!node.bounds.intersects(query_bounds)) {
            return;
        }

        if (node.isLeaf()) {
            const start: usize = node.start;
            const end = start + node.count;
            for (self.items.items[start..end]) |item| {
                if (self.pending_removals.contains(item.id)) {
                    continue;
                }
                if (item.bounds.intersects(query_bounds)) {
                    try candidates.append(allocator, item.id);
                }
            }
            return;
        }

        try self.collectAabbCandidatesRecursive(allocator, node.left.?, query_bounds, candidates);
        try self.collectAabbCandidatesRecursive(allocator, node.right.?, query_bounds, candidates);
    }

    fn collectPendingAabbCandidates(
        self: *const StaticBoundsBvh,
        allocator: std.mem.Allocator,
        query_bounds: AABB,
        candidates: *std.ArrayList(ItemId),
    ) !void {
        for (self.pending_additions.items) |item| {
            if (item.bounds.intersects(query_bounds)) {
                try candidates.append(allocator, item.id);
            }
        }
    }

    fn removePendingAdditionAt(self: *StaticBoundsBvh, item_index: usize) void {
        const removed_id = self.pending_additions.items[item_index].id;
        const moved_item = self.pending_additions.items[self.pending_additions.items.len - 1];
        _ = self.pending_additions.swapRemove(item_index);
        _ = self.pending_addition_indices.remove(removed_id);
        if (item_index < self.pending_additions.items.len) {
            self.pending_addition_indices.put(moved_item.id, item_index) catch {};
        }
    }

    fn markDirtyIfOverlayTooLarge(self: *StaticBoundsBvh) void {
        const overlay_items = self.pending_additions.items.len + self.pending_removals.count();
        if (overlay_items >= max_incremental_overlay_items or
            overlay_items * 2 > self.items.items.len + self.pending_additions.items.len)
        {
            self.dirty = true;
        }
    }
};

fn longestAxis(bounds: AABB) usize {
    const extent = bounds.extent();
    if (extent[1] > extent[0] and extent[1] >= extent[2]) {
        return 1;
    }
    if (extent[2] > extent[0] and extent[2] >= extent[1]) {
        return 2;
    }
    return 0;
}

fn lessThanCentroid(axis: usize, lhs: BoundsItem, rhs: BoundsItem) bool {
    return lhs.bounds.centroid()[axis] < rhs.bounds.centroid()[axis];
}

fn computeBoundsForRange(items: []const BoundsItem, start: usize, end: usize) AABB {
    var bounds = AABB.empty();
    for (items[start..end]) |item| {
        bounds.expandAABB(item.bounds);
    }
    return bounds;
}

fn insertionCost(existing: AABB, incoming: AABB) f32 {
    return boundsVolume(combinedBounds(existing, incoming)) - boundsVolume(existing);
}

fn combinedBounds(a: AABB, b: AABB) AABB {
    var bounds = a;
    bounds.expandAABB(b);
    return bounds;
}

fn boundsVolume(bounds: AABB) f32 {
    const extent = bounds.extent();
    return extent[0] * extent[1] * extent[2];
}

fn siblingNodeIndex(parent: Node, child_index: u32) ?u32 {
    if (parent.left == child_index) return parent.right;
    if (parent.right == child_index) return parent.left;
    return null;
}

fn lessThanRayCandidateDistance(_: void, lhs: RayCandidate, rhs: RayCandidate) bool {
    return lhs.enter_distance < rhs.enter_distance;
}

fn isImbalanced(left_count: usize, right_count: usize) bool {
    const larger = @max(left_count, right_count);
    const smaller = @min(left_count, right_count);
    if (larger < StaticBoundsBvh.rebalance_min_items) {
        return false;
    }
    if (smaller == 0) {
        return true;
    }
    return larger >= smaller * StaticBoundsBvh.rebalance_ratio_threshold;
}

test "StaticBoundsBvh returns only ray-overlapping candidates" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        },
        .{
            .id = 2,
            .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
        },
        .{
            .id = 3,
            .bounds = .{ .min = .{ -1.0, 5.0, -1.0 }, .max = .{ 1.0, 7.0, 1.0 } },
        },
    });

    const candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(@as(ItemId, 1), candidates[0]);
    try std.testing.expectEqual(@as(ItemId, 2), candidates[1]);
}

test "StaticBoundsBvh can refit a moved item in place" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        },
        .{
            .id = 2,
            .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
        },
    });

    try std.testing.expect(bvh.updateItemBounds(2, .{
        .min = .{ 10.0, -1.0, -1.0 },
        .max = .{ 12.0, 1.0, 1.0 },
    }));

    const old_ray_candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        9.0,
    );
    defer std.testing.allocator.free(old_ray_candidates);
    try std.testing.expectEqual(@as(usize, 1), old_ray_candidates.len);
    try std.testing.expectEqual(@as(ItemId, 1), old_ray_candidates[0]);

    const moved_ray_candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ 8.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        8.0,
    );
    defer std.testing.allocator.free(moved_ray_candidates);
    try std.testing.expectEqual(@as(usize, 1), moved_ray_candidates.len);
    try std.testing.expectEqual(@as(ItemId, 2), moved_ray_candidates[0]);
}

test "StaticBoundsBvh supports incremental insert and remove overlays" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{
            .id = 1,
            .bounds = .{ .min = .{ -1.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } },
        },
    });
    const initial_node_count = bvh.nodeCount();

    try std.testing.expect(bvh.insertItem(.{
        .id = 2,
        .bounds = .{ .min = .{ 5.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } },
    }));
    try std.testing.expectEqual(initial_node_count, bvh.nodeCount());

    const with_insert = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(with_insert);
    try std.testing.expectEqual(@as(usize, 2), with_insert.len);

    try std.testing.expect(bvh.removeItem(1));
    try std.testing.expectEqual(initial_node_count, bvh.nodeCount());

    const after_remove = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -3.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_remove);
    try std.testing.expectEqual(@as(usize, 1), after_remove.len);
    try std.testing.expectEqual(@as(ItemId, 2), after_remove[0]);
}

test "StaticBoundsBvh performs in-tree split and merge" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{ .id = 1, .bounds = .{ .min = .{ -4.0, -1.0, -1.0 }, .max = .{ -3.0, 1.0, 1.0 } } },
        .{ .id = 2, .bounds = .{ .min = .{ -2.0, -1.0, -1.0 }, .max = .{ -1.0, 1.0, 1.0 } } },
        .{ .id = 3, .bounds = .{ .min = .{ 0.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } } },
        .{ .id = 4, .bounds = .{ .min = .{ 2.0, -1.0, -1.0 }, .max = .{ 3.0, 1.0, 1.0 } } },
    });
    const initial_node_count = bvh.nodeCount();

    try std.testing.expect(bvh.insertItem(.{
        .id = 5,
        .bounds = .{ .min = .{ 4.0, -1.0, -1.0 }, .max = .{ 5.0, 1.0, 1.0 } },
    }));
    try std.testing.expect(bvh.nodeCount() > initial_node_count);

    try std.testing.expect(bvh.removeItem(5));
    try std.testing.expect(bvh.itemCount() == 4);

    const candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -6.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 4), candidates.len);
}

test "StaticBoundsBvh local rotations update active root" {
    var bvh = StaticBoundsBvh.init(std.testing.allocator);
    defer bvh.deinit();

    try bvh.rebuild(&.{
        .{ .id = 1, .bounds = .{ .min = .{ -6.0, -1.0, -1.0 }, .max = .{ -5.0, 1.0, 1.0 } } },
        .{ .id = 2, .bounds = .{ .min = .{ -4.0, -1.0, -1.0 }, .max = .{ -3.0, 1.0, 1.0 } } },
        .{ .id = 3, .bounds = .{ .min = .{ -2.0, -1.0, -1.0 }, .max = .{ -1.0, 1.0, 1.0 } } },
        .{ .id = 4, .bounds = .{ .min = .{ 0.0, -1.0, -1.0 }, .max = .{ 1.0, 1.0, 1.0 } } },
        .{ .id = 5, .bounds = .{ .min = .{ 2.0, -1.0, -1.0 }, .max = .{ 3.0, 1.0, 1.0 } } },
        .{ .id = 6, .bounds = .{ .min = .{ 4.0, -1.0, -1.0 }, .max = .{ 5.0, 1.0, 1.0 } } },
        .{ .id = 7, .bounds = .{ .min = .{ 6.0, -1.0, -1.0 }, .max = .{ 7.0, 1.0, 1.0 } } },
        .{ .id = 8, .bounds = .{ .min = .{ 8.0, -1.0, -1.0 }, .max = .{ 9.0, 1.0, 1.0 } } },
    });

    const initial_root = bvh.root_index.?;
    for (9..19) |id| {
        const min_x = @as(f32, @floatFromInt((id - 9) * 2 + 10));
        try std.testing.expect(bvh.insertItem(.{
            .id = @intCast(id),
            .bounds = .{
                .min = .{ min_x, -1.0, -1.0 },
                .max = .{ min_x + 1.0, 1.0, 1.0 },
            },
        }));
    }
    try std.testing.expect(bvh.root_index.? != initial_root);

    const candidates = try bvh.queryRayCandidates(
        std.testing.allocator,
        .{ -8.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        48.0,
    );
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 18), candidates.len);
    try std.testing.expect(bvh.nodeCount() > 0);
}
