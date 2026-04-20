const engine = @import("guava");
const EditorState = @import("state.zig").EditorState;
const PlaybackState = @import("state.zig").PlaybackState;
const history = @import("../actions/history.zig");
const utils = @import("../common/utils.zig");

fn setPlaybackState(state: *EditorState, layer_context: *engine.core.LayerContext, playback_state: PlaybackState) void {
    state.playback_state = playback_state;
    layer_context.playback_controller.setState(playback_state);
}

fn beginPlayMode(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.play_mode_active) {
        return;
    }

    try history.refreshSnapshotBaseline(state, layer_context.world);
    state.history_snapshot_needs_refresh = false;
    state.play_mode_active = true;
}

pub fn play(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.play_mode_active and layer_context.playback_controller.state == .stopped) {
        try beginPlayMode(state, layer_context);
    }
    setPlaybackState(state, layer_context, .playing);
}

pub fn pause(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.play_mode_active and layer_context.playback_controller.state == .stopped) {
        return;
    }
    setPlaybackState(state, layer_context, .paused);
}

pub fn stop(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.play_mode_active and layer_context.playback_controller.state == .stopped) {
        setPlaybackState(state, layer_context, .stopped);
        return;
    }
    setPlaybackState(state, layer_context, .stopped);
}

pub fn step(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!state.play_mode_active and layer_context.playback_controller.state == .stopped) {
        try beginPlayMode(state, layer_context);
    }
    state.playback_state = .paused;
    layer_context.playback_controller.requestStep();
}

pub fn sync(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const next_state = layer_context.playback_controller.state;
    state.playback_state = next_state;

    if (state.play_mode_active and next_state == .stopped) {
        state.play_mode_active = false;
        state.history_snapshot_needs_refresh = false;
        try history.restorePlayModeSnapshot(state, layer_context);
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}
