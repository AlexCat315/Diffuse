// host/log.zig — 日志桥接
const std = @import("std");
const mod = @import("./mod.zig");

pub fn guavaHostLog(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    std.log.info("[Script:{d}] {s}", .{ ctx.entity, ptr[0..len] });
}
