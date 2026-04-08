///! Behavior Tree system — ticks all entities with a BehaviorTreeComponent each frame.
const std = @import("std");
const bt = @import("behavior_tree.zig");
const world_mod = @import("../scene/world.zig");

pub const BehaviorTree = bt.BehaviorTree;
pub const Blackboard = bt.Blackboard;
pub const BlackboardValue = bt.BlackboardValue;
pub const Status = bt.Status;
pub const TickContext = bt.TickContext;
pub const TickFn = bt.TickFn;
pub const ConditionFn = bt.ConditionFn;
pub const Builder = bt.Builder;
pub const NodeKind = bt.NodeKind;

/// ECS component attached to entities that have a behavior tree.
pub const BehaviorTreeComponent = struct {
    tree: BehaviorTree,
    blackboard: Blackboard = .{},
    /// Whether the tree ticks each frame.
    enabled: bool = true,
    /// Last tick result.
    last_status: Status = .failure,

    pub fn deinit(self: *BehaviorTreeComponent, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        self.blackboard.deinit(allocator);
    }
};

/// Tick all entities that have a BehaviorTreeComponent.
pub fn update(world: *world_mod.World, delta_seconds: f32) void {
    if (delta_seconds <= 0.0) return;

    for (world.entities.items) |*entity| {
        const comp = &(entity.behavior_tree orelse continue);
        if (!comp.enabled) continue;

        var ctx = TickContext{
            .blackboard = &comp.blackboard,
            .allocator = world.allocator,
            .delta_seconds = delta_seconds,
            .entity_id = entity.id,
            .user_data = @ptrCast(world),
        };
        comp.last_status = comp.tree.tick(&ctx);
    }
}
