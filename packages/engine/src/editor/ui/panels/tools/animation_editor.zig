const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const utils = @import("../../../common/utils.zig");
const history = @import("../../../actions/history.zig");
const inspector = @import("../scene/inspector.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const animation_graph_mod = engine.animation.animation_graph;
const handles = engine.assets.handles;
const i18n = @import("../../../i18n/message_id.zig");

const TimelineTrack = struct {
    name: []const u8,
    type: enum { translation, rotation, scale },
    target_index: u32,
    keyframes: std.ArrayList(Keyframe),

    const Keyframe = struct {
        time: f32,
        value: union(enum) {
            vec3: [3]f32,
            quat: [4]f32,
        },
        interpolation: engine.assets.AnimationInterpolation,
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.keyframes.deinit(allocator);
        self.* = undefined;
    }
};

pub const AnimationEditorState = struct {
    selected_entity: ?engine.scene.EntityId = null,
    selected_clip: ?handles.AnimationClipHandle = null,
    selected_graph: ?*const animation_graph_mod.AnimationGraph = null,
    selected_runtime: ?animation_graph_mod.RuntimeClipBlend = null,
    selected_graph_state: ?u32 = null,
    selected_graph_transition: ?u32 = null,
    selected_transition_condition: ?u32 = null,
    new_transition_target_state: u32 = 0,
    new_transition_elapsed_seconds: f32 = 0.25,
    new_transition_duration: f32 = 0.2,
    timeline_scale: f32 = 1.0,
    timeline_offset: f32 = 0.0,
    current_time: f32 = 0.0,
    is_playing: bool = false,
    selected_track: ?u32 = null,
    selected_keyframe: ?u32 = null,
    state_name_buffer: [128]u8 = [_]u8{0} ** 128,
    condition_parameter_name_buffer: [128]u8 = [_]u8{0} ** 128,
    tracks: std.ArrayList(TimelineTrack),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.tracks.items) |*track| {
            track.deinit(allocator);
        }
        self.tracks.deinit(allocator);
        self.* = undefined;
    }

    pub fn loadClip(self: *@This(), allocator: std.mem.Allocator, clip: *const engine.assets.AnimationClipResource) !void {
        self.clearTracks(allocator);
        self.current_time = 0.0;
        self.selected_track = null;
        self.selected_keyframe = null;

        for (clip.translation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Translation_{}", .{track.target_entity_index}),
                .type = .translation,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }

        for (clip.rotation_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Rotation_{}", .{track.target_entity_index}),
                .type = .rotation,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .quat = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }

        for (clip.scale_tracks) |track| {
            var timeline_track = TimelineTrack{
                .name = try std.fmt.allocPrint(allocator, "Scale_{}", .{track.target_entity_index}),
                .type = .scale,
                .target_index = track.target_entity_index,
                .keyframes = .empty,
            };

            for (track.times, 0..) |time, idx| {
                try timeline_track.keyframes.append(allocator, .{
                    .time = time,
                    .value = .{ .vec3 = track.values[idx] },
                    .interpolation = track.interpolation,
                });
            }

            try self.tracks.append(allocator, timeline_track);
        }
    }

    fn clearTracks(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.tracks.items) |*track| {
            track.deinit(allocator);
        }
        self.tracks.clearRetainingCapacity();
    }
};

pub fn drawAnimationEditorWindow(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .animation_editor, "animation_editor_popup");
    var open = state.animation_editor_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.animation_editor_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("animation_editor_popup");

    if (!open) {
        return;
    }

    try syncAnimationSource(layer_context, editor_state);
    const runtime_driven = editor_state.selected_graph != null and editor_state.selected_runtime != null;

    if (runtime_driven) {
        editor_state.is_playing = false;
        editor_state.current_time = editor_state.selected_runtime.?.primary.sample_time;
    } else if (editor_state.is_playing) {
        const clip_duration = if (editor_state.selected_clip) |clip_handle|
            if (layer_context.world.resources.animationClip(clip_handle)) |clip| @max(clip.duration, 0.001) else 0.0
        else
            0.0;
        if (clip_duration > 0.0) {
            editor_state.current_time = @mod(editor_state.current_time + layer_context.delta_seconds, clip_duration);
        }
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    {
        const child_visible = gui.beginChild("animation_graph_runtime_panel", -1.0, 184.0, true);
        defer gui.endChild();
        if (child_visible) {
            drawGraphRuntimePanel(state, layer_context, editor_state);
        }
    }

    {
        const child_visible = gui.beginChild("animation_editor_main", -1.0, -48.0, false);
        defer gui.endChild();
        if (child_visible) {
            if (gui.beginTable("animation_editor_layout", 2)) {
                gui.tableSetupColumn("Tracks", true, 0.3);
                gui.tableSetupColumn("Timeline", true, 0.7);

                gui.tableNextRow();
                gui.tableNextColumn();

                drawTrackList(state, editor_state, layer_context);

                gui.tableNextColumn();

                drawTimeline(state, editor_state, layer_context);

                gui.endTable();
            }
        }
    }

    try drawTimelineControls(state, editor_state, layer_context);
}

fn drawTrackList(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    gui.text(localText(state, .animation_tracks));
    gui.separator();

    const child_visible = gui.beginChild("track_list", -1.0, -1.0, false);
    defer gui.endChild();

    if (child_visible) {
        for (editor_state.tracks.items, 0..) |track, index| {
            const is_selected = editor_state.selected_track == @as(u32, @intCast(index));

            var track_label: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&track_label, "{s}##track_{}", .{ track.name, index }) catch continue;

            if (gui.selectable(label, is_selected, false, -1.0, 22.0)) {
                editor_state.selected_track = @intCast(index);
            }

            if (gui.beginPopupContextItem(null)) {
                defer gui.endPopup();

                if (gui.menuItem(localText(state, .delete_track), null, false, true)) {
                    deleteTrack(
                        editor_state,
                        state.allocator orelse layer_context.world.allocator,
                        index,
                    );
                }
            }
        }

        if (editor_state.tracks.items.len == 0) {
            gui.textWrapped(localText(state, .no_animation_tracks_loaded));
        }
    }
}

fn drawTimeline(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) void {
    gui.text(localText(state, .animation_timeline));
    gui.separator();

    const clip = if (editor_state.selected_clip) |clip_handle|
        layer_context.world.resources.animationClip(clip_handle)
    else
        null;

    const duration: f32 = if (clip) |clip_resource| clip_resource.duration else 1.0;
    const pixels_per_second = 50.0 * editor_state.timeline_scale;

    const timeline_visible = gui.beginChild("timeline_area", -1.0, -1.0, true);
    defer gui.endChild();

    if (timeline_visible) {
        const track_height = 24.0;
        const track_spacing = 2.0;

        {
            const ruler_visible = gui.beginChild("timeline_ruler", -1.0, 24.0, false);
            defer gui.endChild();

            if (ruler_visible) {
                const canvas_width = gui.contentRegionAvail()[0];

                var draw_list = gui.getWindowDrawList();
                const cursor_pos = gui.cursorScreenPos();

                const major_tick_height: f32 = 12.0;
                const minor_tick_height: f32 = 6.0;
                const time_interval: f32 = if (pixels_per_second > 30.0) 0.1 else if (pixels_per_second > 10.0) 0.5 else 1.0;

                var time: f32 = 0.0;
                while (time <= duration) : (time += time_interval) {
                    const x = cursor_pos[0] + time * pixels_per_second - editor_state.timeline_offset;
                    if (x >= cursor_pos[0] and x <= cursor_pos[0] + canvas_width) {
                        const is_major = @abs(@mod(time, 1.0)) < 0.01 or time == 0.0;
                        const tick_height: f32 = if (is_major) major_tick_height else minor_tick_height;

                        draw_list.addLine(.{ x, cursor_pos[1] + 2 }, .{ x, cursor_pos[1] + tick_height }, gui.getColorU32(.{ 0.7, 0.7, 0.7, 1.0 }), 1.0);

                        if (is_major and time < duration) {
                            var time_label: [16]u8 = undefined;
                            const label = std.fmt.bufPrint(&time_label, "{d:.1}s", .{time}) catch continue;
                            draw_list.addText(.{ x + 2, cursor_pos[1] + 2 }, gui.getColorU32(.{ 0.8, 0.8, 0.8, 1.0 }), label);
                        }
                    }
                }

                const current_time_x = cursor_pos[0] + editor_state.current_time * pixels_per_second - editor_state.timeline_offset;
                if (current_time_x >= cursor_pos[0] and current_time_x <= cursor_pos[0] + canvas_width) {
                    draw_list.addLine(.{ current_time_x, cursor_pos[1] }, .{ current_time_x, cursor_pos[1] + 22 }, gui.getColorU32(.{ 0.9, 0.3, 0.3, 1.0 }), 2.0);
                }
            }
        }

        {
            const tracks_visible = gui.beginChild("timeline_tracks", -1.0, -1.0, false);
            defer gui.endChild();

            if (tracks_visible) {
                const canvas_width = gui.contentRegionAvail()[0];
                var draw_list = gui.getWindowDrawList();

                for (editor_state.tracks.items, 0..) |track, track_index| {
                    gui.pushIdU64(track_index);
                    defer gui.popId();

                    const cursor_pos = gui.cursorScreenPos();
                    const is_selected = editor_state.selected_track == @as(u32, @intCast(track_index));
                    if (gui.invisibleButton("track_row", canvas_width, track_height)) {
                        editor_state.selected_track = @intCast(track_index);
                    }

                    const background_color: [4]f32 = if (is_selected)
                        .{ 0.18, 0.23, 0.30, 1.0 }
                    else
                        .{ 0.15, 0.15, 0.15, 1.0 };
                    draw_list.addRectFilled(
                        cursor_pos,
                        .{ cursor_pos[0] + canvas_width, cursor_pos[1] + track_height },
                        gui.getColorU32(background_color),
                        0,
                        0,
                    );
                    draw_list.addLine(
                        .{ cursor_pos[0], cursor_pos[1] + track_height - 1.0 },
                        .{ cursor_pos[0] + canvas_width, cursor_pos[1] + track_height - 1.0 },
                        gui.getColorU32(.{ 0.24, 0.24, 0.24, 1.0 }),
                        1.0,
                    );

                    const current_time_x = cursor_pos[0] + editor_state.current_time * pixels_per_second - editor_state.timeline_offset;
                    if (current_time_x >= cursor_pos[0] and current_time_x <= cursor_pos[0] + canvas_width) {
                        draw_list.addLine(
                            .{ current_time_x, cursor_pos[1] },
                            .{ current_time_x, cursor_pos[1] + track_height },
                            gui.getColorU32(.{ 0.9, 0.3, 0.3, 1.0 }),
                            1.0,
                        );
                    }

                    for (track.keyframes.items, 0..) |keyframe, keyframe_index| {
                        const x = cursor_pos[0] + keyframe.time * pixels_per_second - editor_state.timeline_offset;
                        if (x >= cursor_pos[0] and x <= cursor_pos[0] + canvas_width) {
                            const keyframe_color = switch (track.type) {
                                .translation => [4]f32{ 0.2, 0.6, 0.9, 1.0 },
                                .rotation => [4]f32{ 0.9, 0.6, 0.2, 1.0 },
                                .scale => [4]f32{ 0.2, 0.9, 0.6, 1.0 },
                            };

                            draw_list.addCircleFilled(
                                .{ x, cursor_pos[1] + track_height * 0.5 },
                                4.0,
                                gui.getColorU32(keyframe_color),
                                8,
                            );

                            if (keyframe_index == 0) {
                                draw_list.addLine(
                                    .{ cursor_pos[0], cursor_pos[1] + track_height * 0.5 },
                                    .{ x, cursor_pos[1] + track_height * 0.5 },
                                    gui.getColorU32(keyframe_color),
                                    1.0,
                                );
                            }

                            if (keyframe_index < track.keyframes.items.len - 1) {
                                const next_keyframe = track.keyframes.items[keyframe_index + 1];
                                const next_x = cursor_pos[0] + next_keyframe.time * pixels_per_second - editor_state.timeline_offset;

                                if (next_x >= cursor_pos[0] and next_x <= cursor_pos[0] + canvas_width) {
                                    draw_list.addLine(
                                        .{ x, cursor_pos[1] + track_height * 0.5 },
                                        .{ next_x, cursor_pos[1] + track_height * 0.5 },
                                        gui.getColorU32(keyframe_color),
                                        1.0,
                                    );
                                }
                            }
                        }
                    }

                    gui.dummy(0.0, track_spacing);
                }
            }
        }
    }
}

fn drawTimelineControls(state: *EditorState, editor_state: *AnimationEditorState, layer_context: *engine.core.LayerContext) !void {
    const runtime_driven = editor_state.selected_graph != null and editor_state.selected_runtime != null;

    if (runtime_driven) {
        gui.textWrapped(localText(state, .runtime_driven_timeline));
    }

    if (gui.button(localText(state, .play_pause))) {
        if (!runtime_driven) {
            editor_state.is_playing = !editor_state.is_playing;
        }
    }

    gui.sameLine();
    if (gui.button(localText(state, .stop))) {
        if (!runtime_driven) {
            editor_state.is_playing = false;
            editor_state.current_time = 0.0;
        }
    }

    gui.sameLine();
    gui.setNextItemWidth(100.0);
    _ = gui.dragFloat("##current_time", &editor_state.current_time, 0.01, 0.0, 100.0);

    gui.sameLine();
    gui.setNextItemWidth(100.0);
    _ = gui.dragFloat("##timeline_scale", &editor_state.timeline_scale, 0.01, 0.1, 10.0);

    gui.sameLine();
    if (gui.button(localText(state, .load_clip))) {
        try syncAnimationSource(layer_context, editor_state);
    }
}

pub fn createAnimationEditorState(allocator: std.mem.Allocator) !AnimationEditorState {
    _ = allocator;
    return AnimationEditorState{
        .tracks = .empty,
    };
}

pub fn destroyAnimationEditorState(editor_state: *AnimationEditorState, allocator: std.mem.Allocator) void {
    editor_state.deinit(allocator);
}

pub const MessageId = enum {
    animation_editor,
    animation_graph,
    graph_overview,
    graph_states,
    animation_tracks,
    animation_timeline,
    bound_graph,
    current_state,
    next_state,
    transition_progress,
    graph_parameters,
    graph_transitions,
    state_name,
    clip,
    speed,
    loop,
    duration,
    default_state,
    set_default_state,
    activate_state,
    add_state,
    no_graph_states,
    no_graph_state_selected,
    transition_source,
    transition_target,
    transition_trigger_time,
    blend_duration,
    add_transition,
    delete_transition,
    transition_details,
    no_transition_selected,
    transition_conditions,
    no_transition_conditions,
    add_condition,
    delete_condition,
    no_condition_selected,
    condition_type,
    threshold,
    parameter_name,
    comparison,
    condition_kind_elapsed,
    condition_kind_remaining,
    condition_kind_parameter,
    no_animator_selected,
    no_animation_graph_bound,
    no_graph_parameters,
    no_graph_transitions,
    runtime_driven_timeline,
    play_pause,
    stop,
    load_clip,
    no_animation_tracks_loaded,
    delete_track,

    pub const en_us = .{
        .animation_editor = "Animation Editor",
        .animation_graph = "Animation Graph",
        .graph_overview = "Graph Overview",
        .graph_states = "States",
        .animation_tracks = "Animation Tracks",
        .animation_timeline = "Timeline",
        .bound_graph = "Bound Graph",
        .current_state = "Current State",
        .next_state = "Next State",
        .transition_progress = "Transition",
        .graph_parameters = "Parameters",
        .graph_transitions = "Transitions",
        .state_name = "State Name",
        .clip = "Clip",
        .speed = "Speed",
        .loop = "Loop",
        .duration = "Duration",
        .default_state = "Default State",
        .set_default_state = "Set Default",
        .activate_state = "Activate Now",
        .add_state = "Add State",
        .no_graph_states = "This animation graph has no states yet.",
        .no_graph_state_selected = "Select a graph state to edit it.",
        .transition_source = "Source State",
        .transition_target = "Target State",
        .transition_trigger_time = "Trigger Time",
        .blend_duration = "Blend Duration",
        .add_transition = "Add Transition",
        .delete_transition = "Delete Transition",
        .transition_details = "Transition Details",
        .no_transition_selected = "Select a transition to inspect it.",
        .transition_conditions = "Conditions",
        .no_transition_conditions = "This transition has no conditions and will fire immediately.",
        .add_condition = "Add Condition",
        .delete_condition = "Delete Condition",
        .no_condition_selected = "Select a condition to edit it.",
        .condition_type = "Condition Type",
        .threshold = "Threshold",
        .parameter_name = "Parameter",
        .comparison = "Comparison",
        .condition_kind_elapsed = "Time Elapsed",
        .condition_kind_remaining = "Time Remaining",
        .condition_kind_parameter = "Parameter",
        .no_animator_selected = "Select an entity with an Animator component to inspect runtime animation data.",
        .no_animation_graph_bound = "The selected Animator is using clip playback only; no animation graph is bound.",
        .no_graph_parameters = "This animation graph does not define any runtime parameters.",
        .no_graph_transitions = "This animation graph does not define any transitions.",
        .runtime_driven_timeline = "Timeline is following the selected animator runtime because this entity is graph-driven.",
        .play_pause = "Play/Pause",
        .stop = "Stop",
        .load_clip = "Load Selected Clip",
        .no_animation_tracks_loaded = "No animation tracks loaded. Select an entity with an Animator component.",
        .delete_track = "Delete Track",
    };

    pub const zh_cn = .{
        .animation_editor = "动画编辑器",
        .animation_graph = "动画图",
        .graph_overview = "图总览",
        .graph_states = "状态",
        .animation_tracks = "动画轨道",
        .animation_timeline = "时间轴",
        .bound_graph = "绑定动画图",
        .current_state = "当前状态",
        .next_state = "下一状态",
        .transition_progress = "过渡进度",
        .graph_parameters = "参数",
        .graph_transitions = "过渡",
        .state_name = "状态名",
        .clip = "动画片段",
        .speed = "速度",
        .loop = "循环",
        .duration = "时长",
        .default_state = "默认状态",
        .set_default_state = "设为默认",
        .activate_state = "立即激活",
        .add_state = "添加状态",
        .no_graph_states = "该动画图还没有任何状态。",
        .no_graph_state_selected = "请选择一个图状态进行编辑。",
        .transition_source = "源状态",
        .transition_target = "目标状态",
        .transition_trigger_time = "触发时间",
        .blend_duration = "混合时长",
        .add_transition = "添加过渡",
        .delete_transition = "删除过渡",
        .transition_details = "过渡详情",
        .no_transition_selected = "请选择一个过渡以查看详情。",
        .transition_conditions = "条件",
        .no_transition_conditions = "该过渡没有任何条件，会立刻触发。",
        .add_condition = "添加条件",
        .delete_condition = "删除条件",
        .no_condition_selected = "请选择一个条件进行编辑。",
        .condition_type = "条件类型",
        .threshold = "阈值",
        .parameter_name = "参数",
        .comparison = "比较",
        .condition_kind_elapsed = "已过时间",
        .condition_kind_remaining = "剩余时间",
        .condition_kind_parameter = "参数",
        .no_animator_selected = "请选择带有 Animator 组件的实体以查看运行时动画数据。",
        .no_animation_graph_bound = "当前选中的 Animator 仍在使用 clip 播放，没有绑定动画图。",
        .no_graph_parameters = "该动画图没有定义运行时参数。",
        .no_graph_transitions = "该动画图没有定义过渡。",
        .runtime_driven_timeline = "该实体由动画图驱动，时间轴会跟随当前运行时状态。",
        .play_pause = "播放/暂停",
        .stop = "停止",
        .load_clip = "加载选中动画",
        .no_animation_tracks_loaded = "未加载动画轨道。请选择带有 Animator 组件的实体。",
        .delete_track = "删除轨道",
    };
};

pub const text_map = .{
    .en_us = &MessageId.en_us,
    .zh_cn = &MessageId.zh_cn,
};

fn localText(state: *const EditorState, id: MessageId) []const u8 {
    return switch (state.language) {
        .en_us => switch (id) {
            .animation_editor => MessageId.en_us.animation_editor,
            .animation_graph => MessageId.en_us.animation_graph,
            .graph_overview => MessageId.en_us.graph_overview,
            .graph_states => MessageId.en_us.graph_states,
            .animation_tracks => MessageId.en_us.animation_tracks,
            .animation_timeline => MessageId.en_us.animation_timeline,
            .bound_graph => MessageId.en_us.bound_graph,
            .current_state => MessageId.en_us.current_state,
            .next_state => MessageId.en_us.next_state,
            .transition_progress => MessageId.en_us.transition_progress,
            .graph_parameters => MessageId.en_us.graph_parameters,
            .graph_transitions => MessageId.en_us.graph_transitions,
            .state_name => MessageId.en_us.state_name,
            .clip => MessageId.en_us.clip,
            .speed => MessageId.en_us.speed,
            .loop => MessageId.en_us.loop,
            .duration => MessageId.en_us.duration,
            .default_state => MessageId.en_us.default_state,
            .set_default_state => MessageId.en_us.set_default_state,
            .activate_state => MessageId.en_us.activate_state,
            .add_state => MessageId.en_us.add_state,
            .no_graph_states => MessageId.en_us.no_graph_states,
            .no_graph_state_selected => MessageId.en_us.no_graph_state_selected,
            .transition_source => MessageId.en_us.transition_source,
            .transition_target => MessageId.en_us.transition_target,
            .transition_trigger_time => MessageId.en_us.transition_trigger_time,
            .blend_duration => MessageId.en_us.blend_duration,
            .add_transition => MessageId.en_us.add_transition,
            .delete_transition => MessageId.en_us.delete_transition,
            .transition_details => MessageId.en_us.transition_details,
            .no_transition_selected => MessageId.en_us.no_transition_selected,
            .transition_conditions => MessageId.en_us.transition_conditions,
            .no_transition_conditions => MessageId.en_us.no_transition_conditions,
            .add_condition => MessageId.en_us.add_condition,
            .delete_condition => MessageId.en_us.delete_condition,
            .no_condition_selected => MessageId.en_us.no_condition_selected,
            .condition_type => MessageId.en_us.condition_type,
            .threshold => MessageId.en_us.threshold,
            .parameter_name => MessageId.en_us.parameter_name,
            .comparison => MessageId.en_us.comparison,
            .condition_kind_elapsed => MessageId.en_us.condition_kind_elapsed,
            .condition_kind_remaining => MessageId.en_us.condition_kind_remaining,
            .condition_kind_parameter => MessageId.en_us.condition_kind_parameter,
            .no_animator_selected => MessageId.en_us.no_animator_selected,
            .no_animation_graph_bound => MessageId.en_us.no_animation_graph_bound,
            .no_graph_parameters => MessageId.en_us.no_graph_parameters,
            .no_graph_transitions => MessageId.en_us.no_graph_transitions,
            .runtime_driven_timeline => MessageId.en_us.runtime_driven_timeline,
            .play_pause => MessageId.en_us.play_pause,
            .stop => MessageId.en_us.stop,
            .load_clip => MessageId.en_us.load_clip,
            .no_animation_tracks_loaded => MessageId.en_us.no_animation_tracks_loaded,
            .delete_track => MessageId.en_us.delete_track,
        },
        .zh_cn => switch (id) {
            .animation_editor => MessageId.zh_cn.animation_editor,
            .animation_graph => MessageId.zh_cn.animation_graph,
            .graph_overview => MessageId.zh_cn.graph_overview,
            .graph_states => MessageId.zh_cn.graph_states,
            .animation_tracks => MessageId.zh_cn.animation_tracks,
            .animation_timeline => MessageId.zh_cn.animation_timeline,
            .bound_graph => MessageId.zh_cn.bound_graph,
            .current_state => MessageId.zh_cn.current_state,
            .next_state => MessageId.zh_cn.next_state,
            .transition_progress => MessageId.zh_cn.transition_progress,
            .graph_parameters => MessageId.zh_cn.graph_parameters,
            .graph_transitions => MessageId.zh_cn.graph_transitions,
            .state_name => MessageId.zh_cn.state_name,
            .clip => MessageId.zh_cn.clip,
            .speed => MessageId.zh_cn.speed,
            .loop => MessageId.zh_cn.loop,
            .duration => MessageId.zh_cn.duration,
            .default_state => MessageId.zh_cn.default_state,
            .set_default_state => MessageId.zh_cn.set_default_state,
            .activate_state => MessageId.zh_cn.activate_state,
            .add_state => MessageId.zh_cn.add_state,
            .no_graph_states => MessageId.zh_cn.no_graph_states,
            .no_graph_state_selected => MessageId.zh_cn.no_graph_state_selected,
            .transition_source => MessageId.zh_cn.transition_source,
            .transition_target => MessageId.zh_cn.transition_target,
            .transition_trigger_time => MessageId.zh_cn.transition_trigger_time,
            .blend_duration => MessageId.zh_cn.blend_duration,
            .add_transition => MessageId.zh_cn.add_transition,
            .delete_transition => MessageId.zh_cn.delete_transition,
            .transition_details => MessageId.zh_cn.transition_details,
            .no_transition_selected => MessageId.zh_cn.no_transition_selected,
            .transition_conditions => MessageId.zh_cn.transition_conditions,
            .no_transition_conditions => MessageId.zh_cn.no_transition_conditions,
            .add_condition => MessageId.zh_cn.add_condition,
            .delete_condition => MessageId.zh_cn.delete_condition,
            .no_condition_selected => MessageId.zh_cn.no_condition_selected,
            .condition_type => MessageId.zh_cn.condition_type,
            .threshold => MessageId.zh_cn.threshold,
            .parameter_name => MessageId.zh_cn.parameter_name,
            .comparison => MessageId.zh_cn.comparison,
            .condition_kind_elapsed => MessageId.zh_cn.condition_kind_elapsed,
            .condition_kind_remaining => MessageId.zh_cn.condition_kind_remaining,
            .condition_kind_parameter => MessageId.zh_cn.condition_kind_parameter,
            .no_animator_selected => MessageId.zh_cn.no_animator_selected,
            .no_animation_graph_bound => MessageId.zh_cn.no_animation_graph_bound,
            .no_graph_parameters => MessageId.zh_cn.no_graph_parameters,
            .no_graph_transitions => MessageId.zh_cn.no_graph_transitions,
            .runtime_driven_timeline => MessageId.zh_cn.runtime_driven_timeline,
            .play_pause => MessageId.zh_cn.play_pause,
            .stop => MessageId.zh_cn.stop,
            .load_clip => MessageId.zh_cn.load_clip,
            .no_animation_tracks_loaded => MessageId.zh_cn.no_animation_tracks_loaded,
            .delete_track => MessageId.zh_cn.delete_track,
        },
    };
}

fn blendQuat(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var qa = engine.math.quat.normalize(a);
    var qb = engine.math.quat.normalize(b);
    var dot_value = qa[0] * qb[0] + qa[1] * qb[1] + qa[2] * qb[2] + qa[3] * qb[3];

    if (dot_value < 0.0) {
        qb = .{ -qb[0], -qb[1], -qb[2], -qb[3] };
        dot_value = -dot_value;
    }

    if (dot_value > 0.9995) {
        qa = .{
            std.math.lerp(qa[0], qb[0], t),
            std.math.lerp(qa[1], qb[1], t),
            std.math.lerp(qa[2], qb[2], t),
            std.math.lerp(qa[3], qb[3], t),
        };
        return engine.math.quat.normalize(qa);
    }

    const theta_0 = std.math.acos(std.math.clamp(dot_value, -1.0, 1.0));
    const theta = theta_0 * t;
    const sin_theta = std.math.sin(theta);
    const sin_theta_0 = std.math.sin(theta_0);

    const s0 = std.math.cos(theta) - dot_value * sin_theta / sin_theta_0;
    const s1 = sin_theta / sin_theta_0;
    return .{
        qa[0] * s0 + qb[0] * s1,
        qa[1] * s0 + qb[1] * s1,
        qa[2] * s0 + qb[2] * s1,
        qa[3] * s0 + qb[3] * s1,
    };
}

fn clearGraphAuthoringState(editor_state: *AnimationEditorState) void {
    editor_state.selected_graph_state = null;
    editor_state.selected_graph_transition = null;
    editor_state.selected_transition_condition = null;
    editor_state.new_transition_target_state = 0;
    editor_state.new_transition_elapsed_seconds = 0.25;
    editor_state.new_transition_duration = 0.2;
    @memset(editor_state.state_name_buffer[0..], 0);
    @memset(editor_state.condition_parameter_name_buffer[0..], 0);
}

fn writeTextBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    if (buffer.len == 0) {
        return;
    }

    const copy_len = @min(buffer.len - 1, value.len);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
}

fn setSelectedGraphState(
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
    state_index: ?u32,
) void {
    editor_state.selected_graph_state = state_index;
    if (state_index) |index| {
        if (index < graph.states.items.len) {
            writeTextBuffer(editor_state.state_name_buffer[0..], graph.states.items[index].name);
            return;
        }
    }
    @memset(editor_state.state_name_buffer[0..], 0);
}

fn setSelectedTransitionCondition(
    editor_state: *AnimationEditorState,
    transition: *const animation_graph_mod.Transition,
    condition_index: ?u32,
) void {
    editor_state.selected_transition_condition = condition_index;
    @memset(editor_state.condition_parameter_name_buffer[0..], 0);

    if (condition_index) |index| {
        if (index < transition.conditions.len) {
            switch (transition.conditions[index]) {
                .parameter => |parameter| writeTextBuffer(editor_state.condition_parameter_name_buffer[0..], parameter.name),
                else => {},
            }
        }
    }
}

fn defaultTransitionTarget(
    graph: *const animation_graph_mod.AnimationGraph,
    source_state: ?u32,
) u32 {
    if (graph.states.items.len <= 1) {
        return 0;
    }

    const source_index = source_state orelse 0;
    if (source_index + 1 < graph.states.items.len) {
        return source_index + 1;
    }
    return 0;
}

fn syncGraphAuthoringSelection(
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    if (graph.states.items.len == 0) {
        clearGraphAuthoringState(editor_state);
        return;
    }

    const current_selection = if (editor_state.selected_graph_state) |selected|
        if (selected < graph.states.items.len) selected else null
    else
        null;

    const runtime_state = if (editor_state.selected_runtime) |runtime|
        if (runtime.primary.state_index < graph.states.items.len) runtime.primary.state_index else null
    else
        null;

    const default_state = if (graph.default_state) |selected|
        if (selected < graph.states.items.len) selected else null
    else
        null;

    const next_state = current_selection orelse runtime_state orelse default_state orelse 0;
    if (editor_state.selected_graph_state != next_state) {
        setSelectedGraphState(editor_state, graph, next_state);
    }

    if (graph.transitions.items.len == 0) {
        editor_state.selected_graph_transition = null;
    } else if (editor_state.selected_graph_transition) |selected_transition| {
        if (selected_transition >= graph.transitions.items.len) {
            editor_state.selected_graph_transition = @as(u32, @intCast(graph.transitions.items.len - 1));
        }
    }

    if (editor_state.new_transition_target_state >= graph.states.items.len or
        (editor_state.selected_graph_state != null and editor_state.new_transition_target_state == editor_state.selected_graph_state.?))
    {
        editor_state.new_transition_target_state = defaultTransitionTarget(graph, editor_state.selected_graph_state);
    }
}

fn syncTransitionConditionSelection(
    editor_state: *AnimationEditorState,
    transition: *const animation_graph_mod.Transition,
) void {
    if (transition.conditions.len == 0) {
        setSelectedTransitionCondition(editor_state, transition, null);
        return;
    }

    if (editor_state.selected_transition_condition) |selected_condition| {
        if (selected_condition < transition.conditions.len) {
            if (transition.conditions[selected_condition] == .parameter and
                utils.zeroTerminatedSlice(editor_state.condition_parameter_name_buffer[0..]).len == 0)
            {
                setSelectedTransitionCondition(editor_state, transition, selected_condition);
            }
            return;
        }
    }

    setSelectedTransitionCondition(editor_state, transition, 0);
}

fn replaceOwnedText(allocator: std.mem.Allocator, target: *[]u8, value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = owned;
}

fn selectedGraphForEditing(
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
) ?*animation_graph_mod.AnimationGraph {
    const entity_id = editor_state.selected_entity orelse return null;
    return layer_context.world.animatorGraphMutable(entity_id);
}

fn refreshGraphEditorData(
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
) void {
    if (editor_state.selected_entity) |entity_id| {
        if (layer_context.world.animatorGraphInstance(entity_id)) |instance| {
            instance.update(0.0);
        }
    }
    syncAnimationSource(layer_context, editor_state) catch |err| {
        std.log.err("Failed to refresh animation graph editor data: {}", .{err});
    };
}

fn commitGraphAuthoringChange(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
) void {
    history.captureSnapshot(state, layer_context) catch |err| {
        std.log.err("Failed to capture animation graph history snapshot: {}", .{err});
    };
    refreshGraphEditorData(layer_context, editor_state);
}

fn clipLabel(
    layer_context: *engine.core.LayerContext,
    clip_handle: ?handles.AnimationClipHandle,
    buffer: *[128]u8,
) []const u8 {
    if (clip_handle) |handle| {
        if (layer_context.world.resources.animationClip(handle)) |clip| {
            return clip.name;
        }
        return std.fmt.bufPrint(buffer, "Clip #{}", .{@intFromEnum(handle)}) catch "Clip";
    }
    return "-";
}

fn stateLabel(
    graph: *const animation_graph_mod.AnimationGraph,
    runtime: ?animation_graph_mod.RuntimeClipBlend,
    index: u32,
    buffer: *[192]u8,
) []const u8 {
    const state = graph.states.items[index];
    const is_default = graph.default_state != null and graph.default_state.? == index;
    const is_current = runtime != null and runtime.?.primary.state_index == index;
    const is_next = runtime != null and runtime.?.secondary != null and runtime.?.secondary.?.state_index == index;

    if (is_default and is_current) {
        return std.fmt.bufPrint(buffer, "{s} [default, active]", .{state.name}) catch state.name;
    }
    if (is_default) {
        return std.fmt.bufPrint(buffer, "{s} [default]", .{state.name}) catch state.name;
    }
    if (is_current) {
        return std.fmt.bufPrint(buffer, "{s} [active]", .{state.name}) catch state.name;
    }
    if (is_next) {
        return std.fmt.bufPrint(buffer, "{s} [next]", .{state.name}) catch state.name;
    }
    return state.name;
}

fn transitionConditionLabel(
    condition: animation_graph_mod.TransitionCondition,
    buffer: *[192]u8,
) []const u8 {
    return switch (condition) {
        .time_elapsed => |value| std.fmt.bufPrint(buffer, "time elapsed >= {d:.2}s", .{value}) catch "time elapsed",
        .time_remaining => |value| std.fmt.bufPrint(buffer, "time remaining <= {d:.2}s", .{value}) catch "time remaining",
        .parameter => |parameter| {
            const comparator = switch (parameter.comparison) {
                .less => "<",
                .greater => ">",
                .equal => "==",
            };
            return std.fmt.bufPrint(buffer, "{s} {s} {d:.2}", .{ parameter.name, comparator, parameter.value }) catch parameter.name;
        },
    };
}

fn transitionConditionNumericValue(condition: animation_graph_mod.TransitionCondition) f32 {
    return switch (condition) {
        .time_elapsed => |value| value,
        .time_remaining => |value| value,
        .parameter => |parameter| parameter.value,
    };
}

fn transitionConditionTypeIndex(condition: animation_graph_mod.TransitionCondition) u32 {
    return switch (condition) {
        .time_elapsed => 0,
        .time_remaining => 1,
        .parameter => 2,
    };
}

fn transitionConditionTypeLabel(state: *EditorState, type_index: u32) []const u8 {
    return switch (type_index) {
        0 => localText(state, .condition_kind_elapsed),
        1 => localText(state, .condition_kind_remaining),
        else => localText(state, .condition_kind_parameter),
    };
}

fn defaultConditionParameterName(
    editor_state: *const AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) []const u8 {
    if (graph.parameters.items.len != 0) {
        return graph.parameters.items[0].name;
    }

    const typed_name = utils.zeroTerminatedSlice(editor_state.condition_parameter_name_buffer[0..]);
    if (typed_name.len != 0) {
        return typed_name;
    }

    return "Parameter";
}

fn drawConditionTypeCombo(state: *EditorState, widget_id: []const u8, type_index: *u32) bool {
    var changed = false;
    if (gui.beginCombo(widget_id, transitionConditionTypeLabel(state, type_index.*))) {
        defer gui.endCombo();

        for ([_]u32{ 0, 1, 2 }) |candidate| {
            const selected = candidate == type_index.*;
            if (gui.selectable(transitionConditionTypeLabel(state, candidate), selected, false, -1.0, 22.0)) {
                type_index.* = candidate;
                changed = true;
            }
        }
    }
    return changed;
}

fn comparisonLabel(comparison: anytype) []const u8 {
    return switch (comparison) {
        .less => "<",
        .greater => ">",
        .equal => "==",
    };
}

fn drawComparisonCombo(
    widget_id: []const u8,
    comparison: anytype,
) bool {
    var changed = false;
    if (gui.beginCombo(widget_id, comparisonLabel(comparison.*))) {
        defer gui.endCombo();

        if (gui.selectable("<", comparison.* == .less, false, -1.0, 22.0)) {
            comparison.* = .less;
            changed = true;
        }
        if (gui.selectable(">", comparison.* == .greater, false, -1.0, 22.0)) {
            comparison.* = .greater;
            changed = true;
        }
        if (gui.selectable("==", comparison.* == .equal, false, -1.0, 22.0)) {
            comparison.* = .equal;
            changed = true;
        }
    }
    return changed;
}

fn syncAnimationSource(layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) !void {
    const previous_entity = editor_state.selected_entity;
    const previous_graph = editor_state.selected_graph;
    const selected_entity = layer_context.renderer.selectedEntity();
    editor_state.selected_entity = selected_entity;
    if (previous_entity != selected_entity) {
        clearGraphAuthoringState(editor_state);
    }
    editor_state.selected_graph = null;
    editor_state.selected_runtime = null;

    const entity_id = selected_entity orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };
    const entity = layer_context.world.getEntityConst(entity_id) orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };
    const animator = entity.animator orelse {
        clearLoadedClip(editor_state, layer_context.world.allocator);
        return;
    };

    if (layer_context.world.animatorGraph(entity_id)) |graph| {
        if (previous_graph != graph) {
            clearGraphAuthoringState(editor_state);
        }
        editor_state.selected_graph = graph;
        if (layer_context.world.animatorGraphInstanceConst(entity_id)) |instance| {
            editor_state.selected_runtime = instance.runtimeClipBlend();
        }
        syncGraphAuthoringSelection(editor_state, graph);
    }

    const desired_clip = if (editor_state.selected_graph) |graph|
        if (editor_state.selected_graph_state) |state_index|
            if (state_index < graph.states.items.len) graph.states.items[state_index].clip_handle else null
        else if (editor_state.selected_runtime) |runtime|
            runtime.primary.clip_handle
        else
            animator.default_clip_handle
    else if (editor_state.selected_runtime) |runtime|
        runtime.primary.clip_handle
    else
        animator.default_clip_handle;

    try loadSelectedClipIfNeeded(editor_state, layer_context.world.allocator, layer_context, desired_clip);
}

fn clearLoadedClip(editor_state: *AnimationEditorState, allocator: std.mem.Allocator) void {
    editor_state.selected_clip = null;
    editor_state.selected_graph = null;
    editor_state.selected_runtime = null;
    editor_state.current_time = 0.0;
    editor_state.selected_track = null;
    editor_state.selected_keyframe = null;
    clearGraphAuthoringState(editor_state);
    editor_state.clearTracks(allocator);
}

fn loadSelectedClipIfNeeded(
    editor_state: *AnimationEditorState,
    allocator: std.mem.Allocator,
    layer_context: *engine.core.LayerContext,
    clip_handle: ?handles.AnimationClipHandle,
) !void {
    if (editor_state.selected_clip == clip_handle) {
        return;
    }
    if (clip_handle) |handle| {
        const clip = layer_context.world.resources.animationClip(handle) orelse {
            clearLoadedClip(editor_state, allocator);
            return;
        };
        editor_state.selected_clip = handle;
        try editor_state.loadClip(allocator, clip);
        if (editor_state.selected_runtime) |runtime| {
            editor_state.current_time = runtime.primary.sample_time;
        } else {
            editor_state.current_time = 0.0;
        }
        return;
    }
    clearLoadedClip(editor_state, allocator);
}

fn drawGraphRuntimePanel(state: *EditorState, layer_context: *engine.core.LayerContext, editor_state: *AnimationEditorState) void {
    const selected_entity = editor_state.selected_entity orelse {
        gui.textWrapped(localText(state, .no_animator_selected));
        return;
    };
    const entity = layer_context.world.getEntityConst(selected_entity) orelse {
        gui.textWrapped(localText(state, .no_animator_selected));
        return;
    };
    if (entity.animator == null) {
        gui.textWrapped(localText(state, .no_animator_selected));
        return;
    }

    gui.text(localText(state, .animation_graph));
    gui.separator();

    const graph = editor_state.selected_graph orelse {
        gui.textWrapped(localText(state, .no_animation_graph_bound));
        return;
    };

    gui.text(localText(state, .bound_graph));
    gui.sameLine();
    gui.pushStyleColor(.text, .{ 0.32, 0.82, 0.58, 1.0 });
    gui.text(graph.name);
    gui.popStyleColor(1);

    const runtime = editor_state.selected_runtime;
    if (gui.collapsingHeader(localText(state, .animation_graph), true)) {
        if (layout.beginInspectorPropertyTable("animation_graph_runtime_summary", 0.34)) {
            defer layout.endInspectorPropertyTable();

            layout.drawInspectorPropertyRow(localText(state, .current_state), null);
            drawRuntimeStateName(graph, if (runtime) |value| value.primary.state_index else null, .{ 0.36, 0.84, 0.60, 1.0 });

            layout.drawInspectorPropertyRow(localText(state, .next_state), null);
            drawRuntimeStateName(
                graph,
                if (runtime) |value| if (value.secondary) |secondary| secondary.state_index else null else null,
                .{ 0.92, 0.74, 0.28, 1.0 },
            );

            layout.drawInspectorPropertyRow(localText(state, .transition_progress), null);
            if (runtime) |value| {
                if (value.secondary != null) {
                    var progress_buffer: [32]u8 = undefined;
                    const progress_text = std.fmt.bufPrint(
                        &progress_buffer,
                        "{d:.0}% ({d:.2}s / {d:.2}s)",
                        .{ value.blend_factor * 100.0, value.transition_time, value.transition_duration },
                    ) catch "-";
                    gui.text(progress_text);
                } else {
                    gui.text("-");
                }
            } else {
                gui.text("-");
            }
        }
    }

    if (gui.collapsingHeader(localText(state, .graph_overview), true)) {
        drawGraphOverview(state, layer_context, editor_state, graph);
    }

    if (gui.collapsingHeader(localText(state, .graph_states), true)) {
        drawGraphStateEditor(state, layer_context, editor_state, graph);
    }

    if (gui.collapsingHeader(localText(state, .graph_parameters), true)) {
        drawGraphParameterControls(state, layer_context, editor_state, graph);
    }

    if (gui.collapsingHeader(localText(state, .graph_transitions), false)) {
        drawGraphTransitionsList(state, layer_context, editor_state, graph);
    }
}

fn drawRuntimeStateName(
    graph: *const animation_graph_mod.AnimationGraph,
    state_index: ?u32,
    color: [4]f32,
) void {
    if (state_index) |index| {
        if (index < graph.states.items.len) {
            gui.pushStyleColor(.text, color);
            defer gui.popStyleColor(1);
            gui.text(graph.states.items[index].name);
            return;
        }
    }
    gui.text("-");
}

fn drawStateCombo(
    widget_id: []const u8,
    graph: *const animation_graph_mod.AnimationGraph,
    selected_index: *u32,
) bool {
    if (graph.states.items.len == 0) {
        return false;
    }

    const preview = if (selected_index.* < graph.states.items.len)
        graph.states.items[selected_index.*].name
    else
        graph.states.items[0].name;

    var changed = false;
    if (gui.beginCombo(widget_id, preview)) {
        defer gui.endCombo();

        for (graph.states.items, 0..) |state, index| {
            const selected = selected_index.* == index;
            if (gui.selectable(state.name, selected, false, -1.0, 22.0)) {
                selected_index.* = @intCast(index);
                changed = true;
            }
        }
    }
    return changed;
}

fn drawAnimationClipCombo(
    layer_context: *engine.core.LayerContext,
    widget_id: []const u8,
    selected_handle: *?handles.AnimationClipHandle,
) bool {
    var preview_buffer: [128]u8 = undefined;
    const preview = clipLabel(layer_context, selected_handle.*, &preview_buffer);

    var changed = false;
    if (gui.beginCombo(widget_id, preview)) {
        defer gui.endCombo();

        if (gui.selectable("-", selected_handle.* == null, false, -1.0, 22.0)) {
            selected_handle.* = null;
            changed = true;
        }

        for (layer_context.world.resources.animation_clips.items, 0..) |clip, index| {
            const handle = handles.animationClipHandle(index);
            const selected = selected_handle.* != null and selected_handle.*.? == handle;
            if (gui.selectable(clip.name, selected, false, -1.0, 22.0)) {
                selected_handle.* = handle;
                changed = true;
            }
        }
    }
    return changed;
}

fn drawGraphOverview(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    if (graph.states.items.len == 0) {
        gui.textWrapped(localText(state, .no_graph_states));
        return;
    }

    const canvas_visible = gui.beginChild("animation_graph_overview_canvas", -1.0, 132.0, true);
    defer gui.endChild();
    if (!canvas_visible) {
        return;
    }

    const card_width = 150.0;
    const card_height = 44.0;
    const spacing = 10.0;
    const available_width = gui.contentRegionAvail()[0];
    const raw_columns = @max(1.0, (available_width + spacing) / (card_width + spacing));
    const column_count = @max(@as(usize, 1), @as(usize, @intFromFloat(raw_columns)));

    for (graph.states.items, 0..) |_, index| {
        const state_index: u32 = @intCast(index);
        const is_selected = editor_state.selected_graph_state != null and editor_state.selected_graph_state.? == state_index;
        const is_current = editor_state.selected_runtime != null and editor_state.selected_runtime.?.primary.state_index == state_index;
        const is_next = editor_state.selected_runtime != null and
            editor_state.selected_runtime.?.secondary != null and
            editor_state.selected_runtime.?.secondary.?.state_index == state_index;
        const is_default = graph.default_state != null and graph.default_state.? == state_index;

        var button_color: [4]f32 = .{ 0.20, 0.22, 0.24, 1.0 };
        if (is_default) {
            button_color = .{ 0.20, 0.33, 0.26, 1.0 };
        }
        if (is_current) {
            button_color = .{ 0.22, 0.39, 0.30, 1.0 };
        }
        if (is_next) {
            button_color = .{ 0.37, 0.29, 0.16, 1.0 };
        }
        if (is_selected) {
            button_color = .{ 0.23, 0.30, 0.41, 1.0 };
        }

        gui.pushStyleColor(.button, button_color);
        gui.pushStyleColor(.button_hovered, .{ button_color[0] + 0.05, button_color[1] + 0.05, button_color[2] + 0.05, 1.0 });
        gui.pushStyleColor(.button_active, .{ button_color[0] + 0.08, button_color[1] + 0.08, button_color[2] + 0.08, 1.0 });
        defer gui.popStyleColor(3);

        var label_buffer: [192]u8 = undefined;
        const label = stateLabel(graph, editor_state.selected_runtime, state_index, &label_buffer);
        if (gui.buttonEx(label, card_width, card_height)) {
            setSelectedGraphState(editor_state, graph, state_index);
            refreshGraphEditorData(layer_context, editor_state);
        }

        if ((index + 1) % column_count != 0 and index + 1 < graph.states.items.len) {
            gui.sameLineEx(0.0, spacing);
        }
    }
}

fn drawGraphStateEditor(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    const editable_graph = selectedGraphForEditing(layer_context, editor_state) orelse {
        gui.textWrapped(localText(state, .no_animation_graph_bound));
        return;
    };

    if (gui.button(localText(state, .add_state))) {
        var name_buffer: [32]u8 = undefined;
        const next_state_name = std.fmt.bufPrint(&name_buffer, "State {}", .{editable_graph.states.items.len + 1}) catch "State";
        const new_state_index = editable_graph.addState(next_state_name, null) catch |err| {
            std.log.err("Failed to add animation graph state: {}", .{err});
            return;
        };
        setSelectedGraphState(editor_state, editable_graph, new_state_index);
        commitGraphAuthoringChange(state, layer_context, editor_state);
    }

    if (graph.states.items.len == 0) {
        gui.textWrapped(localText(state, .no_graph_states));
        return;
    }

    if (!gui.beginTable("animation_graph_states_layout", 2)) {
        return;
    }
    defer gui.endTable();

    gui.tableSetupColumn("StateList", true, 0.36);
    gui.tableSetupColumn("StateDetails", true, 0.64);
    gui.tableNextRow();
    gui.tableNextColumn();

    {
        const list_visible = gui.beginChild("animation_graph_state_list", -1.0, 180.0, true);
        defer gui.endChild();

        if (list_visible) {
            for (graph.states.items, 0..) |_, index| {
                const state_index: u32 = @intCast(index);
                const selected = editor_state.selected_graph_state != null and editor_state.selected_graph_state.? == state_index;

                var label_buffer: [192]u8 = undefined;
                const label = stateLabel(graph, editor_state.selected_runtime, state_index, &label_buffer);
                if (gui.selectable(label, selected, false, -1.0, 22.0)) {
                    setSelectedGraphState(editor_state, graph, state_index);
                    refreshGraphEditorData(layer_context, editor_state);
                }
            }
        }
    }

    gui.tableNextColumn();

    const state_index = editor_state.selected_graph_state orelse {
        gui.textWrapped(localText(state, .no_graph_state_selected));
        return;
    };
    if (state_index >= editable_graph.states.items.len) {
        gui.textWrapped(localText(state, .no_graph_state_selected));
        return;
    }

    const selected_state = &editable_graph.states.items[state_index];
    if (layout.beginInspectorPropertyTable("animation_graph_state_editor", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow(localText(state, .state_name), null);
        if (gui.inputTextWithHint("##graph_state_name", "State", editor_state.state_name_buffer[0..])) {
            const next_name = utils.zeroTerminatedSlice(editor_state.state_name_buffer[0..]);
            if (next_name.len != 0 and !std.mem.eql(u8, next_name, selected_state.name)) {
                replaceOwnedText(editable_graph.allocator, &selected_state.name, next_name) catch |err| {
                    std.log.err("Failed to rename animation graph state: {}", .{err});
                };
                commitGraphAuthoringChange(state, layer_context, editor_state);
            }
        }

        layout.drawInspectorPropertyRow(localText(state, .clip), null);
        var clip_handle = selected_state.clip_handle;
        if (drawAnimationClipCombo(layer_context, "##graph_state_clip", &clip_handle)) {
            selected_state.clip_handle = clip_handle;
            if (clip_handle) |handle| {
                if (layer_context.world.resources.animationClip(handle)) |clip| {
                    if (selected_state.duration_seconds <= 0.0001) {
                        selected_state.duration_seconds = clip.duration;
                    }
                }
            }
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .speed), null);
        var speed = selected_state.speed;
        if (gui.dragFloat("##graph_state_speed", &speed, 0.01, -8.0, 8.0)) {
            selected_state.speed = speed;
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .loop), null);
        var loop = selected_state.loop;
        if (gui.checkbox("##graph_state_loop", &loop)) {
            selected_state.loop = loop;
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .duration), null);
        var duration = selected_state.duration_seconds;
        if (gui.dragFloat("##graph_state_duration", &duration, 0.01, 0.0, 120.0)) {
            selected_state.duration_seconds = @max(duration, 0.0);
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .default_state), null);
        gui.text(if (editable_graph.default_state != null and editable_graph.default_state.? == state_index) "Yes" else "No");
    }

    if (gui.button(localText(state, .set_default_state))) {
        editable_graph.default_state = state_index;
        commitGraphAuthoringChange(state, layer_context, editor_state);
    }

    gui.sameLine();
    if (gui.button(localText(state, .activate_state))) {
        if (editor_state.selected_entity) |entity_id| {
            if (layer_context.world.animatorGraphInstance(entity_id)) |instance| {
                instance.current_state = state_index;
                instance.next_state = null;
                instance.transition_time = 0.0;
                instance.transition_duration = 0.0;
                instance.state_time = 0.0;
            }
        }
        refreshGraphEditorData(layer_context, editor_state);
    }
}

fn drawGraphParameterControls(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    if (graph.parameters.items.len == 0) {
        gui.textWrapped(localText(state, .no_graph_parameters));
        return;
    }

    const entity_id = editor_state.selected_entity orelse return;
    const instance = layer_context.world.animatorGraphInstance(entity_id) orelse return;
    if (layout.beginInspectorPropertyTable("animation_graph_parameters_table", 0.34)) {
        defer layout.endInspectorPropertyTable();

        for (graph.parameters.items, 0..) |parameter, index| {
            layout.drawInspectorPropertyRow(parameter.name, null);

            var widget_id_buffer: [64]u8 = undefined;
            const widget_id = std.fmt.bufPrint(&widget_id_buffer, "##anim_graph_param_{}", .{index}) catch continue;

            var changed = false;
            switch (instance.parameters.items[index]) {
                .float => |current_value| {
                    var value = current_value;
                    changed = gui.dragFloat(widget_id, &value, 0.01, -1000.0, 1000.0);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .float = value }) catch {};
                    }
                },
                .bool => |current_value| {
                    var value = current_value;
                    changed = gui.checkbox(widget_id, &value);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .bool = value }) catch {};
                    }
                },
                .int => |current_value| {
                    var value = @as(f32, @floatFromInt(current_value));
                    changed = gui.dragFloat(widget_id, &value, 1.0, -1000.0, 1000.0);
                    if (changed) {
                        layer_context.world.setAnimatorGraphParameter(entity_id, @intCast(index), .{ .int = @as(i32, @intFromFloat(@round(value))) }) catch {};
                    }
                },
            }

            if (changed) {
                instance.update(0.0);
                syncAnimationSource(layer_context, editor_state) catch |err| {
                    std.log.err("Failed to refresh animation editor after graph parameter edit: {}", .{err});
                };
            }
        }
    }
}

fn drawGraphTransitionsList(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *AnimationEditorState,
    graph: *const animation_graph_mod.AnimationGraph,
) void {
    const editable_graph = selectedGraphForEditing(layer_context, editor_state) orelse {
        gui.textWrapped(localText(state, .no_animation_graph_bound));
        return;
    };

    if (graph.states.items.len >= 2) {
        if (layout.beginInspectorPropertyTable("animation_graph_new_transition", 0.34)) {
            defer layout.endInspectorPropertyTable();

            layout.drawInspectorPropertyRow(localText(state, .transition_source), null);
            if (editor_state.selected_graph_state) |selected_state| {
                if (selected_state < graph.states.items.len) {
                    gui.text(graph.states.items[selected_state].name);
                } else {
                    gui.text("-");
                }
            } else {
                gui.text("-");
            }

            layout.drawInspectorPropertyRow(localText(state, .transition_target), null);
            _ = drawStateCombo("##graph_new_transition_target", graph, &editor_state.new_transition_target_state);

            layout.drawInspectorPropertyRow(localText(state, .transition_trigger_time), null);
            _ = gui.dragFloat("##graph_new_transition_time", &editor_state.new_transition_elapsed_seconds, 0.01, 0.0, 120.0);

            layout.drawInspectorPropertyRow(localText(state, .blend_duration), null);
            _ = gui.dragFloat("##graph_new_transition_duration", &editor_state.new_transition_duration, 0.01, 0.0, 30.0);
        }

        const can_add_transition = editor_state.selected_graph_state != null and
            editor_state.selected_graph_state.? < graph.states.items.len and
            editor_state.new_transition_target_state < graph.states.items.len and
            editor_state.new_transition_target_state != editor_state.selected_graph_state.?;

        if (gui.button(localText(state, .add_transition))) {
            if (can_add_transition) {
                const conditions = [_]animation_graph_mod.TransitionCondition{
                    .{ .time_elapsed = @max(editor_state.new_transition_elapsed_seconds, 0.0) },
                };
                editable_graph.addTransition(
                    editor_state.selected_graph_state.?,
                    editor_state.new_transition_target_state,
                    @max(editor_state.new_transition_duration, 0.0),
                    &conditions,
                ) catch |err| {
                    std.log.err("Failed to add animation graph transition: {}", .{err});
                    return;
                };
                editor_state.selected_graph_transition = @as(u32, @intCast(editable_graph.transitions.items.len - 1));
                commitGraphAuthoringChange(state, layer_context, editor_state);
            }
        }
    }

    if (graph.transitions.items.len == 0) {
        gui.textWrapped(localText(state, .no_graph_transitions));
        return;
    }

    if (!gui.beginTable("animation_graph_transition_layout", 2)) {
        return;
    }
    defer gui.endTable();

    gui.tableSetupColumn("TransitionList", true, 0.42);
    gui.tableSetupColumn("TransitionDetails", true, 0.58);
    gui.tableNextRow();
    gui.tableNextColumn();

    const active_transition = if (editor_state.selected_runtime) |runtime|
        if (runtime.secondary) |secondary|
            [2]u32{ runtime.primary.state_index, secondary.state_index }
        else
            null
    else
        null;

    const show_transition_list = gui.beginChild("animation_graph_transition_list", -1.0, 180.0, true);
    defer gui.endChild();
    if (show_transition_list) {
        for (graph.transitions.items, 0..) |transition, index| {
            const from_name = if (transition.from_state < graph.states.items.len) graph.states.items[transition.from_state].name else "?";
            const to_name = if (transition.to_state < graph.states.items.len) graph.states.items[transition.to_state].name else "?";
            const is_active = active_transition != null and active_transition.?[0] == transition.from_state and active_transition.?[1] == transition.to_state;
            const is_selected = editor_state.selected_graph_transition != null and editor_state.selected_graph_transition.? == index;

            var label_buffer: [256]u8 = undefined;
            const label = std.fmt.bufPrint(
                &label_buffer,
                "{s} -> {s} ({d:.2}s){s}",
                .{ from_name, to_name, transition.duration, if (is_active) " [active]" else "" },
            ) catch continue;
            if (gui.selectable(label, is_selected, false, -1.0, 22.0)) {
                editor_state.selected_graph_transition = @intCast(index);
                setSelectedTransitionCondition(editor_state, &graph.transitions.items[index], null);
            }
        }
    }

    gui.tableNextColumn();

    const transition_index = editor_state.selected_graph_transition orelse {
        gui.textWrapped(localText(state, .no_transition_selected));
        return;
    };
    if (transition_index >= editable_graph.transitions.items.len) {
        gui.textWrapped(localText(state, .no_transition_selected));
        return;
    }

    const transition = &editable_graph.transitions.items[transition_index];
    syncTransitionConditionSelection(editor_state, transition);

    if (layout.beginInspectorPropertyTable("animation_graph_transition_details", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow(localText(state, .transition_source), null);
        var from_state = transition.from_state;
        if (drawStateCombo("##graph_transition_source", editable_graph, &from_state)) {
            transition.from_state = from_state;
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .transition_target), null);
        var to_state = transition.to_state;
        if (drawStateCombo("##graph_transition_target", editable_graph, &to_state)) {
            transition.to_state = to_state;
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .blend_duration), null);
        var duration = transition.duration;
        if (gui.dragFloat("##graph_transition_duration", &duration, 0.01, 0.0, 30.0)) {
            transition.duration = @max(duration, 0.0);
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        layout.drawInspectorPropertyRow(localText(state, .transition_conditions), null);
        if (transition.conditions.len == 0) {
            gui.textWrapped(localText(state, .no_transition_conditions));
        } else {
            const show_condition_list = gui.beginChild("animation_graph_transition_conditions", -1.0, 116.0, true);
            defer gui.endChild();

            if (show_condition_list) {
                for (transition.conditions, 0..) |condition, index| {
                    gui.pushIdU64(index);
                    defer gui.popId();

                    const is_selected = editor_state.selected_transition_condition != null and
                        editor_state.selected_transition_condition.? == index;

                    var condition_buffer: [192]u8 = undefined;
                    if (gui.selectable(
                        transitionConditionLabel(condition, &condition_buffer),
                        is_selected,
                        false,
                        -1.0,
                        22.0,
                    )) {
                        setSelectedTransitionCondition(editor_state, transition, @intCast(index));
                    }
                }
            }
        }
    }

    if (gui.button(localText(state, .add_condition))) {
        transition.addCondition(editable_graph.allocator, .{ .time_elapsed = 0.0 }) catch |err| {
            std.log.err("Failed to add animation graph transition condition: {}", .{err});
            return;
        };
        setSelectedTransitionCondition(editor_state, transition, @as(u32, @intCast(transition.conditions.len - 1)));
        commitGraphAuthoringChange(state, layer_context, editor_state);
    }

    const condition_index = editor_state.selected_transition_condition orelse {
        gui.textWrapped(localText(state, .no_condition_selected));
        if (gui.button(localText(state, .delete_transition))) {
            var removed = editable_graph.transitions.orderedRemove(transition_index);
            removed.deinit(editable_graph.allocator);

            editor_state.selected_transition_condition = null;
            @memset(editor_state.condition_parameter_name_buffer[0..], 0);

            if (editable_graph.transitions.items.len == 0) {
                editor_state.selected_graph_transition = null;
            } else if (transition_index >= editable_graph.transitions.items.len) {
                editor_state.selected_graph_transition = @as(u32, @intCast(editable_graph.transitions.items.len - 1));
            }
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }
        return;
    };

    if (condition_index >= transition.conditions.len) {
        gui.textWrapped(localText(state, .no_condition_selected));
        if (gui.button(localText(state, .delete_transition))) {
            var removed = editable_graph.transitions.orderedRemove(transition_index);
            removed.deinit(editable_graph.allocator);

            editor_state.selected_transition_condition = null;
            @memset(editor_state.condition_parameter_name_buffer[0..], 0);

            if (editable_graph.transitions.items.len == 0) {
                editor_state.selected_graph_transition = null;
            } else if (transition_index >= editable_graph.transitions.items.len) {
                editor_state.selected_graph_transition = @as(u32, @intCast(editable_graph.transitions.items.len - 1));
            }
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }
        return;
    }

    const selected_condition = &transition.conditions[condition_index];
    if (layout.beginInspectorPropertyTable("animation_graph_transition_condition_editor", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow(localText(state, .condition_type), null);
        var condition_type = transitionConditionTypeIndex(selected_condition.*);
        if (drawConditionTypeCombo(state, "##graph_transition_condition_type", &condition_type)) {
            const previous_condition = selected_condition.*;
            const previous_value = @max(transitionConditionNumericValue(previous_condition), 0.0);
            const previous_comparison = switch (previous_condition) {
                .parameter => |parameter| parameter.comparison,
                else => .greater,
            };
            const parameter_name = switch (previous_condition) {
                .parameter => |parameter| parameter.name,
                else => defaultConditionParameterName(editor_state, editable_graph),
            };

            selected_condition.set(editable_graph.allocator, switch (condition_type) {
                0 => .{ .time_elapsed = previous_value },
                1 => .{ .time_remaining = previous_value },
                else => .{
                    .parameter = .{
                        .name = @constCast(parameter_name),
                        .value = previous_value,
                        .comparison = previous_comparison,
                    },
                },
            }) catch |err| {
                std.log.err("Failed to change animation graph condition type: {}", .{err});
            };
            setSelectedTransitionCondition(editor_state, transition, @intCast(condition_index));
            commitGraphAuthoringChange(state, layer_context, editor_state);
        }

        switch (selected_condition.*) {
            .time_elapsed => |*threshold| {
                layout.drawInspectorPropertyRow(localText(state, .threshold), null);
                var value = threshold.*;
                if (gui.dragFloat("##graph_transition_condition_threshold", &value, 0.01, 0.0, 120.0)) {
                    threshold.* = @max(value, 0.0);
                    commitGraphAuthoringChange(state, layer_context, editor_state);
                }
            },
            .time_remaining => |*threshold| {
                layout.drawInspectorPropertyRow(localText(state, .threshold), null);
                var value = threshold.*;
                if (gui.dragFloat("##graph_transition_condition_threshold", &value, 0.01, 0.0, 120.0)) {
                    threshold.* = @max(value, 0.0);
                    commitGraphAuthoringChange(state, layer_context, editor_state);
                }
            },
            .parameter => |*parameter| {
                layout.drawInspectorPropertyRow(localText(state, .parameter_name), null);
                if (editable_graph.parameters.items.len == 0) {
                    if (gui.inputTextWithHint(
                        "##graph_transition_condition_parameter",
                        localText(state, .parameter_name),
                        editor_state.condition_parameter_name_buffer[0..],
                    )) {
                        const next_name = utils.zeroTerminatedSlice(editor_state.condition_parameter_name_buffer[0..]);
                        if (next_name.len != 0 and !std.mem.eql(u8, next_name, parameter.name)) {
                            replaceOwnedText(editable_graph.allocator, &parameter.name, next_name) catch |err| {
                                std.log.err("Failed to rename animation graph condition parameter: {}", .{err});
                            };
                            setSelectedTransitionCondition(editor_state, transition, @intCast(condition_index));
                            commitGraphAuthoringChange(state, layer_context, editor_state);
                        }
                    }
                } else {
                    const preview = if (editable_graph.findParameter(parameter.name)) |parameter_index|
                        editable_graph.parameters.items[parameter_index].name
                    else
                        parameter.name;

                    if (gui.beginCombo("##graph_transition_condition_parameter", preview)) {
                        defer gui.endCombo();

                        for (editable_graph.parameters.items) |graph_parameter| {
                            const is_selected = std.mem.eql(u8, graph_parameter.name, parameter.name);
                            if (gui.selectable(graph_parameter.name, is_selected, false, -1.0, 22.0)) {
                                replaceOwnedText(editable_graph.allocator, &parameter.name, graph_parameter.name) catch |err| {
                                    std.log.err("Failed to assign animation graph condition parameter: {}", .{err});
                                    continue;
                                };
                                setSelectedTransitionCondition(editor_state, transition, @intCast(condition_index));
                                commitGraphAuthoringChange(state, layer_context, editor_state);
                            }
                        }
                    }
                }

                layout.drawInspectorPropertyRow(localText(state, .comparison), null);
                if (drawComparisonCombo("##graph_transition_condition_comparison", &parameter.comparison)) {
                    commitGraphAuthoringChange(state, layer_context, editor_state);
                }

                layout.drawInspectorPropertyRow(localText(state, .threshold), null);
                var value = parameter.value;
                if (gui.dragFloat("##graph_transition_condition_parameter_value", &value, 0.01, -1000.0, 1000.0)) {
                    parameter.value = value;
                    commitGraphAuthoringChange(state, layer_context, editor_state);
                }
            },
        }
    }

    if (gui.button(localText(state, .delete_condition))) {
        transition.removeCondition(editable_graph.allocator, condition_index) catch |err| {
            std.log.err("Failed to remove animation graph transition condition: {}", .{err});
            return;
        };
        syncTransitionConditionSelection(editor_state, transition);
        commitGraphAuthoringChange(state, layer_context, editor_state);
    }

    if (gui.button(localText(state, .delete_transition))) {
        var removed = editable_graph.transitions.orderedRemove(transition_index);
        removed.deinit(editable_graph.allocator);

        editor_state.selected_transition_condition = null;
        @memset(editor_state.condition_parameter_name_buffer[0..], 0);

        if (editable_graph.transitions.items.len == 0) {
            editor_state.selected_graph_transition = null;
        } else if (transition_index >= editable_graph.transitions.items.len) {
            editor_state.selected_graph_transition = @as(u32, @intCast(editable_graph.transitions.items.len - 1));
        }
        commitGraphAuthoringChange(state, layer_context, editor_state);
    }
}

fn deleteTrack(editor_state: *AnimationEditorState, allocator: std.mem.Allocator, index: usize) void {
    if (index >= editor_state.tracks.items.len) {
        return;
    }

    const index_u32: u32 = @intCast(index);
    var removed = editor_state.tracks.orderedRemove(index);
    removed.deinit(allocator);

    if (editor_state.selected_track) |selected_track| {
        if (selected_track == index_u32) {
            editor_state.selected_track = null;
            editor_state.selected_keyframe = null;
        } else if (selected_track > index_u32) {
            editor_state.selected_track = selected_track - 1;
        }
    }
}
