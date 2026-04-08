// host/input.zig — 键盘/鼠标/手柄输入桥接
const std = @import("std");
const mod = @import("./mod.zig");
const input_mod = @import("../../core/input.zig");

// ─── Keyboard ─────────────────────────────────────────────────────────────

pub fn guavaHostIsKeyDown(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx.isKeyDown(key)) 1 else 0;
}

pub fn guavaHostWasKeyPressed(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx.wasKeyPressed(key)) 1 else 0;
}

pub fn guavaHostWasKeyReleased(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.meta.intToEnum(input_mod.Key, @as(u8, @intCast(key_raw))) catch return 0;
    return if (ctx.wasKeyReleased(key)) 1 else 0;
}

// ─── Mouse ────────────────────────────────────────────────────────────────

pub fn guavaHostIsMouseButtonDown(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const button = std.meta.intToEnum(input_mod.MouseButton, @as(u2, @intCast(btn_raw))) catch return 0;
    return if (ctx.isMouseButtonDown(button)) 1 else 0;
}

pub fn guavaHostGetMousePosition(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const pos = ctx.getMousePosition() orelse return;
    x.* = pos[0];
    y.* = pos[1];
}

pub fn guavaHostGetMouseDelta(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const delta = ctx.getMouseDelta() orelse return;
    x.* = delta[0];
    y.* = delta[1];
}

pub fn guavaHostGetMouseWheel(userdata: ?*anyopaque, x: *f32, y: *f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const wheel = ctx.getMouseWheel() orelse return;
    x.* = wheel[0];
    y.* = wheel[1];
}

// ─── Gamepad ──────────────────────────────────────────────────────────────

pub fn guavaHostIsGamepadConnected(userdata: ?*anyopaque) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    return if (input_state.gamepad_connected) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostIsGamepadButtonDown(userdata: ?*anyopaque, button: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const btn = std.meta.intToEnum(input_mod.GamepadButton, @as(u8, @intCast(button))) catch return 0;
    return if (input_state.isGamepadButtonDown(btn)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasGamepadButtonPressed(userdata: ?*anyopaque, button: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const btn = std.meta.intToEnum(input_mod.GamepadButton, @as(u8, @intCast(button))) catch return 0;
    return if (input_state.wasGamepadButtonPressed(btn)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostGetGamepadAxis(userdata: ?*anyopaque, axis: u32) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    const input_state = ctx.input orelse return 0.0;
    const ax = std.meta.intToEnum(input_mod.GamepadAxis, @as(u8, @intCast(axis))) catch return 0.0;
    return input_state.getGamepadAxis(ax);
}
