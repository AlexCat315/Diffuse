// WASD Movement Demo Script
// Attach this script to any entity to control it with keyboard.
// WASD = move on XZ plane, Space/Shift = up/down, auto-rotates on Y axis.
//
// Usage: Open in Script Editor, assign to entity with Script component, press Play.

const std = @import("std");

var rotation_angle: f32 = 0.0;
var move_speed: f32 = 5.0;
var rotate_speed: f32 = 1.5;

pub fn onInit() void {
    guava.log("WASD Move script initialized! Use WASD to move, Space/Shift for up/down.");
}

pub fn onUpdate(dt: f32) void {
    const eid = guava.entityId();
    var pos = guava.getEntityPosition(eid);

    // WASD movement
    if (guava.isKeyDown(guava.Key.w)) pos[2] -= move_speed * dt;
    if (guava.isKeyDown(guava.Key.s)) pos[2] += move_speed * dt;
    if (guava.isKeyDown(guava.Key.a)) pos[0] -= move_speed * dt;
    if (guava.isKeyDown(guava.Key.d)) pos[0] += move_speed * dt;

    // Up/Down
    if (guava.isKeyDown(guava.Key.space)) pos[1] += move_speed * dt;
    if (guava.isKeyDown(guava.Key.shift)) pos[1] -= move_speed * dt;

    _ = guava.setEntityPosition(eid, pos);

    // Auto-rotate around Y axis
    rotation_angle += rotate_speed * dt;
    const half = rotation_angle * 0.5;
    _ = guava.setEntityRotation(eid, .{ 0.0, std.math.sin(half), 0.0, std.math.cos(half) });
}

pub fn onDestroy() void {
    guava.log("WASD Move script destroyed.");
}
