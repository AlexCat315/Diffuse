///! handlers/utilities.zig — editor utility runtime inspection.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const editor_utility_runtime = @import("../../script/editor_utility_runtime.zig");
const handles = @import("../../assets/handles.zig");

pub fn list(ctx: *Ctx) !void {
    const runtime = ctx.layer.editor_utility_runtime orelse {
        try ctx.reply(.{ .utilities = @as([]const u8, &.{}) });
        return;
    };
    const snapshots = runtime.listAlloc(ctx.layer.world.allocator) catch {
        try ctx.reply(.{ .utilities = @as([]const u8, &.{}) });
        return;
    };
    defer editor_utility_runtime.freeSnapshots(ctx.layer.world.allocator, snapshots);

    var arr = std.ArrayList(struct {
        handle: u64,
        name: []const u8,
        description: []const u8,
        sourcePath: []const u8,
        status: []const u8,
        open: bool,
        lastError: []const u8,
    }).empty;
    defer arr.deinit(ctx.allocator);

    for (snapshots) |s| {
        try arr.append(ctx.allocator, .{
            .handle = @intFromEnum(s.handle),
            .name = s.name,
            .description = s.description,
            .sourcePath = s.source_path,
            .status = statusLabel(s.status),
            .open = s.open,
            .lastError = s.last_error,
        });
    }
    try ctx.reply(.{ .utilities = arr.items });
}

pub fn setOpen(ctx: *Ctx) !void {
    const runtime = ctx.layer.editor_utility_runtime orelse return error.RuntimeNotAvailable;
    const handle_int = try ctx.param(u64, "handle");
    const open = try ctx.param(bool, "open");
    const handle: handles.ScriptHandle = @enumFromInt(handle_int);
    runtime.setOpen(handle, open);
    try ctx.reply(.{});
}

pub fn remove(ctx: *Ctx) !void {
    const runtime = ctx.layer.editor_utility_runtime orelse return error.RuntimeNotAvailable;
    const handle_int = try ctx.param(u64, "handle");
    const handle: handles.ScriptHandle = @enumFromInt(handle_int);
    _ = runtime.remove(handle);
    try ctx.reply(.{});
}

fn statusLabel(status: editor_utility_runtime.Status) []const u8 {
    return switch (status) {
        .ready => "ready",
        .load_error => "load_error",
        .init_error => "init_error",
        .update_error => "update_error",
    };
}
