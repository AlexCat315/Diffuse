///! handlers/editor.zig — editor lifecycle & state methods.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const dispatch = @import("../dispatch.zig");

pub fn ping(ctx: *Ctx) !void {
    try ctx.reply(.{ .pong = true });
}

pub fn getCapabilities(ctx: *Ctx) !void {
    try ctx.reply(.{
        .version = "0.1.0",
        .methods = &dispatch.method_names,
        .subscriptions = &dispatch.subscription_names,
    });
}

pub fn setSelection(ctx: *Ctx) !void {
    const std = @import("std");
    const arr = try ctx.paramArray("entityIds");
    var ids = std.ArrayList(ctx_mod.EntityId).empty;
    defer ids.deinit(ctx.allocator);

    for (arr.items) |item| {
        const id: ctx_mod.EntityId = switch (item) {
            .integer => |i| @intCast(i),
            .float => |f| @intFromFloat(f),
            else => continue,
        };
        try ids.append(ctx.allocator, id);
    }
    _ = try ctx.layer.renderer.selection_history.replaceSelection(ids.items);
    try ctx.reply(.{});
}

pub fn undo(ctx: *Ctx) !void {
    // TODO: wire to command history
    try ctx.reply(.{});
}

pub fn redo(ctx: *Ctx) !void {
    // TODO: wire to command history
    try ctx.reply(.{});
}
