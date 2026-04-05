///! Mesh editing bridge — lives in the root module so it can access
///! both the `guava` module (for MeshOps type) and `editor_backend`
///! (for the actual mesh_edit implementation).
const engine = @import("guava");
const core = engine.core;
const MeshOps = engine.editor_rpc.mesh_ops.MeshOps;
const Snapshot = engine.editor_rpc.mesh_ops.Snapshot;
const SelectionMode = engine.editor_rpc.mesh_ops.SelectionMode;

const EditorState = @import("engine/editor_backend/core/state.zig").EditorState;
const mesh_edit = @import("engine/editor_backend/interaction/mesh_edit.zig");

fn cast(ptr: *anyopaque) *EditorState {
    return @ptrCast(@alignCast(ptr));
}

fn getSnapshot(state_ptr: *anyopaque, layer: *core.LayerContext) Snapshot {
    const s = cast(state_ptr);
    return .{
        .active = mesh_edit.isEditModeActive(s),
        .mode_edit = s.mesh_edit_mode == .edit,
        .selection_mode = switch (s.mesh_edit_selection_mode) {
            .vertex => .vertex,
            .edge => .edge,
            .face => .face,
        },
        .selection_count = @intCast(s.mesh_edit_selected_elements.items.len),
        .entity_id = if (s.mesh_edit_entity) |eid| eid else null,
        .can_enter_edit_mode = mesh_edit.canEnterEditMode(s, layer),
    };
}

fn enterEditMode(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.enterEditMode(cast(state_ptr), layer);
}

fn exitEditMode(state_ptr: *anyopaque, layer: *core.LayerContext) void {
    mesh_edit.exitEditMode(cast(state_ptr), layer);
}

fn setSelectionMode(state_ptr: *anyopaque, mode: SelectionMode) void {
    const native = switch (mode) {
        .vertex => mesh_edit.MeshElementSelectionMode.vertex,
        .edge => mesh_edit.MeshElementSelectionMode.edge,
        .face => mesh_edit.MeshElementSelectionMode.face,
    };
    mesh_edit.setSelectionMode(cast(state_ptr), native);
}

fn selectEntity(state_ptr: *anyopaque, layer: *core.LayerContext, entity_id: u64) anyerror!void {
    _ = cast(state_ptr); // validate pointer
    _ = try layer.renderer.selection_history.replaceSelection(&.{entity_id});
}

fn extrudeFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.extrudeSelectedFaces(cast(state_ptr), layer);
}

fn insetFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.insetSelectedFaces(cast(state_ptr), layer);
}

fn bevelFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.bevelSelectedEdges(cast(state_ptr), layer);
}

fn loopCutFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.loopCut(cast(state_ptr), layer);
}

fn mergeFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.mergeSelectedVertices(cast(state_ptr), layer);
}

fn deleteFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.deleteSelectedElements(cast(state_ptr), layer);
}

fn duplicateFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.duplicateSelectedElements(cast(state_ptr), layer);
}

fn separateFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.separateSelectedFaces(cast(state_ptr), layer);
}

fn recalcNormalsFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.recalculateNormals(cast(state_ptr), layer);
}

fn pivotToSelectionFn(state_ptr: *anyopaque, layer: *core.LayerContext) anyerror!bool {
    return mesh_edit.pivotToSelection(cast(state_ptr), layer);
}

/// Create a MeshOps vtable pointing at the given EditorState.
pub fn init(state: *EditorState) MeshOps {
    return .{
        .state_ptr = @ptrCast(state),
        .getSnapshot = &getSnapshot,
        .enterEditMode = &enterEditMode,
        .exitEditMode = &exitEditMode,
        .setSelectionMode = &setSelectionMode,
        .selectEntity = &selectEntity,
        .extrude = &extrudeFn,
        .inset = &insetFn,
        .bevel = &bevelFn,
        .loopCut = &loopCutFn,
        .merge = &mergeFn,
        .delete = &deleteFn,
        .duplicate = &duplicateFn,
        .separate = &separateFn,
        .recalcNormals = &recalcNormalsFn,
        .pivotToSelection = &pivotToSelectionFn,
    };
}
