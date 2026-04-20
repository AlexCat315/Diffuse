// host/physics.zig — 射线检测/速度/冲量桥接
const mod = @import("./mod.zig");

pub fn guavaHostRaycast(
    userdata: ?*anyopaque,
    ox: f32,
    oy: f32,
    oz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
    max_dist: f32,
    hit_x: *f32,
    hit_y: *f32,
    hit_z: *f32,
    hit_dist: *f32,
    hit_entity: *u64,
) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const hit = ctx.physicsRaycast(.{ ox, oy, oz }, .{ dx, dy, dz }, max_dist) orelse return 0;
    hit_x.* = hit.position[0];
    hit_y.* = hit.position[1];
    hit_z.* = hit.position[2];
    hit_dist.* = hit.distance;
    hit_entity.* = hit.entity_id;
    return 1;
}

pub fn guavaHostSetLinearVelocity(userdata: ?*anyopaque, target: u64, vx: f32, vy: f32, vz: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const ps = ctx.physics_state orelse return;
    ps.setBodyLinearVelocity(ctx.world, target, .{ vx, vy, vz });
}

pub fn guavaHostGetLinearVelocity(userdata: ?*anyopaque, target: u64, vx: *f32, vy: *f32, vz: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const ps = ctx.physics_state orelse return;
    const vel = ps.getBodyLinearVelocity(ctx.world, target) orelse return;
    vx.* = vel[0];
    vy.* = vel[1];
    vz.* = vel[2];
}

pub fn guavaHostAddImpulse(userdata: ?*anyopaque, target: u64, ix: f32, iy: f32, iz: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const ps = ctx.physics_state orelse return;
    ps.addBodyImpulse(ctx.world, target, .{ ix, iy, iz });
}

// ─── Extended Physics Queries ─────────────────────────────────────────────

pub fn guavaHostOverlapBox(
    userdata: ?*anyopaque,
    cx: f32,
    cy: f32,
    cz: f32,
    hx: f32,
    hy: f32,
    hz: f32,
    exclude_entity: u64,
    include_triggers: u32,
    out_entities: [*]u64,
    max_results: u32,
) callconv(.c) u32 {
    const physics_mod = @import("../../physics/system.zig");
    const ctx = mod.activeContext(userdata) orelse return 0;
    const filter = physics_mod.QueryFilter{
        .exclude_entity = if (exclude_entity != 0) exclude_entity else null,
        .include_triggers = include_triggers != 0,
    };
    const hits = ctx.physicsOverlapBox(.{ cx, cy, cz }, .{ hx, hy, hz }, filter) catch return 0;
    defer ctx.allocator.free(hits);
    const count: u32 = @intCast(@min(hits.len, max_results));
    for (0..count) |i| {
        out_entities[i] = hits[i].entity_id;
    }
    return count;
}

pub fn guavaHostSweepBox(
    userdata: ?*anyopaque,
    cx: f32,
    cy: f32,
    cz: f32,
    hx: f32,
    hy: f32,
    hz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
    exclude_entity: u64,
    include_triggers: u32,
    out_entity: *u64,
    out_fraction: *f32,
    out_nx: *f32,
    out_ny: *f32,
    out_nz: *f32,
) callconv(.c) u32 {
    const physics_mod = @import("../../physics/system.zig");
    const ctx = mod.activeContext(userdata) orelse return 0;
    const filter = physics_mod.QueryFilter{
        .exclude_entity = if (exclude_entity != 0) exclude_entity else null,
        .include_triggers = include_triggers != 0,
    };
    const hit = ctx.physicsSweepBox(.{ cx, cy, cz }, .{ hx, hy, hz }, .{ dx, dy, dz }, filter) orelse return 0;
    out_entity.* = hit.entity_id;
    out_fraction.* = hit.fraction;
    out_nx.* = hit.normal[0];
    out_ny.* = hit.normal[1];
    out_nz.* = hit.normal[2];
    return 1;
}
