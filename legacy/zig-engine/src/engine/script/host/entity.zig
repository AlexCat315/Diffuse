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

// ─── Entity Hierarchy ─────────────────────────────────────────────────────

pub fn guavaHostGetChildCount(userdata: ?*anyopaque) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return @intCast(ctx.getChildCount());
}

pub fn guavaHostGetChildEntity(userdata: ?*anyopaque, index: u32) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return ctx.getChild(@intCast(index)) orelse 0;
}

pub fn guavaHostGetParentEntity(userdata: ?*anyopaque) callconv(.c) u64 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return ctx.getParent() orelse 0;
}

// ─── Tag Query ────────────────────────────────────────────────────────────

pub fn guavaHostFindEntitiesByTag(userdata: ?*anyopaque, ptr: [*]const u8, len: usize, out: [*]u64, max: u32) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    return @intCast(ctx.findEntitiesByTag(ptr[0..len], out[0..max]));
}

pub fn guavaHostGetTag(userdata: ?*anyopaque, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const tag = ctx.getTag();
    out_ptr.* = tag.ptr;
    out_len.* = tag.len;
}

pub fn guavaHostSetTag(userdata: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    ctx.setTag(ptr[0..len]);
}
