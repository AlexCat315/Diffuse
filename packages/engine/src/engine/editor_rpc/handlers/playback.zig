///! handlers/playback.zig — play / pause / stop controls.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn play(ctx: *Ctx) !void {
    ctx.layer.playback_controller.setState(.playing);
    try ctx.reply(.{});
}

pub fn pause(ctx: *Ctx) !void {
    ctx.layer.playback_controller.setState(.paused);
    try ctx.reply(.{});
}

pub fn stop(ctx: *Ctx) !void {
    ctx.layer.playback_controller.setState(.stopped);
    try ctx.reply(.{});
}
