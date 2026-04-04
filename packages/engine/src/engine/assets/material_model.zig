const std = @import("std");
const handles = @import("handles.zig");

pub const MaterialChannel = enum {
    base_color,
    metallic,
    roughness,
    normal,
    occlusion,
    emissive,
    alpha_cutoff,
};

pub const MaterialGraphNodeKind = enum {
    input_parameter,
    constant,
    texture_sample,
    math_add,
    math_multiply,
    split_channels,
    normal_map,
    output,
};

pub const MaterialGraphSocketType = enum {
    scalar,
    vec2,
    vec3,
    vec4,
    texture,
    surface,
};

pub const MaterialGraphValueKind = enum {
    none,
    scalar,
    vec2,
    vec3,
    vec4,
    texture,
};

pub const MaterialGraphValue = struct {
    kind: MaterialGraphValueKind = .none,
    scalar: f32 = 0.0,
    vec2: [2]f32 = .{ 0.0, 0.0 },
    vec3: [3]f32 = .{ 0.0, 0.0, 0.0 },
    vec4: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    texture: ?handles.TextureHandle = null,
};

pub const MaterialGraphNode = struct {
    id: u32,
    kind: MaterialGraphNodeKind,
    output_type: MaterialGraphSocketType = .scalar,
    channel: ?MaterialChannel = null,
    value: MaterialGraphValue = .{},
};

pub const MaterialGraphConnection = struct {
    from_node_id: u32,
    from_slot: u8 = 0,
    to_node_id: u32,
    to_slot: u8 = 0,
};

pub const MaterialGraphOutput = struct {
    channel: MaterialChannel,
    source_node_id: u32,
    source_slot: u8 = 0,
};

pub const MaterialGraph = struct {
    nodes: []MaterialGraphNode = &.{},
    connections: []MaterialGraphConnection = &.{},
    outputs: []MaterialGraphOutput = &.{},

    pub fn isEmpty(self: MaterialGraph) bool {
        return self.nodes.len == 0 and self.connections.len == 0 and self.outputs.len == 0;
    }
};

pub const MaterialInheritanceInfo = struct {
    parent_material_handle: ?handles.MaterialHandle = null,
    parent_material_name_hint: ?[]const u8 = null,
    generation: u32 = 0,

    pub fn hasParent(self: MaterialInheritanceInfo) bool {
        return self.parent_material_handle != null or self.parent_material_name_hint != null;
    }
};

pub fn cloneGraphAlloc(allocator: std.mem.Allocator, graph: MaterialGraph) !MaterialGraph {
    return .{
        .nodes = if (graph.nodes.len == 0) &.{} else try allocator.dupe(MaterialGraphNode, graph.nodes),
        .connections = if (graph.connections.len == 0) &.{} else try allocator.dupe(MaterialGraphConnection, graph.connections),
        .outputs = if (graph.outputs.len == 0) &.{} else try allocator.dupe(MaterialGraphOutput, graph.outputs),
    };
}

pub fn deinitGraph(allocator: std.mem.Allocator, graph: *MaterialGraph) void {
    if (graph.nodes.len > 0) allocator.free(graph.nodes);
    if (graph.connections.len > 0) allocator.free(graph.connections);
    if (graph.outputs.len > 0) allocator.free(graph.outputs);
    graph.* = .{};
}

pub fn hasUsefulInheritance(info: MaterialInheritanceInfo) bool {
    return info.hasParent() or info.generation > 0;
}

test "cloneGraphAlloc duplicates graph arrays" {
    var source_nodes = [_]MaterialGraphNode{.{
        .id = 1,
        .kind = .input_parameter,
        .output_type = .vec4,
        .channel = .base_color,
        .value = .{ .kind = .vec4, .vec4 = .{ 1.0, 0.5, 0.25, 1.0 } },
    }};
    var source_connections = [_]MaterialGraphConnection{.{ .from_node_id = 1, .to_node_id = 2 }};
    var source_outputs = [_]MaterialGraphOutput{.{ .channel = .base_color, .source_node_id = 1 }};
    const source: MaterialGraph = .{
        .nodes = source_nodes[0..],
        .connections = source_connections[0..],
        .outputs = source_outputs[0..],
    };

    var clone = try cloneGraphAlloc(std.testing.allocator, source);
    defer deinitGraph(std.testing.allocator, &clone);

    try std.testing.expectEqual(@as(usize, 1), clone.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), clone.connections.len);
    try std.testing.expectEqual(@as(usize, 1), clone.outputs.len);
    try std.testing.expect(clone.nodes.ptr != source.nodes.ptr);
}
