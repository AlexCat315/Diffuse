///! handlers/mesh.zig — mesh editing RPC operations.
///!
///! Delegates to MeshOps vtable (set from main.zig) to avoid
///! cross-module imports of editor_backend.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const MeshOps = @import("../mesh_ops.zig").MeshOps;
const SelectionMode = @import("../mesh_ops.zig").SelectionMode;

// ── Helpers ──────────────────────────────────────────────────────

fn ops(ctx: *Ctx) !*const MeshOps {
    return ctx.mesh_ops orelse error.InvalidArguments;
}

// ── Mode management ──────────────────────────────────────────────

pub fn getState(ctx: *Ctx) !void {
    const m = try ops(ctx);
    const snap = m.getSnapshot(m.state_ptr, ctx.layer);

    const mode_str: []const u8 = if (snap.mode_edit) "edit" else "object";
    const sel_str: []const u8 = switch (snap.selection_mode) {
        .vertex => "vertex",
        .edge => "edge",
        .face => "face",
    };

    try ctx.reply(.{
        .active = snap.active,
        .mode = mode_str,
        .selectionMode = sel_str,
        .selectionCount = @as(u64, snap.selection_count),
        .canEnterEditMode = snap.can_enter_edit_mode,
        .entityId = snap.entity_id,
    });
}

pub fn enterEditMode(ctx: *Ctx) !void {
    const m = try ops(ctx);
    if (try ctx.paramOpt(u64, "entityId")) |eid| {
        try m.selectEntity(m.state_ptr, ctx.layer, eid);
    }
    const success = try m.enterEditMode(m.state_ptr, ctx.layer);
    try ctx.reply(.{ .success = success });
}

pub fn exitEditMode(ctx: *Ctx) !void {
    const m = try ops(ctx);
    m.exitEditMode(m.state_ptr, ctx.layer);
    try ctx.reply(.{});
}

pub fn setSelectionMode(ctx: *Ctx) !void {
    const m = try ops(ctx);
    const mode_str = try ctx.param([]const u8, "mode");
    const mode: SelectionMode = if (std.mem.eql(u8, mode_str, "vertex"))
        .vertex
    else if (std.mem.eql(u8, mode_str, "edge"))
        .edge
    else if (std.mem.eql(u8, mode_str, "face"))
        .face
    else
        return error.InvalidArguments;
    m.setSelectionMode(m.state_ptr, mode);
    try ctx.reply(.{});
}

// ── Mesh operations ──────────────────────────────────────────────

fn opReply(ctx: *Ctx, func: *const fn (*anyopaque, *@import("../../core/layer.zig").LayerContext) anyerror!bool, state_ptr: *anyopaque) !void {
    const success = try func(state_ptr, ctx.layer);
    try ctx.reply(.{ .success = success });
}

pub fn extrude(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.extrude, m.state_ptr);
}

pub fn inset(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.inset, m.state_ptr);
}

pub fn bevel(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.bevel, m.state_ptr);
}

pub fn loopCut(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.loopCut, m.state_ptr);
}

pub fn merge(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.merge, m.state_ptr);
}

pub fn delete(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.delete, m.state_ptr);
}

pub fn duplicate(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.duplicate, m.state_ptr);
}

pub fn separate(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.separate, m.state_ptr);
}

pub fn recalcNormals(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.recalcNormals, m.state_ptr);
}

pub fn pivotToSelection(ctx: *Ctx) !void {
    const m = try ops(ctx);
    try opReply(ctx, m.pivotToSelection, m.state_ptr);
}
