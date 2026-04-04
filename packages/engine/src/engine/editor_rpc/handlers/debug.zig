///! handlers/debug.zig — debug statistics and diagnostics.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn getRhiStats(ctx: *Ctx) !void {
    const dev = ctx.layer.renderer.rhi_device orelse {
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
    .{ .name = "FXAA", .status = "RHI" },
    .{ .name = "Bloom", .status = "RHI" },
    .{ .name = "Tonemap", .status = "RHI" },
    .{ .name = "Contact Shadow", .status = "RHI" },
    .{ .name = "DOF", .status = "RHI" },
    .{ .name = "SSR", .status = "RHI" },
    .{ .name = "Volumetric Fog", .status = "RHI" },
    .{ .name = "Depth Prepass", .status = "RHI" },
    .{ .name = "Shadow Pass", .status = "RHI" },
    .{ .name = "Outline", .status = "RHI" },
    .{ .name = "Skybox", .status = "RHI" },
    .{ .name = "TAA", .status = "RHI" },
    .{ .name = "IBL Compute", .status = "RHI (BRDF + Irradiance)" },
    .{ .name = "Gizmo", .status = "RHI (line geometry)" },
    .{ .name = "ID Pass", .status = "RHI (entity picking)" },
    .{ .name = "Omni Shadow", .status = "RHI (6-face cubemap)" },
    .{ .name = "RT Shadow Composite", .status = "RHI (fullscreen multiply)" },
    .{ .name = "Base Pass", .status = "RHI (10-set PBR + IBL + CSM)" },
};

pub fn resetRhiStats(ctx: *Ctx) !void {
    if (ctx.layer.renderer.rhi_device) |dev| {
        dev.resetBindingSetCacheStats();
    }
    try ctx.reply(.{});
}
