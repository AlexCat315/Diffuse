///! editor_backend/mod.zig — public entry point for the editor backend module.
///!
///! Re-exports key submodules so downstream code can use
///! `@import("guava").editor_backend.*` instead of direct file paths.
pub const core = struct {
    pub const layer = @import("core/layer.zig");
    pub const state = @import("core/state.zig");
    pub const logging = @import("core/logging.zig");
    pub const preferences = @import("core/preferences.zig");
    pub const playback_session = @import("core/playback_session.zig");

    pub const EditorLayer = layer.EditorLayer;
    pub const EditorState = state.EditorState;
};

pub const actions = struct {
    pub const command = @import("actions/command.zig");
    pub const history = @import("actions/history.zig");
    pub const material_ops = @import("actions/material_ops.zig");
    pub const reparenting = @import("actions/reparenting.zig");
};

test {
    _ = @import("core/layer.zig");
    _ = @import("core/state.zig");
    _ = @import("core/logging.zig");
    _ = @import("actions/material_ops.zig");
}
