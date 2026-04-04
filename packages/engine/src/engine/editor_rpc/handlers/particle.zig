///! handlers/particle.zig — VFX / particle system inspection & editing.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const components = @import("../../scene/components.zig");
const Vfx = components.Vfx;
const VfxKind = components.VfxKind;

// ── helpers ─────────────────────────────────────────────────────

fn kindToString(kind: VfxKind) []const u8 {
    return switch (kind) {
        .fountain => "fountain",
        .orbit => "orbit",
    };
}

fn stringToKind(s: []const u8) ?VfxKind {
    if (std.mem.eql(u8, s, "fountain")) return .fountain;
    if (std.mem.eql(u8, s, "orbit")) return .orbit;
    return null;
}

// ── RPC handlers ────────────────────────────────────────────────

/// List all entities that have a Vfx component.
pub fn listVfxEntities(ctx: *Ctx) !void {
    const world = ctx.layer.world;
    const a = ctx.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"entities\":[");

    var first = true;
    for (world.entities.items) |entity| {
        if (entity.vfx) |vfx| {
            if (!first) try buf.appendSlice(a, ",");
            first = false;
            try buf.appendSlice(a, "{\"entityId\":");
            var id_buf: [20]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{}", .{entity.id}) catch "0";
            try buf.appendSlice(a, id_str);
            try buf.appendSlice(a, ",\"name\":\"");
            try appendJsonEscaped(&buf, a, entity.name);
            try buf.appendSlice(a, "\",\"kind\":\"");
            try buf.appendSlice(a, kindToString(vfx.kind));
            try buf.appendSlice(a, "\"}");
        }
    }

    try buf.appendSlice(a, "]}");
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

/// Get VFX configuration for a specific entity.
pub fn getConfig(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;

    if (entity.vfx) |vfx| {
        try ctx.reply(.{
            .found = true,
            .config = .{
                .kind = kindToString(vfx.kind),
                .looping = vfx.looping,
                .emissionRate = @as(f64, vfx.emission_rate),
                .particleLifetime = @as(f64, vfx.particle_lifetime),
                .speed = @as(f64, vfx.speed),
                .maxParticles = @as(u32, vfx.max_particles),
                .radius = @as(f64, vfx.radius),
                .spread = @as(f64, vfx.spread),
                .size = @as(f64, vfx.size),
                .colorR = @as(f64, vfx.color[0]),
                .colorG = @as(f64, vfx.color[1]),
                .colorB = @as(f64, vfx.color[2]),
            },
        });
    } else {
        try ctx.reply(.{ .found = false });
    }
}

/// Update VFX configuration fields (partial update, only non-null fields applied).
pub fn setConfig(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;
    var vfx = &(entity.vfx orelse return error.InvalidArguments);

    if (try ctx.paramOpt([]const u8, "kind")) |k| {
        if (stringToKind(k)) |new_kind| vfx.kind = new_kind;
    }
    if (try ctx.paramOpt(bool, "looping")) |v| vfx.looping = v;
    if (try ctx.paramOpt(f64, "emissionRate")) |v| vfx.emission_rate = @floatCast(v);
    if (try ctx.paramOpt(f64, "particleLifetime")) |v| vfx.particle_lifetime = @floatCast(v);
    if (try ctx.paramOpt(f64, "speed")) |v| vfx.speed = @floatCast(v);
    if (try ctx.paramOpt(u64, "maxParticles")) |v| vfx.max_particles = @intCast(std.math.clamp(v, 1, 1000));
    if (try ctx.paramOpt(f64, "radius")) |v| vfx.radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "spread")) |v| vfx.spread = @floatCast(v);
    if (try ctx.paramOpt(f64, "size")) |v| vfx.size = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorR")) |v| vfx.color[0] = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorG")) |v| vfx.color[1] = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorB")) |v| vfx.color[2] = @floatCast(v);

    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{ .success = true });
}

/// Apply a named preset, resetting all fields to defaults.
pub fn applyPreset(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const preset_name = try ctx.param([]const u8, "preset");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;

    const kind = stringToKind(preset_name) orelse return error.InvalidArguments;
    entity.vfx = components.defaultVfx(kind);
    ctx.layer.world.markSceneChanged();
    try ctx.reply(.{ .success = true });
}

// ── JSON escape helper ──────────────────────────────────────────

fn appendJsonEscaped(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
}
