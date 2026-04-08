// host/entity.zig — 实体 CRUD 桥接
const mod = @import("./mod.zig");
const world_mod = @import("../../scene/world.zig");

pub fn guavaHostGetEntityId(userdata: ?*anyopaque) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return ctx.entity;
}

pub fn guavaHostFindEntityByName(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return ctx.findEntityByName(ptr[0..len]) orelse 0;
}

pub fn guavaHostSpawnEntity(userdata: ?*anyopaque) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    const new_id = ctx.world.createEntity(.{ .name = "SpawnedEntity" }) catch return 0;
    return new_id;
}

pub fn guavaHostDestroyEntity(userdata: ?*anyopaque, target: u64) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.destroyEntity(target);
}
