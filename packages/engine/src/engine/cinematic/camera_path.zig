const std = @import("std");
const keyframe = @import("keyframe.zig");

// ---------------------------------------------------------------------------
// Camera path spline interpolation (Bézier & Catmull-Rom)
//
// These operate on arrays of control points rather than keyframe tracks.
// The higher-level CameraPathTrack in track.zig handles time → parameter
// mapping; this module provides the pure geometric curve evaluation.
// ---------------------------------------------------------------------------

pub const Vec3 = [3]f32;

// ---------------------------------------------------------------------------
// Cubic Bézier
// ---------------------------------------------------------------------------

/// Evaluate a cubic Bézier curve at parameter t ∈ [0, 1].
///
/// `p0` and `p3` are the endpoints; `p1` and `p2` are the control handles.
pub fn cubicBezier(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3, t: f32) Vec3 {
    const u = 1.0 - t;
    const uu = u * u;
    const tt = t * t;
    const uuu = uu * u;
    const ttt = tt * t;

    return .{
        uuu * p0[0] + 3.0 * uu * t * p1[0] + 3.0 * u * tt * p2[0] + ttt * p3[0],
        uuu * p0[1] + 3.0 * uu * t * p1[1] + 3.0 * u * tt * p2[1] + ttt * p3[1],
        uuu * p0[2] + 3.0 * uu * t * p1[2] + 3.0 * u * tt * p2[2] + ttt * p3[2],
    };
}

/// Evaluate the tangent of a cubic Bézier curve at parameter t.
pub fn cubicBezierTangent(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3, t: f32) Vec3 {
    const u = 1.0 - t;
    const uu = u * u;
    const tt = t * t;

    return .{
        3.0 * uu * (p1[0] - p0[0]) + 6.0 * u * t * (p2[0] - p1[0]) + 3.0 * tt * (p3[0] - p2[0]),
        3.0 * uu * (p1[1] - p0[1]) + 6.0 * u * t * (p2[1] - p1[1]) + 3.0 * tt * (p3[1] - p2[1]),
        3.0 * uu * (p1[2] - p0[2]) + 6.0 * u * t * (p2[2] - p1[2]) + 3.0 * tt * (p3[2] - p2[2]),
    };
}

// ---------------------------------------------------------------------------
// Catmull-Rom spline
// ---------------------------------------------------------------------------

/// Evaluate a Catmull-Rom spline segment defined by four points at
/// parameter t ∈ [0, 1].  The curve passes through `p1` (t=0) and `p2`
/// (t=1); `p0` and `p3` influence curvature.
pub fn catmullRom(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3, t: f32) Vec3 {
    const tt = t * t;
    const ttt = tt * t;

    // Standard Catmull-Rom matrix (tension = 0.5).
    return .{
        0.5 * ((2.0 * p1[0]) + (-p0[0] + p2[0]) * t + (2.0 * p0[0] - 5.0 * p1[0] + 4.0 * p2[0] - p3[0]) * tt + (-p0[0] + 3.0 * p1[0] - 3.0 * p2[0] + p3[0]) * ttt),
        0.5 * ((2.0 * p1[1]) + (-p0[1] + p2[1]) * t + (2.0 * p0[1] - 5.0 * p1[1] + 4.0 * p2[1] - p3[1]) * tt + (-p0[1] + 3.0 * p1[1] - 3.0 * p2[1] + p3[1]) * ttt),
        0.5 * ((2.0 * p1[2]) + (-p0[2] + p2[2]) * t + (2.0 * p0[2] - 5.0 * p1[2] + 4.0 * p2[2] - p3[2]) * tt + (-p0[2] + 3.0 * p1[2] - 3.0 * p2[2] + p3[2]) * ttt),
    };
}

/// Evaluate the tangent of a Catmull-Rom segment at parameter t.
pub fn catmullRomTangent(p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3, t: f32) Vec3 {
    const tt = t * t;

    return .{
        0.5 * ((-p0[0] + p2[0]) + (4.0 * p0[0] - 10.0 * p1[0] + 8.0 * p2[0] - 2.0 * p3[0]) * t + (-3.0 * p0[0] + 9.0 * p1[0] - 9.0 * p2[0] + 3.0 * p3[0]) * tt),
        0.5 * ((-p0[1] + p2[1]) + (4.0 * p0[1] - 10.0 * p1[1] + 8.0 * p2[1] - 2.0 * p3[1]) * t + (-3.0 * p0[1] + 9.0 * p1[1] - 9.0 * p2[1] + 3.0 * p3[1]) * tt),
        0.5 * ((-p0[2] + p2[2]) + (4.0 * p0[2] - 10.0 * p1[2] + 8.0 * p2[2] - 2.0 * p3[2]) * t + (-3.0 * p0[2] + 9.0 * p1[2] - 9.0 * p2[2] + 3.0 * p3[2]) * tt),
    };
}

// ---------------------------------------------------------------------------
// Multi-point Catmull-Rom path evaluation
// ---------------------------------------------------------------------------

/// Evaluate a multi-point Catmull-Rom path at a global parameter u ∈ [0, 1].
/// `points` must have at least 2 elements.
/// The path passes through all points; at the endpoints the curve is
/// clamped (first/last control points are duplicated).
pub fn evaluateCatmullRomPath(points: []const Vec3, u: f32) Vec3 {
    const n = points.len;
    if (n == 0) return .{ 0, 0, 0 };
    if (n == 1) return points[0];

    const segments: f32 = @floatFromInt(n - 1);
    const clamped_u = std.math.clamp(u, 0.0, 1.0);
    const scaled = clamped_u * segments;
    const seg_index: usize = @intFromFloat(@min(scaled, segments - 1.0));
    const local_t = scaled - @as(f32, @floatFromInt(seg_index));

    const p0 = if (seg_index == 0) points[0] else points[seg_index - 1];
    const p1 = points[seg_index];
    const p2 = points[seg_index + 1];
    const p3 = if (seg_index + 2 < n) points[seg_index + 2] else points[n - 1];

    return catmullRom(p0, p1, p2, p3, local_t);
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

fn vecLength(v: Vec3) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

fn vecSub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "cubicBezier endpoints" {
    const p0 = Vec3{ 0, 0, 0 };
    const p1 = Vec3{ 1, 2, 0 };
    const p2 = Vec3{ 3, 2, 0 };
    const p3 = Vec3{ 4, 0, 0 };

    const start = cubicBezier(p0, p1, p2, p3, 0.0);
    try std.testing.expectApproxEqAbs(start[0], 0.0, 0.001);
    try std.testing.expectApproxEqAbs(start[1], 0.0, 0.001);

    const end = cubicBezier(p0, p1, p2, p3, 1.0);
    try std.testing.expectApproxEqAbs(end[0], 4.0, 0.001);
    try std.testing.expectApproxEqAbs(end[1], 0.0, 0.001);
}

test "catmullRom passes through p1 and p2" {
    const p0 = Vec3{ 0, 0, 0 };
    const p1 = Vec3{ 1, 1, 0 };
    const p2 = Vec3{ 2, 0, 0 };
    const p3 = Vec3{ 3, 1, 0 };

    const at0 = catmullRom(p0, p1, p2, p3, 0.0);
    try std.testing.expectApproxEqAbs(at0[0], 1.0, 0.001);
    try std.testing.expectApproxEqAbs(at0[1], 1.0, 0.001);

    const at1 = catmullRom(p0, p1, p2, p3, 1.0);
    try std.testing.expectApproxEqAbs(at1[0], 2.0, 0.001);
    try std.testing.expectApproxEqAbs(at1[1], 0.0, 0.001);
}

test "evaluateCatmullRomPath endpoints" {
    const pts = [_]Vec3{
        .{ 0, 0, 0 },
        .{ 5, 0, 0 },
        .{ 10, 0, 0 },
    };

    const start = evaluateCatmullRomPath(&pts, 0.0);
    try std.testing.expectApproxEqAbs(start[0], 0.0, 0.01);

    const end = evaluateCatmullRomPath(&pts, 1.0);
    try std.testing.expectApproxEqAbs(end[0], 10.0, 0.01);

    // Midpoint should be near 5
    const mid = evaluateCatmullRomPath(&pts, 0.5);
    try std.testing.expectApproxEqAbs(mid[0], 5.0, 0.01);
}
