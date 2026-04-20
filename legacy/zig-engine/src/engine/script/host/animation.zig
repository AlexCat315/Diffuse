// host/animation.zig — 动画控制桥接
const mod = @import("./mod.zig");
const animator_system = @import("../../animation/animator_system.zig");

pub fn guavaHostAnimPlay(userdata: ?*anyopaque, entity_id: u64, clip_ptr: [*]const u8, clip_len: usize, blend_duration: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    const clip_asset_id = clip_ptr[0..clip_len];
    const clip_handle = ctx.world.resources.animationClipHandleByAssetId(clip_asset_id) orelse return;
    animator_system.playClip(ctx.world, entity_id, clip_handle, .{ .blend_duration_seconds = blend_duration }) catch return;
}

pub fn guavaHostAnimStop(userdata: ?*anyopaque, entity_id: u64) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    if (ctx.world.id_to_index.get(entity_id)) |idx| {
        var entity = &ctx.world.entities.items[idx];
        if (entity.animator) |*anim| {
            anim.playing = false;
        }
    }
}

pub fn guavaHostAnimSetSpeed(userdata: ?*anyopaque, entity_id: u64, speed: f32) callconv(.c) void {
    const ctx = mod.activeContext(userdata) orelse return;
    if (ctx.world.id_to_index.get(entity_id)) |idx| {
        var entity = &ctx.world.entities.items[idx];
        if (entity.animator) |*anim| {
            anim.speed = speed;
        }
    }
}

pub fn guavaHostAnimIsPlaying(userdata: ?*anyopaque, entity_id: u64) callconv(.c) u32 {
    const ctx = mod.activeContext(userdata) orelse return 0;
    if (ctx.world.id_to_index.get(entity_id)) |idx| {
        const entity = ctx.world.entities.items[idx];
        if (entity.animator) |anim| {
            return if (anim.playing) @as(u32, 1) else @as(u32, 0);
        }
    }
    return 0;
}
