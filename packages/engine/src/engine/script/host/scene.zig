// host/scene.zig — 场景加载/卸载桥接
const mod = @import("./mod.zig");

pub fn guavaHostLoadScene(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.loadScene(ptr[0..len]);
}
