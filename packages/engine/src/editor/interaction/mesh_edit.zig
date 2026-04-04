const std = @import("std");
const engine = @import("guava");
const state_mod = @import("../core/state.zig");
const history = @import("../actions/history.zig");
const camera = @import("camera.zig");
const manipulation = @import("manipulation.zig");

const EditorState = state_mod.EditorState;
pub const MeshElementSelectionMode = state_mod.MeshElementSelectionMode;
const MeshShortcutBinding = state_mod.MeshShortcutBinding;

pub const Edge = struct {
    a: u32,
    b: u32,
};

pub const ActiveContext = struct {
    entity_id: engine.scene.EntityId,
    mesh_handle: engine.assets.MeshHandle,
    mesh: *const engine.assets.MeshResource,
    world_transform: engine.scene.Transform,
};

const EdgeEntry = struct {
    count: u32 = 0,
    directed_a: u32 = 0,
    directed_b: u32 = 0,
};

const EdgeSplit = struct {
    min_split: u32,
    max_split: u32,
};

const InteractiveMeshOpKind = enum {
    extrude,
    inset,
    bevel,
    loop_cut,
};

const InteractiveMeshOp = struct {
    kind: InteractiveMeshOpKind,
    entity_id: engine.scene.EntityId,
    mesh_handle: engine.assets.MeshHandle,
    selection_mode: MeshElementSelectionMode,
    selected_elements: []u32,
    base_vertices: []engine.assets.MeshVertex,
    base_indices: []u32,
    seed_edge_index: ?u32,
    amount: f32,
    start_amount: f32,
    start_mouse_position: [2]f32,
};

var interactive_mesh_op: ?InteractiveMeshOp = null;

pub fn isEditModeActive(state: *const EditorState) bool {
    return state.mesh_edit_mode == .edit and state.mesh_edit_entity != null;
}

pub fn selectedElements(state: *const EditorState) []const u32 {
    return state.mesh_edit_selected_elements.items;
}

pub fn activeContext(state: *EditorState, layer_context: *engine.core.LayerContext) ?ActiveContext {
    if (!isEditModeActive(state)) {
        return null;
    }

    const entity_id = state.mesh_edit_entity orelse return null;
    const entity = layer_context.world.getEntityConst(entity_id) orelse return null;
    const mesh_component = entity.mesh orelse return null;
    const mesh_handle = mesh_component.handle orelse return null;
    const mesh = layer_context.world.assets().mesh(mesh_handle) orelse return null;
    const world_transform = layer_context.world.worldTransformConst(entity_id) orelse entity.local_transform;
    return .{
        .entity_id = entity_id,
        .mesh_handle = mesh_handle,
        .mesh = mesh,
        .world_transform = world_transform,
    };
}

pub fn canEnterEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) bool {
    _ = state;
    if (layer_context.renderer.selectedEntities().len != 1) {
        return false;
    }
    const entity_id = layer_context.renderer.selectedEntity() orelse return false;
    const entity = layer_context.world.getEntityConst(entity_id) orelse return false;
    if (entity.skinned_mesh != null) {
        return false;
    }
    const mesh_component = entity.mesh orelse return false;
    if (mesh_component.handle != null) {
        return true;
    }
    return mesh_component.primitive != .custom;
}

pub fn toggleEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (isEditModeActive(state)) {
        exitEditMode(state, layer_context);
        return true;
    }
    return enterEditMode(state, layer_context);
}

pub fn enterEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (!canEnterEditMode(state, layer_context)) {
        return false;
    }

    const entity_id = layer_context.renderer.selectedEntity() orelse return false;
    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const mesh_handle = try ensureEditableMeshResource(state, layer_context, entity) orelse return false;
    if (layer_context.world.assets().mesh(mesh_handle) == null) {
        return false;
    }

    state.mesh_edit_mode = .edit;
    state.mesh_edit_entity = entity_id;
    state.mesh_edit_selection_mode = .face;
    clearElementSelection(state);
    manipulation.clearTransformTool(state);
    manipulation.refreshGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
    return true;
}

pub fn exitEditMode(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    cancelInteractiveOperation(state, layer_context) catch {};
    clearElementSelection(state);
    state.mesh_edit_mode = .object;
    state.mesh_edit_entity = null;
    manipulation.refreshGizmoState(state, layer_context);
}

pub fn setSelectionMode(state: *EditorState, mode: MeshElementSelectionMode) void {
    if (state.mesh_edit_selection_mode == mode) {
        return;
    }
    state.mesh_edit_selection_mode = mode;
    clearElementSelection(state);
}

pub fn syncSession(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (!isEditModeActive(state)) {
        return;
    }

    const entity_id = state.mesh_edit_entity orelse {
        exitEditMode(state, layer_context);
        return;
    };

    if (layer_context.renderer.selectedEntities().len != 1 or layer_context.renderer.selectedEntity() != entity_id) {
        exitEditMode(state, layer_context);
        return;
    }

    const entity = layer_context.world.getEntityConst(entity_id) orelse {
        exitEditMode(state, layer_context);
        return;
    };
    if (entity.skinned_mesh != null or entity.mesh == null) {
        exitEditMode(state, layer_context);
        return;
    }
    if ((entity.mesh.?.handle == null and entity.mesh.?.primitive == .custom) or activeContext(state, layer_context) == null) {
        exitEditMode(state, layer_context);
        return;
    }

    try pruneSelectionToCurrentMesh(state, layer_context);
}

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const input = layer_context.input;

    if (input.wasKeyPressed(.tab) and !input.modifiers.shift and !input.modifiers.ctrl and !input.modifiers.alt) {
        if (isEditModeActive(state) or canEnterEditMode(state, layer_context)) {
            _ = try toggleEditMode(state, layer_context);
            return true;
        }
    }

    if (!isEditModeActive(state)) {
        return false;
    }

    if (interactive_mesh_op != null) {
        return try updateInteractiveOperation(state, layer_context);
    }

    if (input.modifiers.shift and input.wasKeyPressed(.tab)) {
        camera.toggleCameraMode(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.one)) {
        setSelectionMode(state, .vertex);
        return true;
    }
    if (input.wasKeyPressed(.two)) {
        setSelectionMode(state, .edge);
        return true;
    }
    if (input.wasKeyPressed(.three)) {
        setSelectionMode(state, .face);
        return true;
    }
    if (input.wasKeyPressed(.delete) or input.wasKeyPressed(.backspace)) {
        _ = try deleteSelectedElements(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.a) and !input.modifiers.ctrl and !input.modifiers.alt) {
        _ = try toggleSelectAllElements(state, layer_context);
        return true;
    }
    if (input.wasKeyPressed(.f) and !input.modifiers.ctrl and !input.modifiers.alt and !input.modifiers.shift) {
        if (try fillFaceFromSelection(state, layer_context)) {
            return true;
        }
        camera.focusSelection(state, layer_context);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.extrude) or (input.wasKeyPressed(.e) and input.modifiers.alt and !input.modifiers.ctrl)) {
        _ = try beginInteractiveOperation(state, layer_context, .extrude);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.inset)) {
        _ = try beginInteractiveOperation(state, layer_context, .inset);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.bevel) or (input.wasKeyPressed(.b) and input.modifiers.ctrl and !input.modifiers.alt)) {
        _ = try beginInteractiveOperation(state, layer_context, .bevel);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.loop_cut)) {
        _ = try beginInteractiveOperation(state, layer_context, .loop_cut);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.merge)) {
        _ = try mergeSelectedVertices(state, layer_context);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.duplicate)) {
        _ = try duplicateSelectedElements(state, layer_context);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.separate)) {
        _ = try separateSelectedFaces(state, layer_context);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.recalc_normals)) {
        _ = try recalculateNormals(state, layer_context);
        return true;
    }
    if (shortcutPressed(input, state.mesh_edit_shortcuts.pivot_to_selection)) {
        _ = try pivotToSelection(state, layer_context);
        return true;
    }
    return false;
}

fn shortcutPressed(input: *const engine.core.InputState, binding: MeshShortcutBinding) bool {
    return binding.matches(input);
}

pub fn handleViewportSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    update_mode: engine.render.SelectionUpdateMode,
) !bool {
    if (interactive_mesh_op != null) {
        return true;
    }

    if (!isEditModeActive(state)) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse {
        exitEditMode(state, layer_context);
        return true;
    };

    switch (state.mesh_edit_selection_mode) {
        .vertex => {
            const picked = pickVertexIndexOnScreen(state, layer_context, context);
            try applyPickedSelection(state, layer_context, update_mode, if (picked) |index| &[_]u32{index} else &.{});
        },
        .edge => {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const picked = try pickEdgeIndexOnScreen(allocator, state, layer_context, context);
            if (picked) |index| {
                if (layer_context.input.modifiers.alt) {
                    const loop_selection = try collectEdgeLoopSelection(allocator, context, index);
                    defer allocator.free(loop_selection);
                    try applyPickedSelection(state, layer_context, update_mode, loop_selection);
                } else {
                    try applyPickedSelection(state, layer_context, update_mode, &[_]u32{index});
                }
            } else {
                try applyPickedSelection(state, layer_context, update_mode, &.{});
            }
        },
        .face => {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const picked_group = try pickFaceGroup(allocator, context, ray);
            defer if (picked_group) |group| allocator.free(group);
            try applyPickedSelection(state, layer_context, update_mode, if (picked_group) |group| group else &.{});
        },
    }

    return true;
}

pub fn buildEdgeList(allocator: std.mem.Allocator, mesh: *const engine.assets.MeshResource) ![]Edge {
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < mesh.indices.len) : (triangle_offset += 3) {
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset], mesh.indices[triangle_offset + 1]);
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset + 1], mesh.indices[triangle_offset + 2]);
        try appendUniqueEdge(allocator, &edges, &seen, mesh.indices[triangle_offset + 2], mesh.indices[triangle_offset]);
    }

    return try edges.toOwnedSlice(allocator);
}

pub fn deleteSelectedElements(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    if (state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    var triangle_remove = try allocator.alloc(bool, context.mesh.indices.len / 3);
    defer allocator.free(triangle_remove);
    @memset(triangle_remove, false);

    switch (state.mesh_edit_selection_mode) {
        .face => {
            for (state.mesh_edit_selected_elements.items) |face_index| {
                if (face_index < triangle_remove.len) {
                    triangle_remove[face_index] = true;
                }
            }
        },
        .vertex => {
            for (state.mesh_edit_selected_elements.items) |vertex_index| {
                var face_index: usize = 0;
                while (face_index < triangle_remove.len) : (face_index += 1) {
                    const triangle_offset = face_index * 3;
                    if (context.mesh.indices[triangle_offset] == vertex_index or
                        context.mesh.indices[triangle_offset + 1] == vertex_index or
                        context.mesh.indices[triangle_offset + 2] == vertex_index)
                    {
                        triangle_remove[face_index] = true;
                    }
                }
            }
        },
        .edge => {
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (state.mesh_edit_selected_elements.items) |edge_index| {
                if (edge_index >= edges.len) {
                    continue;
                }
                const edge = edges[edge_index];
                var face_index: usize = 0;
                while (face_index < triangle_remove.len) : (face_index += 1) {
                    const triangle_offset = face_index * 3;
                    if (triangleContainsEdge(
                        context.mesh.indices[triangle_offset],
                        context.mesh.indices[triangle_offset + 1],
                        context.mesh.indices[triangle_offset + 2],
                        edge.a,
                        edge.b,
                    )) {
                        triangle_remove[face_index] = true;
                    }
                }
            }
        },
    }

    const next_indices = try filteredIndicesWithoutTriangles(allocator, context.mesh.indices, triangle_remove);
    defer allocator.free(next_indices);
    const rebuilt = try compactMeshData(allocator, context.mesh.vertices, next_indices);
    defer allocator.free(rebuilt.vertices);
    defer allocator.free(rebuilt.indices);

    try applyMeshMutation(state, layer_context, context.mesh_handle, rebuilt.vertices, rebuilt.indices);
    clearElementSelection(state);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_delete_action),
        state.text(.mesh_edit_delete_action),
        .human,
    );
    return true;
}

pub fn extrudeSelectedFaces(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .face or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const result = try extrudeFaceRegion(
        allocator,
        context.mesh.vertices,
        context.mesh.indices,
        state.mesh_edit_selected_elements.items,
        0.35,
    );
    defer allocator.free(result.vertices);
    defer allocator.free(result.indices);
    defer allocator.free(result.selected_faces);

    try applyMeshMutation(state, layer_context, context.mesh_handle, result.vertices, result.indices);
    clearElementSelection(state);
    try state.mesh_edit_selected_elements.appendSlice(allocator, result.selected_faces);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_extrude_action),
        state.text(.mesh_edit_extrude_action),
        .human,
    );
    return true;
}

pub fn insetSelectedFaces(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .face or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const result = try insetFaceRegion(
        allocator,
        context.mesh.vertices,
        context.mesh.indices,
        state.mesh_edit_selected_elements.items,
        0.15,
    );
    defer allocator.free(result.vertices);
    defer allocator.free(result.indices);
    defer allocator.free(result.selected_faces);

    try applyMeshMutation(state, layer_context, context.mesh_handle, result.vertices, result.indices);
    clearElementSelection(state);
    try state.mesh_edit_selected_elements.appendSlice(allocator, result.selected_faces);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_inset_action),
        state.text(.mesh_edit_inset_action),
        .human,
    );
    return true;
}

pub fn bevelSelectedEdges(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .edge or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const edges = try buildEdgeList(allocator, context.mesh);
    defer allocator.free(edges);

    const result = try bevelEdgeRegion(
        allocator,
        context.mesh.vertices,
        context.mesh.indices,
        edges,
        state.mesh_edit_selected_elements.items,
        0.2,
    );
    defer allocator.free(result.vertices);
    defer allocator.free(result.indices);

    if (!meshDataIsValid(result.vertices, result.indices)) {
        return false;
    }

    try applyMeshMutation(state, layer_context, context.mesh_handle, result.vertices, result.indices);
    clearElementSelection(state);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_bevel_action),
        state.text(.mesh_edit_bevel_action),
        .human,
    );
    return true;
}

pub fn loopCut(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .edge or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const edges = try buildEdgeList(allocator, context.mesh);
    defer allocator.free(edges);

    if (state.mesh_edit_selected_elements.items.len == 0) return false;
    const seed_edge_index = state.mesh_edit_selected_elements.items[0];
    if (seed_edge_index >= edges.len) return false;

    const result = try loopCutMesh(
        allocator,
        context.mesh.vertices,
        context.mesh.indices,
        edges,
        seed_edge_index,
        0.5,
    );
    defer allocator.free(result.vertices);
    defer allocator.free(result.indices);
    defer allocator.free(result.new_edge_indices);

    if (!meshDataIsValid(result.vertices, result.indices)) {
        return false;
    }

    try applyMeshMutation(state, layer_context, context.mesh_handle, result.vertices, result.indices);
    clearElementSelection(state);

    const new_edges = try buildEdgeList(allocator, layer_context.world.assets().mesh(context.mesh_handle) orelse return false);
    defer allocator.free(new_edges);
    for (result.new_edge_indices) |midpoint_vertex_index| {
        for (new_edges, 0..) |edge, edge_idx| {
            if (edge.a == midpoint_vertex_index or edge.b == midpoint_vertex_index) {
                try state.mesh_edit_selected_elements.append(allocator, @intCast(edge_idx));
            }
        }
    }

    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_loop_cut_action),
        state.text(.mesh_edit_loop_cut_action),
        .human,
    );
    return true;
}

pub fn mergeSelectedVertices(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .vertex or state.mesh_edit_selected_elements.items.len < 2) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    var center = [3]f32{ 0.0, 0.0, 0.0 };
    for (state.mesh_edit_selected_elements.items) |vertex_index| {
        if (vertex_index < context.mesh.vertices.len) {
            center = add3(center, context.mesh.vertices[vertex_index].position);
        }
    }
    const count_f: f32 = @floatFromInt(state.mesh_edit_selected_elements.items.len);
    center = scale3(center, 1.0 / count_f);

    var next_vertices = try allocator.dupe(engine.assets.MeshVertex, context.mesh.vertices);
    defer allocator.free(next_vertices);

    const target_index = state.mesh_edit_selected_elements.items[0];
    if (target_index < next_vertices.len) {
        next_vertices[target_index].position = center;
    }

    const next_indices = try allocator.dupe(u32, context.mesh.indices);
    defer allocator.free(next_indices);

    for (state.mesh_edit_selected_elements.items[1..]) |vertex_index| {
        for (next_indices) |*index| {
            if (index.* == vertex_index) {
                index.* = target_index;
            }
        }
    }

    var degenerate_remove = try allocator.alloc(bool, next_indices.len / 3);
    defer allocator.free(degenerate_remove);
    @memset(degenerate_remove, false);
    var face_index: usize = 0;
    while (face_index < degenerate_remove.len) : (face_index += 1) {
        const offset = face_index * 3;
        if (next_indices[offset] == next_indices[offset + 1] or
            next_indices[offset + 1] == next_indices[offset + 2] or
            next_indices[offset] == next_indices[offset + 2])
        {
            degenerate_remove[face_index] = true;
        }
    }

    const cleaned_indices = try filteredIndicesWithoutTriangles(allocator, next_indices, degenerate_remove);
    defer allocator.free(cleaned_indices);
    const rebuilt = try compactMeshData(allocator, next_vertices, cleaned_indices);
    defer allocator.free(rebuilt.vertices);
    defer allocator.free(rebuilt.indices);

    try applyMeshMutation(state, layer_context, context.mesh_handle, rebuilt.vertices, rebuilt.indices);
    clearElementSelection(state);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_merge_action),
        state.text(.mesh_edit_merge_action),
        .human,
    );
    return true;
}

pub fn duplicateSelectedElements(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .face or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    var vertex_remap = std.AutoHashMap(u32, u32).init(allocator);
    defer vertex_remap.deinit();
    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, context.mesh.vertices);

    for (state.mesh_edit_selected_elements.items) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= context.mesh.indices.len) continue;
        var local_vertex: usize = 0;
        while (local_vertex < 3) : (local_vertex += 1) {
            const original_vi = context.mesh.indices[triangle_offset + local_vertex];
            const gop = try vertex_remap.getOrPut(original_vi);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(next_vertices.items.len);
                try next_vertices.append(allocator, context.mesh.vertices[original_vi]);
            }
        }
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);
    try next_indices.appendSlice(allocator, context.mesh.indices);

    const new_face_start: u32 = @intCast(next_indices.items.len / 3);
    for (state.mesh_edit_selected_elements.items) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= context.mesh.indices.len) continue;
        try next_indices.append(allocator, vertex_remap.get(context.mesh.indices[triangle_offset]).?);
        try next_indices.append(allocator, vertex_remap.get(context.mesh.indices[triangle_offset + 1]).?);
        try next_indices.append(allocator, vertex_remap.get(context.mesh.indices[triangle_offset + 2]).?);
    }

    try applyMeshMutation(state, layer_context, context.mesh_handle, next_vertices.items, next_indices.items);
    clearElementSelection(state);

    const sel_count = @as(u32, @intCast(next_indices.items.len / 3)) - new_face_start;
    var sel_i: u32 = 0;
    while (sel_i < sel_count) : (sel_i += 1) {
        try state.mesh_edit_selected_elements.append(allocator, new_face_start + sel_i);
    }

    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_duplicate_action),
        state.text(.mesh_edit_duplicate_action),
        .human,
    );
    return true;
}

pub fn separateSelectedFaces(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selection_mode != .face or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;
    const face_count = context.mesh.indices.len / 3;

    var selected_mask = try allocator.alloc(bool, face_count);
    defer allocator.free(selected_mask);
    @memset(selected_mask, false);
    for (state.mesh_edit_selected_elements.items) |face_index| {
        if (face_index < selected_mask.len) {
            selected_mask[face_index] = true;
        }
    }

    var remaining_indices = std.ArrayList(u32).empty;
    defer remaining_indices.deinit(allocator);
    var separated_indices = std.ArrayList(u32).empty;
    defer separated_indices.deinit(allocator);

    var fi: usize = 0;
    while (fi < face_count) : (fi += 1) {
        const offset = fi * 3;
        if (selected_mask[fi]) {
            try separated_indices.appendSlice(allocator, context.mesh.indices[offset .. offset + 3]);
        } else {
            try remaining_indices.appendSlice(allocator, context.mesh.indices[offset .. offset + 3]);
        }
    }

    const remaining = try compactMeshData(allocator, context.mesh.vertices, remaining_indices.items);
    defer allocator.free(remaining.vertices);
    defer allocator.free(remaining.indices);

    try applyMeshMutation(state, layer_context, context.mesh_handle, remaining.vertices, remaining.indices);

    const separated = try compactMeshData(allocator, context.mesh.vertices, separated_indices.items);
    defer allocator.free(separated.vertices);
    defer allocator.free(separated.indices);

    const source_entity = layer_context.world.getEntityConst(context.entity_id) orelse return false;
    const new_name = try std.fmt.allocPrint(allocator, "{s}.separated", .{source_entity.name});
    defer allocator.free(new_name);

    const new_mesh_label = try std.fmt.allocPrint(allocator, "{s} Separated Mesh", .{source_entity.name});
    defer allocator.free(new_mesh_label);
    const new_mesh_handle = try layer_context.world.assets().createMesh(.{
        .name = new_mesh_label,
        .vertices = separated.vertices,
        .indices = separated.indices,
        .primitive_type = context.mesh.primitive_type,
    });

    const new_entity_id = try layer_context.world.createEntity(.{
        .name = new_name,
        .local_transform = source_entity.local_transform,
        .mesh = .{ .handle = new_mesh_handle, .primitive = .custom },
    });

    layer_context.world.noteEntityRenderableChanged(new_entity_id);
    layer_context.world.updateHierarchy();

    clearElementSelection(state);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_separate_action),
        state.text(.mesh_edit_separate_action),
        .human,
    );
    return true;
}

pub fn recalculateNormals(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    const next_vertices = try allocator.dupe(engine.assets.MeshVertex, context.mesh.vertices);
    defer allocator.free(next_vertices);
    recalculateVertexNormals(next_vertices, context.mesh.indices);

    try applyMeshMutation(state, layer_context, context.mesh_handle, next_vertices, context.mesh.indices);
    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_recalculate_normals_action),
        state.text(.mesh_edit_recalculate_normals_action),
        .human,
    );
    return true;
}

pub fn pivotToSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    var center = [3]f32{ 0.0, 0.0, 0.0 };
    var count: f32 = 0.0;

    switch (state.mesh_edit_selection_mode) {
        .vertex => {
            for (state.mesh_edit_selected_elements.items) |vertex_index| {
                if (vertex_index < context.mesh.vertices.len) {
                    center = add3(center, context.mesh.vertices[vertex_index].position);
                    count += 1.0;
                }
            }
        },
        .face => {
            for (state.mesh_edit_selected_elements.items) |face_index| {
                const triangle_offset = @as(usize, face_index) * 3;
                if (triangle_offset + 2 >= context.mesh.indices.len) continue;
                var local_vertex: usize = 0;
                while (local_vertex < 3) : (local_vertex += 1) {
                    const vi = context.mesh.indices[triangle_offset + local_vertex];
                    center = add3(center, context.mesh.vertices[vi].position);
                    count += 1.0;
                }
            }
        },
        .edge => {
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (state.mesh_edit_selected_elements.items) |edge_index| {
                if (edge_index < edges.len) {
                    center = add3(center, context.mesh.vertices[edges[edge_index].a].position);
                    center = add3(center, context.mesh.vertices[edges[edge_index].b].position);
                    count += 2.0;
                }
            }
        },
    }

    if (count < 1.0) return false;
    center = scale3(center, 1.0 / count);

    const next_vertices = try allocator.dupe(engine.assets.MeshVertex, context.mesh.vertices);
    defer allocator.free(next_vertices);
    for (next_vertices) |*vertex| {
        vertex.position = sub3(vertex.position, center);
    }

    try applyMeshMutation(state, layer_context, context.mesh_handle, next_vertices, context.mesh.indices);

    const entity = layer_context.world.getEntity(context.entity_id) orelse return false;
    const world_offset = engine.math.quat.rotateVec3(
        entity.local_transform.rotation,
        mul3(entity.local_transform.scale, center),
    );
    entity.local_transform.translation = add3(entity.local_transform.translation, world_offset);
    layer_context.world.markDirty(context.entity_id);
    layer_context.world.updateHierarchy();

    try history.captureSnapshotWithLabel(
        state,
        layer_context,
        state.text(.mesh_edit_pivot_to_selection_action),
        state.text(.mesh_edit_pivot_to_selection_action),
        .human,
    );
    return true;
}

fn clearElementSelection(state: *EditorState) void {
    state.mesh_edit_selected_elements.clearRetainingCapacity();
}

fn toggleSelectAllElements(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    const total_count: usize = switch (state.mesh_edit_selection_mode) {
        .vertex => context.mesh.vertices.len,
        .face => context.mesh.indices.len / 3,
        .edge => blk: {
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            break :blk edges.len;
        },
    };

    if (state.mesh_edit_selected_elements.items.len == total_count) {
        clearElementSelection(state);
        return true;
    }

    clearElementSelection(state);
    try state.mesh_edit_selected_elements.ensureTotalCapacity(allocator, total_count);
    var i: usize = 0;
    while (i < total_count) : (i += 1) {
        state.mesh_edit_selected_elements.appendAssumeCapacity(@intCast(i));
    }
    return true;
}

fn fillFaceFromSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    var tri_vertices: [3]u32 = .{ 0, 0, 0 };
    var tri_count: usize = 0;

    switch (state.mesh_edit_selection_mode) {
        .vertex => {
            for (state.mesh_edit_selected_elements.items) |vertex_index| {
                if (vertex_index >= context.mesh.vertices.len) continue;
                if (!containsVertex(tri_vertices[0..tri_count], vertex_index)) {
                    tri_vertices[tri_count] = vertex_index;
                    tri_count += 1;
                    if (tri_count == 3) break;
                }
            }
        },
        .edge => {
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            for (state.mesh_edit_selected_elements.items) |edge_index| {
                if (edge_index >= edges.len) continue;
                const edge = edges[edge_index];
                if (!containsVertex(tri_vertices[0..tri_count], edge.a)) {
                    tri_vertices[tri_count] = edge.a;
                    tri_count += 1;
                    if (tri_count == 3) break;
                }
                if (!containsVertex(tri_vertices[0..tri_count], edge.b)) {
                    tri_vertices[tri_count] = edge.b;
                    tri_count += 1;
                    if (tri_count == 3) break;
                }
            }
        },
        .face => return false,
    }

    if (tri_count < 3) {
        return false;
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);
    try next_indices.appendSlice(allocator, context.mesh.indices);
    const new_face_index: u32 = @intCast(next_indices.items.len / 3);
    try next_indices.appendSlice(allocator, &tri_vertices);

    const next_vertices = try allocator.dupe(engine.assets.MeshVertex, context.mesh.vertices);
    defer allocator.free(next_vertices);
    recalculateVertexNormals(next_vertices, next_indices.items);

    try applyMeshMutation(state, layer_context, context.mesh_handle, next_vertices, next_indices.items);
    clearElementSelection(state);
    try state.mesh_edit_selected_elements.append(allocator, new_face_index);
    try history.captureSnapshotWithLabel(state, layer_context, "Fill Face", "Fill Face", .human);
    return true;
}

fn containsVertex(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn collectEdgeLoopSelection(allocator: std.mem.Allocator, context: ActiveContext, seed_edge_index: u32) ![]u32 {
    const edges = try buildEdgeList(allocator, context.mesh);
    defer allocator.free(edges);
    if (seed_edge_index >= edges.len) {
        return allocator.dupe(u32, &.{});
    }

    var edge_face_count = std.AutoHashMap(u64, u32).init(allocator);
    defer edge_face_count.deinit();
    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < context.mesh.indices.len) : (triangle_offset += 3) {
        const tri = [3]u32{ context.mesh.indices[triangle_offset], context.mesh.indices[triangle_offset + 1], context.mesh.indices[triangle_offset + 2] };
        const tri_edges = [3][2]u32{
            .{ @min(tri[0], tri[1]), @max(tri[0], tri[1]) },
            .{ @min(tri[1], tri[2]), @max(tri[1], tri[2]) },
            .{ @min(tri[2], tri[0]), @max(tri[2], tri[0]) },
        };
        for (tri_edges) |te| {
            const key = edgeKey(te[0], te[1]);
            const gop = try edge_face_count.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
            } else {
                gop.value_ptr.* += 1;
            }
        }
    }

    var vertex_edges = try allocator.alloc(std.ArrayList(u32), context.mesh.vertices.len);
    defer {
        for (vertex_edges) |*list| list.deinit(allocator);
        allocator.free(vertex_edges);
    }
    for (vertex_edges) |*list| list.* = .empty;
    for (edges, 0..) |edge, idx| {
        try vertex_edges[edge.a].append(allocator, @intCast(idx));
        try vertex_edges[edge.b].append(allocator, @intCast(idx));
    }

    var loop_edge_keys = std.ArrayList(u64).empty;
    defer loop_edge_keys.deinit(allocator);
    var loop_edge_set = std.AutoHashMap(u64, void).init(allocator);
    defer loop_edge_set.deinit();

    const seed_edge = edges[seed_edge_index];
    const seed_key = edgeKey(@min(seed_edge.a, seed_edge.b), @max(seed_edge.a, seed_edge.b));
    try loop_edge_set.put(seed_key, {});
    try loop_edge_keys.append(allocator, seed_key);

    try extendEdgeLoop(
        allocator,
        context.mesh.vertices,
        edges,
        vertex_edges,
        &edge_face_count,
        seed_edge.a,
        seed_edge.b,
        &loop_edge_set,
        &loop_edge_keys,
    );
    try extendEdgeLoop(
        allocator,
        context.mesh.vertices,
        edges,
        vertex_edges,
        &edge_face_count,
        seed_edge.b,
        seed_edge.a,
        &loop_edge_set,
        &loop_edge_keys,
    );

    var selected = std.ArrayList(u32).empty;
    defer selected.deinit(allocator);
    for (loop_edge_keys.items) |key| {
        for (edges, 0..) |edge, edge_index| {
            if (edgeKey(@min(edge.a, edge.b), @max(edge.a, edge.b)) == key) {
                try selected.append(allocator, @intCast(edge_index));
                break;
            }
        }
    }
    return try selected.toOwnedSlice(allocator);
}

fn pruneSelectionToCurrentMesh(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const context = activeContext(state, layer_context) orelse {
        clearElementSelection(state);
        return;
    };

    const max_index: usize = switch (state.mesh_edit_selection_mode) {
        .vertex => context.mesh.vertices.len,
        .face => context.mesh.indices.len / 3,
        .edge => blk: {
            const allocator = state.allocator orelse layer_context.world.allocator;
            const edges = try buildEdgeList(allocator, context.mesh);
            defer allocator.free(edges);
            break :blk edges.len;
        },
    };

    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < state.mesh_edit_selected_elements.items.len) : (read_index += 1) {
        const candidate = state.mesh_edit_selected_elements.items[read_index];
        if (candidate >= max_index) {
            continue;
        }
        state.mesh_edit_selected_elements.items[write_index] = candidate;
        write_index += 1;
    }
    state.mesh_edit_selected_elements.items.len = write_index;
}

fn applyPickedSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    update_mode: engine.render.SelectionUpdateMode,
    picked_elements: []const u32,
) !void {
    _ = layer_context;
    const allocator = state.allocator orelse return;
    switch (update_mode) {
        .replace => {
            clearElementSelection(state);
            try state.mesh_edit_selected_elements.appendSlice(allocator, picked_elements);
        },
        .toggle => {
            for (picked_elements) |element_index| {
                if (indexOfSelectedElement(state, element_index)) |selected_index| {
                    _ = state.mesh_edit_selected_elements.orderedRemove(selected_index);
                } else {
                    try state.mesh_edit_selected_elements.append(allocator, element_index);
                }
            }
        },
    }
}

fn indexOfSelectedElement(state: *const EditorState, element_index: u32) ?usize {
    for (state.mesh_edit_selected_elements.items, 0..) |selected, index| {
        if (selected == element_index) {
            return index;
        }
    }
    return null;
}

fn pickVertexIndexOnScreen(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    context: ActiveContext,
) ?u32 {
    const mouse = layer_context.input.mouse_position;
    var best_distance = std.math.inf(f32);
    var best_index: ?u32 = null;

    for (context.mesh.vertices, 0..) |vertex, index| {
        const world_position = transformPoint(context.world_transform, vertex.position);
        const screen = projectWorldPointToViewport(state, layer_context, world_position) orelse continue;
        const distance = distance2d(mouse, screen);
        if (distance <= 12.0 and distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index);
        }
    }
    return best_index;
}

fn pickEdgeIndexOnScreen(
    allocator: std.mem.Allocator,
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    context: ActiveContext,
) !?u32 {
    const edges = try buildEdgeList(allocator, context.mesh);
    defer allocator.free(edges);

    const mouse = layer_context.input.mouse_position;
    var best_distance = std.math.inf(f32);
    var best_index: ?u32 = null;

    for (edges, 0..) |edge, index| {
        const a_world = transformPoint(context.world_transform, context.mesh.vertices[edge.a].position);
        const b_world = transformPoint(context.world_transform, context.mesh.vertices[edge.b].position);
        const a_screen = projectWorldPointToViewport(state, layer_context, a_world) orelse continue;
        const b_screen = projectWorldPointToViewport(state, layer_context, b_world) orelse continue;
        const distance = distancePointToSegment2d(mouse, a_screen, b_screen);
        if (distance <= 10.0 and distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index);
        }
    }

    return best_index;
}

fn pickFaceGroup(
    allocator: std.mem.Allocator,
    context: ActiveContext,
    ray: engine.scene.Ray,
) !?[]u32 {
    if (context.mesh.indices.len < 3) {
        return null;
    }

    var best_face_index: ?u32 = null;
    var best_distance = std.math.inf(f32);

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < context.mesh.indices.len) : (triangle_offset += 3) {
        const v0 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset]].position);
        const v1 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 1]].position);
        const v2 = transformPoint(context.world_transform, context.mesh.vertices[context.mesh.indices[triangle_offset + 2]].position);
        const hit = rayTriangleIntersection(ray.origin, ray.direction, v0, v1, v2) orelse continue;
        if (hit.distance < best_distance) {
            best_distance = hit.distance;
            best_face_index = @intCast(triangle_offset / 3);
        }
    }

    const seed_face = best_face_index orelse return null;
    return try collectCoplanarFaceGroup(allocator, context.mesh, seed_face);
}

fn collectCoplanarFaceGroup(
    allocator: std.mem.Allocator,
    mesh: *const engine.assets.MeshResource,
    seed_face: u32,
) ![]u32 {
    const face_count = mesh.indices.len / 3;
    var visited = try allocator.alloc(bool, face_count);
    defer allocator.free(visited);
    @memset(visited, false);

    var queue = std.ArrayList(u32).empty;
    defer queue.deinit(allocator);
    var group = std.ArrayList(u32).empty;
    defer group.deinit(allocator);

    const seed_normal = faceNormal(mesh, seed_face);
    const seed_point = mesh.vertices[mesh.indices[@as(usize, seed_face) * 3]].position;

    try queue.append(allocator, seed_face);
    visited[seed_face] = true;

    while (queue.items.len > 0) {
        const face_index = queue.pop().?;
        try group.append(allocator, face_index);

        var candidate: usize = 0;
        while (candidate < face_count) : (candidate += 1) {
            if (visited[candidate]) {
                continue;
            }
            if (!trianglesShareEdge(mesh, face_index, @intCast(candidate))) {
                continue;
            }
            const candidate_normal = faceNormal(mesh, @intCast(candidate));
            if (dot3(seed_normal, candidate_normal) < 0.999) {
                continue;
            }
            if (!triangleIsCoplanar(mesh, @intCast(candidate), seed_normal, seed_point)) {
                continue;
            }
            visited[candidate] = true;
            try queue.append(allocator, @intCast(candidate));
        }
    }

    return try group.toOwnedSlice(allocator);
}

fn triangleIsCoplanar(
    mesh: *const engine.assets.MeshResource,
    face_index: u32,
    plane_normal: [3]f32,
    plane_point: [3]f32,
) bool {
    const triangle_offset = @as(usize, face_index) * 3;
    const epsilon: f32 = 0.0005;
    return @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset]].position, plane_point), plane_normal)) <= epsilon and
        @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset + 1]].position, plane_point), plane_normal)) <= epsilon and
        @abs(dot3(sub3(mesh.vertices[mesh.indices[triangle_offset + 2]].position, plane_point), plane_normal)) <= epsilon;
}

fn trianglesShareEdge(mesh: *const engine.assets.MeshResource, lhs_face: u32, rhs_face: u32) bool {
    const lhs_offset = @as(usize, lhs_face) * 3;
    const rhs_offset = @as(usize, rhs_face) * 3;
    const lhs = [3]u32{
        mesh.indices[lhs_offset],
        mesh.indices[lhs_offset + 1],
        mesh.indices[lhs_offset + 2],
    };
    const rhs = [3]u32{
        mesh.indices[rhs_offset],
        mesh.indices[rhs_offset + 1],
        mesh.indices[rhs_offset + 2],
    };

    var shared: u32 = 0;
    for (lhs) |lhs_vertex| {
        for (rhs) |rhs_vertex| {
            if (lhs_vertex == rhs_vertex) {
                shared += 1;
                break;
            }
        }
    }
    return shared >= 2;
}

fn faceNormal(mesh: *const engine.assets.MeshResource, face_index: u32) [3]f32 {
    const triangle_offset = @as(usize, face_index) * 3;
    const v0 = mesh.vertices[mesh.indices[triangle_offset]].position;
    const v1 = mesh.vertices[mesh.indices[triangle_offset + 1]].position;
    const v2 = mesh.vertices[mesh.indices[triangle_offset + 2]].position;
    return normalize3(cross3(sub3(v1, v0), sub3(v2, v0)));
}

const CompactedMeshData = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
};

fn filteredIndicesWithoutTriangles(
    allocator: std.mem.Allocator,
    indices: []const u32,
    triangle_remove: []const bool,
) ![]u32 {
    var kept_indices = std.ArrayList(u32).empty;
    defer kept_indices.deinit(allocator);

    var face_index: usize = 0;
    while (face_index < triangle_remove.len) : (face_index += 1) {
        if (triangle_remove[face_index]) {
            continue;
        }
        const triangle_offset = face_index * 3;
        try kept_indices.appendSlice(allocator, indices[triangle_offset .. triangle_offset + 3]);
    }

    return try kept_indices.toOwnedSlice(allocator);
}

const InsetResult = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
    selected_faces: []u32,
};

fn insetFaceRegion(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
    selected_faces: []const u32,
    inset_amount: f32,
) !InsetResult {
    var selected_face_mask = try allocator.alloc(bool, indices.len / 3);
    defer allocator.free(selected_face_mask);
    @memset(selected_face_mask, false);
    for (selected_faces) |face_index| {
        if (face_index < selected_face_mask.len) {
            selected_face_mask[face_index] = true;
        }
    }

    var edge_counts = std.AutoHashMap(u64, u32).init(allocator);
    defer edge_counts.deinit();

    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= indices.len) continue;
        const tri = [3]u32{ indices[triangle_offset], indices[triangle_offset + 1], indices[triangle_offset + 2] };
        const tri_edges = [3][2]u32{
            .{ @min(tri[0], tri[1]), @max(tri[0], tri[1]) },
            .{ @min(tri[1], tri[2]), @max(tri[1], tri[2]) },
            .{ @min(tri[2], tri[0]), @max(tri[2], tri[0]) },
        };
        for (tri_edges) |edge| {
            const gop = try edge_counts.getOrPut(edgeKey(edge[0], edge[1]));
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
            } else {
                gop.value_ptr.* += 1;
            }
        }
    }

    const InsetAccum = struct {
        sum: [3]f32,
        count: u32,
    };

    var inset_accum = std.AutoHashMap(u32, InsetAccum).init(allocator);
    defer inset_accum.deinit();

    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= indices.len) continue;

        const vi0 = indices[triangle_offset];
        const vi1 = indices[triangle_offset + 1];
        const vi2 = indices[triangle_offset + 2];
        const centroid = scale3(add3(add3(vertices[vi0].position, vertices[vi1].position), vertices[vi2].position), 1.0 / 3.0);

        for ([_]u32{ vi0, vi1, vi2 }) |vertex_index| {
            const gop = try inset_accum.getOrPut(vertex_index);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .sum = sub3(centroid, vertices[vertex_index].position), .count = 1 };
            } else {
                gop.value_ptr.sum = add3(gop.value_ptr.sum, sub3(centroid, vertices[vertex_index].position));
                gop.value_ptr.count += 1;
            }
        }
    }

    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, vertices);

    var inset_vertex_map = std.AutoHashMap(u32, u32).init(allocator);
    defer inset_vertex_map.deinit();

    var accum_iter = inset_accum.iterator();
    while (accum_iter.next()) |entry| {
        const original_index = entry.key_ptr.*;
        const accum = entry.value_ptr.*;
        const direction = scale3(accum.sum, 1.0 / @as(f32, @floatFromInt(accum.count)));
        var new_vertex = vertices[original_index];
        new_vertex.position = add3(new_vertex.position, scale3(direction, inset_amount));
        const new_index: u32 = @intCast(next_vertices.items.len);
        try next_vertices.append(allocator, new_vertex);
        try inset_vertex_map.put(original_index, new_index);
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);
    try next_indices.appendSlice(allocator, indices);

    var new_face_list = std.ArrayList(u32).empty;
    defer new_face_list.deinit(allocator);

    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= next_indices.items.len) continue;

        const vi0 = next_indices.items[triangle_offset];
        const vi1 = next_indices.items[triangle_offset + 1];
        const vi2 = next_indices.items[triangle_offset + 2];
        const new_vi0 = inset_vertex_map.get(vi0) orelse continue;
        const new_vi1 = inset_vertex_map.get(vi1) orelse continue;
        const new_vi2 = inset_vertex_map.get(vi2) orelse continue;

        next_indices.items[triangle_offset] = new_vi0;
        next_indices.items[triangle_offset + 1] = new_vi1;
        next_indices.items[triangle_offset + 2] = new_vi2;

        try new_face_list.append(allocator, face_index);
    }

    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= indices.len) continue;
        const tri = [3]u32{ indices[triangle_offset], indices[triangle_offset + 1], indices[triangle_offset + 2] };
        const tri_edges = [3][2]u32{ .{ tri[0], tri[1] }, .{ tri[1], tri[2] }, .{ tri[2], tri[0] } };
        for (tri_edges) |edge| {
            const min_v = @min(edge[0], edge[1]);
            const max_v = @max(edge[0], edge[1]);
            const count = edge_counts.get(edgeKey(min_v, max_v)) orelse 0;
            if (count != 1) {
                continue;
            }
            const a_inset = inset_vertex_map.get(edge[0]) orelse continue;
            const b_inset = inset_vertex_map.get(edge[1]) orelse continue;
            try next_indices.appendSlice(allocator, &[_]u32{ edge[0], edge[1], b_inset, edge[0], b_inset, a_inset });
        }
    }

    recalculateVertexNormals(next_vertices.items, next_indices.items);

    return .{
        .vertices = try next_vertices.toOwnedSlice(allocator),
        .indices = try next_indices.toOwnedSlice(allocator),
        .selected_faces = try new_face_list.toOwnedSlice(allocator),
    };
}

const BevelResult = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
};

fn bevelEdgeRegion(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
    edges: []const Edge,
    selected_edge_indices: []const u32,
    bevel_ratio: f32,
) !BevelResult {
    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, vertices);

    var split_by_edge = std.AutoHashMap(u64, EdgeSplit).init(allocator);
    defer split_by_edge.deinit();

    var selected_edge_mask = std.AutoHashMap(u64, void).init(allocator);
    defer selected_edge_mask.deinit();

    for (selected_edge_indices) |edge_index| {
        if (edge_index >= edges.len) continue;
        const edge = edges[edge_index];
        const min_v = @min(edge.a, edge.b);
        const max_v = @max(edge.a, edge.b);
        const selected_key = edgeKey(min_v, max_v);
        if (selected_edge_mask.contains(selected_key)) {
            continue;
        }
        try selected_edge_mask.put(selected_key, {});

        const pa = vertices[min_v].position;
        const pb = vertices[max_v].position;
        const edge_len = distance3(pa, pb);
        if (edge_len <= 0.0001) {
            continue;
        }
        const bevel_offset = std.math.clamp(edge_len * bevel_ratio, 0.01, edge_len * 0.45);
        const edge_dir = normalize3(sub3(pb, pa));

        var va_new = vertices[min_v];
        va_new.position = add3(pa, scale3(edge_dir, bevel_offset));
        const va_new_index: u32 = @intCast(next_vertices.items.len);
        try next_vertices.append(allocator, va_new);

        var vb_new = vertices[max_v];
        vb_new.position = sub3(pb, scale3(edge_dir, bevel_offset));
        const vb_new_index: u32 = @intCast(next_vertices.items.len);
        try next_vertices.append(allocator, vb_new);

        try split_by_edge.put(selected_key, .{ .min_split = va_new_index, .max_split = vb_new_index });
    }

    if (split_by_edge.count() == 0) {
        return .{
            .vertices = try allocator.dupe(engine.assets.MeshVertex, vertices),
            .indices = try allocator.dupe(u32, indices),
        };
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < indices.len) : (triangle_offset += 3) {
        const tri = [3]u32{ indices[triangle_offset], indices[triangle_offset + 1], indices[triangle_offset + 2] };
        const tri_edges = [3][2]u32{
            .{ tri[0], tri[1] },
            .{ tri[1], tri[2] },
            .{ tri[2], tri[0] },
        };

        var split_count: u32 = 0;
        var split_slot: usize = 0;
        var split_info: EdgeSplit = undefined;
        for (tri_edges, 0..) |tri_edge, slot| {
            const key = edgeKey(@min(tri_edge[0], tri_edge[1]), @max(tri_edge[0], tri_edge[1]));
            if (split_by_edge.get(key)) |info| {
                split_count += 1;
                split_slot = slot;
                split_info = info;
            }
        }

        if (split_count == 0) {
            try next_indices.appendSlice(allocator, &[_]u32{ tri[0], tri[1], tri[2] });
            continue;
        }

        if (split_count == 1) {
            const a = tri_edges[split_slot][0];
            const b = tri_edges[split_slot][1];
            const c = tri[(split_slot + 2) % 3];
            const a_split = splitVertexForEndpoint(a, b, split_info);
            const b_split = splitVertexForEndpoint(b, a, split_info);

            try next_indices.appendSlice(allocator, &[_]u32{ a, a_split, c });
            try next_indices.appendSlice(allocator, &[_]u32{ a_split, b_split, c });
            try next_indices.appendSlice(allocator, &[_]u32{ b_split, b, c });
            continue;
        }

        // For adjacent multi-edge bevel selections on one triangle, build a stable fan
        // around a local center to avoid topology cracks at branch transitions.
        var ring = std.ArrayList(u32).empty;
        defer ring.deinit(allocator);
        try ring.append(allocator, tri[0]);

        var edge_slot: usize = 0;
        while (edge_slot < 3) : (edge_slot += 1) {
            const a = tri_edges[edge_slot][0];
            const b = tri_edges[edge_slot][1];
            if (selected_edge_mask.contains(edgeKey(@min(a, b), @max(a, b)))) {
                const key = edgeKey(@min(a, b), @max(a, b));
                const info = split_by_edge.get(key) orelse continue;
                try ring.append(allocator, splitVertexForEndpoint(a, b, info));
                try ring.append(allocator, splitVertexForEndpoint(b, a, info));
            } else {
                try ring.append(allocator, b);
            }
        }

        var clean_ring = std.ArrayList(u32).empty;
        defer clean_ring.deinit(allocator);
        for (ring.items) |vertex_index| {
            if (clean_ring.items.len == 0 or clean_ring.items[clean_ring.items.len - 1] != vertex_index) {
                try clean_ring.append(allocator, vertex_index);
            }
        }
        if (clean_ring.items.len >= 2 and clean_ring.items[0] == clean_ring.items[clean_ring.items.len - 1]) {
            _ = clean_ring.pop();
        }
        if (clean_ring.items.len < 3) {
            try next_indices.appendSlice(allocator, &[_]u32{ tri[0], tri[1], tri[2] });
            continue;
        }

        var center = [3]f32{ 0.0, 0.0, 0.0 };
        var normal = [3]f32{ 0.0, 0.0, 0.0 };
        for (clean_ring.items) |vertex_index| {
            center = add3(center, next_vertices.items[vertex_index].position);
            normal = add3(normal, next_vertices.items[vertex_index].normal);
        }
        const inv_count = 1.0 / @as(f32, @floatFromInt(clean_ring.items.len));
        var center_vertex = vertices[tri[0]];
        center_vertex.position = scale3(center, inv_count);
        center_vertex.normal = normalize3(scale3(normal, inv_count));
        const center_index: u32 = @intCast(next_vertices.items.len);
        try next_vertices.append(allocator, center_vertex);

        for (clean_ring.items, 0..) |a, idx| {
            const b = clean_ring.items[(idx + 1) % clean_ring.items.len];
            if (a == b or a == center_index or b == center_index) {
                continue;
            }
            try next_indices.appendSlice(allocator, &[_]u32{ a, b, center_index });
        }
    }

    var split_iter = split_by_edge.iterator();
    while (split_iter.next()) |entry| {
        const min_v: u32 = @intCast(entry.key_ptr.* >> 32);
        const max_v: u32 = @intCast(entry.key_ptr.* & 0xffffffff);
        const split = entry.value_ptr.*;

        try next_indices.appendSlice(allocator, &[_]u32{
            min_v,
            max_v,
            split.max_split,
            min_v,
            split.max_split,
            split.min_split,
        });
    }

    recalculateVertexNormals(next_vertices.items, next_indices.items);

    return .{
        .vertices = try next_vertices.toOwnedSlice(allocator),
        .indices = try next_indices.toOwnedSlice(allocator),
    };
}

const LoopCutResult = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
    new_edge_indices: []u32,
};

fn loopCutMesh(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
    edges: []const Edge,
    seed_edge_index: u32,
    slide_factor: f32,
) !LoopCutResult {
    const seed_edge = edges[seed_edge_index];
    const face_count = indices.len / 3;

    var edge_face_count = std.AutoHashMap(u64, u32).init(allocator);
    defer edge_face_count.deinit();
    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < indices.len) : (triangle_offset += 3) {
        const tri = [3]u32{ indices[triangle_offset], indices[triangle_offset + 1], indices[triangle_offset + 2] };
        const tri_edges = [3][2]u32{
            .{ @min(tri[0], tri[1]), @max(tri[0], tri[1]) },
            .{ @min(tri[1], tri[2]), @max(tri[1], tri[2]) },
            .{ @min(tri[2], tri[0]), @max(tri[2], tri[0]) },
        };
        for (tri_edges) |te| {
            const key = edgeKey(te[0], te[1]);
            const gop = try edge_face_count.getOrPut(key);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
            } else {
                gop.value_ptr.* += 1;
            }
        }
    }

    var vertex_edges = try allocator.alloc(std.ArrayList(u32), vertices.len);
    defer {
        for (vertex_edges) |*list| list.deinit(allocator);
        allocator.free(vertex_edges);
    }
    for (vertex_edges) |*list| list.* = .empty;
    for (edges, 0..) |edge, idx| {
        try vertex_edges[edge.a].append(allocator, @intCast(idx));
        try vertex_edges[edge.b].append(allocator, @intCast(idx));
    }

    var loop_edge_keys = std.ArrayList(u64).empty;
    defer loop_edge_keys.deinit(allocator);
    var loop_edge_set = std.AutoHashMap(u64, void).init(allocator);
    defer loop_edge_set.deinit();

    const seed_min = @min(seed_edge.a, seed_edge.b);
    const seed_max = @max(seed_edge.a, seed_edge.b);
    const seed_key = edgeKey(seed_min, seed_max);
    try loop_edge_set.put(seed_key, {});
    try loop_edge_keys.append(allocator, seed_key);

    try extendEdgeLoop(
        allocator,
        vertices,
        edges,
        vertex_edges,
        &edge_face_count,
        seed_edge.a,
        seed_edge.b,
        &loop_edge_set,
        &loop_edge_keys,
    );
    try extendEdgeLoop(
        allocator,
        vertices,
        edges,
        vertex_edges,
        &edge_face_count,
        seed_edge.b,
        seed_edge.a,
        &loop_edge_set,
        &loop_edge_keys,
    );

    var midpoint_map = std.AutoHashMap(u64, u32).init(allocator);
    defer midpoint_map.deinit();
    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, vertices);

    var new_vertex_indices = std.ArrayList(u32).empty;
    defer new_vertex_indices.deinit(allocator);

    for (loop_edge_keys.items) |key| {
        if (midpoint_map.contains(key)) continue;

        const min_v: u32 = @intCast(key >> 32);
        const max_v: u32 = @intCast(key & 0xffffffff);

        var mid_vert = vertices[min_v];
        const t = std.math.clamp(slide_factor, 0.05, 0.95);
        mid_vert.position = add3(
            scale3(vertices[min_v].position, 1.0 - t),
            scale3(vertices[max_v].position, t),
        );
        mid_vert.normal = normalize3(scale3(add3(vertices[min_v].normal, vertices[max_v].normal), 0.5));
        mid_vert.uv = .{
            (vertices[min_v].uv[0] + vertices[max_v].uv[0]) * 0.5,
            (vertices[min_v].uv[1] + vertices[max_v].uv[1]) * 0.5,
        };

        const mid_index: u32 = @intCast(next_vertices.items.len);
        try next_vertices.append(allocator, mid_vert);
        try midpoint_map.put(key, mid_index);
        try new_vertex_indices.append(allocator, mid_index);
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);

    var fi: u32 = 0;
    while (fi < face_count) : (fi += 1) {
        const off = @as(usize, fi) * 3;
        const tri = [3]u32{ indices[off], indices[off + 1], indices[off + 2] };

        var split_edges_list: [3]?u32 = .{ null, null, null };
        const edge_pairs = [3][2]u32{
            .{ @min(tri[0], tri[1]), @max(tri[0], tri[1]) },
            .{ @min(tri[1], tri[2]), @max(tri[1], tri[2]) },
            .{ @min(tri[2], tri[0]), @max(tri[2], tri[0]) },
        };

        var split_count: u32 = 0;
        for (edge_pairs, 0..) |ep, idx| {
            const ep_key = (@as(u64, ep[0]) << 32) | @as(u64, ep[1]);
            if (midpoint_map.get(ep_key)) |mid| {
                split_edges_list[idx] = mid;
                split_count += 1;
            }
        }

        if (split_count == 0) {
            try next_indices.appendSlice(allocator, &[_]u32{ tri[0], tri[1], tri[2] });
        } else if (split_count == 1) {
            var split_idx: usize = 0;
            var mid_vi: u32 = undefined;
            for (split_edges_list, 0..) |maybe_mid, idx| {
                if (maybe_mid) |m| {
                    split_idx = idx;
                    mid_vi = m;
                    break;
                }
            }
            const a = tri[split_idx];
            const b = tri[(split_idx + 1) % 3];
            const c = tri[(split_idx + 2) % 3];
            try next_indices.appendSlice(allocator, &[_]u32{ a, mid_vi, c });
            try next_indices.appendSlice(allocator, &[_]u32{ mid_vi, b, c });
        } else if (split_count == 2) {
            var unsplit_idx: usize = 0;
            for (split_edges_list, 0..) |maybe_mid, idx| {
                if (maybe_mid == null) {
                    unsplit_idx = idx;
                    break;
                }
            }
            const a = tri[unsplit_idx];
            const b = tri[(unsplit_idx + 1) % 3];
            const c = tri[(unsplit_idx + 2) % 3];
            const mid_ab = split_edges_list[(unsplit_idx + 1) % 3].?;
            const mid_ca = split_edges_list[(unsplit_idx + 2) % 3].?;
            try next_indices.appendSlice(allocator, &[_]u32{ a, b, mid_ab });
            try next_indices.appendSlice(allocator, &[_]u32{ a, mid_ab, mid_ca });
            try next_indices.appendSlice(allocator, &[_]u32{ mid_ca, mid_ab, c });
        } else {
            const m01 = split_edges_list[0].?;
            const m12 = split_edges_list[1].?;
            const m20 = split_edges_list[2].?;
            try next_indices.appendSlice(allocator, &[_]u32{ tri[0], m01, m20 });
            try next_indices.appendSlice(allocator, &[_]u32{ m01, tri[1], m12 });
            try next_indices.appendSlice(allocator, &[_]u32{ m20, m12, tri[2] });
            try next_indices.appendSlice(allocator, &[_]u32{ m01, m12, m20 });
        }
    }

    recalculateVertexNormals(next_vertices.items, next_indices.items);

    return .{
        .vertices = try next_vertices.toOwnedSlice(allocator),
        .indices = try next_indices.toOwnedSlice(allocator),
        .new_edge_indices = try new_vertex_indices.toOwnedSlice(allocator),
    };
}

fn extendEdgeLoop(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    edges: []const Edge,
    vertex_edges: []const std.ArrayList(u32),
    edge_face_count: *const std.AutoHashMap(u64, u32),
    start_vertex: u32,
    previous_vertex: u32,
    loop_edge_set: *std.AutoHashMap(u64, void),
    loop_edge_keys: *std.ArrayList(u64),
) !void {
    var current_vertex = start_vertex;
    var prev_vertex = previous_vertex;
    var steps: usize = 0;

    while (steps < edges.len) : (steps += 1) {
        var best_edge_index: ?u32 = null;
        var best_next_vertex: u32 = 0;
        var best_score: f32 = -2.0;
        var best_key: u64 = std.math.maxInt(u64);

        const prev_dir = normalize3(sub3(vertices[current_vertex].position, vertices[prev_vertex].position));
        for (vertex_edges[current_vertex].items) |candidate_edge_index| {
            const edge = edges[candidate_edge_index];
            const next_vertex = if (edge.a == current_vertex) edge.b else edge.a;
            if (next_vertex == prev_vertex) {
                continue;
            }

            const key = edgeKey(@min(edge.a, edge.b), @max(edge.a, edge.b));
            if (loop_edge_set.contains(key)) {
                continue;
            }

            const face_count = edge_face_count.get(key) orelse 0;
            if (face_count == 0 or face_count > 2) {
                continue;
            }

            const cand_dir = normalize3(sub3(vertices[next_vertex].position, vertices[current_vertex].position));
            const turn_score = dot3(prev_dir, cand_dir);
            const manifold_bonus: f32 = if (face_count == 2) 0.08 else 0.0;
            const next_valence: f32 = @floatFromInt(vertex_edges[next_vertex].items.len);
            const valence_penalty = @abs(next_valence - 4.0) * 0.02;
            const score = turn_score + manifold_bonus - valence_penalty;
            if (score > best_score or (score == best_score and key < best_key)) {
                best_score = score;
                best_edge_index = candidate_edge_index;
                best_next_vertex = next_vertex;
                best_key = key;
            }
        }

        const chosen_edge_index = best_edge_index orelse break;
        if (best_score < -0.02) {
            break;
        }

        const chosen = edges[chosen_edge_index];
        const chosen_key = edgeKey(@min(chosen.a, chosen.b), @max(chosen.a, chosen.b));
        try loop_edge_set.put(chosen_key, {});
        try loop_edge_keys.append(allocator, chosen_key);

        prev_vertex = current_vertex;
        current_vertex = best_next_vertex;
    }
}

fn splitVertexForEndpoint(endpoint: u32, other: u32, split: EdgeSplit) u32 {
    if (endpoint <= other) {
        return split.min_split;
    }
    return split.max_split;
}

fn meshDataIsValid(vertices: []const engine.assets.MeshVertex, indices: []const u32) bool {
    if (indices.len % 3 != 0) {
        return false;
    }
    for (indices) |index| {
        if (index >= vertices.len) {
            return false;
        }
    }
    for (vertices) |vertex| {
        if (!std.math.isFinite(vertex.position[0]) or
            !std.math.isFinite(vertex.position[1]) or
            !std.math.isFinite(vertex.position[2]))
        {
            return false;
        }
    }
    return true;
}

fn edgeKey(a: u32, b: u32) u64 {
    return (@as(u64, a) << 32) | @as(u64, b);
}

fn distance3(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}

fn compactMeshData(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
) !CompactedMeshData {
    var used = try allocator.alloc(bool, vertices.len);
    defer allocator.free(used);
    @memset(used, false);

    for (indices) |index| {
        if (index < used.len) {
            used[index] = true;
        }
    }

    var remap = try allocator.alloc(u32, vertices.len);
    defer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));

    var compacted_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    errdefer compacted_vertices.deinit(allocator);
    for (vertices, 0..) |vertex, index| {
        if (!used[index]) {
            continue;
        }
        remap[index] = @intCast(compacted_vertices.items.len);
        try compacted_vertices.append(allocator, vertex);
    }

    const compacted_indices = try allocator.alloc(u32, indices.len);
    errdefer allocator.free(compacted_indices);
    for (indices, 0..) |index, dst_index| {
        compacted_indices[dst_index] = remap[index];
    }

    recalculateVertexNormals(compacted_vertices.items, compacted_indices);

    return .{
        .vertices = try compacted_vertices.toOwnedSlice(allocator),
        .indices = compacted_indices,
    };
}

const ExtrudeResult = struct {
    vertices: []engine.assets.MeshVertex,
    indices: []u32,
    selected_faces: []u32,
};

fn extrudeFaceRegion(
    allocator: std.mem.Allocator,
    vertices: []const engine.assets.MeshVertex,
    indices: []const u32,
    selected_faces: []const u32,
    distance_scale: f32,
) !ExtrudeResult {
    var selected_face_mask = try allocator.alloc(bool, indices.len / 3);
    defer allocator.free(selected_face_mask);
    @memset(selected_face_mask, false);
    for (selected_faces) |face_index| {
        if (face_index < selected_face_mask.len) {
            selected_face_mask[face_index] = true;
        }
    }

    var average_normal = [3]f32{ 0.0, 0.0, 0.0 };
    var accumulated_edge_length: f32 = 0.0;
    var accumulated_edge_count: u32 = 0;
    for (selected_faces) |face_index| {
        average_normal = add3(average_normal, faceNormalFromRaw(vertices, indices, face_index));
        const triangle_offset = @as(usize, face_index) * 3;
        if (triangle_offset + 2 >= indices.len) continue;
        const a = indices[triangle_offset];
        const b = indices[triangle_offset + 1];
        const c = indices[triangle_offset + 2];
        accumulated_edge_length += distance3(vertices[a].position, vertices[b].position);
        accumulated_edge_length += distance3(vertices[b].position, vertices[c].position);
        accumulated_edge_length += distance3(vertices[c].position, vertices[a].position);
        accumulated_edge_count += 3;
    }
    average_normal = normalize3(average_normal);
    if (length3(average_normal) <= 0.0001) {
        average_normal = .{ 0.0, 1.0, 0.0 };
    }

    const average_edge_length = if (accumulated_edge_count == 0)
        0.25
    else
        accumulated_edge_length / @as(f32, @floatFromInt(accumulated_edge_count));
    const extrude_distance = std.math.clamp(average_edge_length * distance_scale, -0.9, 0.9);

    var used_vertices = std.AutoHashMap(u32, u32).init(allocator);
    defer used_vertices.deinit();
    var next_vertices = std.ArrayList(engine.assets.MeshVertex).empty;
    defer next_vertices.deinit(allocator);
    try next_vertices.appendSlice(allocator, vertices);

    for (selected_faces) |_| {}
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        var local_vertex: usize = 0;
        while (local_vertex < 3) : (local_vertex += 1) {
            const vertex_index = indices[triangle_offset + local_vertex];
            const gop = try used_vertices.getOrPut(vertex_index);
            if (gop.found_existing) {
                continue;
            }

            var extruded_vertex = vertices[vertex_index];
            extruded_vertex.position = add3(extruded_vertex.position, scale3(average_normal, extrude_distance));
            gop.value_ptr.* = @intCast(next_vertices.items.len);
            try next_vertices.append(allocator, extruded_vertex);
        }
    }

    var edge_entries = std.AutoHashMap(u64, EdgeEntry).init(allocator);
    defer edge_entries.deinit();
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        try recordDirectedEdge(&edge_entries, indices[triangle_offset], indices[triangle_offset + 1]);
        try recordDirectedEdge(&edge_entries, indices[triangle_offset + 1], indices[triangle_offset + 2]);
        try recordDirectedEdge(&edge_entries, indices[triangle_offset + 2], indices[triangle_offset]);
    }

    var next_indices = std.ArrayList(u32).empty;
    defer next_indices.deinit(allocator);
    try next_indices.appendSlice(allocator, indices);

    const top_face_start: u32 = @intCast(next_indices.items.len / 3);
    for (selected_faces) |face_index| {
        const triangle_offset = @as(usize, face_index) * 3;
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset]).?);
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset + 1]).?);
        try next_indices.append(allocator, used_vertices.get(indices[triangle_offset + 2]).?);
    }

    var boundary_iterator = edge_entries.iterator();
    while (boundary_iterator.next()) |entry| {
        if (entry.value_ptr.count != 1) {
            continue;
        }
        const a = entry.value_ptr.directed_a;
        const b = entry.value_ptr.directed_b;
        const a_top = used_vertices.get(a).?;
        const b_top = used_vertices.get(b).?;
        try next_indices.appendSlice(allocator, &[_]u32{
            a,
            b,
            b_top,
            a,
            b_top,
            a_top,
        });
    }

    recalculateVertexNormals(next_vertices.items, next_indices.items);

    const next_selected_faces = try allocator.alloc(u32, selected_faces.len);
    for (selected_faces, 0..) |_, index| {
        next_selected_faces[index] = top_face_start + @as(u32, @intCast(index));
    }

    return .{
        .vertices = try next_vertices.toOwnedSlice(allocator),
        .indices = try allocator.dupe(u32, next_indices.items),
        .selected_faces = next_selected_faces,
    };
}

fn beginInteractiveOperation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    kind: InteractiveMeshOpKind,
) !bool {
    const context = activeContext(state, layer_context) orelse return false;
    const allocator = state.allocator orelse layer_context.world.allocator;

    if (interactive_mesh_op != null) {
        try cancelInteractiveOperation(state, layer_context);
    }

    const required_mode: MeshElementSelectionMode = switch (kind) {
        .extrude, .inset => .face,
        .bevel, .loop_cut => .edge,
    };
    if (state.mesh_edit_selection_mode != required_mode or state.mesh_edit_selected_elements.items.len == 0) {
        return false;
    }

    const base_vertices = try allocator.dupe(engine.assets.MeshVertex, context.mesh.vertices);
    errdefer allocator.free(base_vertices);
    const base_indices = try allocator.dupe(u32, context.mesh.indices);
    errdefer allocator.free(base_indices);
    const selected = try allocator.dupe(u32, state.mesh_edit_selected_elements.items);
    errdefer allocator.free(selected);

    const initial_amount: f32 = switch (kind) {
        .extrude => 0.35,
        .inset => 0.15,
        .bevel => 0.2,
        .loop_cut => 0.5,
    };

    interactive_mesh_op = .{
        .kind = kind,
        .entity_id = context.entity_id,
        .mesh_handle = context.mesh_handle,
        .selection_mode = state.mesh_edit_selection_mode,
        .selected_elements = selected,
        .base_vertices = base_vertices,
        .base_indices = base_indices,
        .seed_edge_index = if (kind == .loop_cut) state.mesh_edit_selected_elements.items[0] else null,
        .amount = initial_amount,
        .start_amount = initial_amount,
        .start_mouse_position = layer_context.input.mouse_position,
    };

    return try applyInteractivePreview(state, layer_context);
}

fn updateInteractiveOperation(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const input = layer_context.input;
    const op = if (interactive_mesh_op) |*value| value else return false;
    const context = activeContext(state, layer_context) orelse {
        try cancelInteractiveOperation(state, layer_context);
        return true;
    };
    if (context.entity_id != op.entity_id or context.mesh_handle != op.mesh_handle) {
        try cancelInteractiveOperation(state, layer_context);
        return true;
    }

    const base_sensitivity = std.math.clamp(state.mesh_modal_drag_sensitivity, 0.0005, 0.05);
    const fine_scale = std.math.clamp(state.mesh_modal_fine_scale, 0.05, 1.0);
    const previous_amount = op.amount;

    if (op.kind == .loop_cut and !input.modifiers.shift) {
        const viewport_width = @max(state.viewport_extent[0], 1.0);
        const local_x = input.mouse_position[0] - state.viewport_origin[0];
        const normalized = std.math.clamp(local_x / viewport_width, 0.0, 1.0);
        op.amount = std.math.clamp(0.05 + normalized * 0.90, 0.05, 0.95);
        op.start_amount = op.amount;
        op.start_mouse_position = input.mouse_position;
    } else {
        const delta = input.mouse_delta[0] - input.mouse_delta[1] * 0.4;
        if (@abs(delta) > 0.0001) {
            const effective_sensitivity = if (input.modifiers.shift)
                base_sensitivity * fine_scale
            else
                base_sensitivity;
            op.amount += delta * effective_sensitivity;
            op.amount = switch (op.kind) {
                .extrude => std.math.clamp(op.amount, -1.5, 1.5),
                .inset => std.math.clamp(op.amount, 0.0, 0.95),
                .bevel => std.math.clamp(op.amount, 0.0, 0.95),
                .loop_cut => std.math.clamp(op.amount, 0.05, 0.95),
            };
        }
    }

    if (@abs(op.amount - previous_amount) > 0.00001) {
        _ = try applyInteractivePreview(state, layer_context);
    }

    if (input.wasMousePressed(.left)) {
        try commitInteractiveOperation(state, layer_context);
        return true;
    }
    if (input.wasMousePressed(.right) or input.wasKeyPressed(.escape)) {
        try cancelInteractiveOperation(state, layer_context);
        return true;
    }
    return true;
}

fn applyInteractivePreview(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const op = interactive_mesh_op orelse return false;
    const context = activeContext(state, layer_context) orelse return false;
    if (context.mesh_handle != op.mesh_handle) {
        return false;
    }

    switch (op.kind) {
        .extrude => {
            const result = try extrudeFaceRegion(
                allocator,
                op.base_vertices,
                op.base_indices,
                op.selected_elements,
                op.amount,
            );
            defer allocator.free(result.vertices);
            defer allocator.free(result.indices);
            defer allocator.free(result.selected_faces);
            if (!meshDataIsValid(result.vertices, result.indices)) {
                return false;
            }
            try applyMeshMutation(state, layer_context, op.mesh_handle, result.vertices, result.indices);
        },
        .inset => {
            const result = try insetFaceRegion(
                allocator,
                op.base_vertices,
                op.base_indices,
                op.selected_elements,
                op.amount,
            );
            defer allocator.free(result.vertices);
            defer allocator.free(result.indices);
            defer allocator.free(result.selected_faces);
            if (!meshDataIsValid(result.vertices, result.indices)) {
                return false;
            }
            try applyMeshMutation(state, layer_context, op.mesh_handle, result.vertices, result.indices);
        },
        .bevel => {
            const edges = try buildEdgeListFromIndices(allocator, op.base_indices);
            defer allocator.free(edges);
            const result = try bevelEdgeRegion(
                allocator,
                op.base_vertices,
                op.base_indices,
                edges,
                op.selected_elements,
                op.amount,
            );
            defer allocator.free(result.vertices);
            defer allocator.free(result.indices);
            if (!meshDataIsValid(result.vertices, result.indices)) {
                return false;
            }
            try applyMeshMutation(state, layer_context, op.mesh_handle, result.vertices, result.indices);
        },
        .loop_cut => {
            const edges = try buildEdgeListFromIndices(allocator, op.base_indices);
            defer allocator.free(edges);
            const seed_edge_index = op.seed_edge_index orelse return false;
            if (seed_edge_index >= edges.len) {
                return false;
            }
            const result = try loopCutMesh(
                allocator,
                op.base_vertices,
                op.base_indices,
                edges,
                seed_edge_index,
                op.amount,
            );
            defer allocator.free(result.vertices);
            defer allocator.free(result.indices);
            defer allocator.free(result.new_edge_indices);
            if (!meshDataIsValid(result.vertices, result.indices)) {
                return false;
            }
            try applyMeshMutation(state, layer_context, op.mesh_handle, result.vertices, result.indices);
        },
    }
    return true;
}

fn buildEdgeListFromIndices(allocator: std.mem.Allocator, indices: []const u32) ![]Edge {
    var edges = std.ArrayList(Edge).empty;
    defer edges.deinit(allocator);
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < indices.len) : (triangle_offset += 3) {
        try appendUniqueEdge(allocator, &edges, &seen, indices[triangle_offset], indices[triangle_offset + 1]);
        try appendUniqueEdge(allocator, &edges, &seen, indices[triangle_offset + 1], indices[triangle_offset + 2]);
        try appendUniqueEdge(allocator, &edges, &seen, indices[triangle_offset + 2], indices[triangle_offset]);
    }

    return try edges.toOwnedSlice(allocator);
}

fn commitInteractiveOperation(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const op = interactive_mesh_op orelse return;

    switch (op.kind) {
        .extrude => {
            try history.captureSnapshotWithLabel(
                state,
                layer_context,
                state.text(.mesh_edit_extrude_action),
                state.text(.mesh_edit_extrude_action),
                .human,
            );
        },
        .inset => {
            try history.captureSnapshotWithLabel(
                state,
                layer_context,
                state.text(.mesh_edit_inset_action),
                state.text(.mesh_edit_inset_action),
                .human,
            );
        },
        .bevel => {
            try history.captureSnapshotWithLabel(
                state,
                layer_context,
                state.text(.mesh_edit_bevel_action),
                state.text(.mesh_edit_bevel_action),
                .human,
            );
        },
        .loop_cut => {
            try history.captureSnapshotWithLabel(
                state,
                layer_context,
                state.text(.mesh_edit_loop_cut_action),
                state.text(.mesh_edit_loop_cut_action),
                .human,
            );
        },
    }

    allocator.free(op.selected_elements);
    allocator.free(op.base_vertices);
    allocator.free(op.base_indices);
    interactive_mesh_op = null;
}

fn cancelInteractiveOperation(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const op = interactive_mesh_op orelse return;
    try applyMeshMutation(state, layer_context, op.mesh_handle, op.base_vertices, op.base_indices);
    allocator.free(op.selected_elements);
    allocator.free(op.base_vertices);
    allocator.free(op.base_indices);
    interactive_mesh_op = null;
}

fn recordDirectedEdge(entries: *std.AutoHashMap(u64, EdgeEntry), a: u32, b: u32) !void {
    const edge_min = @min(a, b);
    const edge_max = @max(a, b);
    const key = (@as(u64, edge_min) << 32) | @as(u64, edge_max);
    const gop = try entries.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{
            .count = 1,
            .directed_a = a,
            .directed_b = b,
        };
        return;
    }
    gop.value_ptr.count += 1;
}

fn applyMeshMutation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    handle: engine.assets.MeshHandle,
    next_vertices: []const engine.assets.MeshVertex,
    next_indices: []const u32,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const mesh = layer_context.world.assets().meshMutable(handle) orelse return error.MeshNotFound;

    allocator.free(mesh.vertices);
    allocator.free(mesh.indices);
    mesh.vertices = try allocator.dupe(engine.assets.MeshVertex, next_vertices);
    mesh.indices = try allocator.dupe(u32, next_indices);
    mesh.local_bounds = engine.assets.computeMeshLocalBounds(mesh.vertices);

    layer_context.renderer.invalidateMainWorldMeshResource(handle);
    layer_context.world.noteMeshResourceChanged(handle);
    layer_context.world.updateHierarchy();
}

fn ensureEditableMeshResource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !?engine.assets.MeshHandle {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const mesh_component = if (entity.mesh) |*mesh| mesh else return null;

    if (mesh_component.handle == null and mesh_component.primitive != .custom) {
        mesh_component.handle = try layer_context.world.assets().ensurePrimitiveMesh(mesh_component.primitive);
    }
    const mesh_handle = mesh_component.handle orelse return null;

    if (meshUsageCount(layer_context.world, mesh_handle) <= 1 and !meshHandleRequiresEditableInstance(layer_context.world, mesh_handle)) {
        return mesh_handle;
    }

    const source = layer_context.world.assets().mesh(mesh_handle) orelse return null;
    const instance_name = try std.fmt.allocPrint(allocator, "{s} Mesh", .{entity.name});
    defer allocator.free(instance_name);

    const new_handle = try layer_context.world.assets().createMesh(.{
        .name = instance_name,
        .vertices = source.vertices,
        .indices = source.indices,
        .primitive_type = source.primitive_type,
    });
    mesh_component.handle = new_handle;
    mesh_component.primitive = .custom;
    layer_context.world.noteEntityRenderableChanged(entity.id);
    layer_context.world.updateHierarchy();
    return new_handle;
}

fn meshHandleRequiresEditableInstance(world: *engine.scene.World, handle: engine.assets.MeshHandle) bool {
    const asset_id = world.assets().meshAssetId(handle) orelse return false;
    const record = world.assets().assetRecordById(asset_id) orelse return true;
    return !std.mem.startsWith(u8, record.source_path, "scene://embedded/");
}

fn meshUsageCount(world: *const engine.scene.World, handle: engine.assets.MeshHandle) usize {
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.mesh) |mesh_component| {
            if (mesh_component.handle == handle) {
                count += 1;
            }
        }
        if (entity.skinned_mesh) |skinned_mesh_component| {
            if (skinned_mesh_component.mesh_handle == handle) {
                count += 1;
            }
        }
    }
    return count;
}

fn appendUniqueEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(Edge),
    seen: *std.AutoHashMap(u64, void),
    a: u32,
    b: u32,
) !void {
    const edge_min = @min(a, b);
    const edge_max = @max(a, b);
    const key = (@as(u64, edge_min) << 32) | @as(u64, edge_max);
    const gop = try seen.getOrPut(key);
    if (gop.found_existing) {
        return;
    }
    try edges.append(allocator, .{ .a = a, .b = b });
}

fn triangleContainsEdge(a: u32, b: u32, c: u32, edge_a: u32, edge_b: u32) bool {
    return (a == edge_a or b == edge_a or c == edge_a) and
        (a == edge_b or b == edge_b or c == edge_b);
}

fn recalculateVertexNormals(vertices: []engine.assets.MeshVertex, indices: []const u32) void {
    for (vertices) |*vertex| {
        vertex.normal = .{ 0.0, 0.0, 0.0 };
    }

    var triangle_offset: usize = 0;
    while (triangle_offset + 2 < indices.len) : (triangle_offset += 3) {
        const a = indices[triangle_offset];
        const b = indices[triangle_offset + 1];
        const c = indices[triangle_offset + 2];
        const face_normal = normalize3(cross3(
            sub3(vertices[b].position, vertices[a].position),
            sub3(vertices[c].position, vertices[a].position),
        ));
        vertices[a].normal = add3(vertices[a].normal, face_normal);
        vertices[b].normal = add3(vertices[b].normal, face_normal);
        vertices[c].normal = add3(vertices[c].normal, face_normal);
    }

    for (vertices) |*vertex| {
        if (length3(vertex.normal) <= 0.0001) {
            vertex.normal = .{ 0.0, 1.0, 0.0 };
        } else {
            vertex.normal = normalize3(vertex.normal);
        }
        if (vertex.tangent[0] == 0.0 and vertex.tangent[1] == 0.0 and vertex.tangent[2] == 0.0) {
            vertex.tangent = .{ 1.0, 0.0, 0.0, 1.0 };
        }
    }
}

fn rayTriangleIntersection(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?struct { distance: f32 } {
    const epsilon: f32 = 0.00001;
    const edge1 = sub3(v1, v0);
    const edge2 = sub3(v2, v0);
    const pvec = cross3(ray_direction, edge2);
    const determinant = dot3(edge1, pvec);
    if (@abs(determinant) <= epsilon) {
        return null;
    }

    const inverse_determinant = 1.0 / determinant;
    const tvec = sub3(ray_origin, v0);
    const u = dot3(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) {
        return null;
    }

    const qvec = cross3(tvec, edge1);
    const v = dot3(ray_direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) {
        return null;
    }

    const distance = dot3(edge2, qvec) * inverse_determinant;
    if (distance <= epsilon) {
        return null;
    }
    return .{ .distance = distance };
}

fn projectWorldPointToViewport(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world_position: [3]f32,
) ?[2]f32 {
    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0 or state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) {
        return null;
    }

    const view = camera.activeCameraViewMatrix(state, layer_context);
    const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));
    const projection = engine.math.mat4.projectionForCamera(camera.activeCameraComponent(state, layer_context), aspect);
    const view_projection = engine.math.mat4.mul(projection, view);
    const clip = transformPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
    if (@abs(clip[3]) <= 0.00001 or clip[3] <= 0.0) {
        return null;
    }

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    if (ndc_x < -1.15 or ndc_x > 1.15 or ndc_y < -1.15 or ndc_y > 1.15) {
        return null;
    }

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn transformPoint(transform: engine.scene.Transform, point: [3]f32) [3]f32 {
    return add3(
        transform.translation,
        engine.math.quat.rotateVec3(transform.rotation, mul3(transform.scale, point)),
    );
}

fn transformPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
}

fn distancePointToSegment2d(point: [2]f32, segment_a: [2]f32, segment_b: [2]f32) f32 {
    const ab = .{ segment_b[0] - segment_a[0], segment_b[1] - segment_a[1] };
    const ap = .{ point[0] - segment_a[0], point[1] - segment_a[1] };
    const ab_len_sq = ab[0] * ab[0] + ab[1] * ab[1];
    if (ab_len_sq <= 0.00001) {
        return distance2d(point, segment_a);
    }

    const t = std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / ab_len_sq, 0.0, 1.0);
    const projected = .{ segment_a[0] + ab[0] * t, segment_a[1] + ab[1] * t };
    return distance2d(point, projected);
}

fn distance2d(a: [2]f32, b: [2]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return @sqrt(dx * dx + dy * dy);
}

fn faceNormalFromRaw(vertices: []const engine.assets.MeshVertex, indices: []const u32, face_index: u32) [3]f32 {
    const triangle_offset = @as(usize, face_index) * 3;
    const a = indices[triangle_offset];
    const b = indices[triangle_offset + 1];
    const c = indices[triangle_offset + 2];
    return normalize3(cross3(sub3(vertices[b].position, vertices[a].position), sub3(vertices[c].position, vertices[a].position)));
}

fn add3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mul3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

fn scale3(v: [3]f32, scalar: f32) [3]f32 {
    return .{ v[0] * scalar, v[1] * scalar, v[2] * scalar };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn length3(v: [3]f32) f32 {
    return @sqrt(dot3(v, v));
}

fn normalize3(v: [3]f32) [3]f32 {
    const len = length3(v);
    if (len <= 0.00001) {
        return .{ 0.0, 0.0, 0.0 };
    }
    return scale3(v, 1.0 / len);
}
