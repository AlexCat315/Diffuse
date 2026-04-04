const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const i18n = @import("../../../i18n/mod.zig");
const layout = @import("../../layout.zig");
const props = @import("../../properties.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const EditorViewportState = engine.render.EditorViewportState;
const EditorViewportLutPreset = engine.render.EditorViewportLutPreset;

const effect_drag_type = "post_effect";
const graph_node_width: f32 = 196.0;
const graph_node_height: f32 = 96.0;
const graph_node_header_height: f32 = 30.0;
const graph_pin_radius: f32 = 7.0;
const graph_pin_hit_size: f32 = 28.0;
const graph_splitter_width: f32 = 18.0;
const graph_min_palette_width: f32 = 152.0;
const graph_min_inspector_width: f32 = 220.0;
const graph_min_canvas_width: f32 = 240.0;

const ActiveSplitter = enum {
    none,
    palette,
    inspector,
};

const PinKind = enum {
    input,
    output,
};

const EffectPaletteItem = struct {
    effect: PostProcessEffect,
    label: []const u8,
    hint: []const u8,
    color: [4]f32,
};

const all_effects = [_]EffectPaletteItem{
    .{ .effect = .bloom, .label = "Bloom", .hint = "Highlight glow", .color = .{ 1.0, 0.8, 0.2, 1.0 } },
    .{ .effect = .tonemap, .label = "Tonemap", .hint = "Exposure and LUT", .color = .{ 1.0, 0.9, 0.5, 1.0 } },
    .{ .effect = .taa, .label = "TAA", .hint = "Temporal resolve", .color = .{ 0.6, 0.6, 1.0, 1.0 } },
    .{ .effect = .ssr, .label = "SSR", .hint = "Screen-space reflections", .color = .{ 0.4, 0.8, 0.8, 1.0 } },
    .{ .effect = .ssgi, .label = "SSGI", .hint = "Screen-space GI", .color = .{ 0.9, 0.6, 0.2, 1.0 } },
    .{ .effect = .dof, .label = "DOF", .hint = "Depth of field", .color = .{ 0.8, 0.6, 0.4, 1.0 } },
    .{ .effect = .ssao, .label = "SSAO", .hint = "Ambient occlusion", .color = .{ 0.8, 0.4, 0.8, 1.0 } },
    .{ .effect = .fxaa, .label = "FXAA", .hint = "Fast approximate AA", .color = .{ 0.2, 0.8, 1.0, 1.0 } },
    .{ .effect = .color_grading, .label = "Color Grading", .hint = "Tone shaping", .color = .{ 1.0, 0.6, 0.8, 1.0 } },
    .{ .effect = .contact_shadows, .label = "Contact Shadows", .hint = "Small-scale occlusion", .color = .{ 0.5, 0.5, 0.5, 1.0 } },
};

fn effectPaletteItem(effect: PostProcessEffect) EffectPaletteItem {
    for (all_effects) |item| {
        if (item.effect == effect) return item;
    }

    return .{
        .effect = effect,
        .label = "Effect",
        .hint = "",
        .color = .{ 0.5, 0.5, 0.5, 1.0 },
    };
}

pub const PostProcessEffect = enum {
    bloom,
    fxaa,
    ssao,
    ssgi,
    ssr,
    taa,
    dof,
    color_grading,
    contact_shadows,
    tonemap,
};

pub const PostProcessEffectNode = struct {
    effect: PostProcessEffect,
    position: [2]f32 = .{ 0, 0 },
    input_connections: std.ArrayList(usize),
    output_connections: std.ArrayList(usize),

    pub fn init(effect: PostProcessEffect) PostProcessEffectNode {
        return .{
            .effect = effect,
            .input_connections = .empty,
            .output_connections = .empty,
        };
    }

    pub fn deinit(self: *PostProcessEffectNode, allocator: std.mem.Allocator) void {
        self.input_connections.deinit(allocator);
        self.output_connections.deinit(allocator);
        self.* = undefined;
    }

    pub fn getName(self: *const PostProcessEffectNode) []const u8 {
        return switch (self.effect) {
            .bloom => "Bloom",
            .fxaa => "FXAA",
            .ssao => "SSAO",
            .ssgi => "SSGI",
            .ssr => "SSR",
            .taa => "TAA",
            .dof => "DOF",
            .color_grading => "Color Grading",
            .contact_shadows => "Contact Shadows",
            .tonemap => "Tonemap",
        };
    }

    pub fn getColor(self: *const PostProcessEffectNode) [4]f32 {
        return switch (self.effect) {
            .bloom => .{ 1.0, 0.8, 0.2, 1.0 },
            .fxaa => .{ 0.2, 0.8, 1.0, 1.0 },
            .ssao => .{ 0.8, 0.4, 0.8, 1.0 },
            .ssgi => .{ 0.9, 0.6, 0.2, 1.0 },
            .ssr => .{ 0.4, 0.8, 0.8, 1.0 },
            .taa => .{ 0.6, 0.6, 1.0, 1.0 },
            .dof => .{ 0.8, 0.6, 0.4, 1.0 },
            .color_grading => .{ 1.0, 0.6, 0.8, 1.0 },
            .contact_shadows => .{ 0.5, 0.5, 0.5, 1.0 },
            .tonemap => .{ 1.0, 0.9, 0.5, 1.0 },
        };
    }
};

pub const PostProcessPipelineEditorState = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(PostProcessEffectNode),
    selected_node_index: ?usize = null,
    view_pan: [2]f32 = .{ 0, 0 },
    view_zoom: f32 = 1.0,
    connecting_from: ?usize = null,
    preview_split: f32 = 0.42,
    palette_width: f32 = 224.0,
    inspector_width: f32 = 320.0,
    active_splitter: ActiveSplitter = .none,
    splitter_drag_last_mouse_x: f32 = 0.0,
    dragging_node_index: ?usize = null,
    node_drag_offset: [2]f32 = .{ 0.0, 0.0 },

    pub fn init(allocator: std.mem.Allocator) PostProcessPipelineEditorState {
        return .{
            .allocator = allocator,
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *PostProcessPipelineEditorState) void {
        for (self.nodes.items) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addNode(self: *PostProcessPipelineEditorState, effect: PostProcessEffect, x: f32, y: f32) !usize {
        var node = PostProcessEffectNode.init(effect);
        node.position = .{ x, y };
        try self.nodes.append(self.allocator, node);
        return self.nodes.items.len - 1;
    }

    pub fn removeNode(self: *PostProcessPipelineEditorState, index: usize) bool {
        if (index >= self.nodes.items.len) return false;
        self.clearConnectionsForNode(index);
        var node = self.nodes.orderedRemove(index);
        node.deinit(self.allocator);
        for (self.nodes.items) |*other_node| {
            shiftConnectionIndicesAfterRemoval(&other_node.input_connections, index);
            shiftConnectionIndicesAfterRemoval(&other_node.output_connections, index);
        }
        if (self.selected_node_index) |*si| {
            if (si.* == index) {
                self.selected_node_index = null;
            } else if (si.* > index) {
                si.* -= 1;
            }
        }
        if (self.connecting_from) |*from_index| {
            if (from_index.* == index) {
                self.connecting_from = null;
            } else if (from_index.* > index) {
                from_index.* -= 1;
            }
        }
        return true;
    }

    pub fn connect(self: *PostProcessPipelineEditorState, from_index: usize, to_index: usize) !void {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) return;
        if (from_index == to_index) return;
        if (self.hasConnection(from_index, to_index)) return;

        try self.nodes.items[from_index].output_connections.append(self.allocator, to_index);
        try self.nodes.items[to_index].input_connections.append(self.allocator, from_index);
    }

    pub fn hasConnection(self: *const PostProcessPipelineEditorState, from_index: usize, to_index: usize) bool {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) return false;
        for (self.nodes.items[from_index].output_connections.items) |existing| {
            if (existing == to_index) return true;
        }
        return false;
    }

    pub fn disconnect(self: *PostProcessPipelineEditorState, from_index: usize, to_index: usize) void {
        if (from_index >= self.nodes.items.len or to_index >= self.nodes.items.len) return;
        const from_node = &self.nodes.items[from_index];
        var i: usize = 0;
        while (i < from_node.output_connections.items.len) {
            if (from_node.output_connections.items[i] == to_index) {
                _ = from_node.output_connections.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        const to_node = &self.nodes.items[to_index];
        var j: usize = 0;
        while (j < to_node.input_connections.items.len) {
            if (to_node.input_connections.items[j] == from_index) {
                _ = to_node.input_connections.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }

    pub fn clearConnectionsForNode(self: *PostProcessPipelineEditorState, index: usize) void {
        if (index >= self.nodes.items.len) return;

        while (self.nodes.items[index].output_connections.items.len > 0) {
            const to_index = self.nodes.items[index].output_connections.items[self.nodes.items[index].output_connections.items.len - 1];
            self.disconnect(index, to_index);
        }
        while (self.nodes.items[index].input_connections.items.len > 0) {
            const from_index = self.nodes.items[index].input_connections.items[self.nodes.items[index].input_connections.items.len - 1];
            self.disconnect(from_index, index);
        }
    }

    pub fn getSelectedNode(self: *const PostProcessPipelineEditorState) ?*PostProcessEffectNode {
        if (self.selected_node_index) |index| {
            if (index < self.nodes.items.len) {
                return &self.nodes.items[index];
            }
        }
        return null;
    }

    pub fn syncGraphToViewportState(self: *const PostProcessPipelineEditorState, viewport_state: *EditorViewportState) void {
        var has_bloom = false;
        var has_tonemap = false;
        var has_fxaa = false;
        var has_ssao = false;
        var has_ssgi = false;
        var has_ssr = false;
        var has_taa = false;
        var has_dof = false;
        var has_color_grading = false;
        var has_contact_shadows = false;

        for (self.nodes.items) |node| {
            switch (node.effect) {
                .bloom => has_bloom = true,
                .tonemap => has_tonemap = true,
                .fxaa => has_fxaa = true,
                .ssao => has_ssao = true,
                .ssgi => has_ssgi = true,
                .ssr => has_ssr = true,
                .taa => has_taa = true,
                .dof => has_dof = true,
                .color_grading => has_color_grading = true,
                .contact_shadows => has_contact_shadows = true,
            }
        }

        viewport_state.bloom_enabled = has_bloom;
        viewport_state.exposure_enabled = has_tonemap;
        viewport_state.lut_enabled = has_tonemap;
        viewport_state.fxaa_enabled = has_fxaa;
        viewport_state.ssao_enabled = has_ssao;
        viewport_state.ssgi_enabled = has_ssgi;
        viewport_state.ssr_enabled = has_ssr;
        viewport_state.taa_enabled = has_taa;
        viewport_state.dof_enabled = has_dof;
        viewport_state.color_grading_enabled = has_color_grading;
        viewport_state.contact_shadows_enabled = has_contact_shadows;
    }
};

fn shiftConnectionIndicesAfterRemoval(list: *std.ArrayList(usize), removed_index: usize) void {
    for (list.items) |*connection_index| {
        if (connection_index.* > removed_index) {
            connection_index.* -= 1;
        }
    }
}

pub fn drawPostProcessPipelineEditorWindow(
    editor_state_: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
) !void {
    editor_state.syncGraphToViewportState(viewport_state);

    var title_buffer: [80]u8 = undefined;
    const title = try editor_state_.windowLabel(&title_buffer, .post_process_pipeline, "post_process_panel");
    const open_window = gui.beginWindowOpen(title, &editor_state_.post_process_editor_open);
    floating_window_blocker.registerCurrentWindow("post_process_panel");
    if (!open_window) {
        gui.endWindow();
        return;
    }
    defer gui.endWindow();

    const node_count = editor_state.nodes.items.len;

    drawPipelineToolbar(editor_state_, editor_state, node_count);
    gui.separator();

    const content_region = gui.contentRegionAvail();
    const has_nodes = node_count != 0;
    clampPipelinePanelWidths(editor_state, content_region[0]);

    const graph_width = @max(
        graph_min_canvas_width,
        content_region[0] - editor_state.palette_width - editor_state.inspector_width - graph_splitter_width * 2.0,
    );

    if (gui.beginChild("effect_palette", editor_state.palette_width, -1.0, true)) {
        drawEffectPalette(editor_state, .{ graph_width, content_region[1] });
    }
    gui.endChild();

    gui.sameLine();
    drawVerticalSplitter(
        layer_context.input,
        "post_process_palette_splitter",
        editor_state,
        .palette,
        content_region[1],
        &editor_state.palette_width,
        graph_min_palette_width,
        @max(graph_min_palette_width, content_region[0] - graph_min_canvas_width - editor_state.inspector_width - graph_splitter_width * 2.0),
        1.0,
    );

    gui.sameLine();
    if (gui.beginChild("pipeline_graph", graph_width, -1.0, true)) {
        try drawPipelineGraph(editor_state_, layer_context.input, editor_state, has_nodes);
    }
    gui.endChild();

    gui.sameLine();
    drawVerticalSplitter(
        layer_context.input,
        "post_process_inspector_splitter",
        editor_state,
        .inspector,
        content_region[1],
        &editor_state.inspector_width,
        graph_min_inspector_width,
        @max(graph_min_inspector_width, content_region[0] - graph_min_canvas_width - editor_state.palette_width - graph_splitter_width * 2.0),
        -1.0,
    );

    gui.sameLine();
    if (gui.beginChild("effect_inspector", -1.0, -1.0, true)) {
        drawInspectorPanel(editor_state_, editor_state, viewport_state);
    }
    gui.endChild();
}

fn clampPipelinePanelWidths(editor_state: *PostProcessPipelineEditorState, total_width: f32) void {
    const max_palette = @max(
        graph_min_palette_width,
        total_width - graph_min_canvas_width - graph_min_inspector_width - graph_splitter_width * 2.0,
    );
    editor_state.palette_width = std.math.clamp(editor_state.palette_width, graph_min_palette_width, max_palette);

    const max_inspector = @max(
        graph_min_inspector_width,
        total_width - graph_min_canvas_width - editor_state.palette_width - graph_splitter_width * 2.0,
    );
    editor_state.inspector_width = std.math.clamp(editor_state.inspector_width, graph_min_inspector_width, max_inspector);
}

fn drawVerticalSplitter(
    input: *const engine.core.InputState,
    id: []const u8,
    editor_state: *PostProcessPipelineEditorState,
    splitter_kind: ActiveSplitter,
    height: f32,
    width_value: *f32,
    min_width: f32,
    max_width: f32,
    delta_sign: f32,
) void {
    const draw_list = gui.getWindowDrawList();
    const splitter_height = @max(height, 1.0);
    _ = gui.invisibleButton(id, graph_splitter_width, splitter_height);
    const item_min = gui.getItemRectMin();
    const item_max = gui.getItemRectMax();
    const hovered = gui.isItemHovered();
    const active = gui.isItemActive() or editor_state.active_splitter == splitter_kind;

    const mouse_x = gui.mousePos()[0];

    if (hovered and input.wasMousePressed(.left)) {
        editor_state.active_splitter = splitter_kind;
        editor_state.splitter_drag_last_mouse_x = mouse_x;
    }
    if (active) {
        if (input.isMouseDown(.left)) {
            const delta_x = mouse_x - editor_state.splitter_drag_last_mouse_x;
            editor_state.splitter_drag_last_mouse_x = mouse_x;
            width_value.* = std.math.clamp(width_value.* + delta_x * delta_sign, min_width, max_width);
        } else {
            editor_state.active_splitter = .none;
        }
    }

    const bg = if (active)
        gui.getColorU32(.{ 0.28, 0.49, 0.72, 0.45 })
    else if (hovered)
        gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.10 })
    else
        gui.getColorU32(.{ 1.0, 1.0, 1.0, 0.04 });
    draw_list.addRectFilled(item_min, item_max, bg, 3.0, 0);

    const line_x = (item_min[0] + item_max[0]) * 0.5;
    draw_list.addLine(
        .{ line_x, item_min[1] + 8.0 },
        .{ line_x, item_max[1] - 8.0 },
        gui.getColorU32(.{ 0.72, 0.76, 0.82, if (hovered or active) 0.85 else 0.45 }),
        1.0,
    );
}

fn drawInspectorPanel(
    state: *const EditorState,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
) void {
    drawPreviewPanel(state, viewport_state);
    gui.separator();

    if (editor_state.selected_node_index) |selected_index| {
        if (editor_state.getSelectedNode()) |node| {
            drawConnectionInspector(editor_state, selected_index, node);
            gui.separator();
            drawEffectParameters(state, editor_state, viewport_state, selected_index, node);
            return;
        }
    }

    if (editor_state.nodes.items.len != 0) {
        drawEmptySelectionState(state);
    } else {
        gui.textWrapped("Add an effect from the palette, drag nodes on the canvas, and click output then input pins to wire the stack.");
    }
}

fn drawConnectionInspector(
    editor_state: *PostProcessPipelineEditorState,
    selected_index: usize,
    node: *PostProcessEffectNode,
) void {
    gui.text("Connections");
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, "Click an output pin, then an input pin, to create a link.");
    var connection_buf: [64]u8 = undefined;
    const connection_text = std.fmt.bufPrint(
        &connection_buf,
        "Incoming {d}  Outgoing {d}",
        .{ node.input_connections.items.len, node.output_connections.items.len },
    ) catch "Incoming 0  Outgoing 0";
    gui.textColored(.{ 0.82, 0.86, 0.92, 1.0 }, connection_text);
    if (gui.button("Clear Links")) {
        editor_state.clearConnectionsForNode(selected_index);
    }
}

fn drawPipelineToolbar(
    state: *const EditorState,
    editor_state: *PostProcessPipelineEditorState,
    node_count: usize,
) void {
    if (gui.button(state.text(.post_process_clear_all))) {
        clearAllNodes(editor_state);
    }

    gui.sameLine();
    if (gui.button("Auto Arrange")) {
        autoArrangeNodes(editor_state);
    }

    gui.sameLine();
    if (gui.button("Reset View")) {
        editor_state.view_pan = .{ 0.0, 0.0 };
    }

    gui.sameLine();
    gui.text(state.text(.post_process_preview));

    gui.dummy(0.0, 6.0);
    var summary_buf: [128]u8 = undefined;
    const summary_text = i18n.bufPrintMessage(
        &summary_buf,
        .post_process_graph_nodes_fmt,
        state.language,
        .{node_count},
    ) catch state.text(.post_process_pipeline);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, summary_text);

    if (node_count == 0) {
        gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_toolbar_empty_hint));
    } else {
        gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, "Drag cards freely, middle-drag the canvas, and single-click pins to connect nodes.");
    }
}

fn autoArrangeNodes(editor_state: *PostProcessPipelineEditorState) void {
    if (editor_state.nodes.items.len == 0) return;

    const column_count: usize = if (editor_state.nodes.items.len > 6) 2 else 1;
    for (editor_state.nodes.items, 0..) |*node, index| {
        const column = index % column_count;
        const row = index / column_count;
        node.position[0] = 72.0 + @as(f32, @floatFromInt(column)) * (graph_node_width + 120.0);
        node.position[1] = 64.0 + @as(f32, @floatFromInt(row)) * (graph_node_height + 52.0);
    }
    editor_state.view_pan = .{ 0.0, 0.0 };
}

fn drawPipelineGraph(
    state: *const EditorState,
    input: *const engine.core.InputState,
    editor_state: *PostProcessPipelineEditorState,
    has_nodes: bool,
) !void {
    const canvas_size = gui.contentRegionAvail();
    const canvas_min = gui.cursorScreenPos();
    gui.dummy(canvas_size[0], canvas_size[1]);
    const canvas_max = .{ canvas_min[0] + canvas_size[0], canvas_min[1] + canvas_size[1] };
    const mouse = gui.mousePos();
    const inside_canvas = pointInRect(mouse, canvas_min, canvas_max);

    const hovered_output_pin = hitTestPin(editor_state, canvas_min, mouse, .output);
    const hovered_input_pin = hitTestPin(editor_state, canvas_min, mouse, .input);
    const hovered_node = if (hovered_output_pin != null or hovered_input_pin != null)
        null
    else
        hitTestNode(editor_state, canvas_min, mouse);

    drawPipelineCanvasBackground(editor_state, canvas_min, canvas_max);
    handleCanvasPanning(input, editor_state, canvas_min, canvas_size);

    if (editor_state.dragging_node_index) |dragging_index| {
        if (!input.isMouseDown(.left)) {
            editor_state.dragging_node_index = null;
        } else if (dragging_index < editor_state.nodes.items.len) {
            editor_state.nodes.items[dragging_index].position = .{
                mouse[0] - canvas_min[0] - editor_state.view_pan[0] - editor_state.node_drag_offset[0],
                mouse[1] - canvas_min[1] - editor_state.view_pan[1] - editor_state.node_drag_offset[1],
            };
        }
    } else if (inside_canvas and input.wasMousePressed(.left)) {
        if (hovered_output_pin) |from_index| {
            if (editor_state.connecting_from != null and editor_state.connecting_from.? == from_index) {
                editor_state.connecting_from = null;
            } else {
                editor_state.connecting_from = from_index;
                editor_state.selected_node_index = from_index;
            }
        } else if (hovered_input_pin) |to_index| {
            if (editor_state.connecting_from) |from_index| {
                if (from_index != to_index) {
                    editor_state.connect(from_index, to_index) catch {};
                }
                editor_state.connecting_from = null;
                editor_state.selected_node_index = to_index;
            } else {
                editor_state.selected_node_index = to_index;
            }
        } else if (hovered_node) |node_index| {
            editor_state.selected_node_index = node_index;
            editor_state.dragging_node_index = node_index;
            const node_screen_min = nodeScreenMin(editor_state, canvas_min, node_index);
            editor_state.node_drag_offset = .{
                mouse[0] - node_screen_min[0],
                mouse[1] - node_screen_min[1],
            };
            editor_state.nodes.items[node_index].position = .{
                mouse[0] - canvas_min[0] - editor_state.view_pan[0] - editor_state.node_drag_offset[0],
                mouse[1] - canvas_min[1] - editor_state.view_pan[1] - editor_state.node_drag_offset[1],
            };
            editor_state.connecting_from = null;
        } else {
            editor_state.selected_node_index = null;
            editor_state.connecting_from = null;
        }
    }

    gui.pushClipRect(canvas_min, canvas_max, true);
    defer gui.popClipRect();

    if (!has_nodes) {
        drawEmptyPipelineCanvas(state, editor_state, canvas_size);
        try handleCanvasDrop(editor_state, canvas_min, canvas_size);
        return;
    }

    drawConnectionLines(editor_state, canvas_min, graph_node_width, graph_node_height * 0.5);
    drawPendingConnection(editor_state, canvas_min, graph_node_width, graph_node_height * 0.5);

    for (editor_state.nodes.items, 0..) |*node, index| {
        if (editor_state.selected_node_index != null and editor_state.selected_node_index.? == index) continue;
        drawPipelineNode(
            editor_state,
            node,
            index,
            canvas_min,
            hovered_node != null and hovered_node.? == index,
            hovered_input_pin != null and hovered_input_pin.? == index,
            hovered_output_pin != null and hovered_output_pin.? == index,
        );
    }
    if (editor_state.selected_node_index) |selected_index| {
        if (selected_index < editor_state.nodes.items.len) {
            drawPipelineNode(
                editor_state,
                &editor_state.nodes.items[selected_index],
                selected_index,
                canvas_min,
                hovered_node != null and hovered_node.? == selected_index,
                hovered_input_pin != null and hovered_input_pin.? == selected_index,
                hovered_output_pin != null and hovered_output_pin.? == selected_index,
            );
        }
    }

    try handleCanvasDrop(editor_state, canvas_min, canvas_size);
}

fn drawPipelineCanvasBackground(
    editor_state: *const PostProcessPipelineEditorState,
    canvas_min: [2]f32,
    canvas_max: [2]f32,
) void {
    const draw_list = gui.getWindowDrawList();
    draw_list.addRectFilled(canvas_min, canvas_max, gui.getColorU32(.{ 0.075, 0.082, 0.095, 1.0 }), 10.0, 0);

    const fine_step: f32 = 28.0;
    const major_step = fine_step * 4.0;
    const width = canvas_max[0] - canvas_min[0];
    const height = canvas_max[1] - canvas_min[1];
    const fine_offset_x = @mod(editor_state.view_pan[0], fine_step);
    const fine_offset_y = @mod(editor_state.view_pan[1], fine_step);

    var x = canvas_min[0] + fine_offset_x;
    while (x < canvas_min[0] + width) : (x += fine_step) {
        const is_major = @mod(x - canvas_min[0], major_step) < 0.5 or @mod(x - canvas_min[0], major_step) > major_step - 0.5;
        draw_list.addLine(
            .{ x, canvas_min[1] },
            .{ x, canvas_max[1] },
            gui.getColorU32(if (is_major) .{ 1.0, 1.0, 1.0, 0.08 } else .{ 1.0, 1.0, 1.0, 0.035 }),
            1.0,
        );
    }

    var y = canvas_min[1] + fine_offset_y;
    while (y < canvas_min[1] + height) : (y += fine_step) {
        const is_major = @mod(y - canvas_min[1], major_step) < 0.5 or @mod(y - canvas_min[1], major_step) > major_step - 0.5;
        draw_list.addLine(
            .{ canvas_min[0], y },
            .{ canvas_max[0], y },
            gui.getColorU32(if (is_major) .{ 1.0, 1.0, 1.0, 0.08 } else .{ 1.0, 1.0, 1.0, 0.035 }),
            1.0,
        );
    }
}

fn drawPendingConnection(
    editor_state: *const PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    node_width: f32,
    pin_offset_y: f32,
) void {
    if (editor_state.connecting_from) |from_idx| {
        if (from_idx >= editor_state.nodes.items.len) return;
        const draw_list = gui.getWindowDrawList();
        const mouse = gui.mousePos();
        const from_node = &editor_state.nodes.items[from_idx];
        const from_x = canvas_pos[0] + from_node.position[0] + editor_state.view_pan[0] + node_width;
        const from_y = canvas_pos[1] + from_node.position[1] + editor_state.view_pan[1] + pin_offset_y;
        const p0 = [2]f32{ from_x, from_y };
        const p1 = [2]f32{ mouse[0], mouse[1] };
        const dx = @max(p1[0] - p0[0], 72.0);
        const cp0 = [2]f32{ p0[0] + dx * 0.45, p0[1] };
        const cp1 = [2]f32{ p1[0] - dx * 0.45, p1[1] };
        const color = from_node.getColor();
        draw_list.addBezierCurve(p0, cp0, cp1, p1, gui.getColorU32(.{ color[0], color[1], color[2], 0.65 }), 2.5, 24);
    }
}

fn drawPipelineNode(
    editor_state: *PostProcessPipelineEditorState,
    node: *PostProcessEffectNode,
    index: usize,
    canvas_pos: [2]f32,
    is_hovered: bool,
    input_pin_hovered: bool,
    output_pin_hovered: bool,
) void {
    const draw_list = gui.getWindowDrawList();
    const item = effectPaletteItem(node.effect);
    const is_selected = editor_state.selected_node_index != null and editor_state.selected_node_index.? == index;
    const node_pos = [2]f32{
        canvas_pos[0] + node.position[0] + editor_state.view_pan[0],
        canvas_pos[1] + node.position[1] + editor_state.view_pan[1],
    };

    gui.pushIdU64(@intCast(index));
    defer gui.popId();

    gui.setCursorScreenPos(.{ node_pos[0] + graph_pin_hit_size * 0.5, node_pos[1] });
    _ = gui.invisibleButton("node_card_body", graph_node_width - graph_pin_hit_size, graph_node_height);

    const card_min = node_pos;
    const card_max = .{ node_pos[0] + graph_node_width, node_pos[1] + graph_node_height };

    const card_bg: [4]f32 = if (is_selected)
        .{ 0.13, 0.16, 0.20, 0.98 }
    else if (is_hovered)
        .{ 0.11, 0.14, 0.18, 0.96 }
    else
        .{ 0.09, 0.11, 0.14, 0.94 };
    draw_list.addRectFilled(card_min, card_max, gui.getColorU32(card_bg), 12.0, 0);
    draw_list.addRectFilled(
        card_min,
        .{ card_max[0], card_min[1] + graph_node_header_height },
        gui.getColorU32(.{ item.color[0] * 0.36, item.color[1] * 0.36, item.color[2] * 0.36, 0.98 }),
        0.0,
        0,
    );

    draw_list.addText(.{ card_min[0] + 14.0, card_min[1] + 9.0 }, gui.getColorU32(.{ 0.96, 0.98, 1.0, 1.0 }), node.getName());
    draw_list.addText(.{ card_min[0] + 14.0, card_min[1] + graph_node_header_height + 10.0 }, gui.getColorU32(.{ 0.68, 0.72, 0.79, 1.0 }), item.hint);

    var detail_buf: [64]u8 = undefined;
    const detail_text = std.fmt.bufPrint(
        &detail_buf,
        "In {d}  Out {d}",
        .{ node.input_connections.items.len, node.output_connections.items.len },
    ) catch "";
    draw_list.addText(.{ card_min[0] + 14.0, card_max[1] - 24.0 }, gui.getColorU32(.{ 0.74, 0.78, 0.84, 1.0 }), detail_text);

    const pin_y = card_min[1] + graph_node_height * 0.5;
    drawNodePin(editor_state, index, true, .{ card_min[0], pin_y }, item.color, input_pin_hovered);
    drawNodePin(editor_state, index, false, .{ card_max[0], pin_y }, item.color, output_pin_hovered);
}

fn drawNodePin(
    editor_state: *PostProcessPipelineEditorState,
    node_index: usize,
    is_input: bool,
    center: [2]f32,
    color: [4]f32,
    hovered: bool,
) void {
    const draw_list = gui.getWindowDrawList();
    _ = editor_state;
    _ = node_index;
    _ = is_input;
    const alpha: f32 = if (hovered) 1.0 else 0.92;
    const radius = if (hovered) graph_pin_radius + 1.5 else graph_pin_radius;
    draw_list.addCircleFilled(center, radius, gui.getColorU32(.{ color[0], color[1], color[2], alpha }), 14);
    draw_list.addCircleFilled(center, radius * 0.45, gui.getColorU32(.{ 0.06, 0.08, 0.10, 0.95 }), 10);
}

fn handleCanvasPanning(
    input: *const engine.core.InputState,
    editor_state: *PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    canvas_size: [2]f32,
) void {
    const mouse = gui.mousePos();
    const inside = mouse[0] >= canvas_pos[0] and mouse[0] <= canvas_pos[0] + canvas_size[0] and
        mouse[1] >= canvas_pos[1] and mouse[1] <= canvas_pos[1] + canvas_size[1];

    if (inside and input.isMouseDown(.middle)) {
        editor_state.view_pan[0] += input.mouse_delta[0];
        editor_state.view_pan[1] += input.mouse_delta[1];
    }
}

fn pointInRect(point: [2]f32, rect_min: [2]f32, rect_max: [2]f32) bool {
    return point[0] >= rect_min[0] and point[0] <= rect_max[0] and
        point[1] >= rect_min[1] and point[1] <= rect_max[1];
}

fn pointInCircle(point: [2]f32, center: [2]f32, radius: f32) bool {
    const dx = point[0] - center[0];
    const dy = point[1] - center[1];
    return dx * dx + dy * dy <= radius * radius;
}

fn nodeScreenMin(editor_state: *const PostProcessPipelineEditorState, canvas_pos: [2]f32, index: usize) [2]f32 {
    const node = &editor_state.nodes.items[index];
    return .{
        canvas_pos[0] + node.position[0] + editor_state.view_pan[0],
        canvas_pos[1] + node.position[1] + editor_state.view_pan[1],
    };
}

fn pinCenter(editor_state: *const PostProcessPipelineEditorState, canvas_pos: [2]f32, index: usize, kind: PinKind) [2]f32 {
    const node_min = nodeScreenMin(editor_state, canvas_pos, index);
    return switch (kind) {
        .input => .{ node_min[0], node_min[1] + graph_node_height * 0.5 },
        .output => .{ node_min[0] + graph_node_width, node_min[1] + graph_node_height * 0.5 },
    };
}

fn hitTestPin(
    editor_state: *const PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    mouse: [2]f32,
    kind: PinKind,
) ?usize {
    if (editor_state.selected_node_index) |selected_index| {
        if (selected_index < editor_state.nodes.items.len and pointInCircle(mouse, pinCenter(editor_state, canvas_pos, selected_index, kind), graph_pin_hit_size * 0.5)) {
            return selected_index;
        }
    }

    var index = editor_state.nodes.items.len;
    while (index > 0) {
        index -= 1;
        if (editor_state.selected_node_index != null and editor_state.selected_node_index.? == index) continue;
        if (pointInCircle(mouse, pinCenter(editor_state, canvas_pos, index, kind), graph_pin_hit_size * 0.5)) {
            return index;
        }
    }
    return null;
}

fn hitTestNode(editor_state: *const PostProcessPipelineEditorState, canvas_pos: [2]f32, mouse: [2]f32) ?usize {
    if (editor_state.selected_node_index) |selected_index| {
        if (selected_index < editor_state.nodes.items.len) {
            const node_min = nodeScreenMin(editor_state, canvas_pos, selected_index);
            const node_max = .{ node_min[0] + graph_node_width, node_min[1] + graph_node_height };
            if (pointInRect(mouse, node_min, node_max)) return selected_index;
        }
    }

    var index = editor_state.nodes.items.len;
    while (index > 0) {
        index -= 1;
        if (editor_state.selected_node_index != null and editor_state.selected_node_index.? == index) continue;
        const node_min = nodeScreenMin(editor_state, canvas_pos, index);
        const node_max = .{ node_min[0] + graph_node_width, node_min[1] + graph_node_height };
        if (pointInRect(mouse, node_min, node_max)) return index;
    }
    return null;
}

fn handleCanvasDrop(
    editor_state: *PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    canvas_size: [2]f32,
) !void {
    const mouse = gui.mousePos();
    const inside = mouse[0] >= canvas_pos[0] and mouse[0] <= canvas_pos[0] + canvas_size[0] and
        mouse[1] >= canvas_pos[1] and mouse[1] <= canvas_pos[1] + canvas_size[1];

    if (!inside) return;

    var effect_val: u64 = 0;
    if (gui.acceptDragDropPayloadU64(effect_drag_type, &effect_val)) {
        const effect: PostProcessEffect = @enumFromInt(effect_val);
        const placement = suggestNodePlacement(
            editor_state,
            .{
                mouse[0] - canvas_pos[0] - editor_state.view_pan[0] - graph_node_width * 0.5,
                mouse[1] - canvas_pos[1] - editor_state.view_pan[1] - graph_node_height * 0.5,
            },
        );
        const local_x = placement[0];
        const local_y = placement[1];
        const idx = try editor_state.addNode(effect, local_x, local_y);
        editor_state.selected_node_index = idx;
    }
}

fn suggestNodePlacement(editor_state: *const PostProcessPipelineEditorState, desired: [2]f32) [2]f32 {
    var candidate = desired;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        var overlaps = false;
        for (editor_state.nodes.items) |node| {
            if (@abs(node.position[0] - candidate[0]) < graph_node_width * 0.6 and
                @abs(node.position[1] - candidate[1]) < graph_node_height * 0.75)
            {
                overlaps = true;
                break;
            }
        }
        if (!overlaps) break;
        candidate[0] += 28.0;
        candidate[1] += 22.0;
    }
    return candidate;
}

fn drawPinHandles(
    editor_state: *PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    node_width: f32,
    pin_offset_y: f32,
    pin_radius: f32,
) void {
    const draw_list = gui.getWindowDrawList();

    for (editor_state.nodes.items) |*node| {
        const cx_out = canvas_pos[0] + node.position[0] + editor_state.view_pan[0] + node_width;
        const cy = canvas_pos[1] + node.position[1] + editor_state.view_pan[1] + pin_offset_y;
        const cx_in = canvas_pos[0] + node.position[0] + editor_state.view_pan[0];

        const col = node.getColor();
        const out_color = gui.getColorU32(.{ col[0], col[1], col[2], 1.0 });
        const in_color = gui.getColorU32(.{ col[0], col[1], col[2], 1.0 });

        draw_list.addCircleFilled(.{ cx_out, cy }, pin_radius, out_color, 10);
        draw_list.addCircleFilled(.{ cx_in, cy }, pin_radius, in_color, 10);
    }
}

fn handleConnectionInteraction(
    editor_state: *PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    node_width: f32,
    pin_offset_y: f32,
    pin_radius: f32,
    canvas_size: [2]f32,
) void {
    const draw_list = gui.getWindowDrawList();
    const mouse = gui.mousePos();

    var output_pin_hovered: ?usize = null;
    var input_pin_hovered: ?usize = null;

    for (editor_state.nodes.items, 0..) |*node, index| {
        const out_cx = canvas_pos[0] + node.position[0] + editor_state.view_pan[0] + node_width;
        const cy = canvas_pos[1] + node.position[1] + editor_state.view_pan[1] + pin_offset_y;
        const in_cx = canvas_pos[0] + node.position[0] + editor_state.view_pan[0];

        const hit_r = pin_radius * 3.0;
        const dx_out = mouse[0] - out_cx;
        const dy_out = mouse[1] - cy;
        if (dx_out * dx_out + dy_out * dy_out <= hit_r * hit_r) {
            output_pin_hovered = index;
        }

        const dx_in = mouse[0] - in_cx;
        const dy_in = mouse[1] - cy;
        if (dx_in * dx_in + dy_in * dy_in <= hit_r * hit_r) {
            input_pin_hovered = index;
        }
    }

    if (editor_state.connecting_from) |from_idx| {
        const from_node = &editor_state.nodes.items[from_idx];
        const from_cx = canvas_pos[0] + from_node.position[0] + editor_state.view_pan[0] + node_width;
        const from_cy = canvas_pos[1] + from_node.position[1] + editor_state.view_pan[1] + pin_offset_y;

        const p0 = [2]f32{ from_cx, from_cy };
        const p1 = [2]f32{ mouse[0], mouse[1] };

        const dx = @max(p1[0] - p0[0], 60.0);
        const cp0 = [2]f32{ p0[0] + dx * 0.5, p0[1] };
        const cp1 = [2]f32{ p1[0] - dx * 0.5, p1[1] };

        const col = from_node.getColor();
        const line_color = gui.getColorU32(.{ col[0], col[1], col[2], 0.5 });
        draw_list.addBezierCurve(p0, cp0, cp1, p1, line_color, 2.0, 16);

        if (input_pin_hovered) |to_idx| {
            if (to_idx != from_idx) {
                var already_connected = false;
                for (from_node.output_connections.items) |existing| {
                    if (existing == to_idx) {
                        already_connected = true;
                        break;
                    }
                }
                if (!already_connected) {
                    editor_state.connect(from_idx, to_idx) catch {};
                }
                editor_state.connecting_from = null;
            }
        }

        if (editor_state.connecting_from != null) {
            const canvas_min = canvas_pos;
            const canvas_max = [2]f32{ canvas_pos[0] + canvas_size[0], canvas_pos[1] + canvas_size[1] };
            if (mouse[0] < canvas_min[0] or mouse[0] > canvas_max[0] or mouse[1] < canvas_min[1] or mouse[1] > canvas_max[1]) {
                editor_state.connecting_from = null;
            }
        }
    } else {
        if (output_pin_hovered) |idx| {
            if (gui.isMouseDoubleClicked(.left)) {
                editor_state.connecting_from = idx;
            }
        }
    }
}

fn drawConnectionLines(
    editor_state: *PostProcessPipelineEditorState,
    canvas_pos: [2]f32,
    node_width: f32,
    pin_offset_y: f32,
) void {
    const draw_list = gui.getWindowDrawList();

    for (editor_state.nodes.items) |*from_node| {
        if (from_node.output_connections.items.len == 0) continue;

        const from_screen_x = canvas_pos[0] + from_node.position[0] + editor_state.view_pan[0] + node_width;
        const from_screen_y = canvas_pos[1] + from_node.position[1] + editor_state.view_pan[1] + pin_offset_y;

        for (from_node.output_connections.items) |to_index| {
            if (to_index >= editor_state.nodes.items.len) continue;
            const to_node = &editor_state.nodes.items[to_index];

            const to_screen_x = canvas_pos[0] + to_node.position[0] + editor_state.view_pan[0];
            const to_screen_y = canvas_pos[1] + to_node.position[1] + editor_state.view_pan[1] + pin_offset_y;

            const p0 = [2]f32{ from_screen_x, from_screen_y };
            const p1 = [2]f32{ to_screen_x, to_screen_y };

            const dx = @max(p1[0] - p0[0], 60.0);
            const cp0 = [2]f32{ p0[0] + dx * 0.5, p0[1] };
            const cp1 = [2]f32{ p1[0] - dx * 0.5, p1[1] };

            const from_color = from_node.getColor();
            const line_color = gui.getColorU32(.{ from_color[0], from_color[1], from_color[2], 0.7 });
            const thickness: f32 = 2.5;
            const segments: i32 = 24;

            draw_list.addBezierCurve(p0, cp0, cp1, p1, line_color, thickness, segments);

            const pin_radius: f32 = 4.5;
            const pin_color = gui.getColorU32(.{ from_color[0], from_color[1], from_color[2], 1.0 });
            draw_list.addCircleFilled(p0, pin_radius, pin_color, 12);
            draw_list.addCircleFilled(p1, pin_radius, pin_color, 12);
        }
    }
}

fn drawEmptyPipelineCanvas(state: *const EditorState, editor_state: *PostProcessPipelineEditorState, canvas_size: [2]f32) void {
    const spacer = @max(canvas_size[1] * 0.12, 16.0);
    gui.dummy(0.0, spacer);

    gui.textColored(.{ 0.92, 0.95, 0.98, 1.0 }, state.text(.post_process_graph_empty_title));
    gui.textWrapped(state.text(.post_process_graph_empty_desc));

    gui.dummy(0.0, 10.0);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_graph_empty_tip));
    _ = editor_state;
}

fn drawEffectPalette(
    editor_state: *PostProcessPipelineEditorState,
    canvas_size: [2]f32,
) void {
    gui.text("Effects");
    gui.separator();
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, "Drag effects onto the canvas or click to drop them into the current view.");
    gui.dummy(0.0, 8.0);

    for (all_effects) |item| {
        gui.pushStyleColor(.button, .{ item.color[0] * 0.35, item.color[1] * 0.35, item.color[2] * 0.35, 0.9 });
        gui.pushStyleColor(.button_hovered, .{ item.color[0] * 0.5, item.color[1] * 0.5, item.color[2] * 0.5, 0.95 });
        gui.pushStyleColor(.button_active, .{ item.color[0] * 0.25, item.color[1] * 0.25, item.color[2] * 0.25, 1.0 });
        defer gui.popStyleColor(3);

        if (gui.buttonEx(item.label, -1.0, 0.0)) {
            const suggested = suggestNodePlacement(
                editor_state,
                .{
                    -editor_state.view_pan[0] + canvas_size[0] * 0.5 - graph_node_width * 0.5,
                    -editor_state.view_pan[1] + canvas_size[1] * 0.28 - graph_node_height * 0.5,
                },
            );
            const next_x = suggested[0];
            const next_y = suggested[1];
            const idx = editor_state.addNode(item.effect, next_x, next_y) catch continue;
            editor_state.selected_node_index = idx;
        }
        if (gui.isItemHovered()) {
            gui.setTooltip(item.hint);
        }

        _ = gui.dragDropSourceU64(effect_drag_type, @intFromEnum(item.effect), item.label);
    }
}

fn drawPreviewPanel(state: *const EditorState, viewport_state: *const EditorViewportState) void {
    gui.text(state.text(.post_process_live_preview_title));
    gui.separator();
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, state.text(.post_process_live_preview_legend));

    gui.dummy(0.0, 6.0);
    gui.text(state.text(.post_process_core));
    drawPreviewCoreStatus(viewport_state);

    gui.dummy(0.0, 6.0);
    gui.text(state.text(.post_process_screen_space));
    drawPreviewScreenStatus(viewport_state);

    gui.dummy(0.0, 8.0);
    var status_buf: [96]u8 = undefined;
    const status_text = i18n.bufPrintMessage(
        &status_buf,
        .post_process_live_preview_enabled_fmt,
        state.language,
        .{enabledEffectCount(viewport_state)},
    ) catch state.text(.post_process_live_preview_title);
    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, status_text);
}

fn drawPreviewCoreStatus(viewport_state: *const EditorViewportState) void {
    const items = [_]PreviewStatusItem{
        .{ .label = "Manual Exposure", .hint = "HDR preview", .value = viewport_state.exposure_enabled },
        .{ .label = "Bloom", .hint = "Glow pass", .value = viewport_state.bloom_enabled },
        .{ .label = "Color Grading", .hint = "Tone shaping", .value = viewport_state.color_grading_enabled },
        .{ .label = "FXAA", .hint = "Fallback AA", .value = viewport_state.fxaa_enabled },
        .{ .label = "TAA", .hint = "Temporal AA", .value = viewport_state.taa_enabled },
        .{ .label = "LUT", .hint = "Look-up table", .value = viewport_state.lut_enabled },
    };
    drawPreviewStatusGrid(items[0..], 138.0);
}

fn drawPreviewScreenStatus(viewport_state: *const EditorViewportState) void {
    const items = [_]PreviewStatusItem{
        .{ .label = "SSAO", .hint = "Ambient occlusion", .value = viewport_state.ssao_enabled },
        .{ .label = "SSGI", .hint = "Global illumination", .value = viewport_state.ssgi_enabled },
        .{ .label = "SSR", .hint = "Screen-space reflections", .value = viewport_state.ssr_enabled },
        .{ .label = "DOF", .hint = "Lens blur", .value = viewport_state.dof_enabled },
        .{ .label = "Contact Shadows", .hint = "Small-scale occlusion", .value = viewport_state.contact_shadows_enabled },
        .{ .label = "RT Shadows", .hint = "Hardware shadow path", .value = viewport_state.rt_shadows_enabled },
    };
    drawPreviewStatusGrid(items[0..], 138.0);
}

const PreviewStatusItem = struct {
    label: []const u8,
    hint: []const u8,
    value: bool,
};

fn drawPreviewStatusGrid(items: []const PreviewStatusItem, min_width_hint: f32) void {
    const columns = layout.responsiveButtonColumns(items.len, min_width_hint);
    const width = layout.responsiveButtonWidth(columns);
    for (items, 0..) |item, index| {
        if (index > 0) {
            layout.advanceResponsiveRow(index, columns);
        }
        drawStatusChip(item.label, width, item.hint, item.value);
    }
}

fn drawStatusChip(label: []const u8, width: f32, hint: []const u8, active: bool) void {
    const bg: [4]f32 = if (active)
        .{ 0.20, 0.53, 0.36, 0.92 }
    else
        .{ 0.14, 0.16, 0.18, 0.82 };

    gui.pushStyleColor(.button, bg);
    gui.pushStyleColor(.button_hovered, bg);
    gui.pushStyleColor(.button_active, bg);
    defer gui.popStyleColor(3);

    _ = gui.buttonEx(label, width, 0.0);
    if (gui.isItemHovered() and hint.len != 0) {
        gui.setTooltip(hint);
    }
}

fn drawEffectParameters(
    state: *const EditorState,
    editor_state: *PostProcessPipelineEditorState,
    viewport_state: *EditorViewportState,
    selected_index: usize,
    node: *PostProcessEffectNode,
) void {
    gui.text(state.text(.post_process_effect_parameters));
    gui.sameLine();
    if (gui.button(state.text(.post_process_remove_node))) {
        _ = editor_state.removeNode(selected_index);
        return;
    }
    gui.separator();

    gui.textColored(.{ 0.62, 0.66, 0.71, 1.0 }, node.getName());
    gui.textWrapped(state.text(.post_process_effect_parameters_desc));

    if (props.beginPropertyGrid("effect_params")) {
        defer props.endPropertyGrid();

        switch (node.effect) {
            .bloom => {
                _ = props.float("Threshold", &viewport_state.bloom_threshold, 0.1, 0.0, 10.0);
                _ = props.float("Intensity", &viewport_state.bloom_intensity, 0.1, 0.0, 5.0);
            },
            .ssao => {
                _ = props.float("Radius", &viewport_state.ssao_radius, 0.1, 0.0, 5.0);
                _ = props.float("Bias", &viewport_state.ssao_bias, 0.01, 0.0, 1.0);
                _ = props.float("Intensity", &viewport_state.ssao_intensity, 0.1, 0.0, 5.0);
                _ = props.float("Power", &viewport_state.ssao_power, 0.1, 0.0, 10.0);
            },
            .ssgi => {
                _ = props.float("Radius", &viewport_state.ssgi_radius, 0.1, 0.1, 10.0);
                _ = props.float("Intensity", &viewport_state.ssgi_intensity, 0.1, 0.0, 10.0);
                _ = props.float("Bias", &viewport_state.ssgi_bias, 0.01, 0.0, 1.0);
                var ray_count: i32 = @intCast(viewport_state.ssgi_ray_count);
                if (props.int("Ray Count", &ray_count, 1.0, 1, 64)) {
                    viewport_state.ssgi_ray_count = @intCast(std.math.clamp(ray_count, 1, 64));
                }
                var step_count: i32 = @intCast(viewport_state.ssgi_step_count);
                if (props.int("Step Count", &step_count, 1.0, 1, 64)) {
                    viewport_state.ssgi_step_count = @intCast(std.math.clamp(step_count, 1, 64));
                }
            },
            .ssr => {
                _ = props.float("Intensity", &viewport_state.ssr_intensity, 0.1, 0.0, 2.0);
                _ = props.float("Ray Step", &viewport_state.ssr_ray_step, 0.01, 0.01, 1.0);
                _ = props.float("Max Distance", &viewport_state.ssr_ray_max_distance, 1.0, 10.0, 500.0);
                _ = props.float("Ray Thickness", &viewport_state.ssr_ray_thickness, 0.01, 0.01, 2.0);
                _ = props.float("Fade Distance", &viewport_state.ssr_fade_distance, 0.1, 0.0, 100.0);
                _ = props.float("Edge Fade", &viewport_state.ssr_edge_fade, 0.01, 0.0, 1.0);
                _ = props.float("Roughness Blur", &viewport_state.ssr_roughness_blur_strength, 0.1, 0.0, 8.0);
            },
            .taa => {
                _ = props.float("Blend Factor", &viewport_state.taa_blend_factor, 0.01, 0.0, 1.0);
                _ = props.float("Motion Blur Scale", &viewport_state.taa_motion_blur_scale, 0.01, 0.0, 2.0);
                _ = props.float("Feedback Min", &viewport_state.taa_feedback_min, 0.01, 0.0, 1.0);
                _ = props.float("Feedback Max", &viewport_state.taa_feedback_max, 0.01, 0.0, 1.0);
            },
            .dof => {
                _ = props.float("Focus Distance", &viewport_state.dof_focus_distance, 1.0, 0.0, 100.0);
                _ = props.float("Focus Range", &viewport_state.dof_focus_range, 0.5, 0.0, 50.0);
                _ = props.float("Blur Radius", &viewport_state.dof_blur_radius, 1.0, 0.0, 50.0);
                _ = props.float("Bokeh Radius", &viewport_state.dof_bokeh_radius, 0.5, 0.0, 32.0);
                _ = props.float("Near Blur", &viewport_state.dof_near_blur, 0.1, 0.0, 50.0);
                _ = props.float("Far Blur", &viewport_state.dof_far_blur, 0.5, 0.0, 250.0);
                var quality: i32 = @intCast(viewport_state.dof_quality);
                if (props.int("Quality", &quality, 1.0, 1, 8)) {
                    viewport_state.dof_quality = @intCast(std.math.clamp(quality, 1, 8));
                }
            },
            .fxaa => {
                gui.textWrapped("No additional parameters.");
            },
            .color_grading => {
                _ = props.float("Saturation", &viewport_state.color_grading_saturation, 0.01, 0.0, 2.0);
                _ = props.float("Contrast", &viewport_state.color_grading_contrast, 0.01, 0.5, 2.0);
                _ = props.float("Gamma", &viewport_state.color_grading_gamma, 0.01, 0.5, 2.0);
            },
            .contact_shadows => {
                _ = props.float("Distance", &viewport_state.contact_shadows_distance, 0.05, 0.05, 2.0);
                _ = props.float("Thickness", &viewport_state.contact_shadows_thickness, 0.01, 0.01, 0.5);
                _ = props.float("Intensity", &viewport_state.contact_shadows_intensity, 0.05, 0.0, 1.0);
                _ = props.float("Bias", &viewport_state.contact_shadows_bias, 0.005, 0.0, 0.1);
                var steps: i32 = @intCast(viewport_state.contact_shadows_steps);
                if (props.int("Steps", &steps, 1.0, 1, 64)) {
                    viewport_state.contact_shadows_steps = @intCast(std.math.clamp(steps, 1, 64));
                }
            },
            .tonemap => {
                _ = props.boolean("Manual Exposure", &viewport_state.exposure_enabled);
                _ = props.float("Exposure", &viewport_state.exposure, 0.01, 0.1, 8.0);
                _ = props.boolean("LUT", &viewport_state.lut_enabled);
                _ = props.float("LUT Intensity", &viewport_state.lut_intensity, 0.01, 0.0, 1.0);
                drawLutPresetProperty(viewport_state);
            },
        }
    }
}

fn drawEmptySelectionState(state: *const EditorState) void {
    gui.text(state.text(.post_process_empty_selection_title));
    gui.textWrapped(state.text(.post_process_empty_selection_desc));
}

fn clearAllNodes(editor_state: *PostProcessPipelineEditorState) void {
    for (editor_state.nodes.items) |*node| {
        node.deinit(editor_state.allocator);
    }
    editor_state.nodes.clearRetainingCapacity();
    editor_state.selected_node_index = null;
    editor_state.connecting_from = null;
}

fn enabledEffectCount(viewport_state: *const EditorViewportState) usize {
    return @as(usize, @intFromBool(viewport_state.exposure_enabled)) +
        @as(usize, @intFromBool(viewport_state.bloom_enabled)) +
        @as(usize, @intFromBool(viewport_state.color_grading_enabled)) +
        @as(usize, @intFromBool(viewport_state.fxaa_enabled)) +
        @as(usize, @intFromBool(viewport_state.ssao_enabled)) +
        @as(usize, @intFromBool(viewport_state.ssgi_enabled)) +
        @as(usize, @intFromBool(viewport_state.ssr_enabled)) +
        @as(usize, @intFromBool(viewport_state.taa_enabled)) +
        @as(usize, @intFromBool(viewport_state.dof_enabled)) +
        @as(usize, @intFromBool(viewport_state.contact_shadows_enabled)) +
        @as(usize, @intFromBool(viewport_state.rt_shadows_enabled)) +
        @as(usize, @intFromBool(viewport_state.lut_enabled));
}

fn drawLutPresetProperty(viewport_state: *EditorViewportState) void {
    const preview = lutPresetLabel(viewport_state.lut_preset);
    if (!props.combo("LUT Preset", preview)) {
        return;
    }
    defer gui.endCombo();

    const presets = [_]EditorViewportLutPreset{ .neutral, .warm, .cool, .filmic };
    for (presets) |preset| {
        const selected = viewport_state.lut_preset == preset;
        if (gui.selectable(lutPresetLabel(preset), selected, false, 0.0, 0.0)) {
            viewport_state.lut_preset = preset;
        }
    }
}

fn lutPresetLabel(preset: EditorViewportLutPreset) []const u8 {
    return switch (preset) {
        .neutral => "Neutral",
        .warm => "Warm",
        .cool => "Cool",
        .filmic => "Filmic",
    };
}
