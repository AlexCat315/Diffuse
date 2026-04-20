const std = @import("std");
const mat4_mod = @import("../math/mat4.zig");
const vec3 = @import("../math/vec3.zig");

pub const csm_cascade_count = 4;

fn shadowViewUpVector(light_dir: [3]f32) [3]f32 {
    const default_up = [3]f32{ 0.0, 1.0, 0.0 };
    if (@abs(vec3.dot(light_dir, default_up)) > 0.99) {
        return .{ 0.0, 0.0, 1.0 };
    }
    return default_up;
}

/// Practical split scheme: lerp between logarithmic and uniform distribution.
/// lambda = 1.0 -> fully logarithmic, lambda = 0.0 -> fully uniform.
pub fn computeCascadeSplits(near: f32, far: f32, comptime count: usize, lambda: f32) [count]f32 {
    var splits: [count]f32 = undefined;
    for (0..count) |i| {
        const p = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(count));
        const log_split = near * std.math.pow(f32, far / near, p);
        const uni_split = near + (far - near) * p;
        splits[i] = lambda * log_split + (1.0 - lambda) * uni_split;
    }
    return splits;
}

/// Transform a Vec4 (x,y,z,w) by a 4x4 column-major matrix, return (x,y,z) after perspective divide.
fn transformPoint4(m: [16]f32, pt: [4]f32) [3]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |r| {
        out[r] = m[0 * 4 + r] * pt[0] + m[1 * 4 + r] * pt[1] + m[2 * 4 + r] * pt[2] + m[3 * 4 + r] * pt[3];
    }
    const w = if (@abs(out[3]) > 1e-7) out[3] else 1.0;
    return .{ out[0] / w, out[1] / w, out[2] / w };
}

/// Compute a tight-fit light-space VP matrix for one cascade.
/// `split_near`/`split_far` are view-space Z distances (positive values).
pub fn computeCascadeMatrix(
    camera_inv_vp: [16]f32,
    split_near: f32,
    split_far: f32,
    cam_near: f32,
    cam_far: f32,
    light_dir: [3]f32,
    shadow_resolution: f32,
) [16]f32 {
    const ndc_near = cam_far * (cam_near - split_near) / (split_near * (cam_near - cam_far));
    const ndc_far = cam_far * (cam_near - split_far) / (split_far * (cam_near - cam_far));

    const ndc_corners = [8][4]f32{
        .{ -1, -1, ndc_near, 1 }, .{ 1, -1, ndc_near, 1 },
        .{ -1, 1, ndc_near, 1 },  .{ 1, 1, ndc_near, 1 },
        .{ -1, -1, ndc_far, 1 },  .{ 1, -1, ndc_far, 1 },
        .{ -1, 1, ndc_far, 1 },   .{ 1, 1, ndc_far, 1 },
    };

    var world_corners: [8][3]f32 = undefined;
    var center: [3]f32 = .{ 0, 0, 0 };
    for (0..8) |i| {
        world_corners[i] = transformPoint4(camera_inv_vp, ndc_corners[i]);
        center[0] += world_corners[i][0];
        center[1] += world_corners[i][1];
        center[2] += world_corners[i][2];
    }
    center = vec3.scale(center, 1.0 / 8.0);

    const light_pos = vec3.sub(center, vec3.scale(light_dir, split_far + 50.0));
    const light_view = mat4_mod.lookAt(light_pos, center, shadowViewUpVector(light_dir));

    var center_ls = transformPoint4(light_view, .{ center[0], center[1], center[2], 1.0 });
    var min_z: f32 = std.math.floatMax(f32);
    var max_z: f32 = -std.math.floatMax(f32);
    var radius: f32 = 0.0;
    for (world_corners) |corner| {
        const lv = transformPoint4(light_view, .{ corner[0], corner[1], corner[2], 1.0 });
        min_z = @min(min_z, lv[2]);
        max_z = @max(max_z, lv[2]);
        const dx = lv[0] - center_ls[0];
        const dy = lv[1] - center_ls[1];
        radius = @max(radius, @sqrt(dx * dx + dy * dy));
    }
    radius = @ceil(radius * 16.0) / 16.0;

    const z_range = @max(max_z - min_z, 0.001);
    // Keep the light-space depth range tight. Excessive padding burns shadow-map
    // precision and shows up as blocky self-shadowing on flat faces.
    const caster_guard = @max(radius * 0.85, z_range * 0.45);
    const receiver_guard = @max(radius * 0.12, z_range * 0.12);
    min_z -= caster_guard;
    max_z += receiver_guard;

    if (shadow_resolution > 0 and radius > 0) {
        const world_units_per_texel = (radius * 2.0) / shadow_resolution;
        center_ls[0] = @floor(center_ls[0] / world_units_per_texel) * world_units_per_texel;
        center_ls[1] = @floor(center_ls[1] / world_units_per_texel) * world_units_per_texel;
    }

    const min_x = center_ls[0] - radius;
    const max_x = center_ls[0] + radius;
    const min_y = center_ls[1] - radius;
    const max_y = center_ls[1] + radius;

    const light_proj = mat4_mod.orthographicOffCenter(min_x, max_x, min_y, max_y, min_z, max_z);
    return mat4_mod.mul(light_proj, light_view);
}
