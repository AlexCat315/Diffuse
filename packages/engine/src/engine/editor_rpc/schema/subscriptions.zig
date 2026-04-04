///! Subscription event payloads.
const types = @import("types.zig");

pub const @"on:scene.changed" = struct {
    revision: u64,
    entityIds: []const u64,
};

pub const @"on:selection.changed" = struct {
    entityIds: []const u64,
};

pub const @"on:console.log" = types.LogEntry;

pub const @"on:console.logs" = struct {
    entries: []const types.LogEntry,
};

pub const @"on:viewport.metrics" = struct {
    fps: u32,
    frameTimeMs: u32,
    drawCalls: u32,
    triangles: u32,
    frameDelayMs: u32,
};

pub const @"on:playback.stateChanged" = struct {
    state: []const u8,
};

pub const @"on:asset.changed" = struct {
    assetId: []const u8,
    changeType: []const u8,
};

pub const @"on:editor.historyChanged" = struct {
    cursor: u64,
    totalEntries: u64,
};
