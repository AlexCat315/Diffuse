const std = @import("std");

/// Easing function applied between two keyframes.
pub const EasingMode = enum {
    linear,
    step,
    ease_in,
    ease_out,
    ease_in_out,

    pub fn evaluate(self: EasingMode, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .step => if (t < 1.0) @as(f32, 0.0) else 1.0,
            .ease_in => t * t,
            .ease_out => t * (2.0 - t),
            .ease_in_out => blk: {
                const s = t * 2.0;
                break :blk if (s < 1.0)
                    s * s * 0.5
                else
                    -0.5 * ((s - 1.0) * (s - 3.0) - 1.0);
            },
        };
    }
};

/// A single keyframe holding a value at a specific point in time.
pub fn Keyframe(comptime T: type) type {
    return struct {
        time: f32,
        value: T,
        easing: EasingMode = .linear,
    };
}

/// Scalar keyframe (e.g. fov, intensity, opacity).
pub const ScalarKeyframe = Keyframe(f32);

/// Vec3 keyframe (position, scale, color).
pub const Vec3Keyframe = Keyframe([3]f32);

/// Quaternion keyframe (rotation).
pub const QuatKeyframe = Keyframe([4]f32);

// ---------------------------------------------------------------------------
// Interpolation helpers
// ---------------------------------------------------------------------------

/// Linearly interpolate two f32 values.
pub fn lerpScalar(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Linearly interpolate two Vec3 values.
pub fn lerpVec3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    };
}

/// Spherical-linear interpolation for quaternions (x,y,z,w).
pub fn slerpQuat(a: [4]f32, b_in: [4]f32, t: f32) [4]f32 {
    var d = a[0] * b_in[0] + a[1] * b_in[1] + a[2] * b_in[2] + a[3] * b_in[3];
    var b = b_in;
    if (d < 0.0) {
        d = -d;
        b = .{ -b[0], -b[1], -b[2], -b[3] };
    }

    if (d > 0.9995) {
        // Very close — fall back to nlerp.
        var result: [4]f32 = .{
            a[0] + (b[0] - a[0]) * t,
            a[1] + (b[1] - a[1]) * t,
            a[2] + (b[2] - a[2]) * t,
            a[3] + (b[3] - a[3]) * t,
        };
        const len = @sqrt(result[0] * result[0] + result[1] * result[1] + result[2] * result[2] + result[3] * result[3]);
        if (len > 0.00001) {
            result[0] /= len;
            result[1] /= len;
            result[2] /= len;
            result[3] /= len;
        }
        return result;
    }

    const theta_0 = std.math.acos(d);
    const theta = theta_0 * t;
    const sin_theta = @sin(theta);
    const sin_theta_0 = @sin(theta_0);
    const s0 = @cos(theta) - d * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;

    return .{
        a[0] * s0 + b[0] * s1,
        a[1] * s0 + b[1] * s1,
        a[2] * s0 + b[2] * s1,
        a[3] * s0 + b[3] * s1,
    };
}

/// Find the two surrounding keyframes for a given time and compute the local t.
/// Returns `null` when the list is empty.
pub fn findSegment(comptime T: type, keyframes: []const Keyframe(T), time: f32) ?struct { a: Keyframe(T), b: Keyframe(T), t: f32 } {
    if (keyframes.len == 0) return null;
    if (keyframes.len == 1 or time <= keyframes[0].time) return .{ .a = keyframes[0], .b = keyframes[0], .t = 0.0 };
    if (time >= keyframes[keyframes.len - 1].time) return .{ .a = keyframes[keyframes.len - 1], .b = keyframes[keyframes.len - 1], .t = 0.0 };

    var lo: usize = 0;
    var hi: usize = keyframes.len - 1;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (keyframes[mid].time <= time) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    const a = keyframes[lo];
    const b = keyframes[hi];
    const span = b.time - a.time;
    const raw_t = if (span > 0.00001) (time - a.time) / span else 0.0;
    return .{ .a = a, .b = b, .t = a.easing.evaluate(raw_t) };
}

/// Evaluate a scalar keyframe track at the given time.
pub fn evaluateScalar(keyframes: []const ScalarKeyframe, time: f32) f32 {
    const seg = findSegment(f32, keyframes, time) orelse return 0.0;
    return lerpScalar(seg.a.value, seg.b.value, seg.t);
}

/// Evaluate a Vec3 keyframe track at the given time.
pub fn evaluateVec3(keyframes: []const Vec3Keyframe, time: f32) [3]f32 {
    const seg = findSegment([3]f32, keyframes, time) orelse return .{ 0, 0, 0 };
    return lerpVec3(seg.a.value, seg.b.value, seg.t);
}

/// Evaluate a Quat keyframe track at the given time.
pub fn evaluateQuat(keyframes: []const QuatKeyframe, time: f32) [4]f32 {
    const seg = findSegment([4]f32, keyframes, time) orelse return .{ 0, 0, 0, 1 };
    return slerpQuat(seg.a.value, seg.b.value, seg.t);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "easing linear" {
    try std.testing.expectApproxEqAbs(EasingMode.linear.evaluate(0.0), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(EasingMode.linear.evaluate(0.5), 0.5, 0.001);
    try std.testing.expectApproxEqAbs(EasingMode.linear.evaluate(1.0), 1.0, 0.001);
}

test "easing step" {
    try std.testing.expectApproxEqAbs(EasingMode.step.evaluate(0.0), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(EasingMode.step.evaluate(0.99), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(EasingMode.step.evaluate(1.0), 1.0, 0.001);
}

test "evaluateScalar basic" {
    const kfs = [_]ScalarKeyframe{
        .{ .time = 0.0, .value = 10.0 },
        .{ .time = 1.0, .value = 20.0 },
    };
    try std.testing.expectApproxEqAbs(evaluateScalar(&kfs, 0.5), 15.0, 0.01);
    try std.testing.expectApproxEqAbs(evaluateScalar(&kfs, 0.0), 10.0, 0.01);
    try std.testing.expectApproxEqAbs(evaluateScalar(&kfs, 1.0), 20.0, 0.01);
}

test "evaluateScalar clamp before/after" {
    const kfs = [_]ScalarKeyframe{
        .{ .time = 1.0, .value = 5.0 },
        .{ .time = 3.0, .value = 15.0 },
    };
    // Before first keyframe → first value
    try std.testing.expectApproxEqAbs(evaluateScalar(&kfs, 0.0), 5.0, 0.01);
    // After last keyframe → last value
    try std.testing.expectApproxEqAbs(evaluateScalar(&kfs, 999.0), 15.0, 0.01);
}

test "slerpQuat identity" {
    const id: [4]f32 = .{ 0, 0, 0, 1 };
    const result = slerpQuat(id, id, 0.5);
    try std.testing.expectApproxEqAbs(result[3], 1.0, 0.001);
}
