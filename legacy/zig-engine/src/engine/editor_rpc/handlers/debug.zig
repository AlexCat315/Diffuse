///! handlers/debug.zig — debug statistics and diagnostics.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn getRhiStats(ctx: *Ctx) !void {
    const dev = ctx.layer.renderer.gfx_device orelse {
        try ctx.reply(.{
            .bindingCache = .{
                .hits = @as(u64, 0),
                .misses = @as(u64, 0),
                .evictions = @as(u64, 0),
                .entries = @as(u32, 0),
                .maxEntries = @as(u32, 1024),
                .hitRate = @as(f64, 0),
                .frameHits = @as(u64, 0),
                .frameMisses = @as(u64, 0),
                .frameEvictions = @as(u64, 0),
            },
            .passes = &[0]PassInfo{},
        });
        return;
    };

    const stats = dev.bindingSetCacheStats();
    const frame_delta = stats.delta(dev.prev_frame_stats);
    const entries = dev.bindingSetCacheEntryCount();

    try ctx.reply(.{
        .bindingCache = .{
            .hits = stats.hits,
            .misses = stats.misses,
            .evictions = stats.evictions,
            .entries = entries,
            .maxEntries = @as(u32, 1024),
            .hitRate = stats.hitRate() * 100.0,
            .frameHits = frame_delta.hits,
            .frameMisses = frame_delta.misses,
            .frameEvictions = frame_delta.evictions,
        },
        .passes = &passes,
    });
}

const PassInfo = struct { name: []const u8, status: []const u8 };

const passes = [_]PassInfo{
    .{ .name = "SSAO", .status = "compute" },
    .{ .name = "FXAA", .status = "GFX" },
    .{ .name = "Bloom", .status = "GFX" },
    .{ .name = "Tonemap", .status = "GFX" },
    .{ .name = "Contact Shadow", .status = "GFX" },
    .{ .name = "DOF", .status = "GFX" },
    .{ .name = "SSR", .status = "GFX" },
    .{ .name = "Volumetric Fog", .status = "GFX" },
    .{ .name = "Depth Prepass", .status = "GFX" },
    .{ .name = "Shadow Pass", .status = "GFX" },
    .{ .name = "Outline", .status = "GFX" },
    .{ .name = "Skybox", .status = "GFX" },
    .{ .name = "TAA", .status = "GFX" },
    .{ .name = "IBL Compute", .status = "GFX (BRDF + Irradiance)" },
    .{ .name = "Gizmo", .status = "GFX (line geometry)" },
    .{ .name = "ID Pass", .status = "GFX (entity picking)" },
    .{ .name = "Omni Shadow", .status = "GFX (6-face cubemap)" },
    .{ .name = "RT Shadow Composite", .status = "GFX (fullscreen multiply)" },
    .{ .name = "Base Pass", .status = "GFX (10-set PBR + IBL + CSM)" },
};

pub fn resetRhiStats(ctx: *Ctx) !void {
    if (ctx.layer.renderer.gfx_device) |dev| {
        dev.resetBindingSetCacheStats();
    }
    try ctx.reply(.{});
}
