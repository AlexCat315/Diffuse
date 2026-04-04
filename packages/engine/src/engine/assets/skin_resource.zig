const std = @import("std");
const handles = @import("handles.zig");

pub const SkinResource = struct {
    name: []u8,
    skeleton: handles.SkeletonHandle,
    joint_entity_indices: []u32,
    inverse_bind_matrices: [][16]f32,

    pub fn deinit(self: *SkinResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.joint_entity_indices);
        allocator.free(self.inverse_bind_matrices);
        self.* = undefined;
    }
};

pub const SkinResourceDesc = struct {
    name: []const u8,
    skeleton: handles.SkeletonHandle,
    joint_entity_indices: []const u32,
    inverse_bind_matrices: []const [16]f32,
};

pub fn clone(allocator: std.mem.Allocator, desc: SkinResourceDesc) !SkinResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .skeleton = desc.skeleton,
        .joint_entity_indices = try allocator.dupe(u32, desc.joint_entity_indices),
        .inverse_bind_matrices = try allocator.dupe([16]f32, desc.inverse_bind_matrices),
    };
}

test "skin resource clone keeps inverse bind matrices" {
    const joint_indices = [_]u32{ 0, 1 };
    const inverse_bind_matrices = [_][16]f32{
        .{ 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 1.0 },
    };

    var resource = try clone(std.testing.allocator, .{
        .name = "SkinA",
        .skeleton = handles.skeletonHandle(0),
        .joint_entity_indices = joint_indices[0..],
        .inverse_bind_matrices = inverse_bind_matrices[0..],
    });
    defer resource.deinit(std.testing.allocator);

    try std.testing.expectEqual(handles.skeletonHandle(0), resource.skeleton);
    try std.testing.expectEqual(@as(usize, 2), resource.inverse_bind_matrices.len);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), resource.inverse_bind_matrices[1][12], 0.0001);
}
