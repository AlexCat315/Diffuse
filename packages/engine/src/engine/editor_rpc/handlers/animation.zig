///! handlers/animation.zig — animation graph editor RPC handler.
///!
///! Provides CRUD operations on animation graphs attached to entities:
///! state management, transitions, conditions, parameters, and runtime control.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const animation_graph_mod = @import("../../animation/animation_graph.zig");
const handles = @import("../../assets/handles.zig");

// ── Helpers ─────────────────────────────────────────────────────

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeJsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => try buf.append(a, c),
        }
    }
    try buf.append(a, '"');
}

fn writeFloat(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: f32) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:.4}", .{v}) catch "0";
    try buf.appendSlice(a, s);
}

fn writeInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    var tmp: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0";
    try buf.appendSlice(a, s);
}

fn parseComparison(s: []const u8) animation_graph_mod.TransitionCondition.Comparison {
    if (strEql(s, "<") or strEql(s, "less")) return .less;
    if (strEql(s, ">") or strEql(s, "greater")) return .greater;
    return .equal;
}

fn comparisonStr(c: anytype) []const u8 {
    return switch (c) {
        .less => "<",
        .greater => ">",
        .equal => "==",
    };
}

// ═══════════════════════════════════════════════════════════════════
//  Public handlers
// ═══════════════════════════════════════════════════════════════════

/// animation.getState(entityId) → full snapshot of animation graph state.
pub fn getState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const world = &ctx.layer.world;

    const entity = world.getEntityConst(entity_id) orelse {
        try ctx.reply(.{ .hasAnimator = false, .hasGraph = false });
        return;
    };

    if (entity.animator == null) {
        try ctx.reply(.{ .hasAnimator = false, .hasGraph = false });
        return;
    }

    const graph = world.animatorGraph(entity_id) orelse {
        try ctx.reply(.{ .hasAnimator = true, .hasGraph = false });
        return;
    };

    const instance = world.animatorGraphInstanceConst(entity_id);
    const runtime = if (instance) |inst| inst.runtimeClipBlend() else null;

    const a = ctx.allocator;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);

    try buf.appendSlice(a, "{\"hasAnimator\":true,\"hasGraph\":true,\"graphName\":");
    try writeJsonStr(&buf, a, graph.name);

    // Current runtime state
    if (runtime) |rt| {
        try buf.appendSlice(a, ",\"currentState\":");
        try writeInt(&buf, a, rt.primary.state_index);
        try buf.appendSlice(a, ",\"sampleTime\":");
        try writeFloat(&buf, a, rt.primary.sample_time);
        if (rt.secondary) |secondary| {
            try buf.appendSlice(a, ",\"nextState\":");
            try writeInt(&buf, a, secondary.state_index);
            try buf.appendSlice(a, ",\"blendFactor\":");
            try writeFloat(&buf, a, rt.blend_factor);
            try buf.appendSlice(a, ",\"transitionTime\":");
            try writeFloat(&buf, a, rt.transition_time);
            try buf.appendSlice(a, ",\"transitionDuration\":");
            try writeFloat(&buf, a, rt.transition_duration);
        }
    }

    if (graph.default_state) |ds| {
        try buf.appendSlice(a, ",\"defaultState\":");
        try writeInt(&buf, a, ds);
    }

    // States
    try buf.appendSlice(a, ",\"states\":[");
    for (graph.states.items, 0..) |state, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"index\":");
        try writeInt(&buf, a, i);
        try buf.appendSlice(a, ",\"name\":");
        try writeJsonStr(&buf, a, state.name);

        if (state.clip_handle) |clip_handle| {
            if (world.resources.animationClip(clip_handle)) |clip| {
                try buf.appendSlice(a, ",\"clipName\":");
                try writeJsonStr(&buf, a, clip.name);
            }
        }

        try buf.appendSlice(a, ",\"speed\":");
        try writeFloat(&buf, a, state.speed);
        try buf.appendSlice(a, if (state.loop) ",\"loop\":true" else ",\"loop\":false");
        try buf.appendSlice(a, ",\"duration\":");
        try writeFloat(&buf, a, state.duration_seconds);

        const is_default = graph.default_state != null and graph.default_state.? == i;
        try buf.appendSlice(a, if (is_default) ",\"isDefault\":true" else ",\"isDefault\":false");

        const is_current = runtime != null and runtime.?.primary.state_index == i;
        try buf.appendSlice(a, if (is_current) ",\"isCurrent\":true" else ",\"isCurrent\":false");

        const is_next = runtime != null and runtime.?.secondary != null and runtime.?.secondary.?.state_index == i;
        try buf.appendSlice(a, if (is_next) ",\"isNext\":true" else ",\"isNext\":false");

        try buf.append(a, '}');
    }
    try buf.append(a, ']');

    // Transitions
    try buf.appendSlice(a, ",\"transitions\":[");
    for (graph.transitions.items, 0..) |transition, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.appendSlice(a, "{\"index\":");
        try writeInt(&buf, a, i);
        try buf.appendSlice(a, ",\"fromState\":");
        try writeInt(&buf, a, transition.from_state);
        try buf.appendSlice(a, ",\"toState\":");
        try writeInt(&buf, a, transition.to_state);
        try buf.appendSlice(a, ",\"fromStateName\":");
        if (transition.from_state < graph.states.items.len) {
            try writeJsonStr(&buf, a, graph.states.items[transition.from_state].name);
        } else {
            try buf.appendSlice(a, "\"?\"");
        }
        try buf.appendSlice(a, ",\"toStateName\":");
        if (transition.to_state < graph.states.items.len) {
            try writeJsonStr(&buf, a, graph.states.items[transition.to_state].name);
        } else {
            try buf.appendSlice(a, "\"?\"");
        }
        try buf.appendSlice(a, ",\"duration\":");
        try writeFloat(&buf, a, transition.duration);

        try buf.appendSlice(a, ",\"conditions\":[");
        for (transition.conditions, 0..) |condition, ci| {
            if (ci > 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"index\":");
            try writeInt(&buf, a, ci);
            switch (condition) {
                .time_elapsed => |v| {
                    try buf.appendSlice(a, ",\"conditionType\":\"time_elapsed\",\"threshold\":");
                    try writeFloat(&buf, a, v);
                },
                .time_remaining => |v| {
                    try buf.appendSlice(a, ",\"conditionType\":\"time_remaining\",\"threshold\":");
                    try writeFloat(&buf, a, v);
                },
                .parameter => |param| {
                    try buf.appendSlice(a, ",\"conditionType\":\"parameter\",\"threshold\":");
                    try writeFloat(&buf, a, param.value);
                    try buf.appendSlice(a, ",\"parameterName\":");
                    try writeJsonStr(&buf, a, param.name);
                    try buf.appendSlice(a, ",\"comparison\":");
                    try writeJsonStr(&buf, a, comparisonStr(param.comparison));
                },
            }
            try buf.append(a, '}');
        }
        try buf.appendSlice(a, "]");
        try buf.append(a, '}');
    }
    try buf.append(a, ']');

    // Parameters
    try buf.appendSlice(a, ",\"parameters\":[");
    if (instance) |inst| {
        for (graph.parameters.items, 0..) |param, i| {
            if (i > 0) try buf.append(a, ',');
            try buf.appendSlice(a, "{\"index\":");
            try writeInt(&buf, a, i);
            try buf.appendSlice(a, ",\"name\":");
            try writeJsonStr(&buf, a, param.name);
            try buf.appendSlice(a, ",\"paramType\":");
            try writeJsonStr(&buf, a, @tagName(param.type));

            if (i < inst.parameters.items.len) {
                switch (inst.parameters.items[i]) {
                    .float => |v| {
                        try buf.appendSlice(a, ",\"floatValue\":");
                        try writeFloat(&buf, a, v);
                    },
                    .bool => |v| {
                        try buf.appendSlice(a, if (v) ",\"boolValue\":true" else ",\"boolValue\":false");
                    },
                    .int => |v| {
                        try buf.appendSlice(a, ",\"intValue\":");
                        var tmp: [16]u8 = undefined;
                        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch "0";
                        try buf.appendSlice(a, s);
                    },
                }
            }
            try buf.append(a, '}');
        }
    }
    try buf.append(a, ']');

    // Clip tracks (from current state's clip)
    const current_clip_handle = if (runtime) |rt|
        if (rt.primary.state_index < graph.states.items.len) graph.states.items[rt.primary.state_index].clip_handle else null
    else if (graph.default_state) |ds|
        if (ds < graph.states.items.len) graph.states.items[ds].clip_handle else null
    else
        null;

    if (current_clip_handle) |clip_handle| {
        if (world.resources.animationClip(clip_handle)) |clip| {
            try buf.appendSlice(a, ",\"clipDuration\":");
            try writeFloat(&buf, a, clip.duration);

            try buf.appendSlice(a, ",\"clipTracks\":[");
            var track_idx: usize = 0;
            for (clip.translation_tracks, 0..) |_, ti| {
                if (track_idx > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(&buf, a, track_idx);
                try buf.appendSlice(a, ",\"name\":\"Translation_");
                try writeInt(&buf, a, ti);
                try buf.appendSlice(a, "\",\"trackType\":\"translation\",\"keyframeCount\":");
                try writeInt(&buf, a, clip.translation_tracks[ti].times.len);
                try buf.append(a, '}');
                track_idx += 1;
            }
            for (clip.rotation_tracks, 0..) |_, ri| {
                if (track_idx > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(&buf, a, track_idx);
                try buf.appendSlice(a, ",\"name\":\"Rotation_");
                try writeInt(&buf, a, ri);
                try buf.appendSlice(a, "\",\"trackType\":\"rotation\",\"keyframeCount\":");
                try writeInt(&buf, a, clip.rotation_tracks[ri].times.len);
                try buf.append(a, '}');
                track_idx += 1;
            }
            for (clip.scale_tracks, 0..) |_, si| {
                if (track_idx > 0) try buf.append(a, ',');
                try buf.appendSlice(a, "{\"index\":");
                try writeInt(&buf, a, track_idx);
                try buf.appendSlice(a, ",\"name\":\"Scale_");
                try writeInt(&buf, a, si);
                try buf.appendSlice(a, "\",\"trackType\":\"scale\",\"keyframeCount\":");
                try writeInt(&buf, a, clip.scale_tracks[si].times.len);
                try buf.append(a, '}');
                track_idx += 1;
            }
            try buf.append(a, ']');
        }
    }

    try buf.append(a, '}');
    ctx.replyRaw(try buf.toOwnedSlice(a));
}

/// animation.addState(entityId, name?) → add a new state to the graph.
pub fn addState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    const name = (try ctx.paramOpt([]const u8, "name")) orelse blk: {
        var tmp: [32]u8 = undefined;
        const default_name = std.fmt.bufPrint(&tmp, "State {}", .{graph.states.items.len + 1}) catch "State";
        break :blk default_name;
    };

    const new_index = try graph.addState(name, null);
    try ctx.reply(.{ .index = new_index });
}

/// animation.updateState(entityId, stateIndex, ...) → update state properties.
pub fn updateState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const state_index: usize = @intCast(try ctx.param(u64, "stateIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (state_index >= graph.states.items.len) return error.InvalidArguments;
    const state = &graph.states.items[state_index];

    if (try ctx.paramOpt([]const u8, "name")) |name| {
        if (name.len > 0 and !std.mem.eql(u8, name, state.name)) {
            const owned = try graph.allocator.dupe(u8, name);
            graph.allocator.free(state.name);
            state.name = owned;
        }
    }
    if (try ctx.paramOpt(f64, "speed")) |v| state.speed = @floatCast(v);
    if (try ctx.paramOpt(bool, "loop")) |v| state.loop = v;
    if (try ctx.paramOpt(f64, "duration")) |v| state.duration_seconds = @max(@as(f32, @floatCast(v)), 0.0);

    // Clip assignment by name
    if (try ctx.paramOpt([]const u8, "clip")) |clip_name| {
        if (clip_name.len == 0) {
            state.clip_handle = null;
        } else {
            // Find clip by name
            for (ctx.layer.world.resources.animation_clips.items, 0..) |clip, i| {
                if (std.mem.eql(u8, clip.name, clip_name)) {
                    state.clip_handle = handles.animationClipHandle(i);
                    if (state.duration_seconds <= 0.0001) {
                        state.duration_seconds = clip.duration;
                    }
                    break;
                }
            }
        }
    }

    try ctx.reply(.{});
}

/// animation.removeState(entityId, stateIndex) → remove a state.
pub fn removeState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const state_index: usize = @intCast(try ctx.param(u64, "stateIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (state_index >= graph.states.items.len) return error.InvalidArguments;

    var removed = graph.states.orderedRemove(state_index);
    removed.deinit(graph.allocator);

    // Adjust default_state index
    if (graph.default_state) |ds| {
        if (ds == state_index) {
            graph.default_state = null;
        } else if (ds > state_index) {
            graph.default_state = ds - 1;
        }
    }

    // Adjust transition indices
    var to_remove = std.ArrayList(usize).empty;
    defer to_remove.deinit(graph.allocator);
    for (graph.transitions.items, 0..) |*tr, i| {
        if (tr.from_state == state_index or tr.to_state == state_index) {
            try to_remove.append(graph.allocator, i);
        } else {
            if (tr.from_state > state_index) tr.from_state -= 1;
            if (tr.to_state > state_index) tr.to_state -= 1;
        }
    }
    // Remove transitions in reverse order
    var ri = to_remove.items.len;
    while (ri > 0) {
        ri -= 1;
        var tr = graph.transitions.orderedRemove(to_remove.items[ri]);
        tr.deinit(graph.allocator);
    }

    try ctx.reply(.{});
}

/// animation.setDefaultState(entityId, stateIndex) → set default state.
pub fn setDefaultState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const state_index: u32 = @intCast(try ctx.param(u64, "stateIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (state_index >= graph.states.items.len) return error.InvalidArguments;

    graph.default_state = state_index;
    try ctx.reply(.{});
}

/// animation.activateState(entityId, stateIndex) → instantly switch to state.
pub fn activateState(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const state_index: u32 = @intCast(try ctx.param(u64, "stateIndex"));

    const world = &ctx.layer.world;
    const graph = world.animatorGraph(entity_id) orelse return error.InvalidArguments;
    if (state_index >= graph.states.items.len) return error.InvalidArguments;

    if (world.animatorGraphInstance(entity_id)) |instance| {
        instance.current_state = state_index;
        instance.next_state = null;
        instance.transition_time = 0.0;
        instance.transition_duration = 0.0;
        instance.state_time = 0.0;
    }
    try ctx.reply(.{});
}

/// animation.addTransition(entityId, fromState, toState, duration?, triggerTime?)
pub fn addTransition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const from_state: u32 = @intCast(try ctx.param(u64, "fromState"));
    const to_state: u32 = @intCast(try ctx.param(u64, "toState"));
    const duration: f32 = @floatCast((try ctx.paramOpt(f64, "duration")) orelse 0.2);
    const trigger_time: f32 = @floatCast((try ctx.paramOpt(f64, "triggerTime")) orelse 0.25);

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (from_state >= graph.states.items.len or to_state >= graph.states.items.len) return error.InvalidArguments;

    const conditions = [_]animation_graph_mod.TransitionCondition{
        .{ .time_elapsed = @max(trigger_time, 0.0) },
    };
    try graph.addTransition(from_state, to_state, @max(duration, 0.0), &conditions);
    try ctx.reply(.{ .index = graph.transitions.items.len - 1 });
}

/// animation.updateTransition(entityId, transitionIndex, ...) → update transition properties.
pub fn updateTransition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const transition_index: usize = @intCast(try ctx.param(u64, "transitionIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (transition_index >= graph.transitions.items.len) return error.InvalidArguments;
    const transition = &graph.transitions.items[transition_index];

    if (try ctx.paramOpt(u64, "fromState")) |v| transition.from_state = @intCast(v);
    if (try ctx.paramOpt(u64, "toState")) |v| transition.to_state = @intCast(v);
    if (try ctx.paramOpt(f64, "duration")) |v| transition.duration = @max(@as(f32, @floatCast(v)), 0.0);

    try ctx.reply(.{});
}

/// animation.removeTransition(entityId, transitionIndex)
pub fn removeTransition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const transition_index: usize = @intCast(try ctx.param(u64, "transitionIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (transition_index >= graph.transitions.items.len) return error.InvalidArguments;

    var removed = graph.transitions.orderedRemove(transition_index);
    removed.deinit(graph.allocator);
    try ctx.reply(.{});
}

/// animation.addCondition(entityId, transitionIndex, conditionType, threshold?, parameterName?, comparison?)
pub fn addCondition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const transition_index: usize = @intCast(try ctx.param(u64, "transitionIndex"));
    const condition_type = try ctx.param([]const u8, "conditionType");
    const threshold: f32 = @floatCast((try ctx.paramOpt(f64, "threshold")) orelse 0.0);

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (transition_index >= graph.transitions.items.len) return error.InvalidArguments;
    const transition = &graph.transitions.items[transition_index];

    const condition: animation_graph_mod.TransitionCondition = if (strEql(condition_type, "time_elapsed"))
        .{ .time_elapsed = @max(threshold, 0.0) }
    else if (strEql(condition_type, "time_remaining"))
        .{ .time_remaining = @max(threshold, 0.0) }
    else if (strEql(condition_type, "parameter"))
        .{ .parameter = .{
            .name = @constCast((try ctx.paramOpt([]const u8, "parameterName")) orelse "Parameter"),
            .value = threshold,
            .comparison = parseComparison((try ctx.paramOpt([]const u8, "comparison")) orelse "=="),
        } }
    else
        return error.InvalidArguments;

    try transition.addCondition(graph.allocator, condition);
    try ctx.reply(.{ .index = transition.conditions.len - 1 });
}

/// animation.updateCondition(entityId, transitionIndex, conditionIndex, ...)
pub fn updateCondition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const transition_index: usize = @intCast(try ctx.param(u64, "transitionIndex"));
    const condition_index: usize = @intCast(try ctx.param(u64, "conditionIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (transition_index >= graph.transitions.items.len) return error.InvalidArguments;
    const transition = &graph.transitions.items[transition_index];
    if (condition_index >= transition.conditions.len) return error.InvalidArguments;

    const selected = &transition.conditions[condition_index];

    // If conditionType is provided, replace the condition entirely
    if (try ctx.paramOpt([]const u8, "conditionType")) |ct| {
        const threshold: f32 = @floatCast((try ctx.paramOpt(f64, "threshold")) orelse
            switch (selected.*) {
                .time_elapsed => |v| @as(f64, v),
                .time_remaining => |v| @as(f64, v),
                .parameter => |p| @as(f64, p.value),
            });

        const new_condition: animation_graph_mod.TransitionCondition = if (strEql(ct, "time_elapsed"))
            .{ .time_elapsed = threshold }
        else if (strEql(ct, "time_remaining"))
            .{ .time_remaining = threshold }
        else if (strEql(ct, "parameter"))
            .{ .parameter = .{
                .name = @constCast((try ctx.paramOpt([]const u8, "parameterName")) orelse switch (selected.*) {
                    .parameter => |p| @as([]const u8, p.name),
                    else => "Parameter",
                }),
                .value = threshold,
                .comparison = parseComparison((try ctx.paramOpt([]const u8, "comparison")) orelse "=="),
            } }
        else
            return error.InvalidArguments;

        try selected.set(graph.allocator, new_condition);
    } else {
        // Update existing condition in-place
        if (try ctx.paramOpt(f64, "threshold")) |v| {
            const threshold: f32 = @floatCast(v);
            switch (selected.*) {
                .time_elapsed => |*val| val.* = threshold,
                .time_remaining => |*val| val.* = threshold,
                .parameter => |*param| param.value = threshold,
            }
        }
        switch (selected.*) {
            .parameter => |*param| {
                if (try ctx.paramOpt([]const u8, "parameterName")) |name| {
                    const owned = try graph.allocator.dupe(u8, name);
                    graph.allocator.free(param.name);
                    param.name = owned;
                }
                if (try ctx.paramOpt([]const u8, "comparison")) |c| {
                    param.comparison = parseComparison(c);
                }
            },
            else => {},
        }
    }

    try ctx.reply(.{});
}

/// animation.removeCondition(entityId, transitionIndex, conditionIndex)
pub fn removeCondition(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const transition_index: usize = @intCast(try ctx.param(u64, "transitionIndex"));
    const condition_index: usize = @intCast(try ctx.param(u64, "conditionIndex"));

    const graph = ctx.layer.world.animatorGraphMutable(entity_id) orelse return error.InvalidArguments;
    if (transition_index >= graph.transitions.items.len) return error.InvalidArguments;
    const transition = &graph.transitions.items[transition_index];

    try transition.removeCondition(graph.allocator, condition_index);
    try ctx.reply(.{});
}

/// animation.setParameter(entityId, parameterIndex, floatValue?, boolValue?, intValue?)
pub fn setParameter(ctx: *Ctx) !void {
    const entity_id_raw: u64 = try ctx.param(u64, "entityId");
    const entity_id: ctx_mod.World.EntityId = @enumFromInt(entity_id_raw);
    const param_index: u32 = @intCast(try ctx.param(u64, "parameterIndex"));

    const world = &ctx.layer.world;

    if (try ctx.paramOpt(f64, "floatValue")) |v| {
        try world.setAnimatorGraphParameter(entity_id, param_index, .{ .float = @floatCast(v) });
    } else if (try ctx.paramOpt(bool, "boolValue")) |v| {
        try world.setAnimatorGraphParameter(entity_id, param_index, .{ .bool = v });
    } else if (try ctx.paramOpt(i64, "intValue")) |v| {
        try world.setAnimatorGraphParameter(entity_id, param_index, .{ .int = @intCast(v) });
    }

    try ctx.reply(.{});
}
