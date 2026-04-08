///! Collaboration namespace — staged transactions with ghost preview.
const types = @import("types.zig");

pub const @"collaboration.stageTransaction" = struct {
    pub const ai_tool: types.AiTool = .{
        .description = "Stage a batch of RPC tool calls for preview before committing. Executes all commands in an isolated ghost world. Returns a transactionId for apply/discard. commands is an array of {name, arguments} objects.",
        .category = .collaboration,
        .requires_confirmation = true,
    };
    pub const Params = struct {
        commands: types.JsonValue,
        label: ?[]const u8 = null,
        note: ?[]const u8 = null,
    };
    pub const Result = struct {
        transactionId: u64,
        commandCount: u32,
        errorCount: u32,
    };
};

pub const @"collaboration.applyStagedTransaction" = struct {
    pub const ai_tool: types.AiTool = .{
        .description = "Commit the currently staged transaction into the real world. Fails if no transaction is staged.",
        .category = .collaboration,
        .requires_confirmation = true,
    };
    pub const Params = struct {};
    pub const Result = struct {
        applied: bool,
        commandCount: u32,
        changedCount: u32,
        errorCount: u32,
    };
};

pub const @"collaboration.discardStagedTransaction" = struct {
    pub const ai_tool: types.AiTool = .{
        .description = "Discard the currently staged transaction and clear the ghost preview.",
        .category = .collaboration,
    };
    pub const Params = struct {};
    pub const Result = struct {
        hadTransaction: bool,
    };
};
