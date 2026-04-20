const std = @import("std");
const components = @import("../scene/components.zig");

pub const Vec3 = components.Vec3;

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub fn mul(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

pub fn divSafe(a: Vec3, b: Vec3, epsilon: f32) Vec3 {
    return .{
        a[0] / if (@abs(b[0]) <= epsilon) 1.0 else b[0],
        a[1] / if (@abs(b[1]) <= epsilon) 1.0 else b[1],
        a[2] / if (@abs(b[2]) <= epsilon) 1.0 else b[2],
    };
}

pub fn scale(vector: Vec3, scalar: f32) Vec3 {
    return .{ vector[0] * scalar, vector[1] * scalar, vector[2] * scalar };
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn length(vector: Vec3) f32 {
    return std.math.sqrt(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]);
}

pub fn normalize(vector: Vec3) Vec3 {
    const len = length(vector);
    if (len <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return scale(vector, 1.0 / len);
}

test "Vec3 basic operations" {
    const a: Vec3 = .{ 1.0, 2.0, 3.0 };
    const b: Vec3 = .{ 4.0, 5.0, 6.0 };

    try std.testing.expectEqual(Vec3{ 5.0, 7.0, 9.0 }, add(a, b));
    try std.testing.expectEqual(Vec3{ -3.0, -3.0, -3.0 }, sub(a, b));
    try std.testing.expectEqual(Vec3{ 4.0, 10.0, 18.0 }, mul(a, b));
    try std.testing.expectEqual(32.0, dot(a, b));
}

test "Vec3 length and normalize" {
    const v: Vec3 = .{ 3.0, 0.0, 4.0 };
    try std.testing.expectEqual(5.0, length(v));
    const n = normalize(v);
    try std.testing.expectEqual(Vec3{ 0.6, 0.0, 0.8 }, n);
    try std.testing.expectEqual(1.0, length(n));
}

pub fn angleBetween(a: Vec3, b: Vec3) f32 {
    const a_norm = normalize(a);
    const b_norm = normalize(b);
    return std.math.acos(std.math.clamp(dot(a_norm, b_norm), -1.0, 1.0));
}

pub fn forwardFromAngles(yaw: f32, pitch: f32) Vec3 {
    const cos_pitch = std.math.cos(pitch);
    return normalize(.{
        -std.math.sin(yaw) * cos_pitch,
        std.math.sin(pitch),
        -std.math.cos(yaw) * cos_pitch,
    });
}

pub fn rightFromYaw(yaw: f32) Vec3 {
    return normalize(.{
        std.math.cos(yaw),
        0.0,
        -std.math.sin(yaw),
    });
}

test "angleBetween orthogonal vectors is ninety degrees" {
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.5), angleBetween(.{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }), 0.0001);
}

test "verify test logging appears in console" {
    std.log.info("[TEST] This is a test info message that should appear in console", .{});
    std.log.debug("[TEST] This is a test debug message that should appear in console", .{});
    std.log.warn("[TEST] This is a test warning message that should appear in console", .{});
    try std.testing.expect(true);
}
