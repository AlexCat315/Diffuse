// host/time.zig — 时间/帧率桥接
const mod = @import("./mod.zig");

pub fn guavaHostGetDeltaTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.delta_time;
}

pub fn guavaHostGetTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.time;
}

pub fn guavaHostGetTimeScale(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 1.0;
    return ctx.getTimeScale();
}

pub fn guavaHostSetTimeScale(userdata: ?*anyopaque, scale: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setTimeScale(scale);
}

pub fn guavaHostGetScaledDeltaTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.getScaledDeltaTime();
}

pub fn guavaHostGetScaledTime(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.getScaledTime();
}

pub fn guavaHostGetFps(userdata: ?*anyopaque) callconv(.c) f32 {
    const ctx = mod.activeContext(userdata) orelse return 0.0;
    return ctx.getFPS();
}
