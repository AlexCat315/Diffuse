const std = @import("std");
const gizmo_pass_mod = @import("passes/gizmo_pass.zig");
const scene_mod = @import("../scene/scene.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const physics_mod = @import("../physics/system.zig");
const frustum_mod = @import("../math/frustum.zig");
const vec3 = @import("../math/vec3.zig");
const quat = @import("../math/quat.zig");
const AABB = @import("../math/aabb.zig").AABB;
const components = @import("../scene/components.zig");

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

// ── Editor entity icons ──────────────────────────────────────────

/// Camera icon: a small frustum (pyramid) pointing along the entity's local -Z axis.
pub fn appendCameraIconLines(
    allocator: std.mem.Allocator,
    scene: *const scene_mod.Scene,
    camera_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
) !void {
    for (scene.entities.items) |entity| {
        if (entity.camera == null) continue;
        if (entity.editor_only) continue;
        const transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        try appendCameraFrustumIcon(allocator, camera_lines, transform);
    }
}

fn appendCameraFrustumIcon(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    transform: components.Transform,
) !void {
    // Small frustum: near plane at z=-0.15, far plane at z=-0.6
    // Near half-extents: 0.12 x 0.08, Far half-extents: 0.35 x 0.24
    const near_z: f32 = -0.15;
    const far_z: f32 = -0.6;
    const near_hx: f32 = 0.12;
    const near_hy: f32 = 0.08;
    const far_hx: f32 = 0.35;
    const far_hy: f32 = 0.24;

    // Near plane corners
    const n0 = transformPoint(transform, .{ -near_hx, -near_hy, near_z });
    const n1 = transformPoint(transform, .{ near_hx, -near_hy, near_z });
    const n2 = transformPoint(transform, .{ near_hx, near_hy, near_z });
    const n3 = transformPoint(transform, .{ -near_hx, near_hy, near_z });

    // Far plane corners
    const f0 = transformPoint(transform, .{ -far_hx, -far_hy, far_z });
    const f1 = transformPoint(transform, .{ far_hx, -far_hy, far_z });
    const f2 = transformPoint(transform, .{ far_hx, far_hy, far_z });
    const f3 = transformPoint(transform, .{ -far_hx, far_hy, far_z });

    // Near plane rectangle
    try appendLine(allocator, lines, n0, n1);
    try appendLine(allocator, lines, n1, n2);
    try appendLine(allocator, lines, n2, n3);
    try appendLine(allocator, lines, n3, n0);

    // Far plane rectangle
    try appendLine(allocator, lines, f0, f1);
    try appendLine(allocator, lines, f1, f2);
    try appendLine(allocator, lines, f2, f3);
    try appendLine(allocator, lines, f3, f0);

    // Connecting edges (frustum sides)
    try appendLine(allocator, lines, n0, f0);
    try appendLine(allocator, lines, n1, f1);
    try appendLine(allocator, lines, n2, f2);
    try appendLine(allocator, lines, n3, f3);

    // Up-triangle on top of near plane (view-finder indicator)
    const top_mid = transformPoint(transform, .{ 0.0, near_hy + 0.08, near_z });
    try appendLine(allocator, lines, n3, top_mid);
    try appendLine(allocator, lines, top_mid, n2);
}

/// Light icons: draw appropriate wireframe shapes depending on light type.
pub fn appendLightIconLines(
    allocator: std.mem.Allocator,
    scene: *const scene_mod.Scene,
    directional_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    point_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    spot_lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
) !void {
    for (scene.entities.items) |entity| {
        const light = entity.light orelse continue;
        if (entity.editor_only) continue;
        const transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        switch (light.kind) {
            .directional => try appendDirectionalLightIcon(allocator, directional_lines, transform),
            .point => try appendPointLightIcon(allocator, point_lines, transform),
            .spot => try appendSpotLightIcon(allocator, spot_lines, transform),
        }
    }
}

fn appendDirectionalLightIcon(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    transform: components.Transform,
) !void {
    const pos = transform.translation;
    const s: f32 = 0.25; // circle radius
    const arrow_len: f32 = 0.5;
    const segs: u32 = 16;

    // Draw a circle in XY plane
    var i: u32 = 0;
    while (i < segs) : (i += 1) {
        const a0 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
        const a1 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs));
        const p0 = transformPoint(transform, .{ s * std.math.cos(a0), s * std.math.sin(a0), 0.0 });
        const p1 = transformPoint(transform, .{ s * std.math.cos(a1), s * std.math.sin(a1), 0.0 });
        try appendLine(allocator, lines, p0, p1);
    }

    // Draw rays extending from circle downward along -Z
    const ray_count: u32 = 8;
    var r: u32 = 0;
    while (r < ray_count) : (r += 1) {
        const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(ray_count));
        const cx = s * std.math.cos(angle);
        const cy = s * std.math.sin(angle);
        const from = transformPoint(transform, .{ cx, cy, 0.0 });
        const to = transformPoint(transform, .{ cx, cy, -arrow_len });
        try appendLine(allocator, lines, from, to);
    }
    _ = pos;
}

fn appendPointLightIcon(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    transform: components.Transform,
) !void {
    const pos = transform.translation;
    const s: f32 = 0.2;

    // Draw 3 orthogonal circles (like a gimbal) to represent omnidirectional light
    try appendCircle(allocator, lines, pos, s, .xy);
    try appendCircle(allocator, lines, pos, s, .xz);
    try appendCircle(allocator, lines, pos, s, .yz);

    // 6 short rays along each axis
    const ray_len: f32 = 0.15;
    try appendLine(allocator, lines, .{ pos[0] + s + ray_len, pos[1], pos[2] }, .{ pos[0] + s, pos[1], pos[2] });
    try appendLine(allocator, lines, .{ pos[0] - s - ray_len, pos[1], pos[2] }, .{ pos[0] - s, pos[1], pos[2] });
    try appendLine(allocator, lines, .{ pos[0], pos[1] + s + ray_len, pos[2] }, .{ pos[0], pos[1] + s, pos[2] });
    try appendLine(allocator, lines, .{ pos[0], pos[1] - s - ray_len, pos[2] }, .{ pos[0], pos[1] - s, pos[2] });
    try appendLine(allocator, lines, .{ pos[0], pos[1], pos[2] + s + ray_len }, .{ pos[0], pos[1], pos[2] + s });
    try appendLine(allocator, lines, .{ pos[0], pos[1], pos[2] - s - ray_len }, .{ pos[0], pos[1], pos[2] - s });
}

fn appendSpotLightIcon(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    transform: components.Transform,
) !void {
    const cone_len: f32 = 0.6;
    const cone_radius: f32 = 0.35;
    const segs: u32 = 16;

    // Origin point
    const origin = transformPoint(transform, .{ 0.0, 0.0, 0.0 });

    // Draw cone base circle at -Z
    var i: u32 = 0;
    while (i < segs) : (i += 1) {
        const a0 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
        const a1 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs));
        const p0 = transformPoint(transform, .{ cone_radius * std.math.cos(a0), cone_radius * std.math.sin(a0), -cone_len });
        const p1 = transformPoint(transform, .{ cone_radius * std.math.cos(a1), cone_radius * std.math.sin(a1), -cone_len });
        try appendLine(allocator, lines, p0, p1);
    }

    // 4 edges from origin to cone base
    const edge_count: u32 = 4;
    var e: u32 = 0;
    while (e < edge_count) : (e += 1) {
        const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(e)) / @as(f32, @floatFromInt(edge_count));
        const tip = transformPoint(transform, .{ cone_radius * std.math.cos(angle), cone_radius * std.math.sin(angle), -cone_len });
        try appendLine(allocator, lines, origin, tip);
    }
}

const CirclePlane = enum { xy, xz, yz };

fn appendCircle(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(gizmo_pass_mod.WorldLineVertex),
    center: [3]f32,
    radius: f32,
    plane: CirclePlane,
) !void {
    const segs: u32 = 16;
    var i: u32 = 0;
    while (i < segs) : (i += 1) {
        const a0 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
        const a1 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segs));
        const c0 = std.math.cos(a0);
        const s0 = std.math.sin(a0);
        const c1 = std.math.cos(a1);
        const s1 = std.math.sin(a1);
        const p0: [3]f32 = switch (plane) {
            .xy => .{ center[0] + radius * c0, center[1] + radius * s0, center[2] },
            .xz => .{ center[0] + radius * c0, center[1], center[2] + radius * s0 },
            .yz => .{ center[0], center[1] + radius * c0, center[2] + radius * s0 },
        };
        const p1: [3]f32 = switch (plane) {
            .xy => .{ center[0] + radius * c1, center[1] + radius * s1, center[2] },
            .xz => .{ center[0] + radius * c1, center[1], center[2] + radius * s1 },
            .yz => .{ center[0], center[1] + radius * c1, center[2] + radius * s1 },
        };
        try appendLine(allocator, lines, p0, p1);
    }
}

fn transformPoint(transform: components.Transform, local: [3]f32) [3]f32 {
    // Apply rotation then translation (ignoring scale for icon shapes)
    const rotated = quat.rotateVec3(transform.rotation, local);
    return .{
        rotated[0] + transform.translation[0],
        rotated[1] + transform.translation[1],
        rotated[2] + transform.translation[2],
    };
}
