///! handlers/audio.zig — audio mixer status and control.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const audio = @import("../../audio/mod.zig");

pub fn getMixerStatus(ctx: *Ctx) !void {
    const runtime = audio.get() catch {
        try ctx.reply(.{
            .available = false,
            .activeVoices = @as(u32, 0),
            .buses = &[0]BusInfoOut{},
        });
        return;
    };

    const status = runtime.getMixerStatus();

    const buses = [_]BusInfoOut{
        .{ .id = "master", .label = "Master", .volume = status.master_volume, .playing = status.active_voices },
        .{ .id = "music", .label = "Music", .volume = status.music_volume, .playing = status.music_playing },
        .{ .id = "sfx", .label = "SFX", .volume = status.sfx_volume, .playing = status.sfx_playing },
    };

    try ctx.reply(.{
        .available = true,
        .activeVoices = status.active_voices,
        .buses = &buses,
    });
}

const BusInfoOut = struct {
    id: []const u8,
    label: []const u8,
    volume: f32,
    playing: u32,
};

pub fn setBusVolume(ctx: *Ctx) !void {
    const bus_id_str = try ctx.param([]const u8, "busId");
    const volume = try ctx.param(f32, "volume");

    const runtime = audio.get() catch return error.NotAvailable;

    const bus_id: audio.BusId = if (std.mem.eql(u8, bus_id_str, "master"))
        .master
    else if (std.mem.eql(u8, bus_id_str, "music"))
        .music
    else if (std.mem.eql(u8, bus_id_str, "sfx"))
        .sfx
    else
        return error.InvalidArguments;

    runtime.setMixerVolume(bus_id, volume);
    try ctx.reply(.{});
}
