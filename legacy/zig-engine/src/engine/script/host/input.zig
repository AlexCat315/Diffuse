// host/input.zig — 键盘/鼠标/手柄输入桥接
const std = @import("std");
const mod = @import("./mod.zig");
const input_mod = @import("../../core/input.zig");

// ─── Keyboard ─────────────────────────────────────────────────────────────

pub fn guavaHostIsKeyDown(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.enums.fromInt(input_mod.Key, @as(u8, @intCast(key_raw))) orelse return 0;
    return if (ctx.isKeyDown(key)) 1 else 0;
}

pub fn guavaHostWasKeyPressed(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.enums.fromInt(input_mod.Key, @as(u8, @intCast(key_raw))) orelse return 0;
    return if (ctx.wasKeyPressed(key)) 1 else 0;
}

pub fn guavaHostWasKeyReleased(userdata: ?*anyopaque, key_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const key = std.enums.fromInt(input_mod.Key, @as(u8, @intCast(key_raw))) orelse return 0;
    return if (ctx.wasKeyReleased(key)) 1 else 0;
}

// ─── Mouse ────────────────────────────────────────────────────────────────

pub fn guavaHostIsMouseButtonDown(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const button = std.enums.fromInt(input_mod.MouseButton, @as(u2, @intCast(btn_raw))) orelse return 0;
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
    const btn = std.enums.fromInt(input_mod.GamepadButton, @as(u8, @intCast(button))) orelse return 0;
    return if (input_state.isGamepadButtonDown(btn)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasGamepadButtonPressed(userdata: ?*anyopaque, button: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const input_state = ctx.input orelse return 0;
    const btn = std.enums.fromInt(input_mod.GamepadButton, @as(u8, @intCast(button))) orelse return 0;
    return if (input_state.wasGamepadButtonPressed(btn)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostGetGamepadAxis(userdata: ?*anyopaque, axis: u32) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    const input_state = ctx.input orelse return 0.0;
    const ax = std.enums.fromInt(input_mod.GamepadAxis, @as(u8, @intCast(axis))) orelse return 0.0;
    return input_state.getGamepadAxis(ax);
}

// ─── Mouse (extended) ─────────────────────────────────────────────────────

pub fn guavaHostWasMouseButtonPressed(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const button = std.enums.fromInt(input_mod.MouseButton, @as(u2, @intCast(btn_raw))) orelse return 0;
    return if (ctx.wasMouseButtonPressed(button)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasMouseButtonReleased(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const button = std.enums.fromInt(input_mod.MouseButton, @as(u2, @intCast(btn_raw))) orelse return 0;
    return if (ctx.wasMouseButtonReleased(button)) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasMouseDoubleClicked(userdata: ?*anyopaque, btn_raw: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const button = std.enums.fromInt(input_mod.MouseButton, @as(u2, @intCast(btn_raw))) orelse return 0;
    return if (ctx.wasMouseDoubleClicked(button)) @as(u32, 1) else @as(u32, 0);
}

// ─── Action Map ───────────────────────────────────────────────────────────

pub fn guavaHostIsActionPressed(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return if (ctx.isActionPressed(ptr[0..len])) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasActionJustPressed(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return if (ctx.wasActionJustPressed(ptr[0..len])) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostWasActionJustReleased(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return if (ctx.wasActionJustReleased(ptr[0..len])) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostGetActionAxis(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.getActionAxis(ptr[0..len]);
}
