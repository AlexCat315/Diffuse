///! handlers/collaboration.zig — AI staged-transaction operations.
///!
///! Provides RPC handlers for the collaboration store's staged
///! transaction lifecycle: stage → apply/discard.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const collaboration_mod = @import("../../mcp/collaboration.zig");
const tools_mod = @import("../../mcp/tools.zig");

pub fn stageTransaction(ctx: *Ctx) !void {
    const store = ctx.collaboration_store orelse return error.CollaborationStoreUnavailable;

    const commands_value = blk: {
        const p = ctx.params orelse return error.InvalidArguments;
        const obj = switch (p) {
            .object => |o| o,
            else => return error.InvalidArguments,
        };
        break :blk obj.get("commands") orelse return error.InvalidArguments;
    };
    const commands = switch (commands_value) {
        .array => |a| a.items,
        else => return error.InvalidArguments,
    };
    if (commands.len == 0) return error.InvalidArguments;

    var stage_request = collaboration_mod.StageRequest{};
    stage_request.commands = .empty;
    errdefer stage_request.deinit(ctx.allocator);

    if (try ctx.paramOpt([]const u8, "label")) |label| {
        stage_request.label = try ctx.allocator.dupe(u8, label);
    }
    if (try ctx.paramOpt([]const u8, "note")) |note| {
        stage_request.note = try ctx.allocator.dupe(u8, note);
    }

    try stage_request.commands.ensureTotalCapacity(ctx.allocator, commands.len);

    for (commands) |command_value| {
        const command_object = switch (command_value) {
            .object => |o| o,
            else => return error.InvalidArguments,
        };
        const command_name = switch (command_object.get("name") orelse return error.InvalidArguments) {
            .string => |s| s,
            else => return error.InvalidArguments,
        };
        const command_arguments = command_object.get("arguments");

        const parsed = try tools_mod.parseCommandAlloc(ctx.allocator, command_name, command_arguments);
        try stage_request.commands.append(ctx.allocator, .{
            .tool_name = parsed.tool_name,
            .command = parsed.command,
            .meta = .{},
        });
    }

    const result = try store.stageOwnedTransaction(ctx.layer.world, &stage_request);
    try ctx.reply(.{
        .transactionId = result.transaction_id,
        .commandCount = result.command_count,
        .errorCount = result.error_count,
    });
}

pub fn applyStagedTransaction(ctx: *Ctx) !void {
    const store = ctx.collaboration_store orelse return error.CollaborationStoreUnavailable;
    const result = try store.applyStagedTransactionWithMeta(ctx.layer.world, .ai, null);
    try ctx.reply(.{
        .applied = result.had_transaction,
        .commandCount = result.command_count,
        .changedCount = result.changed_count,
        .errorCount = result.error_count,
    });
}

pub fn discardStagedTransaction(ctx: *Ctx) !void {
    const store = ctx.collaboration_store orelse return error.CollaborationStoreUnavailable;
    const result = store.discardStagedTransactionWithMeta(.ai, null);
    try ctx.reply(.{
        .hadTransaction = result.had_transaction,
    });
}
