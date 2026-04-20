const std = @import("std");
const components = @import("../scene/components.zig");

pub const Joint = struct {
    name: []u8,
    node_entity_index: u32,
    parent_joint_index: ?u32 = null,
    rest_local_transform: components.Transform = .{},

    fn cloneOwned(self: Joint, allocator: std.mem.Allocator) !Joint {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .node_entity_index = self.node_entity_index,
            .parent_joint_index = self.parent_joint_index,
            .rest_local_transform = self.rest_local_transform,
        };
    }

    fn deinit(self: *Joint, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const JointDesc = struct {
    name: []const u8,
    node_entity_index: u32,
    parent_joint_index: ?u32 = null,
    rest_local_transform: components.Transform = .{},
};

pub const SkeletonResource = struct {
    name: []u8,
    joints: []Joint,

    pub fn deinit(self: *SkeletonResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.joints) |*joint| {
            joint.deinit(allocator);
        }
        allocator.free(self.joints);
        self.* = undefined;
    }
};

pub const SkeletonResourceDesc = struct {
    name: []const u8,
    joints: []const JointDesc,
};

pub fn clone(allocator: std.mem.Allocator, desc: SkeletonResourceDesc) !SkeletonResource {
    const joints = try allocator.alloc(Joint, desc.joints.len);
    errdefer allocator.free(joints);

    var joint_index: usize = 0;
    errdefer {
        while (joint_index > 0) {
            joint_index -= 1;
            joints[joint_index].deinit(allocator);
        }
    }

    for (desc.joints, 0..) |joint, index| {
        joints[index] = .{
            .name = try allocator.dupe(u8, joint.name),
            .node_entity_index = joint.node_entity_index,
            .parent_joint_index = joint.parent_joint_index,
            .rest_local_transform = joint.rest_local_transform,
        };
        joint_index = index + 1;
    }

    return .{
        .name = try allocator.dupe(u8, desc.name),
        .joints = joints,
    };
}

test "skeleton resource clone owns joint metadata" {
    const desc_joints = [_]JointDesc{
        .{
            .name = "Root",
            .node_entity_index = 0,
        },
        .{
            .name = "Arm",
            .node_entity_index = 1,
            .parent_joint_index = 0,
            .rest_local_transform = .{
                .translation = .{ 1.0, 0.0, 0.0 },
            },
        },
    };

    var resource = try clone(std.testing.allocator, .{
        .name = "TestSkeleton",
        .joints = desc_joints[0..],
    });
    defer resource.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), resource.joints.len);
    try std.testing.expectEqualStrings("TestSkeleton", resource.name);
    try std.testing.expectEqual(@as(u32, 1), resource.joints[1].node_entity_index);
    try std.testing.expectEqual(@as(?u32, 0), resource.joints[1].parent_joint_index);
}
