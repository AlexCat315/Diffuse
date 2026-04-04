const std = @import("std");
const rhi_types = @import("types.zig");

pub const ResourceStates = rhi_types.ResourceStates;
pub const ResourceKind = rhi_types.ResourceKind;
pub const ResourceRef = rhi_types.ResourceRef;

pub const Barrier = struct {
    resource: ResourceRef,
    before: ResourceStates,
    after: ResourceStates,
    cross_queue: bool = false,
};

pub const StateTracker = struct {
    allocator: std.mem.Allocator,
    current_states: std.AutoHashMap(ResourceRef, u32),
    pending_barriers: std.ArrayList(Barrier),

    pub fn init(allocator: std.mem.Allocator) StateTracker {
        return .{
            .allocator = allocator,
            .current_states = std.AutoHashMap(ResourceRef, u32).init(allocator),
            .pending_barriers = .empty,
        };
    }

    pub fn deinit(self: *StateTracker) void {
        self.current_states.deinit();
        self.pending_barriers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *StateTracker) void {
        self.current_states.clearRetainingCapacity();
        self.pending_barriers.clearRetainingCapacity();
    }

    pub fn setInitialState(self: *StateTracker, resource: ResourceRef, state: ResourceStates) !void {
        try self.current_states.put(resource, state.asBits());
    }

    pub fn setCurrentState(self: *StateTracker, resource: ResourceRef, state: ResourceStates) !void {
        try self.current_states.put(resource, state.asBits());
    }

    pub fn currentState(self: *const StateTracker, resource: ResourceRef) ResourceStates {
        const bits = self.current_states.get(resource) orelse 0;
        return ResourceStates.fromBits(bits);
    }

    pub fn removeResource(self: *StateTracker, resource: ResourceRef) void {
        _ = self.current_states.remove(resource);
    }

    pub fn requireState(self: *StateTracker, resource: ResourceRef, desired: ResourceStates) !void {
        const desired_bits = desired.asBits();
        const current_bits = self.current_states.get(resource) orelse 0;

        if (current_bits == desired_bits) return;

        try self.pending_barriers.append(self.allocator, .{
            .resource = resource,
            .before = ResourceStates.fromBits(current_bits),
            .after = desired,
        });
        try self.current_states.put(resource, desired_bits);
    }

    pub fn commitBarriers(self: *StateTracker, allocator: std.mem.Allocator) ![]Barrier {
        if (self.pending_barriers.items.len == 0) {
            return allocator.alloc(Barrier, 0);
        }
        defer self.pending_barriers.clearRetainingCapacity();

        // Merge adjacent transitions for the same subresource by OR-ing target states.
        var merged = std.AutoHashMap(ResourceRef, Barrier).init(allocator);
        defer merged.deinit();

        for (self.pending_barriers.items) |barrier| {
            if (merged.getPtr(barrier.resource)) |existing| {
                const combined = existing.after.asBits() | barrier.after.asBits();
                existing.after = ResourceStates.fromBits(combined);
            } else {
                try merged.put(barrier.resource, barrier);
            }
        }

        var out = std.ArrayList(Barrier).empty;
        defer out.deinit(allocator);

        var it = merged.valueIterator();
        while (it.next()) |value| {
            try out.append(allocator, value.*);
        }

        return out.toOwnedSlice(allocator);
    }
};

test "state tracker emits barrier on state change" {
    var tracker = StateTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const res = ResourceRef{ .kind = .texture, .id = 7 };
    try tracker.setInitialState(res, ResourceStates{ .shader_resource = true });
    try tracker.requireState(res, ResourceStates{ .unordered_access = true });

    const barriers = try tracker.commitBarriers(std.testing.allocator);
    defer std.testing.allocator.free(barriers);

    try std.testing.expectEqual(@as(usize, 1), barriers.len);
    try std.testing.expect(barriers[0].before.shader_resource);
    try std.testing.expect(barriers[0].after.unordered_access);
}

test "state tracker merges repeated transitions" {
    var tracker = StateTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const res = ResourceRef{ .kind = .texture, .id = 42 };
    try tracker.requireState(res, ResourceStates{ .shader_resource = true });
    try tracker.requireState(res, ResourceStates{ .unordered_access = true });

    const barriers = try tracker.commitBarriers(std.testing.allocator);
    defer std.testing.allocator.free(barriers);

    try std.testing.expectEqual(@as(usize, 1), barriers.len);
    try std.testing.expect(barriers[0].after.shader_resource or barriers[0].after.unordered_access);
}
