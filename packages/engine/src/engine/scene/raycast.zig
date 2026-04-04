const std = @import("std");
const components = @import("components.zig");
const world_mod = @import("world.zig");
const raycast_log = std.log.scoped(.raycast);

const BvhLogSnapshot = struct {
    static_items: usize,
    static_nodes: usize,
    dynamic_items: usize,
    dynamic_nodes: usize,
};

var g_logged_bvh_snapshot: ?BvhLogSnapshot = null;

pub const Ray = struct {
    origin: [3]f32,
    direction: [3]f32,
};

pub const SurfaceRaycastHit = struct {
    entity_id: world_mod.EntityId,
    distance: f32,
    position: [3]f32,
    normal: [3]f32,
};

pub fn raycastSurface(world: *world_mod.World, ray: Ray) ?SurfaceRaycastHit {
    const normalized_direction = normalize(ray.direction);
    const candidates = world.queryRenderableRayBounds(
        world.allocator,
        ray.origin,
        normalized_direction,
        std.math.inf(f32),
    ) catch |err| {
        raycast_log.warn("raycast broad phase query failed; fallback to brute force, error={}", .{err});
        return raycastSurfaceBruteForce(world, ray.origin, normalized_direction);
    };
    defer world.allocator.free(candidates);

    const snapshot = BvhLogSnapshot{
        .static_items = world.renderable_spatial_index.itemCount(),
        .static_nodes = world.renderable_spatial_index.nodeCount(),
        .dynamic_items = world.dynamic_renderable_spatial_index.itemCount(),
        .dynamic_nodes = world.dynamic_renderable_spatial_index.nodeCount(),
    };
    if (g_logged_bvh_snapshot == null or
        g_logged_bvh_snapshot.?.static_items != snapshot.static_items or
        g_logged_bvh_snapshot.?.static_nodes != snapshot.static_nodes or
        g_logged_bvh_snapshot.?.dynamic_items != snapshot.dynamic_items or
        g_logged_bvh_snapshot.?.dynamic_nodes != snapshot.dynamic_nodes)
    {
        raycast_log.info("renderable broad phase rebuilt static_items={} static_nodes={} dynamic_items={} dynamic_nodes={}", .{
            snapshot.static_items,
            snapshot.static_nodes,
            snapshot.dynamic_items,
            snapshot.dynamic_nodes,
        });
        g_logged_bvh_snapshot = snapshot;
    }

    var best_hit: ?SurfaceRaycastHit = null;
    // broad phase 现在会给出按 AABB 入射距离排序的 bounds 候选；一旦后续候选已经比当前命中更远，就可以提前停掉窄相位。
    for (candidates) |candidate| {
        if (best_hit) |resolved_best_hit| {
            if (candidate.enter_distance > resolved_best_hit.distance) {
                break;
            }
        }
        const entity = world.getEntityConst(candidate.id) orelse continue;
        testEntitySurface(world, entity, ray.origin, normalized_direction, &best_hit);
    }
    return best_hit;
}

const TriangleHit = struct {
    distance: f32,
    position: [3]f32,
};

fn rayTriangleIntersection(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?TriangleHit {
    const epsilon: f32 = 0.00001;
    const edge1 = sub(v1, v0);
    const edge2 = sub(v2, v0);
    const pvec = cross(ray_direction, edge2);
    const determinant = dot(edge1, pvec);

    if (@abs(determinant) <= epsilon) {
        return null;
    }

    const inverse_determinant = 1.0 / determinant;
    const tvec = sub(ray_origin, v0);
    const u = dot(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) {
        return null;
    }

    const qvec = cross(tvec, edge1);
    const v = dot(ray_direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) {
        return null;
    }

    const distance = dot(edge2, qvec) * inverse_determinant;
    if (distance <= epsilon) {
        return null;
    }

    return .{
        .distance = distance,
        .position = add(ray_origin, scale(ray_direction, distance)),
    };
}

fn transformPoint(transform: components.Transform, point: [3]f32) [3]f32 {
    return add(
        transform.translation,
        @import("../math/quat.zig").rotateVec3(transform.rotation, mul(transform.scale, point)),
    );
}

fn raycastSurfaceBruteForce(
    world: *const world_mod.World,
    ray_origin: [3]f32,
    normalized_direction: [3]f32,
) ?SurfaceRaycastHit {
    var best_hit: ?SurfaceRaycastHit = null;
    for (world.entities.items) |*entity| {
        testEntitySurface(world, entity, ray_origin, normalized_direction, &best_hit);
    }
    return best_hit;
}

fn testEntitySurface(
    world: *const world_mod.World,
    entity: *const world_mod.Entity,
    ray_origin: [3]f32,
    normalized_direction: [3]f32,
    best_hit: *?SurfaceRaycastHit,
) void {
    if (!entity.visible or entity.editor_only) {
        return;
    }
    const mesh_component = entity.mesh orelse return;
    const mesh_handle = mesh_component.handle orelse return;
    const mesh = world.resources.mesh(mesh_handle) orelse return;
    if (mesh.primitive_type != .triangle_list or mesh.indices.len < 3) {
        return;
    }

    const world_transform = world.worldTransformConst(entity.id) orelse entity.local_transform;
    var triangle_index: usize = 0;
    while (triangle_index + 2 < mesh.indices.len) : (triangle_index += 3) {
        const v0 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index]].position);
        const v1 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index + 1]].position);
        const v2 = transformPoint(world_transform, mesh.vertices[mesh.indices[triangle_index + 2]].position);
        const hit = rayTriangleIntersection(ray_origin, normalized_direction, v0, v1, v2) orelse continue;

        if (best_hit.* == null or hit.distance < best_hit.*.?.distance) {
            best_hit.* = .{
                .entity_id = entity.id,
                .distance = hit.distance,
                .position = hit.position,
                .normal = faceCamera(normalize(cross(sub(v1, v0), sub(v2, v0))), normalized_direction),
            };
        }
    }
}

fn rotateVec3Euler(rotation: [3]f32, vector: [3]f32) [3]f32 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn rotateX(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

fn faceCamera(normal: [3]f32, ray_direction: [3]f32) [3]f32 {
    if (dot(normal, ray_direction) > 0.0) {
        return scale(normal, -1.0);
    }
    return normal;
}

fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mul(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

fn scale(vector: [3]f32, scalar: f32) [3]f32 {
    return .{ vector[0] * scalar, vector[1] * scalar, vector[2] * scalar };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn length(vector: [3]f32) f32 {
    return std.math.sqrt(dot(vector, vector));
}

fn normalize(vector: [3]f32) [3]f32 {
    const len = length(vector);
    if (len <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return scale(vector, 1.0 / len);
}

test "raycastSurface hits the nearest visible triangle" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const front = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });
    _ = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, -3.0 },
    });

    // 更新层级以构建空间索引
    world.updateHierarchy();

    const hit = raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }) orelse return error.TestExpectedNonNull;

    try std.testing.expectEqual(front, hit.entity_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hit.position[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), hit.distance, 0.0001);
}

test "raycastSurface ignores editor only meshes" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const mesh_handle = try world.resources.ensurePrimitiveMesh(.plane);
    const material_handle = try world.resources.ensureDefaultMaterial();
    _ = try world.createEntity(.{
        .name = "HiddenPreview",
        .editor_only = true,
        .mesh = .{
            .handle = mesh_handle,
            .primitive = .plane,
        },
        .material = .{
            .handle = material_handle,
        },
    });

    try std.testing.expect(raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }) == null);
}

test "raycastSurface rebuilds broad phase after transform changes" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const plane = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 4.0, 0.0 },
    });

    try std.testing.expect(raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }) == null);

    try std.testing.expect(world.setEntityLocalTransform(plane, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    }));

    const hit = raycastSurface(&world, .{
        .origin = .{ 0.0, 2.0, 0.0 },
        .direction = .{ 0.0, -1.0, 0.0 },
    }) orelse return error.TestExpectedNonNull;

    try std.testing.expectEqual(plane, hit.entity_id);
}
