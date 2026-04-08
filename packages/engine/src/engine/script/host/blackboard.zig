// host/blackboard.zig — 全局黑板桥接
const mod = @import("./mod.zig");

pub fn guavaHostBlackboardSet(userdata: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setBlackboard(key_ptr[0..key_len], val_ptr[0..val_len]);
}

pub fn guavaHostBlackboardGet(userdata: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const val = ctx.getBlackboard(key_ptr[0..key_len]) orelse return 0;
    out_ptr.* = val.ptr;
    out_len.* = val.len;
    return 1;
}

pub fn guavaHostBlackboardRemove(userdata: ?*anyopaque, key_ptr: [*]const u8, key_len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.removeBlackboard(key_ptr[0..key_len]);
}
