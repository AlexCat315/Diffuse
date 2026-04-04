const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const layout = @import("../../layout.zig");
const cinematic = engine.cinematic;

// ---------------------------------------------------------------------------
// Sequencer editor state
// ---------------------------------------------------------------------------

pub const SequencerEditorState = struct {
    /// Currently loaded sequence (owned).
    sequence: ?cinematic.Sequence = null,
    /// Playback controller.
    playback: ?cinematic.SequencePlayback = null,

    /// Timeline view parameters.
    timeline_scale: f32 = 80.0, // pixels per second
    timeline_scroll: f32 = 0.0, // horizontal scroll offset in pixels
    current_time: f32 = 0.0,

    /// Selection.
    selected_track: ?u32 = null,
    selected_keyframe: ?u32 = null,

    /// File path of the currently loaded sequence (for save).
    file_path_buffer: [256]u8 = [_]u8{0} ** 256,
    file_path_len: usize = 0,

    /// New sequence name buffer.
    seq_name_buffer: [128]u8 = [_]u8{0} ** 128,

    /// Track-add combo state.
    new_track_kind: u8 = 0, // 0=camera_path, 1=animation, 2=audio, 3=event, 4=property

    /// New track target name.
    new_track_target_buffer: [128]u8 = [_]u8{0} ** 128,

    pub fn deinit(self: *SequencerEditorState, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.sequence) |*seq| seq.deinit();
        self.* = undefined;
    }

    pub fn ensurePlayback(self: *SequencerEditorState) void {
        if (self.sequence) |*seq| {
            if (self.playback == null) {
                self.playback = cinematic.SequencePlayback.init(seq);
            }
        }
    }
};

pub fn createSequencerEditorState(_: std.mem.Allocator) !SequencerEditorState {
    return .{};
}

pub fn destroySequencerEditorState(state: *SequencerEditorState, allocator: std.mem.Allocator) void {
    state.deinit(allocator);
}

// ---------------------------------------------------------------------------
// I18n (panel-local)
// ---------------------------------------------------------------------------

const MessageId = enum {
    sequencer,
    new_sequence,
    load_sequence,
    save_sequence,
    add_track,
    remove_track,
    no_sequence_loaded,
    sequence_name,
    duration,
    fps,
    track_type,
    target_entity,
    play,
    pause,
    stop_playback,
    time,
    properties,
    position,
    rotation,
    fov,
    easing,
    value,
    clip_path,
    start_time,
    end_time,
    volume,
    blend_in,
    blend_out,
    fade_in,
    fade_out,
    speed,
    event_name,
    property_name,
    add_keyframe,
    delete_keyframe,
    no_track_selected,
    no_keyframe_selected,

    const en_us = .{
        .sequencer = "Sequencer",
        .new_sequence = "New Sequence",
        .load_sequence = "Load",
        .save_sequence = "Save",
        .add_track = "Add Track",
        .remove_track = "Remove",
        .no_sequence_loaded = "No sequence loaded. Create a new one or load an existing .guava_sequence file.",
        .sequence_name = "Name",
        .duration = "Duration",
        .fps = "FPS",
        .track_type = "Track Type",
        .target_entity = "Target Entity",
        .play = "Play",
        .pause = "Pause",
        .stop_playback = "Stop",
        .time = "Time",
        .properties = "Properties",
        .position = "Position",
        .rotation = "Rotation",
        .fov = "FOV",
        .easing = "Easing",
        .value = "Value",
        .clip_path = "Clip",
        .start_time = "Start",
        .end_time = "End",
        .volume = "Volume",
        .blend_in = "Blend In",
        .blend_out = "Blend Out",
        .fade_in = "Fade In",
        .fade_out = "Fade Out",
        .speed = "Speed",
        .event_name = "Event",
        .property_name = "Property",
        .add_keyframe = "+ Key",
        .delete_keyframe = "- Key",
        .no_track_selected = "Select a track",
        .no_keyframe_selected = "Select a keyframe",
    };

    const zh_cn = .{
        .sequencer = "序列编辑器",
        .new_sequence = "新建序列",
        .load_sequence = "加载",
        .save_sequence = "保存",
        .add_track = "添加轨道",
        .remove_track = "删除",
        .no_sequence_loaded = "尚未加载序列。请新建或加载 .guava_sequence 文件。",
        .sequence_name = "名称",
        .duration = "时长",
        .fps = "帧率",
        .track_type = "轨道类型",
        .target_entity = "目标实体",
        .play = "播放",
        .pause = "暂停",
        .stop_playback = "停止",
        .time = "时间",
        .properties = "属性",
        .position = "位置",
        .rotation = "旋转",
        .fov = "视野角",
        .easing = "缓动",
        .value = "值",
        .clip_path = "片段",
        .start_time = "开始",
        .end_time = "结束",
        .volume = "音量",
        .blend_in = "混入",
        .blend_out = "混出",
        .fade_in = "淡入",
        .fade_out = "淡出",
        .speed = "速度",
        .event_name = "事件",
        .property_name = "属性名",
        .add_keyframe = "+ 帧",
        .delete_keyframe = "- 帧",
        .no_track_selected = "请选择轨道",
        .no_keyframe_selected = "请选择关键帧",
    };
};

fn localText(state: *const EditorState, id: MessageId) []const u8 {
    return switch (state.language) {
        .en_us => switch (id) {
            inline else => |tag| @field(MessageId.en_us, @tagName(tag)),
        },
        .zh_cn => switch (id) {
            inline else => |tag| @field(MessageId.zh_cn, @tagName(tag)),
        },
    };
}

// ---------------------------------------------------------------------------
// Main draw entry
// ---------------------------------------------------------------------------

pub fn drawSequencerWindow(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *SequencerEditorState) !void {
    // Update camera path 3D preview in viewport
    updateCameraPathPreview(layer_context, editor_state);

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .sequencer, "sequencer_panel");
    var open = state.sequencer_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.sequencer_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("sequencer_panel");

    if (!open) return;

    layout.beginSectionBody();
    defer layout.endSectionBody();

    // -- Toolbar row ---
    drawToolbar(state, editor_state);

    gui.separator();

    if (editor_state.sequence == null) {
        gui.textWrapped(localText(state, .no_sequence_loaded));
        return;
    }

    // -- Main area: track list (left) + timeline (center) + properties (right) ---
    {
        const child_visible = gui.beginChild("sequencer_main", -1.0, -48.0, false);
        defer gui.endChild();
        if (child_visible) {
            if (gui.beginTable("sequencer_layout", 3)) {
                gui.tableSetupColumn("TrackList", true, 0.20);
                gui.tableSetupColumn("Timeline", true, 0.55);
                gui.tableSetupColumn("Properties", true, 0.25);
                gui.tableNextRow();
                gui.tableNextColumn();
                drawTrackList(state, editor_state);
                gui.tableNextColumn();
                drawTimeline(state, editor_state);
                gui.tableNextColumn();
                drawKeyframeProperties(state, editor_state);
                gui.endTable();
            }
        }
    }

    // -- Playback controls ---
    drawPlaybackControls(state, editor_state);
}

// ---------------------------------------------------------------------------
// Toolbar: New / Load / Save / Sequence properties
// ---------------------------------------------------------------------------

fn drawToolbar(state: *const EditorState, editor_state: *SequencerEditorState) void {
    if (gui.button(localText(state, .new_sequence))) {
        // Create a fresh empty sequence.
        if (editor_state.sequence) |*old| old.deinit();
        editor_state.sequence = cinematic.Sequence.init(std.heap.page_allocator);
        editor_state.playback = null;
        editor_state.selected_track = null;
        editor_state.current_time = 0;
        @memset(editor_state.file_path_buffer[0..], 0);
        editor_state.file_path_len = 0;
    }
    gui.sameLine();

    if (gui.button(localText(state, .load_sequence))) {
        const path = std.mem.sliceTo(&editor_state.file_path_buffer, 0);
        if (path.len > 0) {
            if (cinematic.loadFromPath(std.heap.page_allocator, path)) |loaded| {
                if (editor_state.sequence) |*old| old.deinit();
                editor_state.sequence = loaded;
                editor_state.playback = null;
                editor_state.selected_track = null;
                editor_state.current_time = 0;
            } else |_| {}
        }
    }
    gui.sameLine();

    if (gui.button(localText(state, .save_sequence))) {
        if (editor_state.sequence) |*seq| {
            const path = std.mem.sliceTo(&editor_state.file_path_buffer, 0);
            if (path.len > 0) {
                cinematic.saveToPath(seq, seq.allocator, path) catch {};
            }
        }
    }
    gui.sameLine();

    // File path input
    gui.setNextItemWidth(240.0);
    _ = gui.inputText("##seq_path", &editor_state.file_path_buffer);

    if (editor_state.sequence) |*seq| {
        gui.sameLine();
        gui.setNextItemWidth(100.0);
        _ = gui.inputText("##seq_name", &editor_state.seq_name_buffer);

        gui.sameLine();
        gui.text("FPS:");
        gui.sameLine();
        gui.setNextItemWidth(60.0);
        _ = gui.dragFloat("##seq_fps", &seq.fps, 1.0, 1.0, 240.0);

        gui.sameLine();
        gui.text("Dur:");
        gui.sameLine();
        gui.setNextItemWidth(80.0);
        _ = gui.dragFloat("##seq_dur", &seq.duration, 0.1, 0.0, 3600.0);
    }
}

// ---------------------------------------------------------------------------
// Track list (left column)
// ---------------------------------------------------------------------------

const track_kind_labels = [_][]const u8{ "Camera Path", "Animation", "Audio", "Event", "Property" };

fn drawTrackList(state: *const EditorState, editor_state: *SequencerEditorState) void {
    const seq = &(editor_state.sequence orelse return);

    // Track list child
    {
        const list_visible = gui.beginChild("seq_track_list", -1.0, -32.0, true);
        defer gui.endChild();
        if (list_visible) {
            for (seq.tracks.items, 0..) |t, idx| {
                const selected = editor_state.selected_track != null and editor_state.selected_track.? == idx;
                var label_buf: [192]u8 = undefined;
                const kind_str: []const u8 = switch (t) {
                    .camera_path => "CAM",
                    .animation => "ANIM",
                    .audio => "SFX",
                    .event => "EVT",
                    .property => "PROP",
                };
                const target_name = t.name();
                const label = std.fmt.bufPrint(&label_buf, "[{s}] {s}##track_{d}", .{ kind_str, target_name, idx }) catch continue;
                if (gui.selectable(label, selected, false, -1.0, 22.0)) {
                    editor_state.selected_track = @intCast(idx);
                }
            }
        }
    }

    // Add / remove track row
    gui.setNextItemWidth(80.0);
    {
        const preview = track_kind_labels[editor_state.new_track_kind];
        if (gui.beginCombo("##new_track_kind", preview)) {
            for (track_kind_labels, 0..) |label, i| {
                const selected = editor_state.new_track_kind == @as(u8, @intCast(i));
                if (gui.selectable(label, selected, false, -1.0, 0.0)) {
                    editor_state.new_track_kind = @intCast(i);
                }
            }
            gui.endCombo();
        }
    }
    gui.sameLine();
    gui.setNextItemWidth(80.0);
    _ = gui.inputText("##new_track_target", &editor_state.new_track_target_buffer);
    gui.sameLine();
    if (gui.button(localText(state, .add_track))) {
        const target_slice = std.mem.sliceTo(&editor_state.new_track_target_buffer, 0);
        const alloc = seq.allocator;
        const target = alloc.dupe(u8, target_slice) catch "";
        const track: cinematic.Track = switch (editor_state.new_track_kind) {
            0 => .{ .camera_path = .{ .target = target } },
            1 => .{ .animation = .{ .target = target } },
            2 => .{ .audio = .{ .target = target } },
            3 => .{ .event = .{ .target = target } },
            else => .{ .property = .{ .target = target } },
        };
        seq.addTrack(track) catch {};
    }
    gui.sameLine();
    if (gui.button(localText(state, .remove_track))) {
        if (editor_state.selected_track) |sel| {
            if (sel < seq.tracks.items.len) {
                seq.removeTrack(sel);
                editor_state.selected_track = null;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Timeline (right column) — ruler + track colored bars + playhead
// ---------------------------------------------------------------------------

const track_row_height: f32 = 28.0;
const ruler_height: f32 = 24.0;

/// Map a time value to an x pixel position within the timeline canvas.
fn timeToX(t: f32, editor_state: *const SequencerEditorState) f32 {
    return t * editor_state.timeline_scale - editor_state.timeline_scroll;
}

/// Map an x pixel position back to time.
fn xToTime(x: f32, editor_state: *const SequencerEditorState) f32 {
    return (x + editor_state.timeline_scroll) / editor_state.timeline_scale;
}

fn drawTimeline(state: *const EditorState, editor_state: *SequencerEditorState) void {
    _ = state;
    const seq = &(editor_state.sequence orelse return);

    const avail = gui.getContentRegionAvail();
    const canvas_width = avail.x;
    const canvas_height = avail.y;

    // -- Ruler ---
    {
        const ruler_visible = gui.beginChild("seq_ruler", canvas_width, ruler_height, false);
        defer gui.endChild();
        if (ruler_visible) {
            var draw_list = gui.getWindowDrawList();
            const cursor = gui.cursorScreenPos();
            const gray = gui.getColorU32(.{ 0.6, 0.6, 0.6, 1.0 });

            // Draw time ticks
            const step = computeTickStep(editor_state.timeline_scale);
            var t: f32 = 0.0;
            while (t <= seq.duration + step) : (t += step) {
                const x = cursor[0] + timeToX(t, editor_state);
                if (x < cursor[0] or x > cursor[0] + canvas_width) continue;
                draw_list.addLine(.{ x, cursor[1] + ruler_height - 6 }, .{ x, cursor[1] + ruler_height }, gray, 1.0);

                var tick_buf: [16]u8 = undefined;
                const tick_label = std.fmt.bufPrint(&tick_buf, "{d:.1}s", .{t}) catch continue;
                draw_list.addText(.{ x + 2, cursor[1] }, gray, tick_label);
            }

            // Playhead marker in ruler
            const ph_x = cursor[0] + timeToX(editor_state.current_time, editor_state);
            const red = gui.getColorU32(.{ 1.0, 0.2, 0.2, 1.0 });
            draw_list.addLine(.{ ph_x, cursor[1] }, .{ ph_x, cursor[1] + ruler_height }, red, 2.0);

            // Click on ruler to seek — use isMouseDragging(.left) as click proxy
            if (gui.isWindowHovered() and gui.isMouseDragging(.left)) {
                const mouse_x = gui.mousePos()[0] - cursor[0];
                editor_state.current_time = std.math.clamp(xToTime(mouse_x, editor_state), 0.0, seq.duration);
                if (editor_state.playback) |*pb| pb.seekTo(editor_state.current_time);
            }
        }
    }

    // -- Track rows ---
    {
        const tracks_visible = gui.beginChild("seq_tracks", canvas_width, canvas_height - ruler_height, false);
        defer gui.endChild();
        if (tracks_visible) {
            var draw_list = gui.getWindowDrawList();
            const cursor = gui.cursorScreenPos();

            for (seq.tracks.items, 0..) |track, idx| {
                const y = cursor[1] + @as(f32, @floatFromInt(idx)) * track_row_height;
                if (y > cursor[1] + canvas_height) break;

                const color = trackColor(track);
                drawTrackBar(draw_list, track, cursor[0], y, canvas_width, editor_state, color);

                // Draw keyframe indicators
                drawKeyframeMarkers(draw_list, track, cursor[0], y, editor_state, idx);
            }

            // Draw playhead line across tracks
            const ph_x = cursor[0] + timeToX(editor_state.current_time, editor_state);
            const line_color = gui.getColorU32(.{ 1.0, 0.2, 0.2, 0.8 });
            const total_h = @as(f32, @floatFromInt(seq.tracks.items.len)) * track_row_height;
            draw_list.addLine(.{ ph_x, cursor[1] }, .{ ph_x, cursor[1] + total_h }, line_color, 1.5);
        }
    }

    // Scroll / zoom via mouse
    handleTimelineInput(editor_state, canvas_width);
}

fn computeTickStep(scale: f32) f32 {
    if (scale >= 160) return 0.5;
    if (scale >= 60) return 1.0;
    if (scale >= 20) return 5.0;
    return 10.0;
}

fn trackColor(track: cinematic.Track) [4]f32 {
    return switch (track) {
        .camera_path => .{ 0.3, 0.7, 1.0, 0.8 },
        .animation => .{ 0.3, 0.9, 0.4, 0.8 },
        .audio => .{ 0.9, 0.6, 0.2, 0.8 },
        .event => .{ 0.9, 0.3, 0.9, 0.8 },
        .property => .{ 0.6, 0.6, 0.9, 0.8 },
    };
}

fn drawTrackBar(draw_list: anytype, track: cinematic.Track, origin_x: f32, y: f32, canvas_width: f32, editor_state: *const SequencerEditorState, color: [4]f32) void {
    const bar = trackTimeRange(track);
    const x0 = origin_x + timeToX(bar[0], editor_state);
    const x1 = origin_x + timeToX(bar[1], editor_state);
    const clamped_x0 = @max(x0, origin_x);
    const clamped_x1 = @min(x1, origin_x + canvas_width);
    if (clamped_x1 <= clamped_x0) return;

    draw_list.addRectFilled(
        .{ clamped_x0, y + 2 },
        .{ clamped_x1, y + track_row_height - 2 },
        gui.getColorU32(color),
        3.0,
        0,
    );
}

fn trackTimeRange(t: cinematic.Track) [2]f32 {
    return switch (t) {
        .camera_path => |cp| blk: {
            if (cp.keyframes.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ cp.keyframes.items[0].time, cp.keyframes.items[cp.keyframes.items.len - 1].time };
        },
        .animation => |a| .{ a.start_time, a.end_time },
        .audio => |a| .{ a.start_time, a.end_time },
        .event => |ev| blk: {
            if (ev.events.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ ev.events.items[0].time, ev.events.items[ev.events.items.len - 1].time };
        },
        .property => |p| blk: {
            if (p.keyframes.items.len == 0) break :blk [2]f32{ 0, 0 };
            break :blk .{ p.keyframes.items[0].time, p.keyframes.items[p.keyframes.items.len - 1].time };
        },
    };
}

fn drawKeyframeMarkers(draw_list: anytype, track: cinematic.Track, origin_x: f32, y: f32, editor_state: *SequencerEditorState, track_idx: usize) void {
    const mid_y = y + track_row_height * 0.5;
    const diamond_size: f32 = 4.0;
    const white = gui.getColorU32(.{ 1, 1, 1, 0.9 });
    const sel_color = gui.getColorU32(.{ 1, 0.9, 0.2, 1.0 });
    const is_sel_track = editor_state.selected_track != null and editor_state.selected_track.? == track_idx;

    // Check for click-to-select keyframes (if hovering and left-clicking)
    const can_select = gui.isWindowHovered() and gui.isMouseDoubleClicked(.left);
    const mouse = gui.mousePos();

    switch (track) {
        .camera_path => |cp| {
            for (cp.keyframes.items, 0..) |kf, ki| {
                const x = origin_x + timeToX(kf.time, editor_state);
                const is_sel = is_sel_track and editor_state.selected_keyframe != null and editor_state.selected_keyframe.? == ki;
                drawDiamond(draw_list, x, mid_y, if (is_sel) diamond_size + 2 else diamond_size, if (is_sel) sel_color else white);
                if (can_select and @abs(mouse[0] - x) < 8 and @abs(mouse[1] - mid_y) < 10) {
                    editor_state.selected_track = @intCast(track_idx);
                    editor_state.selected_keyframe = @intCast(ki);
                }
            }
        },
        .event => |ev| {
            for (ev.events.items, 0..) |e, ki| {
                const x = origin_x + timeToX(e.time, editor_state);
                const is_sel = is_sel_track and editor_state.selected_keyframe != null and editor_state.selected_keyframe.? == ki;
                drawDiamond(draw_list, x, mid_y, if (is_sel) diamond_size + 2 else diamond_size, if (is_sel) sel_color else white);
                if (can_select and @abs(mouse[0] - x) < 8 and @abs(mouse[1] - mid_y) < 10) {
                    editor_state.selected_track = @intCast(track_idx);
                    editor_state.selected_keyframe = @intCast(ki);
                }
            }
        },
        .property => |p| {
            for (p.keyframes.items, 0..) |kf, ki| {
                const x = origin_x + timeToX(kf.time, editor_state);
                const is_sel = is_sel_track and editor_state.selected_keyframe != null and editor_state.selected_keyframe.? == ki;
                drawDiamond(draw_list, x, mid_y, if (is_sel) diamond_size + 2 else diamond_size, if (is_sel) sel_color else white);
                if (can_select and @abs(mouse[0] - x) < 8 and @abs(mouse[1] - mid_y) < 10) {
                    editor_state.selected_track = @intCast(track_idx);
                    editor_state.selected_keyframe = @intCast(ki);
                }
            }
        },
        else => {},
    }
}

fn drawDiamond(draw_list: anytype, cx: f32, cy: f32, size: f32, color: u32) void {
    // No addQuadFilled available — use a small filled circle as keyframe marker.
    draw_list.addCircleFilled(.{ cx, cy }, size, color, 6);
}

fn handleTimelineInput(editor_state: *SequencerEditorState, canvas_width: f32) void {
    _ = canvas_width;
    if (!gui.isWindowHovered()) return;

    // Middle mouse drag for panning
    if (gui.isMouseDragging(.middle)) {
        const delta = gui.mouseDragDelta(.middle);
        editor_state.timeline_scroll -= delta[0];
        gui.resetMouseDragDelta(.middle);
    }
}

// ---------------------------------------------------------------------------
// Playback controls (bottom bar)
// ---------------------------------------------------------------------------

fn drawPlaybackControls(state: *const EditorState, editor_state: *SequencerEditorState) void {
    const seq = &(editor_state.sequence orelse return);

    editor_state.ensurePlayback();

    if (editor_state.playback) |*pb| {
        // Play / Pause
        const is_playing = pb.state == .playing;
        if (gui.button(if (is_playing) localText(state, .pause) else localText(state, .play))) {
            if (is_playing) {
                pb.pause();
            } else {
                pb.play();
            }
        }
        gui.sameLine();

        // Stop
        if (gui.button(localText(state, .stop_playback))) {
            pb.stop();
            editor_state.current_time = 0;
        }
        gui.sameLine();

        // Time display / scrub
        gui.text(localText(state, .time));
        gui.sameLine();
        gui.setNextItemWidth(120.0);
        if (gui.dragFloat("##seq_time", &editor_state.current_time, 0.01, 0.0, seq.duration)) {
            pb.seekTo(editor_state.current_time);
        }

        gui.sameLine();
        var label_buf: [64]u8 = undefined;
        const frame_label = std.fmt.bufPrint(&label_buf, "Frame: {d:.0} / {d:.0}", .{ editor_state.current_time * seq.fps, seq.duration * seq.fps }) catch "";
        gui.text(frame_label);

        // If playing, advance playback and sync time
        if (pb.state == .playing) {
            // Use a fixed time step for editor preview (assuming ~60fps editor)
            _ = pb.advance(1.0 / 60.0);
            editor_state.current_time = pb.current_time;
        }
    }
}

// ---------------------------------------------------------------------------
// Keyframe property editing panel (right column)
// ---------------------------------------------------------------------------

const easing_labels = [_][]const u8{ "Linear", "Step", "Ease In", "Ease Out", "Ease InOut" };

fn drawKeyframeProperties(state: *const EditorState, editor_state: *SequencerEditorState) void {
    const prop_visible = gui.beginChild("seq_props", -1.0, -1.0, true);
    defer gui.endChild();
    if (!prop_visible) return;

    gui.text(localText(state, .properties));
    gui.separator();

    const seq = &(editor_state.sequence orelse return);
    const sel_track = editor_state.selected_track orelse {
        gui.textWrapped(localText(state, .no_track_selected));
        return;
    };
    if (sel_track >= seq.tracks.items.len) return;

    const track = &seq.tracks.items[sel_track];

    // Add / delete keyframe buttons
    if (gui.button(localText(state, .add_keyframe))) {
        addKeyframeAtCurrentTime(track, editor_state.current_time, seq.allocator);
        editor_state.selected_keyframe = null;
    }
    gui.sameLine();
    if (gui.button(localText(state, .delete_keyframe))) {
        if (editor_state.selected_keyframe) |ki| {
            deleteKeyframe(track, ki);
            editor_state.selected_keyframe = null;
        }
    }

    gui.separator();

    // Track-level properties (for non-keyframed tracks)
    switch (track.*) {
        .animation => |*a| {
            gui.text(localText(state, .start_time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##anim_start", &a.start_time, 0.01, 0.0, 3600.0);
            gui.text(localText(state, .end_time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##anim_end", &a.end_time, 0.01, 0.0, 3600.0);
            gui.text(localText(state, .blend_in));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##anim_blendin", &a.blend_in, 0.01, 0.0, 10.0);
            gui.text(localText(state, .blend_out));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##anim_blendout", &a.blend_out, 0.01, 0.0, 10.0);
            gui.text(localText(state, .speed));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##anim_speed", &a.speed, 0.01, 0.01, 10.0);
            return;
        },
        .audio => |*a| {
            gui.text(localText(state, .start_time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##aud_start", &a.start_time, 0.01, 0.0, 3600.0);
            gui.text(localText(state, .end_time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##aud_end", &a.end_time, 0.01, 0.0, 3600.0);
            gui.text(localText(state, .volume));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##aud_vol", &a.volume, 0.01, 0.0, 2.0);
            gui.text(localText(state, .fade_in));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##aud_fadein", &a.fade_in, 0.01, 0.0, 10.0);
            gui.text(localText(state, .fade_out));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##aud_fadeout", &a.fade_out, 0.01, 0.0, 10.0);
            return;
        },
        else => {},
    }

    // Keyframe-level properties
    const sel_kf = editor_state.selected_keyframe orelse {
        gui.textWrapped(localText(state, .no_keyframe_selected));
        return;
    };

    switch (track.*) {
        .camera_path => |*cp| {
            if (sel_kf >= cp.keyframes.items.len) return;
            var kf = &cp.keyframes.items[sel_kf];

            gui.text(localText(state, .time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##kf_time", &kf.time, 0.01, 0.0, 3600.0);

            gui.text(localText(state, .position));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat3("##kf_pos", &kf.position, 0.1, -10000.0, 10000.0);

            gui.text(localText(state, .rotation));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat4("##kf_rot", &kf.rotation, 0.01, -1.0, 1.0);

            gui.text(localText(state, .fov));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##kf_fov", &kf.fov, 0.5, 1.0, 179.0);

            drawEasingCombo("##kf_easing", state, &kf.easing);
            gui.separator();
            drawEasingCurve(kf.easing);
        },
        .event => |*ev| {
            if (sel_kf >= ev.events.items.len) return;
            var entry = &ev.events.items[sel_kf];

            gui.text(localText(state, .time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##ev_time", &entry.time, 0.01, 0.0, 3600.0);

            gui.text(localText(state, .event_name));
            gui.textWrapped(entry.name);
        },
        .property => |*p| {
            if (sel_kf >= p.keyframes.items.len) return;
            var kf = &p.keyframes.items[sel_kf];

            gui.text(localText(state, .time));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##pk_time", &kf.time, 0.01, 0.0, 3600.0);

            gui.text(localText(state, .value));
            gui.setNextItemWidth(-1.0);
            _ = gui.dragFloat("##pk_val", &kf.value, 0.01, -10000.0, 10000.0);

            drawEasingCombo("##pk_easing", state, &kf.easing);
            gui.separator();
            drawEasingCurve(kf.easing);
        },
        else => {},
    }
}

fn drawEasingCombo(id: []const u8, state: *const EditorState, easing: *cinematic.EasingMode) void {
    gui.text(localText(state, .easing));
    gui.setNextItemWidth(-1.0);
    const current_idx = @intFromEnum(easing.*);
    const preview = easing_labels[@min(current_idx, easing_labels.len - 1)];
    if (gui.beginCombo(id, preview)) {
        for (easing_labels, 0..) |label, i| {
            const selected = current_idx == i;
            if (gui.selectable(label, selected, false, -1.0, 0.0)) {
                easing.* = @enumFromInt(i);
            }
        }
        gui.endCombo();
    }
}

// ---------------------------------------------------------------------------
// Easing curve visualization
// ---------------------------------------------------------------------------

fn drawEasingCurve(easing: cinematic.EasingMode) void {
    const curve_h: f32 = 80.0;
    const avail = gui.getContentRegionAvail();
    const curve_w = @max(avail.x, 40.0);

    // Reserve space with an invisible button
    _ = gui.invisibleButton("##easing_preview", curve_w, curve_h);

    var draw_list = gui.getWindowDrawList();
    const cursor = gui.cursorScreenPos();
    // The invisible button already advanced the cursor, so the draw area is above current cursor
    const x0 = cursor[0];
    const y0 = cursor[1] - curve_h;

    // Background
    const bg_color = gui.getColorU32(.{ 0.15, 0.15, 0.15, 1.0 });
    draw_list.addRectFilled(.{ x0, y0 }, .{ x0 + curve_w, y0 + curve_h }, bg_color, 2.0, 0);

    // Border
    const border_col = gui.getColorU32(.{ 0.4, 0.4, 0.4, 1.0 });
    draw_list.addLine(.{ x0, y0 }, .{ x0 + curve_w, y0 }, border_col, 1.0);
    draw_list.addLine(.{ x0, y0 + curve_h }, .{ x0 + curve_w, y0 + curve_h }, border_col, 1.0);
    draw_list.addLine(.{ x0, y0 }, .{ x0, y0 + curve_h }, border_col, 1.0);
    draw_list.addLine(.{ x0 + curve_w, y0 }, .{ x0 + curve_w, y0 + curve_h }, border_col, 1.0);

    // Draw curve as a polyline
    const curve_color = gui.getColorU32(.{ 0.4, 0.8, 1.0, 1.0 });
    const padding: f32 = 4.0;
    const inner_w = curve_w - padding * 2;
    const inner_h = curve_h - padding * 2;
    const segments: u32 = 32;

    var i: u32 = 0;
    while (i < segments) : (i += 1) {
        const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments));
        const v0 = easing.evaluate(t0);
        const v1 = easing.evaluate(t1);
        const px0 = x0 + padding + t0 * inner_w;
        const py0 = y0 + padding + (1.0 - v0) * inner_h;
        const px1 = x0 + padding + t1 * inner_w;
        const py1 = y0 + padding + (1.0 - v1) * inner_h;
        draw_list.addLine(.{ px0, py0 }, .{ px1, py1 }, curve_color, 2.0);
    }
}

// ---------------------------------------------------------------------------
// Keyframe add / delete helpers
// ---------------------------------------------------------------------------

fn addKeyframeAtCurrentTime(track: *cinematic.Track, time: f32, allocator: std.mem.Allocator) void {
    switch (track.*) {
        .camera_path => |*cp| {
            cp.keyframes.append(allocator, .{ .time = time }) catch {};
        },
        .event => |*ev| {
            ev.events.append(allocator, .{ .time = time }) catch {};
        },
        .property => |*p| {
            p.keyframes.append(allocator, .{ .time = time, .value = 0, .easing = .linear }) catch {};
        },
        else => {},
    }
}

fn deleteKeyframe(track: *cinematic.Track, idx: u32) void {
    switch (track.*) {
        .camera_path => |*cp| {
            if (idx < cp.keyframes.items.len) {
                _ = cp.keyframes.orderedRemove(idx);
            }
        },
        .event => |*ev| {
            if (idx < ev.events.items.len) {
                _ = ev.events.orderedRemove(idx);
            }
        },
        .property => |*p| {
            if (idx < p.keyframes.items.len) {
                _ = p.keyframes.orderedRemove(idx);
            }
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// 3D Camera Path Spline Gizmo — sends preview lines to the renderer
// ---------------------------------------------------------------------------

const spline_segments_per_span = 16;

fn updateCameraPathPreview(layer_context: *engine.core.LayerContext, editor_state: *const SequencerEditorState) void {
    const seq = editor_state.sequence orelse {
        layer_context.renderer.setCameraPathPreview(&.{});
        return;
    };

    // Find the first camera_path track (or the selected one if it's a camera_path).
    var cam_track: ?*const cinematic.CameraPathTrack = null;
    if (editor_state.selected_track) |sel| {
        if (sel < seq.tracks.items.len) {
            switch (seq.tracks.items[sel]) {
                .camera_path => |*cp| {
                    cam_track = cp;
                },
                else => {},
            }
        }
    }
    // Fallback: use the first camera_path track in the sequence.
    if (cam_track == null) {
        for (seq.tracks.items) |*t| {
            switch (t.*) {
                .camera_path => |*cp| {
                    cam_track = cp;
                    break;
                },
                else => {},
            }
        }
    }

    const cp = cam_track orelse {
        layer_context.renderer.setCameraPathPreview(&.{});
        return;
    };

    const kf_count = cp.keyframes.items.len;
    if (kf_count < 2) {
        // With fewer than 2 keyframes, just show keyframe positions as small cross markers
        if (kf_count == 1) {
            const pos = cp.keyframes.items[0].position;
            const s: f32 = 0.15;
            const marker = [_][3]f32{
                .{ pos[0] - s, pos[1], pos[2] }, .{ pos[0] + s, pos[1], pos[2] },
                .{ pos[0], pos[1] - s, pos[2] }, .{ pos[0], pos[1] + s, pos[2] },
                .{ pos[0], pos[1], pos[2] - s }, .{ pos[0], pos[1], pos[2] + s },
            };
            layer_context.renderer.setCameraPathPreview(&marker);
        } else {
            layer_context.renderer.setCameraPathPreview(&.{});
        }
        return;
    }

    // Generate Catmull-Rom spline segments between keyframes
    const spans = kf_count - 1;
    const total_segments = spans * spline_segments_per_span;
    // Each segment is 2 vertices (line pair), total = total_segments * 2
    // Plus small cross markers at each keyframe: 6 vertices each
    const line_count = total_segments * 2 + kf_count * 6;
    var positions: [2048][3]f32 = undefined;
    if (line_count > positions.len) {
        layer_context.renderer.setCameraPathPreview(&.{});
        return;
    }

    var idx: usize = 0;

    // Spline curve
    for (0..spans) |span_i| {
        const kf_a = cp.keyframes.items[span_i];
        const kf_b = cp.keyframes.items[span_i + 1];

        for (0..spline_segments_per_span) |seg_i| {
            const t0 = @as(f32, @floatFromInt(seg_i)) / @as(f32, @floatFromInt(spline_segments_per_span));
            const t1 = @as(f32, @floatFromInt(seg_i + 1)) / @as(f32, @floatFromInt(spline_segments_per_span));
            const time0 = kf_a.time + (kf_b.time - kf_a.time) * t0;
            const time1 = kf_a.time + (kf_b.time - kf_a.time) * t1;
            const eval0 = cp.evaluate(time0);
            const eval1 = cp.evaluate(time1);
            positions[idx] = eval0.position;
            idx += 1;
            positions[idx] = eval1.position;
            idx += 1;
        }
    }

    // Keyframe position markers (small 3D cross)
    const marker_size: f32 = 0.2;
    for (cp.keyframes.items) |kf| {
        const p = kf.position;
        positions[idx] = .{ p[0] - marker_size, p[1], p[2] };
        idx += 1;
        positions[idx] = .{ p[0] + marker_size, p[1], p[2] };
        idx += 1;
        positions[idx] = .{ p[0], p[1] - marker_size, p[2] };
        idx += 1;
        positions[idx] = .{ p[0], p[1] + marker_size, p[2] };
        idx += 1;
        positions[idx] = .{ p[0], p[1], p[2] - marker_size };
        idx += 1;
        positions[idx] = .{ p[0], p[1], p[2] + marker_size };
        idx += 1;
    }

    layer_context.renderer.setCameraPathPreview(positions[0..idx]);
}
