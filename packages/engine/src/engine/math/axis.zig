const std = @import("std");
const vec3 = @import("vec3.zig");

pub const Axis3 = enum {
    free,
    x,
    y,
    z,
};

pub fn vector(axis: Axis3) vec3.Vec3 {
    return switch (axis) {
        .free => .{ 0.0, 0.0, 0.0 },
        .x => .{ 1.0, 0.0, 0.0 },
        .y => .{ 0.0, 1.0, 0.0 },
        .z => .{ 0.0, 0.0, 1.0 },
    };
}

test "vector returns unit directions" {
    try std.testing.expectEqual(vec3.Vec3{ 1.0, 0.0, 0.0 }, vector(.x));
    try std.testing.expectEqual(vec3.Vec3{ 0.0, 1.0, 0.0 }, vector(.y));
    try std.testing.expectEqual(vec3.Vec3{ 0.0, 0.0, 1.0 }, vector(.z));
}
