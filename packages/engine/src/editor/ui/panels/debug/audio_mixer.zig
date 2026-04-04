const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const layout = @import("../../layout.zig");

const BusId = engine.audio.BusId;

/// Draw the Audio Mixer panel window.
pub fn drawAudioMixerWindow(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    _ = layer_context;
    var open = state.audio_mixer_open;
    const open_window = gui.beginWindowOpen("Audio Mixer###audio_mixer_panel", &open);
    state.audio_mixer_open = open;
    if (!open_window) return;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("audio_mixer_panel");

    const audio_runtime = engine.audio.get() catch {
        gui.textWrapped("Audio system not initialized.");
        return;
    };

    const mixer_status = audio_runtime.getMixerStatus();

    // Active voices summary
    gui.text("Active Voices:");
    gui.sameLine();
    var buf: [64]u8 = undefined;
    const voices_text = std.fmt.bufPrint(&buf, "{}", .{mixer_status.active_voices}) catch "?";
    gui.text(voices_text);

    gui.separator();

    // Bus faders
    drawBusFader(state, audio_runtime, .master, state.text(.audio_mixer_master), mixer_status.active_voices);
    gui.spacing();
    drawBusFader(state, audio_runtime, .music, state.text(.audio_mixer_music), mixer_status.music_playing);
    gui.spacing();
    drawBusFader(state, audio_runtime, .sfx, state.text(.audio_mixer_sfx), mixer_status.sfx_playing);
}

fn drawBusFader(
    state: *const EditorState,
    audio_runtime: *engine.audio.AudioRuntime,
    bus_id: BusId,
    label: []const u8,
    playing_count: u32,
) void {
    _ = state;
    gui.pushIdU64(std.hash.Wyhash.hash(0, label));
    defer gui.popId();

    // Bus header
    gui.text(label);
    gui.sameLine();
    var count_buf: [32]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "({} playing)", .{playing_count}) catch "";
    gui.pushStyleColor(.text, .{ 0.6, 0.6, 0.6, 1.0 });
    gui.text(count_text);
    gui.popStyleColor(1);

    // Volume slider
    var volume = audio_runtime.getMixerVolume(bus_id);
    gui.setNextItemWidth(-1.0);
    if (gui.sliderFloat("##volume", &volume, 0.0, 1.5)) {
        audio_runtime.setMixerVolume(bus_id, volume);
    }

    // Mute button
    const is_muted = volume < 0.001;
    if (is_muted) {
        gui.pushStyleColor(.button, .{ 0.6, 0.2, 0.2, 1.0 });
        gui.pushStyleColor(.button_hovered, .{ 0.7, 0.25, 0.25, 1.0 });
        gui.pushStyleColor(.button_active, .{ 0.8, 0.3, 0.3, 1.0 });
    }
    if (gui.buttonEx("Mute", 60.0, 0.0)) {
        if (is_muted) {
            audio_runtime.setMixerVolume(bus_id, 1.0);
        } else {
            audio_runtime.setMixerVolume(bus_id, 0.0);
        }
    }
    if (is_muted) {
        gui.popStyleColor(3);
    }
}
