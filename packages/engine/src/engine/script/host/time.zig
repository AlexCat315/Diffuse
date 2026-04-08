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
