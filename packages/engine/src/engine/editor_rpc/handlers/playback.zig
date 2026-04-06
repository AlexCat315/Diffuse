///! handlers/playback.zig — play / pause / stop controls.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const scene_io = @import("../../scene/scene_io.zig");
const Ctx = ctx_mod.Ctx;

pub fn play(ctx: *Ctx) !void {
    const pc = ctx.layer.playback_controller;
    // Snapshot the scene when transitioning from stopped → playing.
    if (pc.state == .stopped) {
        if (scene_io.serializeWorldAlloc(ctx.allocator, ctx.layer.world)) |data| {
            pc.storeSnapshot(ctx.allocator, data);
        } else |err| {
            std.log.err("playback: failed to snapshot scene before play: {}", .{err});
            // Continue playing even if snapshot fails — non-fatal.
        }
    }
    pc.setState(.playing);
    try ctx.reply(.{});
}

pub fn pause(ctx: *Ctx) !void {
    ctx.layer.playback_controller.setState(.paused);
    try ctx.reply(.{});
}

pub fn stop(ctx: *Ctx) !void {
    const pc = ctx.layer.playback_controller;
    pc.setState(.stopped);
    // Rollback scene to the pre-play snapshot.
    if (pc.takeSnapshot()) |snapshot| {
        defer ctx.allocator.free(snapshot);
        scene_io.deserializeWorldFromSlice(ctx.allocator, ctx.layer.world, snapshot) catch |err| {
            std.log.err("playback: failed to rollback scene on stop: {}", .{err});
        };
        ctx.layer.world.markSceneChanged();
    }
    try ctx.reply(.{});
}
