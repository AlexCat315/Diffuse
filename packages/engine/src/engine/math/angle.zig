const std = @import("std");

pub fn degreesToRadians(degrees: f32) f32 {
    return degrees * std.math.pi / 180.0;
}

pub fn radiansToDegrees(radians: f32) f32 {
    return radians * 180.0 / std.math.pi;
}

test "degreesToRadians converts right angles" {
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.5), degreesToRadians(90.0), 0.0001);
}

test "radiansToDegrees converts pi" {
    try std.testing.expectApproxEqAbs(@as(f32, 180.0), radiansToDegrees(std.math.pi), 0.0001);
}
