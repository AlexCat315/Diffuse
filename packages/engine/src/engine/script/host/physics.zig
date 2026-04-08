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
