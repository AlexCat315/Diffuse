// host/transform.zig — 位置/旋转/缩放桥接
const mod = @import("./mod.zig");

pub fn guavaHostGetPosition(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const pos = ctx.getPosition() orelse return;
    x.* = pos[0];
    y.* = pos[1];
    z.* = pos[2];
}

pub fn guavaHostSetPosition(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setPosition(.{ x, y, z });
}

pub fn guavaHostGetRotation(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32, w: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const rot = ctx.getRotation() orelse return;
    x.* = rot[0];
    y.* = rot[1];
    z.* = rot[2];
    w.* = rot[3];
}

pub fn guavaHostSetRotation(userdata: ?*anyopaque, x: f32, y: f32, z: f32, w: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setRotation(.{ x, y, z, w });
}

pub fn guavaHostGetScale(userdata: ?*anyopaque, x: *f32, y: *f32, z: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const scale = ctx.getScale() orelse return;
    x.* = scale[0];
    y.* = scale[1];
    z.* = scale[2];
}

pub fn guavaHostSetScale(userdata: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setScale(.{ x, y, z });
}
