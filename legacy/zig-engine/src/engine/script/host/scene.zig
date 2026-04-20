// host/scene.zig — 场景加载/卸载桥接
const mod = @import("./mod.zig");

pub fn guavaHostLoadScene(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.loadScene(ptr[0..len]);
}

pub fn guavaHostUnloadScene(userdata: ?*anyopaque) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.unloadScene();
}

pub fn guavaHostIsSceneLoading(userdata: ?*anyopaque) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return if (ctx.isSceneLoading()) @as(u32, 1) else @as(u32, 0);
}

pub fn guavaHostSetDontDestroyOnLoad(userdata: ?*anyopaque, enabled: u32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setDontDestroyOnLoad(enabled != 0);
}

pub fn guavaHostSetEntityDontDestroyOnLoad(userdata: ?*anyopaque, entity_id: u64, enabled: u32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setEntityDontDestroyOnLoad(entity_id, enabled != 0);
}

// ─── Prefab ───────────────────────────────────────────────────────────────

pub fn guavaHostInstantiatePrefab(userdata: ?*anyopaque, ptr: [*]const u8, len: usize, px: f32, py: f32, pz: f32) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return ctx.instantiatePrefab(ptr[0..len], px, py, pz) orelse 0;
}
