const std = @import("std");
const gizmo_pass_mod = @import("passes/gizmo_pass.zig");
const scene_mod = @import("../scene/scene.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const physics_mod = @import("../physics/system.zig");
const frustum_mod = @import("../math/frustum.zig");
const vec3 = @import("../math/vec3.zig");
const AABB = @import("../math/aabb.zig").AABB;

pub fn appendGridLines(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    camera_world_position: [4]f32,
) !void {
    const spacing: f32 = 1.0;
    const half_cells: i32 = 160;
    const extent = @as(f32, @floatFromInt(half_cells)) * spacing;
    const center_x = @floor(camera_world_position[0] / spacing) * spacing;
    const center_z = @floor(camera_world_position[2] / spacing) * spacing;

    var index: i32 = -half_cells;
    while (index <= half_cells) : (index += 1) {
        const offset = @as(f32, @floatFromInt(index)) * spacing;
        const x = center_x + offset;
        const z = center_z + offset;
        try appendLine(allocator, lines, .{ x, 0.0, center_z - extent }, .{ x, 0.0, center_z + extent });
        try appendLine(allocator, lines, .{ center_x - extent, 0.0, z }, .{ center_x + extent, 0.0, z });
    }
}

pub fn appendBoneLines(
    allocator: std.mem.Allocator,
    scene: *const scene_mod.Scene,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
) !void {
    for (scene.entities.items) |entity| {
        const parent_id = entity.parent orelse continue;
        const parent_transform = scene.worldTransformConst(parent_id) orelse continue;
        const child_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        try appendLine(allocator, lines, parent_transform.translation, child_transform.translation);
    }
}

pub fn appendCollisionLines(
    allocator: std.mem.Allocator,
    scene: *scene_mod.Scene,
    prepared_scene: *const mesh_pass_mod.PreparedScene,
    solid_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    trigger_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    physics_state_opt: ?*physics_mod.PhysicsState,
) !void {
    const debug_shapes = if (physics_state_opt) |ps|
        try ps.collectDebugShapes(scene, allocator)
    else
        &[0]physics_mod.PhysicsDebugInfo{};
    defer allocator.free(debug_shapes);

    if (debug_shapes.len > 0) {
        for (debug_shapes) |shape| {
            switch (shape.shape) {
                .box => |box| {
                    const aabb = AABB{
                        .min = vec3.sub(box.center, box.half_extents),
                        .max = vec3.add(box.center, box.half_extents),
                    };
                    if (shape.is_trigger) {
                        try appendBoxEdges(allocator, trigger_lines, cornersForAabb(aabb));
                    } else {
                        try appendBoxEdges(allocator, solid_lines, cornersForAabb(aabb));
                    }
                },
                .sphere => |sphere| {
                    if (shape.is_trigger) {
                        try appendSphereEdges(allocator, trigger_lines, sphere.center, sphere.radius, 16);
                    } else {
                        try appendSphereEdges(allocator, solid_lines, sphere.center, sphere.radius, 16);
                    }
                },
            }
        }
        return;
    }

    const collision_frustum = frustum_mod.Frustum.fromViewProjection(prepared_scene.view_projection);
    const bounds_items = try scene.queryRenderableBoundsInFrustum(allocator, collision_frustum);
    defer allocator.free(bounds_items);

    for (bounds_items) |item| {
        try appendBoxEdges(allocator, solid_lines, cornersForAabb(item.bounds));
    }
}

pub fn cornersForAabb(bounds: AABB) [8][3]f32 {
    const min = bounds.min;
    const max = bounds.max;
    return .{
        .{ min[0], min[1], min[2] },
        .{ max[0], min[1], min[2] },
        .{ max[0], max[1], min[2] },
        .{ min[0], max[1], min[2] },
        .{ min[0], min[1], max[2] },
        .{ max[0], min[1], max[2] },
        .{ max[0], max[1], max[2] },
        .{ min[0], max[1], max[2] },
    };
}

pub fn appendBoxEdges(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), corners: [8][3]f32) !void {
    try appendLine(allocator, lines, corners[0], corners[1]);
    try appendLine(allocator, lines, corners[1], corners[2]);
    try appendLine(allocator, lines, corners[2], corners[3]);
    try appendLine(allocator, lines, corners[3], corners[0]);
    try appendLine(allocator, lines, corners[4], corners[5]);
    try appendLine(allocator, lines, corners[5], corners[6]);
    try appendLine(allocator, lines, corners[6], corners[7]);
    try appendLine(allocator, lines, corners[7], corners[4]);
    try appendLine(allocator, lines, corners[0], corners[4]);
    try appendLine(allocator, lines, corners[1], corners[5]);
    try appendLine(allocator, lines, corners[2], corners[6]);
    try appendLine(allocator, lines, corners[3], corners[7]);
}

pub fn appendLine(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), a: [3]f32, b: [3]f32) !void {
    try lines.append(allocator, .{ .position = a });
    try lines.append(allocator, .{ .position = b });
}

pub fn appendSphereEdges(allocator: std.mem.Allocator, lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex), center: [3]f32, radius: f32, segments: u32) !void {
    const pi = std.math.pi;

    var i: u32 = 0;
    while (i < segments) : (i += 1) {
        const lat1 = pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) - pi / 2.0;
        const lat2 = pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) - pi / 2.0;

        var j: u32 = 0;
        while (j < segments) : (j += 1) {
            const lon1 = 2.0 * pi * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segments));
            const lon2 = 2.0 * pi * @as(f32, @floatFromInt(j + 1)) / @as(f32, @floatFromInt(segments));

            const p1 = sphericalToCartesian(center, radius, lat1, lon1);
            const p2 = sphericalToCartesian(center, radius, lat1, lon2);
            const p3 = sphericalToCartesian(center, radius, lat2, lon1);

            try appendLine(allocator, lines, p1, p2);
            try appendLine(allocator, lines, p1, p3);
        }
    }
}

fn sphericalToCartesian(center: [3]f32, radius: f32, lat: f32, lon: f32) [3]f32 {
    const x = radius * std.math.cos(lat) * std.math.cos(lon);
    const y = radius * std.math.sin(lat);
    const z = radius * std.math.cos(lat) * std.math.sin(lon);
    return .{ center[0] + x, center[1] + y, center[2] + z };
}
