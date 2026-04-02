// Spinning Cube Demo Plugin for Guava Engine.
//
// Attach to any entity — it will spin around the Y axis automatically.
// Press Space to toggle rotation on/off.

const std = @import("std");

var angle: f32 = 0.0;
var spinning: bool = true;
var spin_speed: f32 = 2.0;

pub fn onInit() void {
    guava.log("Spinning Cube plugin loaded! Press Space to toggle spin.");
}

pub fn onUpdate(dt: f32) void {
    // Toggle spinning with Space key
    if (guava.wasKeyPressed(guava.Key.space)) {
        spinning = !spinning;
    }

    if (spinning) {
        angle += spin_speed * dt;
        const half = angle * 0.5;
        _ = guava.setRotation(.{ 0.0, std.math.sin(half), 0.0, std.math.cos(half) });
    }
}

pub fn onDestroy() void {
    guava.log("Spinning Cube plugin unloaded.");
}
