const std = @import("std");
const engine = @import("guava");
const animation_graph_mod = engine.animation.AnimationGraph;

pub const NodeEditorState = struct {
    pan_offset: [2]f32 = .{ 0, 0 },
    zoom: f32 = 1.0,
    dragging_node: ?u32 = null,
    dragging_canvas: bool = false,
    connecting_from_node: ?u32 = null,
    connecting_to_node: ?u32 = null,
    show_grid: bool = true,
    node_positions: std.AutoHashMap(u32, [2]f32),
    selected_node: ?u32 = null,
    hovered_node: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) NodeEditorState {
        return .{
            .node_positions = std.AutoHashMap(u32, [2]f32).init(allocator),
        };
    }

    pub fn deinit(self: *NodeEditorState) void {
        self.node_positions.deinit();
        self.* = undefined;
    }

    pub fn getNodePosition(self: *const NodeEditorState, node_id: u32, default_x: f32, default_y: f32) [2]f32 {
        return self.node_positions.get(node_id) orelse .{ default_x, default_y };
    }

    pub fn setNodePosition(self: *NodeEditorState, node_id: u32, pos: [2]f32) !void {
        try self.node_positions.put(node_id, pos);
    }

    pub fn screenToCanvas(self: *const NodeEditorState, screen_pos: [2]f32) [2]f32 {
        return .{
            (screen_pos[0] - self.pan_offset[0]) / self.zoom,
            (screen_pos[1] - self.pan_offset[1]) / self.zoom,
        };
    }

    pub fn canvasToScreen(self: *const NodeEditorState, canvas_pos: [2]f32) [2]f32 {
        return .{
            canvas_pos[0] * self.zoom + self.pan_offset[0],
            canvas_pos[1] * self.zoom + self.pan_offset[1],
        };
    }
};

pub const NodeStyle = struct {
    pub const node_radius: f32 = 8.0;
    pub const node_padding: f32 = 12.0;
    pub const slot_radius: f32 = 6.0;
    pub const line_thickness: f32 = 3.0;
    pub const grid_size: f32 = 64.0;

    pub const color_state: [4]f32 = .{ 0.2, 0.4, 0.6, 1.0 };
    pub const color_blend_space: [4]f32 = .{ 0.5, 0.3, 0.6, 1.0 };
    pub const color_transition: [4]f32 = .{ 0.6, 0.5, 0.2, 1.0 };
    pub const color_selected: [4]f32 = .{ 1.0, 0.8, 0.2, 1.0 };
    pub const color_hovered: [4]f32 = .{ 0.8, 0.8, 0.8, 1.0 };
    pub const color_slot_input: [4]f32 = .{ 0.3, 0.8, 0.3, 1.0 };
    pub const color_slot_output: [4]f32 = .{ 0.8, 0.3, 0.3, 1.0 };
    pub const color_grid: [4]f32 = .{ 0.15, 0.15, 0.15, 1.0 };
    pub const color_grid_major: [4]f32 = .{ 0.25, 0.25, 0.25, 1.0 };
    pub const color_connection: [4]f32 = .{ 0.6, 0.6, 0.6, 1.0 };
};

pub fn drawNodeEditor(
    allocator: std.mem.Allocator,
    editor_state: *NodeEditorState,
    graph: *const animation_graph_mod,
    selected_state: *?u32,
    selected_transition: *?u32,
) void {
    _ = allocator;
    _ = editor_state;
    _ = graph;
    _ = selected_state;
    _ = selected_transition;
}
