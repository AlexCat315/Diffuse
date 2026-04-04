//! Guava Engine FPS Controller 示例脚本
//!
//! 演示如何使用 Zig dylib 脚本系统编写完整的 FPS 控制器。
//! 本脚本不使用 //!guava builtin= 指令，会被自动编译为 .dylib 并动态加载。
//!
//! 挂载方法：在 Inspector 中将脚本组件指向此文件路径。

const guava = @import("guava");
const std = @import("std");

// 持久状态 — 使用模块级变量在帧间保持
var pitch: f32 = 0.0;
var yaw: f32 = 0.0;
var vertical_velocity: f32 = 0.0;
var is_grounded: bool = true;

// 配置
const move_speed: f32 = 5.0;
const mouse_sensitivity: f32 = 0.003;
const gravity: f32 = -9.81;
const jump_velocity: f32 = 5.0;
const ground_y: f32 = 0.0;

export fn guava_on_init() callconv(.c) void {
    guava.log("FPS Controller initialized");
    const pos = guava.getPosition();
    is_grounded = pos[1] <= ground_y + 0.01;
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    var pos = guava.getPosition();

    // --- 鼠标视角 ---
    const mouse = guava.getMouseDelta();
    yaw -= mouse[0] * mouse_sensitivity;
    pitch -= mouse[1] * mouse_sensitivity;
    pitch = std.math.clamp(pitch, -1.4, 1.4); // 约 ±80°

    // 四元数 = Yaw * Pitch (绕 Y 轴旋转再绕局部 X 旋转)
    const half_yaw = yaw * 0.5;
    const half_pitch = pitch * 0.5;
    const cy = @cos(half_yaw);
    const sy = @sin(half_yaw);
    const cp = @cos(half_pitch);
    const sp = @sin(half_pitch);

    guava.setRotation(.{
        cy * sp,
        sy * cp,
        -sy * sp,
        cy * cp,
    });

    // --- 键盘移动 (WASD) ---
    const forward = [3]f32{ -@sin(yaw), 0.0, -@cos(yaw) };
    const right = [3]f32{ @cos(yaw), 0.0, -@sin(yaw) };

    var move_x: f32 = 0;
    var move_z: f32 = 0;

    if (guava.isKeyDown(.w)) {
        move_x += forward[0];
        move_z += forward[2];
    }
    if (guava.isKeyDown(.s)) {
        move_x -= forward[0];
        move_z -= forward[2];
    }
    if (guava.isKeyDown(.a)) {
        move_x -= right[0];
        move_z -= right[2];
    }
    if (guava.isKeyDown(.d)) {
        move_x += right[0];
        move_z += right[2];
    }

    // 归一化水平移动分量
    const len = @sqrt(move_x * move_x + move_z * move_z);
    if (len > 0.001) {
        move_x = move_x / len * move_speed * dt;
        move_z = move_z / len * move_speed * dt;
    }

    pos[0] += move_x;
    pos[2] += move_z;

    // --- 重力与跳跃 ---
    if (is_grounded and guava.wasKeyPressed(.space)) {
        vertical_velocity = jump_velocity;
        is_grounded = false;
    }

    vertical_velocity += gravity * dt;
    pos[1] += vertical_velocity * dt;

    if (pos[1] <= ground_y) {
        pos[1] = ground_y;
        vertical_velocity = 0.0;
        is_grounded = true;
    }

    guava.setPosition(pos);
}

export fn guava_on_destroy() callconv(.c) void {
    guava.log("FPS Controller destroyed");
}

// --- 碰撞回调示例 ---
export fn guava_on_collision_enter(other_entity: u64) callconv(.c) void {
    _ = other_entity;
    guava.log("Collision detected!");
}
