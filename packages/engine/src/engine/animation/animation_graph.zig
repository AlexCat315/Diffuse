const std = @import("std");
const handles = @import("../assets/handles.zig");

pub const AnimationNodeType = enum {
    state,
    blend_space_1d,
    blend_space_2d,
    blend_tree,
    layer,
};

pub const AnimationState = struct {
    name: []u8,
    clip_handle: ?handles.AnimationClipHandle,
    speed: f32 = 1.0,
    loop: bool = true,
    duration_seconds: f32 = 0.0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const BlendSpacePoint1D = struct {
    position: f32,
    clip_handle: handles.AnimationClipHandle,
};

pub const BlendSpacePoint2D = struct {
    position: [2]f32,
    clip_handle: handles.AnimationClipHandle,
};

pub const BlendSpace1D = struct {
    name: []u8,
    points: []BlendSpacePoint1D,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.points);
        self.* = undefined;
    }

    pub fn sample(self: *const @This(), parameter: f32) ?handles.AnimationClipHandle {
        if (self.points.len == 0) return null;
        if (self.points.len == 1) return self.points[0].clip_handle;

        var lower_index: usize = 0;
        var upper_index: usize = 0;

        for (self.points, 0..) |point, i| {
            if (parameter >= point.position) {
                lower_index = i;
            }
            if (parameter <= point.position and upper_index == 0) {
                upper_index = i;
            }
        }

        if (lower_index == upper_index) {
            return self.points[lower_index].clip_handle;
        }

        const lower = self.points[lower_index];
        const upper = self.points[upper_index];
        const t = if (upper.position - lower.position < 0.001) 0.0 else (parameter - lower.position) / (upper.position - lower.position);

        return if (t < 0.5) lower.clip_handle else upper.clip_handle;
    }
};

pub const BlendSpace2D = struct {
    name: []u8,
    points: []BlendSpacePoint2D,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.points);
        self.* = undefined;
    }

    pub fn sample(self: *const @This(), parameter: [2]f32) ?handles.AnimationClipHandle {
        if (self.points.len == 0) return null;
        if (self.points.len == 1) return self.points[0].clip_handle;

        var closest_index: usize = 0;
        var closest_distance_sq: f32 = std.math.floatMax(f32);

        for (self.points, 0..) |point, i| {
            const dx = parameter[0] - point.position[0];
            const dy = parameter[1] - point.position[1];
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq < closest_distance_sq) {
                closest_distance_sq = dist_sq;
                closest_index = i;
            }
        }

        return self.points[closest_index].clip_handle;
    }
};

pub const BlendTreeNode = struct {
    name: []u8,
    clip_handle: ?handles.AnimationClipHandle,
    position: [2]f32,
    speed: f32 = 1.0,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const BlendTree = struct {
    name: []u8,
    nodes: []BlendTreeNode,
    parameter_x: []u8,
    parameter_y: ?[]u8,
    blend_type: BlendType,

    pub const BlendType = enum { simple_1d, simple_2d, additive };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.nodes) |*node| {
            node.deinit(allocator);
        }
        allocator.free(self.nodes);
        allocator.free(self.parameter_x);
        if (self.parameter_y) |py| {
            allocator.free(py);
        }
        self.* = undefined;
    }

    pub fn sample(self: *const @This(), param_x: f32, param_y: f32) ?handles.AnimationClipHandle {
        if (self.nodes.len == 0) return null;
        if (self.nodes.len == 1) return self.nodes[0].clip_handle;

        switch (self.blend_type) {
            .simple_1d => {
                var lower_index: usize = 0;
                var upper_index: usize = 0;

                for (self.nodes, 0..) |node, i| {
                    if (param_x >= node.position[0]) {
                        lower_index = i;
                    }
                    if (param_x <= node.position[0] and upper_index == 0) {
                        upper_index = i;
                    }
                }

                if (lower_index == upper_index) {
                    return self.nodes[lower_index].clip_handle;
                }

                const lower = self.nodes[lower_index];
                const upper = self.nodes[upper_index];
                const t = if (upper.position[0] - lower.position[0] < 0.001) 0.0 else (param_x - lower.position[0]) / (upper.position[0] - lower.position[0]);

                return if (t < 0.5) lower.clip_handle else upper.clip_handle;
            },
            .simple_2d => {
                var closest_index: usize = 0;
                var closest_distance_sq: f32 = std.math.floatMax(f32);

                for (self.nodes, 0..) |node, i| {
                    const dx = param_x - node.position[0];
                    const dy = param_y - node.position[1];
                    const dist_sq = dx * dx + dy * dy;
                    if (dist_sq < closest_distance_sq) {
                        closest_distance_sq = dist_sq;
                        closest_index = i;
                    }
                }

                return self.nodes[closest_index].clip_handle;
            },
            .additive => {
                return self.nodes[0].clip_handle;
            },
        }
    }
};

pub const TransitionCondition = union(enum) {
    time_remaining: f32,
    time_elapsed: f32,
    parameter: struct {
        name: []u8,
        value: f32,
        comparison: enum { less, greater, equal },
    },

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .parameter => |*param| {
                allocator.free(param.name);
            },
            else => {},
        }
        self.* = undefined;
    }

    pub fn set(self: *@This(), allocator: std.mem.Allocator, condition: TransitionCondition) !void {
        const next = try cloneTransitionCondition(allocator, condition);
        self.deinit(allocator);
        self.* = next;
    }
};

pub const Transition = struct {
    from_state: u32,
    to_state: u32,
    duration: f32 = 0.2,
    conditions: []TransitionCondition,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.conditions) |*condition| {
            condition.deinit(allocator);
        }
        allocator.free(self.conditions);
        self.* = undefined;
    }

    pub fn addCondition(
        self: *@This(),
        allocator: std.mem.Allocator,
        condition: TransitionCondition,
    ) !void {
        const old_conditions = self.conditions;
        const next_conditions = try allocator.alloc(TransitionCondition, old_conditions.len + 1);
        errdefer allocator.free(next_conditions);

        for (old_conditions, 0..) |existing, index| {
            next_conditions[index] = existing;
        }
        next_conditions[old_conditions.len] = try cloneTransitionCondition(allocator, condition);

        allocator.free(old_conditions);
        self.conditions = next_conditions;
    }

    pub fn removeCondition(
        self: *@This(),
        allocator: std.mem.Allocator,
        condition_index: usize,
    ) !void {
        if (condition_index >= self.conditions.len) {
            return error.IndexOutOfBounds;
        }

        const old_conditions = self.conditions;
        const next_conditions = try allocator.alloc(TransitionCondition, old_conditions.len - 1);

        var next_index: usize = 0;
        for (old_conditions, 0..) |existing, index| {
            if (index == condition_index) {
                continue;
            }
            next_conditions[next_index] = existing;
            next_index += 1;
        }

        old_conditions[condition_index].deinit(allocator);
        allocator.free(old_conditions);
        self.conditions = next_conditions;
    }
};

pub const Parameter = struct {
    name: []u8,
    type: ParameterType,
    default_value: ParameterDefaultValue,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ParameterDefaultValue = union(enum) {
    float: f32,
    bool: bool,
    int: i32,
};

pub const AnimationGraph = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    states: std.ArrayList(AnimationState),
    blend_spaces_1d: std.ArrayList(BlendSpace1D),
    blend_spaces_2d: std.ArrayList(BlendSpace2D),
    blend_trees: std.ArrayList(BlendTree),
    transitions: std.ArrayList(Transition),
    parameters: std.ArrayList(Parameter),
    default_state: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !AnimationGraph {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .states = .empty,
            .blend_spaces_1d = .empty,
            .blend_spaces_2d = .empty,
            .blend_trees = .empty,
            .transitions = .empty,
            .parameters = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        const allocator = self.allocator;

        allocator.free(self.name);

        for (self.states.items) |*state| {
            state.deinit(allocator);
        }
        self.states.deinit(allocator);

        for (self.blend_spaces_1d.items) |*blend_space| {
            blend_space.deinit(allocator);
        }
        self.blend_spaces_1d.deinit(allocator);

        for (self.blend_spaces_2d.items) |*blend_space| {
            blend_space.deinit(allocator);
        }
        self.blend_spaces_2d.deinit(allocator);

        for (self.blend_trees.items) |*blend_tree| {
            blend_tree.deinit(allocator);
        }
        self.blend_trees.deinit(allocator);

        for (self.transitions.items) |*transition| {
            transition.deinit(allocator);
        }
        self.transitions.deinit(allocator);

        for (self.parameters.items) |*parameter| {
            parameter.deinit(allocator);
        }
        self.parameters.deinit(allocator);

        self.* = undefined;
    }

    pub fn clone(self: *const @This(), allocator: std.mem.Allocator) !AnimationGraph {
        var graph = try AnimationGraph.init(allocator, self.name);
        errdefer graph.deinit();

        for (self.states.items) |state| {
            const state_index = try graph.addState(state.name, state.clip_handle);
            graph.states.items[state_index].speed = state.speed;
            graph.states.items[state_index].loop = state.loop;
            graph.states.items[state_index].duration_seconds = state.duration_seconds;
        }
        graph.default_state = self.default_state;

        for (self.blend_spaces_1d.items) |blend_space| {
            _ = try graph.addBlendSpace1D(blend_space.name, blend_space.points);
        }
        for (self.blend_spaces_2d.items) |blend_space| {
            _ = try graph.addBlendSpace2D(blend_space.name, blend_space.points);
        }
        for (self.parameters.items) |parameter| {
            switch (parameter.type) {
                .float => try graph.addParameter(parameter.name, .float, .{ .float = parameter.default_value.float }),
                .bool => try graph.addParameter(parameter.name, .bool, .{ .bool = parameter.default_value.bool }),
                .trigger => try graph.addParameter(parameter.name, .trigger, .{ .bool = parameter.default_value.bool }),
                .int => try graph.addParameter(parameter.name, .int, .{ .int = parameter.default_value.int }),
            }
        }
        for (self.transitions.items) |transition| {
            try graph.addTransition(
                transition.from_state,
                transition.to_state,
                transition.duration,
                transition.conditions,
            );
        }

        return graph;
    }

    pub fn addState(self: *@This(), name: []const u8, clip_handle: ?handles.AnimationClipHandle) !u32 {
        const state = AnimationState{
            .name = try self.allocator.dupe(u8, name),
            .clip_handle = clip_handle,
            .speed = 1.0,
            .loop = true,
            .duration_seconds = 0.0,
        };
        try self.states.append(self.allocator, state);
        return @as(u32, @intCast(self.states.items.len - 1));
    }

    pub fn setStateDuration(self: *@This(), state_index: u32, duration_seconds: f32) bool {
        if (state_index >= self.states.items.len or duration_seconds < 0.0) {
            return false;
        }
        self.states.items[state_index].duration_seconds = duration_seconds;
        return true;
    }

    pub fn addBlendSpace1D(self: *@This(), name: []const u8, points: []const BlendSpacePoint1D) !u32 {
        const allocator = self.allocator;

        var owned_points = try allocator.alloc(BlendSpacePoint1D, points.len);
        for (points, 0..) |point, i| {
            owned_points[i] = point;
        }

        const blend_space = BlendSpace1D{
            .name = try allocator.dupe(u8, name),
            .points = owned_points,
        };

        try self.blend_spaces_1d.append(allocator, blend_space);
        return @as(u32, @intCast(self.blend_spaces_1d.items.len - 1));
    }

    pub fn addBlendSpace2D(self: *@This(), name: []const u8, points: []const BlendSpacePoint2D) !u32 {
        const allocator = self.allocator;

        var owned_points = try allocator.alloc(BlendSpacePoint2D, points.len);
        for (points, 0..) |point, i| {
            owned_points[i] = point;
        }

        const blend_space = BlendSpace2D{
            .name = try allocator.dupe(u8, name),
            .points = owned_points,
        };

        try self.blend_spaces_2d.append(allocator, blend_space);
        return @as(u32, @intCast(self.blend_spaces_2d.items.len - 1));
    }

    pub fn addBlendTree(
        self: *@This(),
        name: []const u8,
        nodes: []const BlendTreeNode,
        parameter_x: []const u8,
        parameter_y: ?[]const u8,
        blend_type: BlendTree.BlendType,
    ) !u32 {
        const allocator = self.allocator;

        var owned_nodes = try allocator.alloc(BlendTreeNode, nodes.len);
        errdefer allocator.free(owned_nodes);
        for (nodes, 0..) |node, i| {
            owned_nodes[i] = .{
                .name = try allocator.dupe(u8, node.name),
                .clip_handle = node.clip_handle,
                .position = node.position,
                .speed = node.speed,
            };
        }
        errdefer {
            for (owned_nodes) |*node| {
                node.deinit(allocator);
            }
            allocator.free(owned_nodes);
        }

        const blend_tree = BlendTree{
            .name = try allocator.dupe(u8, name),
            .nodes = owned_nodes,
            .parameter_x = try allocator.dupe(u8, parameter_x),
            .parameter_y = if (parameter_y) |py| try allocator.dupe(u8, py) else null,
            .blend_type = blend_type,
        };

        try self.blend_trees.append(allocator, blend_tree);
        return @as(u32, @intCast(self.blend_trees.items.len - 1));
    }

    pub fn addTransition(self: *@This(), from_state: u32, to_state: u32, duration: f32, conditions: []const TransitionCondition) !void {
        const allocator = self.allocator;

        var owned_conditions = try allocator.alloc(TransitionCondition, conditions.len);
        errdefer allocator.free(owned_conditions);
        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                owned_conditions[initialized].deinit(allocator);
            }
        }
        for (conditions, 0..) |condition, i| {
            owned_conditions[i] = try cloneTransitionCondition(allocator, condition);
            initialized = i + 1;
        }

        const transition = Transition{
            .from_state = from_state,
            .to_state = to_state,
            .duration = duration,
            .conditions = owned_conditions,
        };

        try self.transitions.append(allocator, transition);
    }

    pub fn addParameter(
        self: *@This(),
        name: []const u8,
        parameter_type: ParameterType,
        default_value: ParameterDefaultValue,
    ) !void {
        const allocator = self.allocator;

        const param = Parameter{
            .name = try allocator.dupe(u8, name),
            .type = parameter_type,
            .default_value = switch (parameter_type) {
                .float => .{ .float = default_value.float },
                .bool => .{ .bool = default_value.bool },
                .int => .{ .int = default_value.int },
                .trigger => .{ .bool = default_value.bool },
            },
        };

        try self.parameters.append(allocator, param);
    }

    pub fn findState(self: *const @This(), name: []const u8) ?u32 {
        for (self.states.items, 0..) |state, i| {
            if (std.mem.eql(u8, state.name, name)) {
                return @as(u32, @intCast(i));
            }
        }
        return null;
    }

    pub fn findParameter(self: *const @This(), name: []const u8) ?u32 {
        for (self.parameters.items, 0..) |param, i| {
            if (std.mem.eql(u8, param.name, name)) {
                return @as(u32, @intCast(i));
            }
        }
        return null;
    }
};

pub const RuntimeClipState = struct {
    state_index: u32,
    clip_handle: ?handles.AnimationClipHandle,
    sample_time: f32,
    speed: f32,
    loop: bool,
};

pub const RuntimeClipBlend = struct {
    primary: RuntimeClipState,
    secondary: ?RuntimeClipState = null,
    blend_factor: f32 = 0.0,
    transition_time: f32 = 0.0,
    transition_duration: f32 = 0.0,
};

pub const AnimationGraphInstance = struct {
    allocator: std.mem.Allocator,
    graph: *const AnimationGraph,
    current_state: u32,
    next_state: ?u32 = null,
    transition_time: f32 = 0.0,
    transition_duration: f32 = 0.0,
    parameters: std.ArrayList(ParameterValue),
    state_time: f32 = 0.0,

    pub const ParameterValue = union(enum) {
        float: f32,
        bool: bool,
        int: i32,
    };

    pub fn init(allocator: std.mem.Allocator, graph: *const AnimationGraph) !AnimationGraphInstance {
        var parameters: std.ArrayList(ParameterValue) = .empty;
        try parameters.ensureTotalCapacity(allocator, graph.parameters.items.len);

        for (graph.parameters.items) |param| {
            switch (param.default_value) {
                .float => |v| try parameters.append(allocator, .{ .float = v }),
                .bool => |v| try parameters.append(allocator, .{ .bool = v }),
                .int => |v| try parameters.append(allocator, .{ .int = v }),
            }
        }

        const default_state = graph.default_state orelse 0;
        return .{
            .allocator = allocator,
            .graph = graph,
            .current_state = default_state,
            .parameters = parameters,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.parameters.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setParameter(self: *@This(), index: u32, value: ParameterValue) void {
        if (index >= self.parameters.items.len) return;

        switch (self.parameters.items[index]) {
            .float => self.parameters.items[index] = .{ .float = parameterValueAsFloat(value) },
            .bool => self.parameters.items[index] = .{ .bool = parameterValueAsBool(value) },
            .int => self.parameters.items[index] = .{ .int = parameterValueAsInt(value) },
        }
    }

    pub fn update(self: *@This(), delta_time: f32) void {
        if (self.next_state) |_| {
            self.transition_time += delta_time;
            if (self.transition_time >= self.transition_duration) {
                self.current_state = self.next_state.?;
                self.next_state = null;
                self.transition_time = 0.0;
                self.transition_duration = 0.0;
                self.state_time = 0.0;
            }
        } else {
            self.state_time += delta_time;

            for (self.graph.transitions.items) |transition| {
                if (transition.from_state != self.current_state) continue;

                var all_conditions_met = true;
                for (transition.conditions) |condition| {
                    if (!evaluateCondition(condition, self.graph, self.parameters.items, self.current_state, self.state_time)) {
                        all_conditions_met = false;
                        break;
                    }
                }

                if (all_conditions_met) {
                    self.next_state = transition.to_state;
                    self.transition_time = 0.0;
                    self.transition_duration = transition.duration;
                    self.consumeTransitionTriggers(transition.conditions);
                    break;
                }
            }
        }
    }

    fn consumeTransitionTriggers(self: *@This(), conditions: []const TransitionCondition) void {
        for (conditions) |condition| {
            const parameter_condition = switch (condition) {
                .parameter => |value| value,
                else => continue,
            };

            const parameter_index = self.graph.findParameter(parameter_condition.name) orelse continue;
            if (parameter_index >= self.graph.parameters.items.len or parameter_index >= self.parameters.items.len) {
                continue;
            }
            if (self.graph.parameters.items[parameter_index].type != .trigger) {
                continue;
            }

            self.parameters.items[parameter_index] = .{ .bool = false };
        }
    }

    pub fn getCurrentClip(self: *const @This()) ?handles.AnimationClipHandle {
        if (self.current_state >= self.graph.states.items.len) return null;

        const state = &self.graph.states.items[self.current_state];
        return state.clip_handle;
    }

    pub fn getBlendFactor(self: *const @This()) f32 {
        if (self.next_state == null or self.transition_duration <= 0.0) {
            return 0.0;
        }
        return std.math.clamp(self.transition_time / self.transition_duration, 0.0, 1.0);
    }

    pub fn runtimeClipBlend(self: *const @This()) ?RuntimeClipBlend {
        const primary = runtimeClipState(self.graph, self.current_state, self.state_time) orelse return null;
        var blend = RuntimeClipBlend{
            .primary = primary,
        };
        if (self.next_state) |next_state| {
            blend.secondary = runtimeClipState(self.graph, next_state, self.transition_time);
            blend.blend_factor = self.getBlendFactor();
            blend.transition_time = self.transition_time;
            blend.transition_duration = self.transition_duration;
        }
        return blend;
    }
};

fn cloneTransitionCondition(allocator: std.mem.Allocator, condition: TransitionCondition) !TransitionCondition {
    return switch (condition) {
        .time_remaining => |threshold| .{ .time_remaining = threshold },
        .time_elapsed => |threshold| .{ .time_elapsed = threshold },
        .parameter => |parameter| .{
            .parameter = .{
                .name = try allocator.dupe(u8, parameter.name),
                .value = parameter.value,
                .comparison = parameter.comparison,
            },
        },
    };
}

fn evaluateCondition(
    condition: TransitionCondition,
    graph: *const AnimationGraph,
    parameters: []const AnimationGraphInstance.ParameterValue,
    current_state: u32,
    state_time: f32,
) bool {
    switch (condition) {
        .time_remaining => |threshold| {
            const remaining = stateRemainingSeconds(graph, current_state, state_time) orelse return false;
            return remaining <= threshold;
        },
        .time_elapsed => |threshold| {
            return state_time >= threshold;
        },
        .parameter => |parameter_condition| {
            const parameter_index = graph.findParameter(parameter_condition.name) orelse return false;
            if (parameter_index >= parameters.len) {
                return false;
            }
            return compareParameterValue(parameters[parameter_index], parameter_condition.value, parameter_condition.comparison);
        },
    }
}

fn runtimeClipState(graph: *const AnimationGraph, state_index: u32, state_time: f32) ?RuntimeClipState {
    if (state_index >= graph.states.items.len) {
        return null;
    }

    const state = graph.states.items[state_index];
    return .{
        .state_index = state_index,
        .clip_handle = state.clip_handle,
        .sample_time = stateSampleTime(state, state_time),
        .speed = state.speed,
        .loop = state.loop,
    };
}

fn stateSampleTime(state: AnimationState, state_time: f32) f32 {
    const elapsed = state_time * state.speed;
    if (state.duration_seconds <= 0.0001) {
        return elapsed;
    }
    if (state.loop) {
        return wrapStateTime(elapsed, state.duration_seconds);
    }
    return std.math.clamp(elapsed, 0.0, state.duration_seconds);
}

fn wrapStateTime(time_seconds: f32, duration: f32) f32 {
    var wrapped = @mod(time_seconds, duration);
    if (wrapped < 0.0) {
        wrapped += duration;
    }
    return wrapped;
}

fn stateRemainingSeconds(graph: *const AnimationGraph, current_state: u32, state_time: f32) ?f32 {
    if (current_state >= graph.states.items.len) {
        return null;
    }

    const state = graph.states.items[current_state];
    if (state.duration_seconds <= 0.0) {
        return null;
    }

    const clip_elapsed = @max(0.0, state_time * @max(state.speed, 0.0));
    if (state.loop) {
        const wrapped = @mod(clip_elapsed, state.duration_seconds);
        return state.duration_seconds - wrapped;
    }

    return @max(0.0, state.duration_seconds - clip_elapsed);
}

fn compareParameterValue(
    actual: AnimationGraphInstance.ParameterValue,
    expected: f32,
    comparison: anytype,
) bool {
    const actual_numeric = switch (actual) {
        .float => |value| value,
        .bool => |value| @as(f32, if (value) 1.0 else 0.0),
        .int => |value| @as(f32, @floatFromInt(value)),
    };

    return switch (comparison) {
        .less => actual_numeric < expected,
        .greater => actual_numeric > expected,
        .equal => @abs(actual_numeric - expected) <= 0.0001,
    };
}

fn parameterValueAsFloat(value: AnimationGraphInstance.ParameterValue) f32 {
    return switch (value) {
        .float => |float_value| float_value,
        .bool => |bool_value| if (bool_value) 1.0 else 0.0,
        .int => |int_value| @as(f32, @floatFromInt(int_value)),
    };
}

fn parameterValueAsBool(value: AnimationGraphInstance.ParameterValue) bool {
    return switch (value) {
        .float => |float_value| @abs(float_value) > 0.0001,
        .bool => |bool_value| bool_value,
        .int => |int_value| int_value != 0,
    };
}

fn parameterValueAsInt(value: AnimationGraphInstance.ParameterValue) i32 {
    return switch (value) {
        .float => |float_value| {
            if (!std.math.isFinite(float_value)) {
                return 0;
            }

            const min_value = @as(f32, @floatFromInt(std.math.minInt(i32)));
            const max_value = @as(f32, @floatFromInt(std.math.maxInt(i32)));
            const clamped = std.math.clamp(float_value, min_value, max_value);
            return @as(i32, @intFromFloat(clamped));
        },
        .bool => |bool_value| if (bool_value) 1 else 0,
        .int => |int_value| int_value,
    };
}

pub const ParameterType = enum { float, bool, trigger, int };

test "AnimationGraph basic state management" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TestGraph");
    defer graph.deinit();

    const state1 = try graph.addState("Idle", null);
    const state2 = try graph.addState("Run", null);

    try std.testing.expectEqual(@as(u32, 0), state1);
    try std.testing.expectEqual(@as(u32, 1), state2);

    const found_state1 = graph.findState("Idle");
    try std.testing.expectEqual(@as(?u32, 0), found_state1);

    const not_found = graph.findState("NonExistent");
    try std.testing.expectEqual(@as(?u32, null), not_found);
}

test "AnimationGraphInstance parameter management" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TestGraph");
    defer graph.deinit();

    try graph.addParameter("Speed", .float, .{ .float = 0.0 });
    try graph.addParameter("IsGrounded", .bool, .{ .bool = true });
    try graph.addParameter("Health", .int, .{ .int = 100 });

    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();

    try std.testing.expectEqual(@as(f32, 0.0), instance.parameters.items[0].float);
    try std.testing.expectEqual(true, instance.parameters.items[1].bool);
    try std.testing.expectEqual(@as(i32, 100), instance.parameters.items[2].int);

    instance.setParameter(0, .{ .float = 5.5 });
    try std.testing.expectEqual(@as(f32, 5.5), instance.parameters.items[0].float);
}

test "BlendSpace1D sampling" {
    const points = [_]BlendSpacePoint1D{
        .{ .position = 0.0, .clip_handle = handles.animationClipHandle(0) },
        .{ .position = 5.0, .clip_handle = handles.animationClipHandle(1) },
        .{ .position = 10.0, .clip_handle = handles.animationClipHandle(2) },
    };

    var blend_space = BlendSpace1D{
        .name = try std.testing.allocator.dupe(u8, "SpeedBlend"),
        .points = try std.testing.allocator.dupe(BlendSpacePoint1D, &points),
    };
    defer blend_space.deinit(std.testing.allocator);

    const clip0 = blend_space.sample(0.0);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(0)), clip0);

    const clip5 = blend_space.sample(5.0);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(1)), clip5);

    const clip2_5 = blend_space.sample(2.5);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(1)), clip2_5);
}

test "AnimationGraph transitions deep copy parameter conditions and evaluate parameters" {
    var graph = try AnimationGraph.init(std.testing.allocator, "ParamGraph");
    defer graph.deinit();

    const idle = try graph.addState("Idle", null);
    const run = try graph.addState("Run", null);
    try graph.addParameter("Speed", .float, .{ .float = 0.0 });

    var parameter_name = try std.testing.allocator.dupe(u8, "Speed");
    defer std.testing.allocator.free(parameter_name);

    const conditions = [_]TransitionCondition{
        .{
            .parameter = .{
                .name = parameter_name,
                .value = 0.5,
                .comparison = .greater,
            },
        },
    };
    try graph.addTransition(idle, run, 0.2, &conditions);

    parameter_name[0] = 'X';

    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();

    instance.setParameter(0, .{ .float = 0.75 });
    instance.update(0.016);

    try std.testing.expectEqual(@as(?u32, run), instance.next_state);
}

test "AnimationGraph time remaining condition transitions near state end" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TimeGraph");
    defer graph.deinit();

    const intro = try graph.addState("Intro", null);
    const loop = try graph.addState("Loop", null);
    try std.testing.expect(graph.setStateDuration(intro, 1.0));
    graph.states.items[intro].loop = false;

    const conditions = [_]TransitionCondition{
        .{ .time_remaining = 0.2 },
    };
    try graph.addTransition(intro, loop, 0.15, &conditions);

    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();

    instance.update(0.7);
    try std.testing.expectEqual(@as(?u32, null), instance.next_state);

    instance.update(0.11);
    try std.testing.expectEqual(@as(?u32, loop), instance.next_state);
}

test "AnimationGraph clone preserves state machine data" {
    var graph = try AnimationGraph.init(std.testing.allocator, "CloneGraph");
    defer graph.deinit();

    const idle = try graph.addState("Idle", handles.animationClipHandle(0));
    const run = try graph.addState("Run", handles.animationClipHandle(1));
    graph.states.items[idle].speed = 0.5;
    graph.states.items[idle].loop = false;
    try std.testing.expect(graph.setStateDuration(idle, 1.5));
    graph.default_state = idle;
    try graph.addParameter("Speed", .float, .{ .float = 0.25 });
    const conditions = [_]TransitionCondition{
        .{ .time_elapsed = 0.2 },
    };
    try graph.addTransition(idle, run, 0.3, &conditions);

    var clone = try graph.clone(std.testing.allocator);
    defer clone.deinit();

    try std.testing.expectEqualStrings("CloneGraph", clone.name);
    try std.testing.expectEqual(@as(?u32, idle), clone.default_state);
    try std.testing.expectEqual(@as(usize, 2), clone.states.items.len);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(0)), clone.states.items[idle].clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), clone.states.items[idle].speed, 0.0001);
    try std.testing.expect(!clone.states.items[idle].loop);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), clone.states.items[idle].duration_seconds, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), clone.parameters.items.len);
    try std.testing.expectEqual(@as(f32, 0.25), clone.parameters.items[0].default_value.float);
    try std.testing.expectEqual(@as(usize, 1), clone.transitions.items.len);
    try std.testing.expectEqual(@as(u32, idle), clone.transitions.items[0].from_state);
    try std.testing.expectEqual(@as(u32, run), clone.transitions.items[0].to_state);
}

test "AnimationGraph runtime clip blend reports sample times and transition progress" {
    var graph = try AnimationGraph.init(std.testing.allocator, "RuntimeGraph");
    defer graph.deinit();

    const idle = try graph.addState("Idle", handles.animationClipHandle(2));
    const run = try graph.addState("Run", handles.animationClipHandle(3));
    graph.states.items[idle].speed = 0.5;
    graph.states.items[idle].loop = false;
    try std.testing.expect(graph.setStateDuration(idle, 2.0));
    graph.states.items[run].speed = 2.0;
    try std.testing.expect(graph.setStateDuration(run, 1.0));

    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();

    instance.current_state = idle;
    instance.next_state = run;
    instance.state_time = 1.5;
    instance.transition_time = 0.25;
    instance.transition_duration = 0.5;

    const runtime = instance.runtimeClipBlend().?;
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(2)), runtime.primary.clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), runtime.primary.sample_time, 0.0001);
    try std.testing.expectEqual(@as(?handles.AnimationClipHandle, handles.animationClipHandle(3)), runtime.secondary.?.clip_handle);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), runtime.secondary.?.sample_time, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), runtime.blend_factor, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), runtime.transition_time, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), runtime.transition_duration, 0.0001);
}

test "Transition condition editing preserves owned data and empty slices" {
    var transition = Transition{
        .from_state = 0,
        .to_state = 1,
        .duration = 0.2,
        .conditions = try std.testing.allocator.alloc(TransitionCondition, 1),
    };
    defer transition.deinit(std.testing.allocator);

    transition.conditions[0] = .{
        .parameter = .{
            .name = try std.testing.allocator.dupe(u8, "Speed"),
            .value = 0.5,
            .comparison = .greater,
        },
    };

    try transition.addCondition(std.testing.allocator, .{ .time_elapsed = 0.25 });
    try std.testing.expectEqual(@as(usize, 2), transition.conditions.len);
    try std.testing.expect(transition.conditions[0] == .parameter);
    try std.testing.expect(transition.conditions[1] == .time_elapsed);

    try transition.conditions[0].set(std.testing.allocator, .{ .time_remaining = 0.1 });
    try std.testing.expect(transition.conditions[0] == .time_remaining);

    try transition.removeCondition(std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 1), transition.conditions.len);
    try std.testing.expect(transition.conditions[0] == .time_elapsed);

    try transition.removeCondition(std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), transition.conditions.len);
}

test "AnimationGraph trigger parameters are consumed when transition starts" {
    var graph = try AnimationGraph.init(std.testing.allocator, "TriggerGraph");
    defer graph.deinit();

    const idle = try graph.addState("Idle", handles.animationClipHandle(0));
    const jump = try graph.addState("Jump", handles.animationClipHandle(1));
    const land = try graph.addState("Land", handles.animationClipHandle(2));
    graph.default_state = idle;
    try graph.addParameter("Jump", .trigger, .{ .bool = false });

    const idle_to_jump_conditions = [_]TransitionCondition{
        .{
            .parameter = .{
                .name = try std.testing.allocator.dupe(u8, "Jump"),
                .value = 0.5,
                .comparison = .greater,
            },
        },
    };
    defer std.testing.allocator.free(idle_to_jump_conditions[0].parameter.name);
    try graph.addTransition(idle, jump, 0.1, &idle_to_jump_conditions);

    const jump_to_land_conditions = [_]TransitionCondition{
        .{
            .parameter = .{
                .name = try std.testing.allocator.dupe(u8, "Jump"),
                .value = 0.5,
                .comparison = .greater,
            },
        },
    };
    defer std.testing.allocator.free(jump_to_land_conditions[0].parameter.name);
    try graph.addTransition(jump, land, 0.1, &jump_to_land_conditions);

    var instance = try AnimationGraphInstance.init(std.testing.allocator, &graph);
    defer instance.deinit();

    instance.setParameter(0, .{ .bool = true });
    instance.update(0.0);

    try std.testing.expectEqual(@as(?u32, jump), instance.next_state);
    try std.testing.expectEqual(false, instance.parameters.items[0].bool);

    instance.update(0.1);
    try std.testing.expectEqual(@as(u32, jump), instance.current_state);
    try std.testing.expectEqual(@as(?u32, null), instance.next_state);

    instance.update(0.0);
    try std.testing.expectEqual(@as(?u32, null), instance.next_state);
}
