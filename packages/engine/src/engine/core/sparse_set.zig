const std = @import("std");
const EntityId = @import("../scene/world.zig").EntityId;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        sparse: []usize,
        dense: []T,
        dense_entities: []EntityId,
        len: usize = 0,
        capacity: usize,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const sparse = try allocator.alloc(usize, capacity * 2);
            @memset(sparse, 0);

            const dense = try allocator.alloc(T, capacity);
            const dense_entities = try allocator.alloc(EntityId, capacity);

            return .{
                .sparse = sparse,
                .dense = dense,
                .dense_entities = dense_entities,
                .len = 0,
                .capacity = capacity,
            };
        }

        pub fn initNoFail(allocator: std.mem.Allocator, capacity: usize) Self {
            return init(allocator, capacity) catch @panic("SparseSet.initNoFail: allocation failed");
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.sparse);
            allocator.free(self.dense);
            allocator.free(self.dense_entities);
            self.* = undefined;
        }

        pub fn clear(self: *Self) void {
            for (0..self.len) |i| {
                self.sparse[self.dense_entities[i]] = 0;
            }
            self.len = 0;
        }

        pub fn contains(self: *const Self, entity_id: EntityId) bool {
            if (entity_id >= self.sparse.len) return false;
            return self.sparse[entity_id] != 0;
        }

        pub fn get(self: *const Self, entity_id: EntityId) ?*const T {
            if (!self.contains(entity_id)) return null;
            const index = self.sparse[entity_id] - 1;
            return &self.dense[index];
        }

        pub fn getPtr(self: *Self, entity_id: EntityId) ?*T {
            if (!self.contains(entity_id)) return null;
            const index = self.sparse[entity_id] - 1;
            return &self.dense[index];
        }

        pub fn insert(self: *Self, entity_id: EntityId, component: T) !void {
            if (self.contains(entity_id)) {
                return error.ComponentAlreadyExists;
            }

            if (self.len >= self.capacity) {
                return error.OutOfCapacity;
            }

            if (entity_id >= self.sparse.len) {
                return error.EntityIdOutOfRange;
            }

            self.sparse[entity_id] = self.len + 1;
            self.dense[self.len] = component;
            self.dense_entities[self.len] = entity_id;
            self.len += 1;
        }

        pub fn remove(self: *Self, entity_id: EntityId) void {
            if (!self.contains(entity_id)) return;

            const index = self.sparse[entity_id] - 1;
            const last_index = self.len - 1;

            if (index != last_index) {
                self.dense[index] = self.dense[last_index];
                self.dense_entities[index] = self.dense_entities[last_index];
                self.sparse[self.dense_entities[index]] = index + 1;
            }

            self.sparse[entity_id] = 0;
            self.len -= 1;
        }

        pub fn getOrCreate(self: *Self, entity_id: EntityId, default_fn: *const fn () T) !*T {
            if (self.getPtr(entity_id)) |ptr| {
                return ptr;
            }
            try self.insert(entity_id, default_fn());
            return self.getPtr(entity_id).?;
        }

        pub fn getOrInsert(self: *Self, entity_id: EntityId, default_value: T) !*T {
            if (self.getPtr(entity_id)) |ptr| {
                return ptr;
            }
            try self.insert(entity_id, default_value);
            return self.getPtr(entity_id).?;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{
                .dense = self.dense,
                .dense_entities = self.dense_entities,
                .len = self.len,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            dense: []const T,
            dense_entities: []const EntityId,
            len: usize,
            index: usize,

            pub fn next(self: *Iterator) ?struct { entity_id: EntityId, component: *const T } {
                if (self.index >= self.len) return null;
                const i = self.index;
                self.index += 1;
                return .{
                    .entity_id = self.dense_entities[i],
                    .component = &self.dense[i],
                };
            }

            pub fn nextPtr(self: *Iterator) ?struct { entity_id: EntityId, component: *const T } {
                if (self.index >= self.len) return null;
                const i = self.index;
                self.index += 1;
                return .{
                    .entity_id = self.dense_entities[i],
                    .component = &self.dense[i],
                };
            }
        };
    };
}

test "SparseSet basic operations" {
    const testing = std.testing;

    var set = try SparseSet(i32).init(testing.allocator, 100);
    defer set.deinit(testing.allocator);

    try testing.expect(!set.contains(1));
    try testing.expect(set.get(1) == null);

    try set.insert(1, 100);
    try testing.expect(set.contains(1));
    try testing.expect(set.get(1).?.* == 100);

    set.remove(1);
    try testing.expect(!set.contains(1));

    try set.insert(2, 200);
    try testing.expect(set.contains(2));
    set.remove(2);
    try testing.expect(!set.contains(2));
}

test "SparseSet iterator" {
    const testing = std.testing;

    var set = try SparseSet(i32).init(testing.allocator, 100);
    defer set.deinit(testing.allocator);

    try set.insert(10, 100);
    try set.insert(20, 200);
    try set.insert(30, 300);

    var count: usize = 0;
    var sum: i32 = 0;
    var iter = set.iterator();
    while (iter.nextPtr()) |item| {
        count += 1;
        sum += item.component.*;
    }

    try testing.expect(count == 3);
    try testing.expect(sum == 600);
}

test "SparseSet swap remove" {
    const testing = std.testing;

    var set = try SparseSet(i32).init(testing.allocator, 100);
    defer set.deinit(testing.allocator);

    try set.insert(1, 100);
    try set.insert(2, 200);
    try set.insert(3, 300);

    set.remove(2);

    try testing.expect(!set.contains(2));
    try testing.expect(set.contains(1));
    try testing.expect(set.contains(3));
    try testing.expect(set.len == 2);

    try testing.expect(set.get(1).?.* == 100);
    try testing.expect(set.get(3).?.* == 300);
}
