const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const theme = @import("theme.zig");
const EditorState = @import("../core/state.zig").EditorState;
const BuildGameStatus = @import("../core/state.zig").BuildGameStatus;
const LaunchGameStatus = @import("../core/state.zig").LaunchGameStatus;
const playback_session = @import("../core/playback_session.zig");
const history = @import("../actions/history.zig");
const ui_icons = @import("icons.zig");

fn drawPlaybackButton(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    id: []const u8,
    path: []const u8,
    palette: ui_icons.ButtonPalette,
) !bool {
    return ui_icons.drawIconButton(
        state,
        layer_context,
        id,
        path,
        theme.Spacing.toolbar_playback_icon_size,
        theme.Spacing.toolbar_playback_white_tint,
        palette,
    );
}

pub fn drawToolbarWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = gui.beginWindowFlags(
        "Toolbar###toolbar_panel",
        gui.WindowFlags.no_title_bar |
            gui.WindowFlags.no_scrollbar |
            gui.WindowFlags.no_resize |
            gui.WindowFlags.no_collapse,
    );
    defer gui.endWindow();

    const content_width = gui.contentRegionAvail()[0];

    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.toolbar_playback_item_spacing, theme.Spacing.toolbar_playback_item_spacing });
    defer gui.popStyleVar(1);

    // Centered playback controls
    const play_button_size: f32 = theme.Spacing.toolbar_playback_button_size;
    const spacing: f32 = theme.Spacing.toolbar_playback_item_spacing;
    const total_playback_width = play_button_size * 3.0 + spacing * 2.0;
    const center_start = (content_width - total_playback_width) * 0.5;

    gui.dummy(0.0, theme.Spacing.toolbar_window_control_height);
    gui.sameLineEx(center_start, 0.0);

    const session_active = state.play_mode_active or state.playback_state != .stopped;
    const is_playing = state.playback_state == .playing;
    const is_paused = state.playback_state == .paused;
    const run_stop_tooltip_id: @import("../i18n/message_id.zig").MessageId = if (session_active) .stop else .run;
    const pause_resume_tooltip_id: @import("../i18n/message_id.zig").MessageId = if (is_paused) .resume_playback else .pause;
    const run_stop_id = if (session_active) "toolbar_stop_toggle" else "toolbar_run_toggle";
    const run_stop_path = if (session_active) ui_icons.paths.toolbar.stop else ui_icons.paths.toolbar.play;
    const run_stop_palette = if (is_playing)
        ui_icons.palettes.toolbar_accent
    else if (session_active)
        ui_icons.palettes.toolbar_active
    else
        ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, run_stop_id, run_stop_path, run_stop_palette)) {
        if (session_active) {
            playback_session.stop(state, layer_context);
        } else {
            try playback_session.play(state, layer_context);
        }
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(run_stop_tooltip_id));
    }
    gui.sameLine();

    const pause_resume_id = if (is_paused) "toolbar_resume" else "toolbar_pause";
    const pause_resume_path = if (is_paused) ui_icons.paths.toolbar.play else ui_icons.paths.toolbar.pause;
    const pause_resume_palette = if (is_paused) ui_icons.palettes.toolbar_active else ui_icons.palettes.toolbar_idle;
    if (try drawPlaybackButton(state, layer_context, pause_resume_id, pause_resume_path, pause_resume_palette)) {
        if (is_paused) {
            try playback_session.play(state, layer_context);
        } else {
            playback_session.pause(state, layer_context);
        }
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(pause_resume_tooltip_id));
    }
    gui.sameLine();

    // Step button
    if (try drawPlaybackButton(state, layer_context, "toolbar_step", ui_icons.paths.toolbar.step, ui_icons.palettes.toolbar_idle)) {
        try playback_session.step(state, layer_context);
    }
    if (gui.isItemHovered()) {
        gui.setTooltip(state.text(.step));
    }

    // --- Launch Game button (right-aligned, left of Build Game) ---
    const launch_button_size: f32 = play_button_size;
    const build_button_size: f32 = play_button_size;
    const build_right_margin: f32 = 8.0;
    const launch_right_margin: f32 = build_right_margin + build_button_size + spacing;
    const launch_x = content_width - launch_button_size - launch_right_margin;
    gui.sameLineEx(launch_x, 0.0);

    const is_launch_busy = state.launch_game_status == .building or state.launch_game_status == .launching;
    const launch_palette = switch (state.launch_game_status) {
        .building, .launching => ui_icons.palettes.toolbar_accent,
        .running => ui_icons.palettes.toolbar_active,
        .failed => ui_icons.palettes.toolbar_accent,
        .idle => ui_icons.palettes.toolbar_idle,
    };
    if (try drawPlaybackButton(state, layer_context, "toolbar_launch_game", ui_icons.paths.toolbar.launch, launch_palette)) {
        if (!is_launch_busy) {
            startLaunchGame(state, layer_context);
        }
    }
    if (gui.isItemHovered()) {
        const launch_tooltip = switch (state.launch_game_status) {
            .building => state.text(.launch_game_building),
            .launching => state.text(.launch_game_launching),
            .running => state.text(.launch_game_running),
            .failed => state.text(.launch_game_failed),
            .idle => state.text(.launch_game_tooltip),
        };
        gui.setTooltip(launch_tooltip);
    }

    // --- Build Game button (right-aligned) ---
    const build_x = content_width - build_button_size - build_right_margin;
    gui.sameLineEx(build_x, 0.0);

    const is_building = state.build_game_status == .building;
    const build_palette = switch (state.build_game_status) {
        .building => ui_icons.palettes.toolbar_accent,
        .success => ui_icons.palettes.toolbar_active,
        .failed => ui_icons.palettes.toolbar_accent,
        .idle => ui_icons.palettes.toolbar_idle,
    };
    if (try drawPlaybackButton(state, layer_context, "toolbar_build_game", ui_icons.paths.toolbar.build, build_palette)) {
        if (!is_building) {
            startBuildGame(state);
        }
    }
    if (gui.isItemHovered()) {
        const tooltip_text = switch (state.build_game_status) {
            .building => state.text(.build_game_building),
            .success => state.text(.build_game_success),
            .failed => state.text(.build_game_failed),
            .idle => state.text(.build_game_tooltip),
        };
        gui.setTooltip(tooltip_text);
    }

    // Show build status text next to button
    if (state.build_game_status != .idle) {
        gui.sameLine();
        const status_text = switch (state.build_game_status) {
            .building => state.text(.build_game_building),
            .success => state.text(.build_game_success),
            .failed => state.text(.build_game_failed),
            .idle => "",
        };
        const status_color: [4]f32 = switch (state.build_game_status) {
            .building => .{ 1.0, 0.85, 0.3, 1.0 },
            .success => .{ 0.3, 1.0, 0.4, 1.0 },
            .failed => .{ 1.0, 0.3, 0.3, 1.0 },
            .idle => .{ 1.0, 1.0, 1.0, 1.0 },
        };
        gui.textColored(status_color, status_text);
    }
}

pub fn startBuildGame(state: *EditorState) void {
    if (state.build_game_status == .building) return;
    state.build_game_status = .building;
    state.build_game_output_len = 0;
    @memset(&state.build_game_output, 0);

    state.build_game_thread = std.Thread.spawn(.{}, buildGameWorker, .{state}) catch {
        state.build_game_status = .failed;
        const msg = "Failed to spawn build thread";
        @memcpy(state.build_game_output[0..msg.len], msg);
        state.build_game_output_len = msg.len;
        return;
    };
}

fn buildGameWorker(state: *EditorState) void {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "zig", "build", "-Doptimize=ReleaseSafe", "package" },
        .max_output_bytes = 1024 * 1024,
    }) catch {
        state.build_game_status = .failed;
        const msg = "Failed to execute zig build package";
        @memcpy(state.build_game_output[0..msg.len], msg);
        state.build_game_output_len = msg.len;
        return;
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);

    const output = if (result.stderr.len > 0) result.stderr else result.stdout;
    const copy_len = @min(output.len, state.build_game_output.len);
    @memcpy(state.build_game_output[0..copy_len], output[0..copy_len]);
    state.build_game_output_len = copy_len;

    switch (result.term) {
        .Exited => |code| {
            state.build_game_status = if (code == 0) .success else .failed;
        },
        else => {
            state.build_game_status = .failed;
        },
    }
}

pub fn startLaunchGame(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (state.launch_game_status == .building or state.launch_game_status == .launching) return;

    // Auto-save scene before launching
    history.saveScene(state, layer_context);

    state.launch_game_status = .building;
    state.launch_game_output_len = 0;
    @memset(&state.launch_game_output, 0);

    state.launch_game_thread = std.Thread.spawn(.{}, launchGameWorker, .{state}) catch {
        state.launch_game_status = .failed;
        const msg = "Failed to spawn launch thread";
        @memcpy(state.launch_game_output[0..msg.len], msg);
        state.launch_game_output_len = msg.len;
        return;
    };
}

fn launchGameWorker(state: *EditorState) void {
    // Step 1: Build the player binary in debug mode (fast)
    const build_result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "zig", "build", "player" },
        .max_output_bytes = 1024 * 1024,
    }) catch {
        state.launch_game_status = .failed;
        const msg = "Failed to execute zig build player";
        @memcpy(state.launch_game_output[0..msg.len], msg);
        state.launch_game_output_len = msg.len;
        return;
    };
    defer std.heap.page_allocator.free(build_result.stdout);
    defer std.heap.page_allocator.free(build_result.stderr);

    const build_exit = switch (build_result.term) {
        .Exited => |code| code,
        else => 1,
    };
    if (build_exit != 0) {
        state.launch_game_status = .failed;
        const output = if (build_result.stderr.len > 0) build_result.stderr else build_result.stdout;
        const copy_len = @min(output.len, state.launch_game_output.len);
        @memcpy(state.launch_game_output[0..copy_len], output[0..copy_len]);
        state.launch_game_output_len = copy_len;
        return;
    }

    // Step 2: Launch the player as a separate process
    state.launch_game_status = .launching;
    const scene_path = @import("../core/state.zig").autosave_path;
    const launch_result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "zig-out/bin/guava-player", "run", "--scene", scene_path },
        .max_output_bytes = 1024 * 1024,
    }) catch {
        state.launch_game_status = .failed;
        const msg = "Failed to spawn guava-player process";
        @memcpy(state.launch_game_output[0..msg.len], msg);
        state.launch_game_output_len = msg.len;
        return;
    };
    defer std.heap.page_allocator.free(launch_result.stdout);
    defer std.heap.page_allocator.free(launch_result.stderr);

    switch (launch_result.term) {
        .Exited => |code| {
            if (code != 0) {
                state.launch_game_status = .failed;
                const output = if (launch_result.stderr.len > 0) launch_result.stderr else launch_result.stdout;
                const copy_len = @min(output.len, state.launch_game_output.len);
                @memcpy(state.launch_game_output[0..copy_len], output[0..copy_len]);
                state.launch_game_output_len = copy_len;
                return;
            }
        },
        else => {
            state.launch_game_status = .failed;
            return;
        },
    }
    state.launch_game_status = .idle;
}
