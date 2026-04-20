// host/persistence.zig — 持久化存储桥接（saves/{key}.dat）
const mod = @import("./mod.zig");

pub fn guavaHostSaveData(userdata: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return if (ctx.saveData(key_ptr[0..key_len], val_ptr[0..val_len])) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostLoadData(userdata: ?*anyopaque, key_ptr: [*]const u8, key_len: usize, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const data = ctx.loadData(key_ptr[0..key_len]) orelse return 0;
    out_ptr.* = data.ptr;
    out_len.* = data.len;
    return 1;
}
