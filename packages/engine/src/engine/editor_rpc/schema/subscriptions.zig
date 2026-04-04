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

pub const @"on:viewport.metrics" = struct {
    fps: f64,
    drawCalls: u64,
    triangles: u64,
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
