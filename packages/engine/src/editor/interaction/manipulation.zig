const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const ai_collaboration = @import("../ai_native/collaboration.zig");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const utils = @import("../common/utils.zig");
const camera = @import("camera.zig");
const history = @import("../actions/history.zig");
const scene_hierarchy = @import("../ui/panels/scene/scene_hierarchy.zig");

const ManipulationMode = state_mod.ManipulationMode;
const TransformSpace = state_mod.TransformSpace;
const AxisConstraint = state_mod.AxisConstraint;
const GizmoDragSession = state_mod.GizmoDragSession;

pub fn handleEditingShortcuts(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const input = layer_context.input;

    // Use wantsTextInput() instead of wantsCaptureKeyboard(): with
    // NavEnableKeyboard the latter is true whenever nav is active —
    // which blocks shortcuts virtually all the time.  wantsTextInput()
    // is scoped to actual InputText editing and won't interfere.
    if (gui.wantsTextInput()) {
        return;
    }

    if (input.modifiers.ctrl and input.wasKeyPressed(.z)) {
        try history.undo(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.y)) {
        try history.redo(state, layer_context);
        return;
    }

    if (input.modifiers.shift and !input.modifiers.ctrl and input.wasKeyPressed(.t)) {
        toggleCursorPlacementMode(state, layer_context);
        return;
    }

    if (state.manipulation_mode != .none) {
        if (input.wasKeyPressed(.q)) {
            try activateSelectTool(state, layer_context);
            return;
        }
        if (input.wasKeyPressed(.x)) {
            toggleManipulationAxis(state, .x);
        }
        if (input.wasKeyPressed(.y)) {
            toggleManipulationAxis(state, .y);
        }
        if (input.wasKeyPressed(.z)) {
            toggleManipulationAxis(state, .z);
        }
        if (input.wasKeyPressed(.space)) {
            try commitActiveTransform(state, layer_context);
        }
        if (input.wasKeyPressed(.escape)) {
            cancelActiveTransform(state, layer_context);
        }
        if (input.wasKeyPressed(.g)) {
            try beginQuickTransform(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.w) and !input.isMouseDown(.right)) {
            try activateTransformTool(state, layer_context, .translate);
        }
        if (input.wasKeyPressed(.e)) {
            try activateTransformTool(state, layer_context, .rotate);
        }
        if (input.wasKeyPressed(.r)) {
            try activateTransformTool(state, layer_context, .scale);
        }
        if (input.wasKeyPressed(.s) and !input.isMouseDown(.right)) {
            try beginQuickTransform(state, layer_context, .scale);
        }
        return;
    }

    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.t)) {
        state.translation_snap_enabled = !state.translation_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.r)) {
        state.rotation_snap_enabled = !state.rotation_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.modifiers.shift and input.wasKeyPressed(.s)) {
        state.scale_snap_enabled = !state.scale_snap_enabled;
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.s)) {
        history.saveScene(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.o)) {
        try history.loadScene(state, layer_context);
        return;
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.n)) {
        try history.newScene(state, layer_context);
        return;
    }

    if (input.wasKeyPressed(.tab)) {
        camera.toggleCameraMode(state, layer_context);
    }
    if (input.wasKeyPressed(.f)) {
        camera.focusSelection(state, layer_context);
    }

    if (input.wasKeyPressed(.delete) or input.wasKeyPressed(.backspace)) {
        try history.deleteSelection(state, layer_context);
    }
    if (input.modifiers.ctrl and input.wasKeyPressed(.d)) {
        try history.duplicateSelection(state, layer_context);
    }
    if (input.wasKeyPressed(.p)) {
        if (input.modifiers.shift) {
            try scene_hierarchy.unparentSelection(state, layer_context);
        } else {
            try scene_hierarchy.parentSelection(state, layer_context);
        }
    }
    if (input.wasKeyPressed(.g)) {
        try beginQuickTransform(state, layer_context, .translate);
    }
    if (input.wasKeyPressed(.q)) {
        try activateSelectTool(state, layer_context);
    }
    if (input.wasKeyPressed(.w) and !input.isMouseDown(.right)) {
        try activateTransformTool(state, layer_context, .translate);
    }
    if (input.wasKeyPressed(.e)) {
        try activateTransformTool(state, layer_context, .rotate);
    }
    if (input.wasKeyPressed(.r)) {
        try activateTransformTool(state, layer_context, .scale);
    }
    if (input.wasKeyPressed(.s) and !input.modifiers.ctrl and !input.isMouseDown(.right)) {
        try beginQuickTransform(state, layer_context, .scale);
    }
    if (input.wasKeyPressed(.one)) {
        try history.spawnPrimitive(state, layer_context, .cube);
    }
    if (input.wasKeyPressed(.two)) {
        try history.spawnPrimitive(state, layer_context, .sphere);
    }
    if (input.wasKeyPressed(.three)) {
        try history.spawnPrimitive(state, layer_context, .plane);
    }
    if (input.wasKeyPressed(.l)) {
        try history.spawnPointLight(state, layer_context);
    }
}

fn toggleManipulationAxis(state: *EditorState, axis: AxisConstraint) void {
    state.manipulation_axis = if (state.manipulation_axis == axis) .free else axis;
}

pub fn toggleCursorPlacementMode(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (state.transform_pivot_mode != .cursor or !state.transform_cursor_place_mode) {
        state.transform_pivot_mode = .cursor;
        state.transform_cursor_place_mode = true;
    } else {
        state.transform_cursor_place_mode = false;
    }
    refreshGizmoState(state, layer_context);
}

pub fn activateTransformTool(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    mode: ManipulationMode,
) !void {
    state.manipulation_mode = mode;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_pivot_local_offset = .{ 0.0, 0.0, 0.0 };
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.gizmo_drag_session = .{};
    state.manipulation_started_from_ui = false;
    clearTransformSnapshot(state);
    try refreshTransformToolTarget(state, layer_context);
    refreshGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
}

pub fn beginQuickTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    mode: ManipulationMode,
) !void {
    try activateTransformTool(state, layer_context, mode);
    state.manipulation_keyboard_mode = true;
    state.gizmo_drag_session = .{ .mode = .mouse_delta };
    if (state.manipulation_entity != null) {
        state.manipulation_drag_active = true;
        ai_collaboration.noteManipulationBegin(state);
    }
}

pub fn activateSelectTool(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    clearTransformTool(state);
    refreshGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
}

pub fn clearTransformTool(state: *EditorState) void {
    clearTransformSnapshot(state);
    state.manipulation_mode = .none;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_pivot_local_offset = .{ 0.0, 0.0, 0.0 };
    state.manipulation_selection_signature = 0;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.gizmo_drag_session = .{};
    state.manipulation_started_from_ui = false;
    clearManipulationBatchState(state);
}

pub fn cancelActiveTransform(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const entity_id = state.manipulation_entity orelse {
        clearTransformTool(state);
        return;
    };
    ai_collaboration.noteManipulationCancel(state, entity_id);
    switch (state.manipulation_target) {
        .main_world => {
            if (state.manipulation_group_origins.items.len > 0) {
                restoreManipulationOrigins(state, layer_context);
            } else {
                _ = layer_context.world.setEntityWorldTransform(entity_id, state.manipulation_origin);
            }
        },
        .staged_preview => ai_collaboration.cancelPreviewEntityTransform(state, layer_context, entity_id, state.manipulation_origin),
    }
    clearTransformTool(state);
    refreshGizmoState(state, layer_context);
}

fn commitActiveTransform(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const entity_id = state.manipulation_entity orelse {
        clearTransformTool(state);
        return;
    };
    ai_collaboration.noteManipulationCommit(state, entity_id);
    if (state.manipulation_target == .staged_preview) {
        const runtime = state.ai_preview_runtime orelse {
            clearTransformTool(state);
            return;
        };
        const transform = runtime.world.worldTransformConst(entity_id) orelse {
            clearTransformTool(state);
            return;
        };
        _ = try ai_collaboration.commitPreviewEntityTransform(state, layer_context, entity_id, transform);
        clearTransformTool(state);
        refreshGizmoState(state, layer_context);
        return;
    }
    if (state.manipulation_batch_snapshot.items.len > 0) {
        const selection_before = layer_context.renderer.selectedEntities();
        state.manipulation_mode = .none;
        state.manipulation_axis = .free;
        state.manipulation_entity = null;
        state.manipulation_target = .main_world;
        state.manipulation_selection_signature = 0;
        state.manipulation_drag_active = false;
        state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
        state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
        state.gizmo_drag_session = .{};
        state.manipulation_started_from_ui = false;
        try history.recordEntityBatchMutation(state, layer_context, &state.manipulation_batch_snapshot, selection_before);
        state.manipulation_batch_snapshot = .empty;
        state.manipulation_group_origins.clearRetainingCapacity();
        refreshGizmoState(state, layer_context);
        return;
    }
    const before = state.manipulation_snapshot orelse {
        clearTransformTool(state);
        return;
    };
    state.manipulation_snapshot = null;
    state.manipulation_mode = .none;
    state.manipulation_axis = .free;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    state.gizmo_drag_session = .{};
    state.manipulation_started_from_ui = false;
    try history.recordEntityMutation(state, layer_context, before, &.{entity_id});
    refreshGizmoState(state, layer_context);
}

fn clearTransformSnapshot(state: *EditorState) void {
    const allocator = state.allocator orelse {
        state.manipulation_snapshot = null;
        return;
    };
    if (state.manipulation_snapshot) |*snapshot| {
        snapshot.deinit(allocator);
        state.manipulation_snapshot = null;
    }
}

fn clearManipulationBatchState(state: *EditorState) void {
    const allocator = state.allocator orelse {
        state.manipulation_batch_snapshot = .empty;
        state.manipulation_group_origins = .empty;
        return;
    };
    for (state.manipulation_batch_snapshot.items) |*snapshot| {
        snapshot.deinit(allocator);
    }
    state.manipulation_batch_snapshot.deinit(allocator);
    state.manipulation_batch_snapshot = .empty;
    state.manipulation_group_origins.deinit(allocator);
    state.manipulation_group_origins = .empty;
}

fn restoreManipulationOrigins(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    for (state.manipulation_group_origins.items) |origin| {
        _ = layer_context.world.setEntityWorldTransform(origin.entity_id, origin.world_transform);
    }
}

fn applyCurrentManipulationToTargets(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: ?engine.scene.Ray,
    quick_mode: bool,
) void {
    if (state.manipulation_target != .main_world or state.manipulation_group_origins.items.len == 0) {
        const entity_id = state.manipulation_entity orelse return;
        var entity_transform = state.manipulation_origin;
        applyManipulationToTransform(state, layer_context, ray, quick_mode, &entity_transform);
        switch (state.manipulation_target) {
            .main_world => _ = layer_context.world.setEntityWorldTransform(entity_id, entity_transform),
            .staged_preview => {
                if (state.ai_preview_runtime) |*runtime| {
                    _ = runtime.world.setEntityWorldTransform(entity_id, entity_transform);
                    runtime.world.updateHierarchy();
                }
            },
        }
        return;
    }

    const saved_origin = state.manipulation_origin;
    const saved_pivot = state.manipulation_pivot_local_offset;
    const saved_session = state.gizmo_drag_session;
    defer {
        state.manipulation_origin = saved_origin;
        state.manipulation_pivot_local_offset = saved_pivot;
        state.gizmo_drag_session = saved_session;
    }

    for (state.manipulation_group_origins.items) |origin| {
        state.manipulation_origin = origin.world_transform;
        state.manipulation_pivot_local_offset = origin.pivot_local_offset;
        if (!quick_mode and ray != null and shouldUseIndividualOriginsLocalSession(state)) {
            state.gizmo_drag_session = buildGizmoDragSessionForTransform(
                state,
                layer_context,
                .{
                    .axis = saved_session.picked_axis,
                    .mode = saved_session.picked_mode,
                    .distance = saved_session.draw_scale,
                },
                .{
                    .origin = saved_session.drag_start_ray_origin,
                    .direction = saved_session.drag_start_ray_direction,
                },
                origin.world_transform,
                origin.pivot_local_offset,
            );
        }
        var entity_transform = origin.world_transform;
        applyManipulationToTransform(state, layer_context, ray, quick_mode, &entity_transform);
        _ = layer_context.world.setEntityWorldTransform(origin.entity_id, entity_transform);
    }
}

fn shouldUseIndividualOriginsLocalSession(state: *const EditorState) bool {
    if (state.manipulation_target != .main_world or
        state.transform_pivot_mode != .individual_origins or
        state.transform_space != .local or
        state.manipulation_group_origins.items.len <= 1)
    {
        return false;
    }
    return switch (state.gizmo_drag_session.picked_mode) {
        .rotate, .scale => true,
        else => false,
    };
}

fn applyManipulationToTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: ?engine.scene.Ray,
    quick_mode: bool,
    entity_transform: *engine.scene.Transform,
) void {
    if (quick_mode) {
        switch (state.manipulation_mode) {
            .none => {},
            .translate => applyQuickTranslate(state, layer_context, entity_transform),
            .rotate => applyQuickRotate(state, entity_transform),
            .scale => applyQuickScale(state, entity_transform),
        }
        return;
    }

    const resolved_ray = ray orelse return;
    switch (state.manipulation_mode) {
        .none => {},
        .translate => applyGizmoDragTranslate(state, layer_context, resolved_ray, entity_transform),
        .rotate => applyGizmoDragRotate(state, resolved_ray, entity_transform),
        .scale => applyGizmoDragScale(state, resolved_ray, entity_transform),
    }
}

pub fn updateActiveTransform(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const input = layer_context.input;

    // Keyboard-mode (Blender-style): mouse moves freely, left-click confirms,
    // right-click cancels.  Do NOT commit on mouse release.
    if (state.manipulation_keyboard_mode and state.manipulation_drag_active) {
        // Right-click or Escape → cancel
        if (input.wasMousePressed(.right)) {
            cancelActiveTransform(state, layer_context);
            return;
        }
        // Left-click → confirm (commit history and end)
        if (input.wasMousePressed(.left)) {
            commitActiveTransform(state, layer_context) catch |err| {
                std.log.err("Failed to commit keyboard manipulation: {}", .{err});
            };
            return;
        }

        // Accumulate mouse delta and apply transform
        state.manipulation_drag_accumulator[0] += input.mouse_delta[0];
        state.manipulation_drag_accumulator[1] += input.mouse_delta[1];
        state.manipulation_accumulated_delta[0] += input.mouse_delta[0];
        state.manipulation_accumulated_delta[1] += input.mouse_delta[1];
        applyCurrentManipulationToTargets(state, layer_context, null, true);
        return;
    }

    // 1. ALWAYS reset UI interaction lock on mouse release to prevent deadlocks
    if (!input.isMouseDown(.left)) {
        state.manipulation_started_from_ui = false;

        if (state.manipulation_drag_active) {
            if (state.manipulation_entity) |entity_id| {
                if (state.manipulation_target == .staged_preview) {
                    if (state.ai_preview_runtime) |*runtime| {
                        if (runtime.world.worldTransformConst(entity_id)) |transform| {
                            _ = ai_collaboration.commitPreviewEntityTransform(state, layer_context, entity_id, transform) catch |err| {
                                std.log.err("Failed to commit preview manipulation: {}", .{err});
                            };
                        }
                    }
                } else if (state.manipulation_batch_snapshot.items.len > 0) {
                    const selection_before = layer_context.renderer.selectedEntities();
                    history.recordEntityBatchMutation(state, layer_context, &state.manipulation_batch_snapshot, selection_before) catch |err| {
                        std.log.err("Failed to commit batch manipulation history: {}", .{err});
                    };
                    state.manipulation_batch_snapshot = .empty;
                    captureManipulationTargets(state, layer_context, entity_id) catch |err| {
                        std.log.err("Failed to refresh manipulation targets: {}", .{err});
                    };
                } else if (state.manipulation_snapshot) |before| {
                    state.manipulation_snapshot = null; // Prevent double free
                    history.recordEntityMutation(state, layer_context, before, &.{entity_id}) catch |err| {
                        std.log.err("Failed to commit manipulation history: {}", .{err});
                    };

                    clearTransformSnapshot(state); // Now safe since snapshot is null
                    if (history.captureEntitySnapshot(state, layer_context.world, entity_id)) |new_snapshot| {
                        state.manipulation_snapshot = new_snapshot;
                    } else |err| {
                        std.log.err("Failed to capture snapshot: {}", .{err});
                    }

                    if (layer_context.world.worldTransform(entity_id)) |transform| {
                        state.manipulation_origin = transform;
                    }
                }
            }
            state.manipulation_drag_active = false;
            state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
            state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
            state.gizmo_drag_session = .{};
        }
        return;
    }

    // 2. If the drag started on a UI element, ignore all movement
    if (state.manipulation_started_from_ui) {
        return;
    }

    const entity_id = state.manipulation_entity orelse return;
    _ = currentToolTargetTransform(state, layer_context, entity_id) orelse {
        clearTransformTool(state);
        return;
    };

    if (!state.manipulation_drag_active) return;

    if (state.gizmo_drag_session.mode != .none and state.gizmo_drag_session.mode != .mouse_delta) {
        const ray = viewportRayUnderCursor(state, layer_context, true) orelse return;
        applyCurrentManipulationToTargets(state, layer_context, ray, false);
        return;
    }

    if (@abs(input.mouse_delta[0]) < 0.0001 and @abs(input.mouse_delta[1]) < 0.0001) {
        return;
    }

    state.manipulation_drag_accumulator[0] += input.mouse_delta[0];
    state.manipulation_drag_accumulator[1] += input.mouse_delta[1];
    state.manipulation_accumulated_delta[0] += input.mouse_delta[0];
    state.manipulation_accumulated_delta[1] += input.mouse_delta[1];

    applyCurrentManipulationToTargets(state, layer_context, null, true);
}

const GizmoViewBasis = struct {
    right: [3]f32,
    up: [3]f32,
    forward: [3]f32,
};

fn effectiveCursorPos(layer_context: *const engine.core.LayerContext) [2]f32 {
    const imgui_mouse_pos = gui.mousePos();
    const invalid_imgui_mouse = !std.math.isFinite(imgui_mouse_pos[0]) or
        !std.math.isFinite(imgui_mouse_pos[1]) or
        imgui_mouse_pos[0] <= -std.math.floatMax(f32) * 0.5 or
        imgui_mouse_pos[1] <= -std.math.floatMax(f32) * 0.5;
    return if (invalid_imgui_mouse) layer_context.input.mouse_position else imgui_mouse_pos;
}

fn viewportPixelUnderCursor(
    state: *const EditorState,
    layer_context: *const engine.core.LayerContext,
    clamp_to_viewport: bool,
) ?[2]u32 {
    if (state.viewport_extent[0] <= 1.0 or state.viewport_extent[1] <= 1.0) return null;

    const mouse_pos = effectiveCursorPos(layer_context);
    var local_x = mouse_pos[0] - state.viewport_origin[0];
    var local_y = mouse_pos[1] - state.viewport_origin[1];
    if (clamp_to_viewport) {
        local_x = std.math.clamp(local_x, 0.0, state.viewport_extent[0]);
        local_y = std.math.clamp(local_y, 0.0, state.viewport_extent[1]);
    } else if (local_x < 0.0 or local_y < 0.0 or local_x > state.viewport_extent[0] or local_y > state.viewport_extent[1]) {
        return null;
    }

    const viewport_size = layer_context.renderer.sceneViewportSize();
    if (viewport_size[0] == 0 or viewport_size[1] == 0) return null;

    const normalized_x = std.math.clamp(local_x / state.viewport_extent[0], 0.0, 1.0);
    const normalized_y = std.math.clamp(local_y / state.viewport_extent[1], 0.0, 1.0);
    return .{
        @as(u32, @intFromFloat(std.math.clamp(
            normalized_x * @as(f32, @floatFromInt(viewport_size[0])),
            0.0,
            @as(f32, @floatFromInt(viewport_size[0] - 1)),
        ))),
        @as(u32, @intFromFloat(std.math.clamp(
            normalized_y * @as(f32, @floatFromInt(viewport_size[1])),
            0.0,
            @as(f32, @floatFromInt(viewport_size[1] - 1)),
        ))),
    };
}

fn viewportRayUnderCursor(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    clamp_to_viewport: bool,
) ?engine.scene.Ray {
    const pixel = viewportPixelUnderCursor(state, layer_context, clamp_to_viewport) orelse return null;
    const viewport_size = layer_context.renderer.sceneViewportSize();
    return camera.activeCameraRayFromViewportPixel(state, layer_context, pixel, viewport_size);
}

fn safeNormalizeOr(vector: [3]f32, fallback: [3]f32) [3]f32 {
    if (vec3.length(vector) <= 0.0001) return vec3.normalize(fallback);
    return vec3.normalize(vector);
}

fn currentGizmoViewBasis(state: *const EditorState, layer_context: *engine.core.LayerContext) GizmoViewBasis {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    return .{
        .right = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 1.0, 0.0, 0.0 })),
        .up = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 1.0, 0.0 })),
        .forward = vec3.normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 })),
    };
}

fn rayPlaneHitPoint(ray: engine.scene.Ray, plane_origin: [3]f32, plane_normal: [3]f32) ?[3]f32 {
    const normal = safeNormalizeOr(plane_normal, .{ 0.0, 0.0, -1.0 });
    const denom = vec3.dot(ray.direction, normal);
    if (@abs(denom) < 1e-5) return null;

    const t = vec3.dot(vec3.sub(plane_origin, ray.origin), normal) / denom;
    if (t < 0.0) return null;
    return vec3.add(ray.origin, vec3.scale(ray.direction, t));
}

fn axisHandleDragPlaneNormal(axis_world: [3]f32, camera_forward: [3]f32, camera_up: [3]f32) [3]f32 {
    const view_cross_axis = vec3.cross(camera_forward, axis_world);
    var normal = vec3.cross(axis_world, view_cross_axis);
    if (vec3.length(normal) <= 0.0001) {
        normal = vec3.cross(axis_world, camera_up);
    }
    if (vec3.length(normal) <= 0.0001) {
        normal = vec3.cross(axis_world, .{ 1.0, 0.0, 0.0 });
    }
    return safeNormalizeOr(normal, camera_forward);
}

fn uniformScaleDragDirection(camera_right: [3]f32, camera_up: [3]f32) [3]f32 {
    return safeNormalizeOr(vec3.add(camera_right, camera_up), camera_right);
}

fn signedRotationAroundAxis(from_vector: [3]f32, to_vector: [3]f32, axis: [3]f32) f32 {
    const from_norm = safeNormalizeOr(from_vector, .{ 1.0, 0.0, 0.0 });
    const to_norm = safeNormalizeOr(to_vector, .{ 1.0, 0.0, 0.0 });
    const axis_norm = safeNormalizeOr(axis, .{ 0.0, 1.0, 0.0 });
    const cross_value = vec3.cross(from_norm, to_norm);
    const sin_angle = vec3.dot(axis_norm, cross_value);
    const cos_angle = std.math.clamp(vec3.dot(from_norm, to_norm), -1.0, 1.0);
    return std.math.atan2(sin_angle, cos_angle);
}

fn buildGizmoDragSessionForTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    picked_handle: PickedGizmoHandle,
    ray: engine.scene.Ray,
    entity_transform: engine.scene.Transform,
    pivot_local_offset: [3]f32,
) GizmoDragSession {
    const camera_basis = currentGizmoViewBasis(state, layer_context);
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const axis_world = if (picked_handle.axis == .free)
        [3]f32{ 0.0, 0.0, 0.0 }
    else
        gizmoAxisDirection(state.transform_space, picked_handle.axis, entity_transform.rotation);
    const gizmo_origin = pivotWorldPosition(entity_transform, pivot_local_offset);
    const gizmo_scale_value = gizmoDrawScale(camera_transform.translation, gizmo_origin);

    var projection = GizmoDragSession{
        .mode = .mouse_delta,
        .picked_mode = picked_handle.mode,
        .picked_axis = picked_handle.axis,
        .plane_origin = gizmo_origin,
        .plane_normal = camera_basis.forward,
        .handle_axis_world = if (picked_handle.axis == .free) uniformScaleDragDirection(camera_basis.right, camera_basis.up) else axis_world,
        .drag_start_ray_origin = ray.origin,
        .drag_start_ray_direction = ray.direction,
        .draw_scale = gizmo_scale_value,
    };

    switch (picked_handle.mode) {
        .translate => {
            if (picked_handle.axis == .free) {
                projection.mode = .move_plane;
                projection.plane_normal = camera_basis.forward;
            } else {
                projection.mode = .move_axis;
                projection.plane_normal = axisHandleDragPlaneNormal(axis_world, camera_basis.forward, camera_basis.up);
            }
            projection.drag_start_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.mode = .mouse_delta;
                return projection;
            };
        },
        .rotate => {
            projection.mode = .rotate_ring;
            projection.handle_axis_world = axis_world;
            projection.plane_normal = safeNormalizeOr(axis_world, camera_basis.up);
            const start_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.mode = .mouse_delta;
                return projection;
            };
            projection.drag_start_vector = vec3.sub(start_point, projection.plane_origin);
            if (vec3.length(projection.drag_start_vector) <= 0.0001) {
                projection.mode = .mouse_delta;
                return projection;
            }
            projection.drag_start_vector = vec3.normalize(projection.drag_start_vector);
        },
        .scale => {
            if (picked_handle.axis == .free) {
                projection.mode = .uniform_scale;
                projection.plane_normal = camera_basis.forward;
                projection.handle_axis_world = uniformScaleDragDirection(camera_basis.right, camera_basis.up);
            } else {
                projection.mode = .axis_scale;
                projection.plane_normal = axisHandleDragPlaneNormal(axis_world, camera_basis.forward, camera_basis.up);
            }
            projection.drag_start_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse {
                projection.mode = .mouse_delta;
                return projection;
            };
            if (picked_handle.axis == .free) {
                const start_offset = vec3.sub(projection.drag_start_point, projection.plane_origin);
                const fallback_distance = @max(projection.draw_scale * 0.18, 0.05);
                const start_distance = vec3.length(start_offset);
                projection.drag_start_distance = @max(start_distance, fallback_distance);
                projection.drag_start_vector = if (start_distance > 0.0001)
                    vec3.normalize(start_offset)
                else
                    camera_basis.right;
            }
        },
        .none => projection.mode = .none,
    }

    return projection;
}

fn startGizmoDragSession(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    picked_handle: PickedGizmoHandle,
    ray: engine.scene.Ray,
) void {
    const entity_id = state.manipulation_entity orelse {
        state.gizmo_drag_session = .{ .mode = .mouse_delta };
        return;
    };
    const entity_transform = currentToolTargetTransform(state, layer_context, entity_id) orelse {
        state.gizmo_drag_session = .{ .mode = .mouse_delta };
        return;
    };
    state.gizmo_drag_session = buildGizmoDragSessionForTransform(
        state,
        layer_context,
        picked_handle,
        ray,
        entity_transform,
        state.manipulation_pivot_local_offset,
    );
}

fn applyGizmoDragTranslate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    const projection = state.gizmo_drag_session;
    const current_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse return;
    const pivot_origin = currentManipulationPivotWorldPosition(state);

    var target = switch (projection.mode) {
        .move_plane => vec3.add(
            pivot_origin,
            vec3.sub(current_point, projection.drag_start_point),
        ),
        .move_axis => vec3.add(
            pivot_origin,
            vec3.scale(
                projection.handle_axis_world,
                vec3.dot(vec3.sub(current_point, projection.drag_start_point), projection.handle_axis_world),
            ),
        ),
        else => return,
    };

    var snap_result = ResolvedPivotSnap{ .position = target };
    if (state.translation_snap_enabled) {
        snap_result = snapPivotTargetPosition(state, layer_context, ray, target);
        target = snap_result.position;
    }

    if (snap_result.normal) |surface_normal| {
        if (state.surface_snap_align_rotation_to_normal) {
            entity_transform.rotation = alignedRotationToSurfaceNormal(state.manipulation_origin.rotation, surface_normal);
        }
    }
    setTransformPivotPosition(entity_transform, state.manipulation_pivot_local_offset, target);
}

fn applyGizmoDragRotate(
    state: *EditorState,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    const projection = state.gizmo_drag_session;
    const current_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse return;
    const current_vector = vec3.sub(current_point, projection.plane_origin);
    if (vec3.length(current_vector) <= 0.0001) return;

    var angle = signedRotationAroundAxis(projection.drag_start_vector, current_vector, projection.handle_axis_world);
    if (state.rotation_snap_enabled) {
        const snap_radians = state.rotation_snap_step_degrees * std.math.pi / 180.0;
        angle = @round(angle / snap_radians) * snap_radians;
    }

    entity_transform.rotation = switch (state.transform_space) {
        .local => quat.normalize(quat.mul(
            state.manipulation_origin.rotation,
            quat.fromAxisAngle(engine.math.axis.vector(state.manipulation_axis), angle),
        )),
        .world => quat.normalize(quat.mul(
            quat.fromAxisAngle(projection.handle_axis_world, angle),
            state.manipulation_origin.rotation,
        )),
    };
    const delta_rotation = switch (state.transform_space) {
        .local => quat.fromAxisAngle(projection.handle_axis_world, angle),
        .world => quat.fromAxisAngle(projection.handle_axis_world, angle),
    };
    const pivot_origin = currentManipulationPivotWorldPosition(state);
    const origin_offset = vec3.sub(state.manipulation_origin.translation, pivot_origin);
    entity_transform.translation = vec3.add(
        pivot_origin,
        engine.math.quat.rotateVec3(delta_rotation, origin_offset),
    );
}

fn applyGizmoDragScale(
    state: *EditorState,
    ray: engine.scene.Ray,
    entity_transform: *engine.scene.Transform,
) void {
    const projection = state.gizmo_drag_session;
    const current_point = rayPlaneHitPoint(ray, projection.plane_origin, projection.plane_normal) orelse return;
    const amount = vec3.dot(vec3.sub(current_point, projection.drag_start_point), projection.handle_axis_world) /
        @max(projection.draw_scale, 0.05);
    const uniform_scalar = blk: {
        const current_offset = vec3.sub(current_point, projection.plane_origin);
        const current_distance = vec3.length(current_offset);
        if (current_distance <= 0.0001) break :blk @as(f32, 0.05);

        const current_direction = vec3.normalize(current_offset);
        const same_side = vec3.dot(current_direction, projection.drag_start_vector);
        if (same_side < -0.1) break :blk @as(f32, 0.05);

        break :blk std.math.clamp(
            current_distance / @max(projection.drag_start_distance, 0.05),
            0.05,
            20.0,
        );
    };
    const axis_scalar = @max(0.05, 1.0 + amount);

    var raw_scale = state.manipulation_origin.scale;
    switch (projection.mode) {
        .uniform_scale => {
            raw_scale[0] *= uniform_scalar;
            raw_scale[1] *= uniform_scalar;
            raw_scale[2] *= uniform_scalar;
        },
        .axis_scale => switch (state.manipulation_axis) {
            .free => {
                raw_scale[0] *= axis_scalar;
                raw_scale[1] *= axis_scalar;
                raw_scale[2] *= axis_scalar;
            },
            .x => raw_scale[0] *= axis_scalar,
            .y => raw_scale[1] *= axis_scalar,
            .z => raw_scale[2] *= axis_scalar,
        },
        else => return,
    }

    if (state.scale_snap_enabled) {
        raw_scale = snapScaleFromOrigin(state.manipulation_origin.scale, raw_scale, state.scale_snap_step);
    }

    entity_transform.scale = .{
        utils.clampScale(raw_scale[0]),
        utils.clampScale(raw_scale[1]),
        utils.clampScale(raw_scale[2]),
    };
    setTransformPivotPosition(entity_transform, state.manipulation_pivot_local_offset, currentManipulationPivotWorldPosition(state));
}

pub fn applyQuickTranslate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_transform: *engine.scene.Transform,
) void {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const camera_euler = quat.toEuler(camera_transform.rotation);
    const right = vec3.rightFromYaw(camera_euler[1]);
    const forward = vec3.forwardFromAngles(camera_euler[1], camera_euler[0]);
    const up = vec3.normalize(vec3.cross(right, forward));

    // 使用manipulation_origin锁定距离计算，防止操作过程中的速率抖动
    const distance = @max(vec3.length(vec3.sub(camera_transform.translation, state.manipulation_origin.translation)), 1.0);
    const move_scale = distance * state.translation_drag_sensitivity;

    const pivot_origin = currentManipulationPivotWorldPosition(state);
    var pivot_target = pivot_origin;

    // 基于累计偏移量计算
    switch (state.manipulation_axis) {
        .free => {
            const delta = vec3.add(
                vec3.scale(right, state.manipulation_accumulated_delta[0] * move_scale),
                vec3.scale(up, state.manipulation_accumulated_delta[1] * move_scale),
            );
            pivot_target = vec3.add(pivot_origin, delta);
        },
        .x, .y, .z => {
            const axis = gizmoAxisDirection(state.transform_space, state.manipulation_axis, state.manipulation_origin.rotation);
            const scalar = combinedMouseDrag(state.manipulation_accumulated_delta) * move_scale;
            pivot_target = vec3.add(pivot_origin, vec3.scale(axis, scalar));
        },
    }

    var snap_result = ResolvedPivotSnap{ .position = pivot_target };
    if (state.translation_snap_enabled) {
        const ray = viewportRayUnderCursor(state, layer_context, true) orelse {
            setTransformPivotPosition(entity_transform, state.manipulation_pivot_local_offset, pivot_target);
            return;
        };
        snap_result = snapPivotTargetPosition(state, layer_context, ray, pivot_target);
        pivot_target = snap_result.position;
    }
    if (snap_result.normal) |surface_normal| {
        if (state.surface_snap_align_rotation_to_normal) {
            entity_transform.rotation = alignedRotationToSurfaceNormal(state.manipulation_origin.rotation, surface_normal);
        }
    }
    setTransformPivotPosition(entity_transform, state.manipulation_pivot_local_offset, pivot_target);
}
pub fn applyQuickRotate(state: *EditorState, entity_transform: *engine.scene.Transform) void {
    // 基于累计偏移量计算旋转
    const scalar = combinedMouseDrag(state.manipulation_accumulated_delta) * state.rotation_drag_sensitivity;
    const origin_euler = quat.toEuler(state.manipulation_origin.rotation);
    var euler = origin_euler;

    switch (state.manipulation_axis) {
        .free => {
            euler[1] -= state.manipulation_accumulated_delta[0] * state.rotation_drag_sensitivity;
            euler[0] -= state.manipulation_accumulated_delta[1] * state.rotation_drag_sensitivity;
        },
        .x => euler[0] += scalar,
        .y => euler[1] += scalar,
        .z => euler[2] += scalar,
    }

    // 对计算出的绝对值进行Snap，不污染下一次计算
    if (state.rotation_snap_enabled) {
        const snap_radians = state.rotation_snap_step_degrees * std.math.pi / 180.0;
        const delta_x = euler[0] - origin_euler[0];
        const delta_y = euler[1] - origin_euler[1];
        const delta_z = euler[2] - origin_euler[2];

        euler = .{
            origin_euler[0] + @round(delta_x / snap_radians) * snap_radians,
            origin_euler[1] + @round(delta_y / snap_radians) * snap_radians,
            origin_euler[2] + @round(delta_z / snap_radians) * snap_radians,
        };
    }

    entity_transform.rotation = quat.fromEuler(euler);
    const pivot_origin = currentManipulationPivotWorldPosition(state);
    const delta_rotation = quat.mul(entity_transform.rotation, quat.inverse(state.manipulation_origin.rotation));
    const origin_offset = vec3.sub(state.manipulation_origin.translation, pivot_origin);
    entity_transform.translation = vec3.add(
        pivot_origin,
        engine.math.quat.rotateVec3(delta_rotation, origin_offset),
    );
}

pub fn applyQuickScale(state: *EditorState, entity_transform: *engine.scene.Transform) void {
    // 使用累计偏移量计算标量
    const scalar = 1.0 + combinedMouseDrag(state.manipulation_accumulated_delta) * state.scale_drag_sensitivity;

    // 始终从原点计算，避免精度丢失
    var raw_scale = state.manipulation_origin.scale;
    switch (state.manipulation_axis) {
        .free => {
            raw_scale[0] *= scalar;
            raw_scale[1] *= scalar;
            raw_scale[2] *= scalar;
        },
        .x => raw_scale[0] *= scalar,
        .y => raw_scale[1] *= scalar,
        .z => raw_scale[2] *= scalar,
    }

    // 对绝对值进行Snap，不污染下一次计算
    if (state.scale_snap_enabled) {
        const origin = state.manipulation_origin.scale;
        const snap = state.scale_snap_step;
        const delta_x = raw_scale[0] - origin[0];
        const delta_y = raw_scale[1] - origin[1];
        const delta_z = raw_scale[2] - origin[2];

        raw_scale = .{
            origin[0] + @round(delta_x / snap) * snap,
            origin[1] + @round(delta_y / snap) * snap,
            origin[2] + @round(delta_z / snap) * snap,
        };
    }

    entity_transform.scale = .{
        utils.clampScale(raw_scale[0]),
        utils.clampScale(raw_scale[1]),
        utils.clampScale(raw_scale[2]),
    };
    setTransformPivotPosition(entity_transform, state.manipulation_pivot_local_offset, currentManipulationPivotWorldPosition(state));
}

pub fn refreshGizmoState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    refreshTransformToolTarget(state, layer_context) catch |err| {
        std.log.err("failed to refresh transform tool target: {}", .{err});
    };
    if (!state.manipulation_drag_active) {
        if (state.manipulation_entity) |entity_id| {
            if (currentManipulationWorld(state, layer_context)) |world| {
                state.manipulation_pivot_local_offset = computePivotLocalOffsetForEntity(state, layer_context, world, entity_id);
            }
        } else {
            state.manipulation_pivot_local_offset = .{ 0.0, 0.0, 0.0 };
        }
    }
    layer_context.renderer.setEditorGizmoState(.{
        .mode = switch (state.manipulation_mode) {
            .none => .idle,
            .translate => .translate,
            .rotate => .rotate,
            .scale => .scale,
        },
        .axis = state.manipulation_axis,
        .space = switch (state.transform_space) {
            .local => .local,
            .world => .world,
        },
    });
    syncEditorGizmoTransformOverride(state, layer_context);
}

fn refreshTransformToolTarget(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.manipulation_mode == .none or state.manipulation_drag_active) {
        if (state.manipulation_mode == .none) {
            clearTransformSnapshot(state);
            state.manipulation_entity = null;
            state.manipulation_pivot_local_offset = .{ 0.0, 0.0, 0.0 };
            state.manipulation_selection_signature = 0;
            clearManipulationBatchState(state);
        }
        return;
    }

    const next = nextTransformToolTarget(state, layer_context);
    const selection_signature = currentManipulationSelectionSignature(state, layer_context, next.target);

    if (next.entity_id == state.manipulation_entity and
        next.target == state.manipulation_target and
        selection_signature == state.manipulation_selection_signature)
    {
        return;
    }

    clearTransformSnapshot(state);
    clearManipulationBatchState(state);
    state.manipulation_entity = next.entity_id;
    state.manipulation_target = next.target;
    state.manipulation_selection_signature = selection_signature;
    state.manipulation_pivot_local_offset = .{ 0.0, 0.0, 0.0 };
    state.manipulation_drag_active = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };

    if (next.entity_id) |entity_id| {
        try captureManipulationTargets(state, layer_context, entity_id);
    }
}

const NextTransformToolTarget = struct {
    entity_id: ?engine.scene.EntityId = null,
    target: state_mod.ManipulationTarget = .main_world,
};

fn nextTransformToolTarget(state: *EditorState, layer_context: *engine.core.LayerContext) NextTransformToolTarget {
    if (state.ai_preview_selected_entity) |entity_id| {
        if (state.ai_preview_runtime) |*runtime| {
            if (runtime.world.hasEntity(entity_id)) {
                return .{
                    .entity_id = entity_id,
                    .target = .staged_preview,
                };
            }
        }
    }

    const selected = layer_context.renderer.selectedEntity();
    const next_entity = blk: {
        const entity_id = selected orelse break :blk null;
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            break :blk null;
        }
        if (utils.isEntitySelectionLocked(state, entity_id)) {
            break :blk null;
        }
        break :blk entity_id;
    };
    return .{
        .entity_id = next_entity,
        .target = .main_world,
    };
}

fn currentManipulationSelectionSignature(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    target: state_mod.ManipulationTarget,
) u64 {
    var hash: u64 = 1469598103934665603;
    switch (target) {
        .main_world => {
            for (layer_context.renderer.selectedEntities()) |entity_id| {
                hash ^= @as(u64, entity_id);
                hash *%= 1099511628211;
            }
        },
        .staged_preview => {
            if (state.ai_preview_selected_entity) |entity_id| {
                hash ^= @as(u64, entity_id);
                hash *%= 1099511628211;
            }
        },
    }
    return hash;
}

fn captureManipulationTargets(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) !void {
    state.manipulation_origin = currentToolTargetTransform(state, layer_context, entity_id) orelse return;
    const world = currentManipulationWorld(state, layer_context) orelse return;
    state.manipulation_pivot_local_offset = computePivotLocalOffsetForEntity(state, layer_context, world, entity_id);

    if (state.manipulation_target != .main_world) {
        return;
    }

    const selection = layer_context.renderer.selectedEntities();
    if (selection.len <= 1) {
        state.manipulation_snapshot = try history.captureEntitySnapshot(state, layer_context.world, entity_id);
        return;
    }

    state.manipulation_batch_snapshot = try history.captureEntitySnapshots(state, layer_context.world, selection);
    const allocator = state.allocator orelse layer_context.world.allocator;
    try state.manipulation_group_origins.ensureTotalCapacity(allocator, selection.len);
    for (selection) |selected_entity_id| {
        if (selectionContainsAncestor(layer_context.world, selection, selected_entity_id)) continue;
        const selected_transform = layer_context.world.worldTransformConst(selected_entity_id) orelse continue;
        try state.manipulation_group_origins.append(allocator, .{
            .entity_id = selected_entity_id,
            .world_transform = selected_transform,
            .pivot_local_offset = computePivotLocalOffsetForEntity(state, layer_context, layer_context.world, selected_entity_id),
        });
    }
}

fn selectionContainsAncestor(
    world: *const engine.scene.World,
    selection: []const engine.scene.EntityId,
    entity_id: engine.scene.EntityId,
) bool {
    var current = (world.getEntityConst(entity_id) orelse return false).parent;
    while (current) |parent_id| {
        for (selection) |selected_id| {
            if (selected_id == parent_id) {
                return true;
            }
        }
        current = if (world.getEntityConst(parent_id)) |parent_entity|
            parent_entity.parent
        else
            null;
    }
    return false;
}

fn currentToolTargetTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) ?engine.scene.Transform {
    return switch (state.manipulation_target) {
        .main_world => layer_context.world.worldTransform(entity_id),
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            runtime.world.worldTransformConst(entity_id)
        else
            null,
    };
}

fn currentManipulationWorld(state: *EditorState, layer_context: *engine.core.LayerContext) ?*engine.scene.World {
    return switch (state.manipulation_target) {
        .main_world => layer_context.world,
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            &runtime.world
        else
            null,
    };
}

fn syncEditorGizmoTransformOverride(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const next = nextTransformToolTarget(state, layer_context);
    const entity_id = next.entity_id orelse {
        layer_context.renderer.setEditorGizmoTransformOverride(null);
        return;
    };

    const world = switch (next.target) {
        .main_world => layer_context.world,
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            &runtime.world
        else {
            layer_context.renderer.setEditorGizmoTransformOverride(null);
            return;
        },
    };

    const transform = switch (next.target) {
        .main_world => layer_context.world.worldTransform(entity_id),
        .staged_preview => world.worldTransformConst(entity_id),
    } orelse {
        layer_context.renderer.setEditorGizmoTransformOverride(null);
        return;
    };

    const pivot_local_offset = computePivotLocalOffsetForEntity(state, layer_context, world, entity_id);
    if (vec3.length(pivot_local_offset) <= 0.0001) {
        layer_context.renderer.setEditorGizmoTransformOverride(null);
        return;
    }

    var gizmo_transform = transform;
    gizmo_transform.translation = pivotWorldPosition(transform, pivot_local_offset);
    layer_context.renderer.setEditorGizmoTransformOverride(gizmo_transform);
}

fn computePivotLocalOffsetForEntity(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
) [3]f32 {
    if (state.transform_pivot_mode == .origin) {
        return .{ 0.0, 0.0, 0.0 };
    }

    const entity = world.getEntityConst(entity_id) orelse return .{ 0.0, 0.0, 0.0 };
    const transform = world.worldTransformConst(entity_id) orelse entity.local_transform;
    const pivot_world = computePivotWorldPositionForEntity(state, layer_context, world, entity_id, entity, transform);
    return worldPointToLocal(transform, pivot_world);
}

fn computePivotWorldPositionForEntity(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    entity: anytype,
    transform: engine.scene.Transform,
) [3]f32 {
    return switch (state.transform_pivot_mode) {
        .origin => transform.translation,
        .bounds_center => boundsCenterPivotWorldPosition(world, entity_id, entity, transform),
        .median_point => selectionMedianPivotWorldPosition(state, layer_context, world, transform),
        .active_element => activeElementPivotWorldPosition(state, layer_context, world, transform),
        .cursor => state.transform_cursor_world_position,
        .individual_origins => transform.translation,
    };
}

fn boundsCenterPivotWorldPosition(
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    entity: anytype,
    transform: engine.scene.Transform,
) [3]f32 {
    if (entity.mesh) |mesh_component| {
        if (mesh_component.handle) |mesh_handle| {
            if (world.resources.mesh(mesh_handle)) |mesh| {
                return localPointToWorld(transform, mesh.local_bounds.centroid());
            }
        }
    }
    if (entity.skinned_mesh) |skinned_mesh_component| {
        if (skinned_mesh_component.mesh_handle) |mesh_handle| {
            if (world.resources.mesh(mesh_handle)) |mesh| {
                return localPointToWorld(transform, mesh.local_bounds.centroid());
            }
        }
    }
    if (world.worldBoundsConst(entity_id)) |bounds| {
        return bounds.centroid();
    }
    return transform.translation;
}

fn selectionMedianPivotWorldPosition(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world: *const engine.scene.World,
    fallback_transform: engine.scene.Transform,
) [3]f32 {
    var sum = [3]f32{ 0.0, 0.0, 0.0 };
    var count: usize = 0;

    switch (state.manipulation_target) {
        .main_world => {
            for (layer_context.renderer.selectedEntities()) |selected_entity_id| {
                if (world.worldTransformConst(selected_entity_id)) |selected_transform| {
                    sum = vec3.add(sum, selected_transform.translation);
                    count += 1;
                }
            }
        },
        .staged_preview => {
            if (state.ai_preview_selected_entity) |selected_entity_id| {
                if (world.worldTransformConst(selected_entity_id)) |selected_transform| {
                    sum = vec3.add(sum, selected_transform.translation);
                    count += 1;
                }
            }
        },
    }

    if (count == 0) {
        return fallback_transform.translation;
    }
    return vec3.scale(sum, 1.0 / @as(f32, @floatFromInt(count)));
}

fn activeElementPivotWorldPosition(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    world: *const engine.scene.World,
    fallback_transform: engine.scene.Transform,
) [3]f32 {
    const active_entity_id = switch (state.manipulation_target) {
        .main_world => layer_context.renderer.selectedEntity(),
        .staged_preview => state.ai_preview_selected_entity,
    } orelse return fallback_transform.translation;

    return if (world.worldTransformConst(active_entity_id)) |active_transform|
        active_transform.translation
    else
        fallback_transform.translation;
}

fn gizmoAxisDirection(space: TransformSpace, axis: state_mod.AxisConstraint, rotation: [4]f32) [3]f32 {
    const base_axis = engine.math.axis.vector(axis);
    return switch (space) {
        .world => base_axis,
        .local => engine.math.quat.rotateVec3(rotation, base_axis),
    };
}

fn pivotWorldPosition(transform: engine.scene.Transform, pivot_local_offset: [3]f32) [3]f32 {
    return localPointToWorld(transform, pivot_local_offset);
}

fn currentManipulationPivotWorldPosition(state: *const EditorState) [3]f32 {
    return pivotWorldPosition(state.manipulation_origin, state.manipulation_pivot_local_offset);
}

fn setTransformPivotPosition(
    transform: *engine.scene.Transform,
    pivot_local_offset: [3]f32,
    pivot_world_position: [3]f32,
) void {
    transform.translation = vec3.sub(
        pivot_world_position,
        engine.math.quat.rotateVec3(transform.rotation, componentMul(transform.scale, pivot_local_offset)),
    );
}

fn localPointToWorld(transform: engine.scene.Transform, local_point: [3]f32) [3]f32 {
    return vec3.add(
        transform.translation,
        engine.math.quat.rotateVec3(transform.rotation, componentMul(transform.scale, local_point)),
    );
}

fn worldPointToLocal(transform: engine.scene.Transform, world_point: [3]f32) [3]f32 {
    const offset_world = vec3.sub(world_point, transform.translation);
    const unrotated = engine.math.quat.rotateVec3(quat.inverse(transform.rotation), offset_world);
    return .{
        safeComponentDivide(unrotated[0], transform.scale[0]),
        safeComponentDivide(unrotated[1], transform.scale[1]),
        safeComponentDivide(unrotated[2], transform.scale[2]),
    };
}

fn componentMul(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[0] * b[0],
        a[1] * b[1],
        a[2] * b[2],
    };
}

fn safeComponentDivide(numerator: f32, denominator: f32) f32 {
    return if (@abs(denominator) > 0.00001) numerator / denominator else 0.0;
}

fn combinedMouseDrag(drag: [2]f32) f32 {
    return drag[0] + drag[1];
}

fn snapPositionFromOrigin(origin: [3]f32, target: [3]f32, step: f32) [3]f32 {
    return .{
        origin[0] + @round((target[0] - origin[0]) / step) * step,
        origin[1] + @round((target[1] - origin[1]) / step) * step,
        origin[2] + @round((target[2] - origin[2]) / step) * step,
    };
}

const ResolvedPivotSnap = struct {
    position: [3]f32,
    normal: ?[3]f32 = null,
};

fn snapPivotTargetPosition(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    raw_target: [3]f32,
) ResolvedPivotSnap {
    return switch (state.translation_snap_target) {
        .grid => .{
            .position = snapPositionFromOrigin(
                currentManipulationPivotWorldPosition(state),
                raw_target,
                state.translation_snap_step,
            ),
        },
        .surface, .vertex => blk: {
            const snap = resolveSurfaceOrVertexSnapPoint(state, layer_context, ray) orelse break :blk .{ .position = raw_target };
            break :blk .{
                .position = constrainSnapPointToActiveAxis(state, snap.position),
                .normal = snap.normal,
            };
        },
    };
}

fn constrainSnapPointToActiveAxis(state: *const EditorState, point: [3]f32) [3]f32 {
    if (state.manipulation_axis == .free) return point;
    const pivot_origin = currentManipulationPivotWorldPosition(state);
    const axis = gizmoAxisDirection(state.transform_space, state.manipulation_axis, state.manipulation_origin.rotation);
    const distance_along_axis = vec3.dot(vec3.sub(point, pivot_origin), axis);
    return vec3.add(pivot_origin, vec3.scale(axis, distance_along_axis));
}

fn resolveSurfaceOrVertexSnapPoint(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
) ?ResolvedPivotSnap {
    const world = currentManipulationWorld(state, layer_context) orelse return null;
    const surface_hit = raycastSurfaceIgnoringEntity(world, ray, state.manipulation_entity) orelse return null;
    return switch (state.translation_snap_target) {
        .grid => null,
        .surface => .{
            .position = surface_hit.position,
            .normal = surface_hit.normal,
        },
        .vertex => .{
            .position = nearestVertexWorldPosition(world, surface_hit.entity_id, surface_hit.position) orelse surface_hit.position,
            .normal = surface_hit.normal,
        },
    };
}

const SnapSurfaceHit = struct {
    entity_id: engine.scene.EntityId,
    distance: f32,
    position: [3]f32,
    normal: [3]f32,
};

const SnapTriangleHit = struct {
    distance: f32,
    position: [3]f32,
};

fn raycastSurfaceIgnoringEntity(
    world: *engine.scene.World,
    ray: engine.scene.Ray,
    ignored_entity: ?engine.scene.EntityId,
) ?SnapSurfaceHit {
    const direction = safeNormalizeOr(ray.direction, .{ 0.0, 0.0, -1.0 });
    const candidates = world.queryRenderableRayBounds(
        world.allocator,
        ray.origin,
        direction,
        std.math.inf(f32),
    ) catch return null;
    defer world.allocator.free(candidates);

    var best_hit: ?SnapSurfaceHit = null;
    for (candidates) |candidate| {
        if (ignored_entity != null and candidate.id == ignored_entity.?) continue;
        if (best_hit) |resolved_best_hit| {
            if (candidate.enter_distance > resolved_best_hit.distance) break;
        }

        const entity = world.getEntityConst(candidate.id) orelse continue;
        if (!entity.visible or entity.editor_only) continue;
        const mesh = (if (entity.mesh) |mesh_component|
            if (mesh_component.handle) |mesh_handle|
                world.resources.mesh(mesh_handle)
            else
                null
        else if (entity.skinned_mesh) |skinned_mesh_component|
            if (skinned_mesh_component.mesh_handle) |mesh_handle|
                world.resources.mesh(mesh_handle)
            else
                null
        else
            null) orelse continue;
        if (mesh.primitive_type != .triangle_list or mesh.indices.len < 3) continue;

        const world_transform = world.worldTransformConst(entity.id) orelse entity.local_transform;
        var triangle_index: usize = 0;
        while (triangle_index + 2 < mesh.indices.len) : (triangle_index += 3) {
            const v0 = localPointToWorld(world_transform, mesh.vertices[mesh.indices[triangle_index]].position);
            const v1 = localPointToWorld(world_transform, mesh.vertices[mesh.indices[triangle_index + 1]].position);
            const v2 = localPointToWorld(world_transform, mesh.vertices[mesh.indices[triangle_index + 2]].position);
            const hit = rayTriangleIntersection(ray.origin, direction, v0, v1, v2) orelse continue;
            if (best_hit == null or hit.distance < best_hit.?.distance) {
                var normal = safeNormalizeOr(vec3.cross(vec3.sub(v1, v0), vec3.sub(v2, v0)), .{ 0.0, 1.0, 0.0 });
                if (vec3.dot(normal, direction) > 0.0) {
                    normal = vec3.scale(normal, -1.0);
                }
                best_hit = .{
                    .entity_id = entity.id,
                    .distance = hit.distance,
                    .position = hit.position,
                    .normal = normal,
                };
            }
        }
    }
    return best_hit;
}

fn nearestVertexWorldPosition(
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    reference_position: [3]f32,
) ?[3]f32 {
    const entity = world.getEntityConst(entity_id) orelse return null;
    const mesh = (if (entity.mesh) |mesh_component|
        if (mesh_component.handle) |mesh_handle|
            world.resources.mesh(mesh_handle)
        else
            null
    else if (entity.skinned_mesh) |skinned_mesh_component|
        if (skinned_mesh_component.mesh_handle) |mesh_handle|
            world.resources.mesh(mesh_handle)
        else
            null
    else
        null) orelse return null;
    const world_transform = world.worldTransformConst(entity_id) orelse entity.local_transform;

    var nearest: ?[3]f32 = null;
    var best_distance_sq = std.math.inf(f32);
    for (mesh.vertices) |vertex| {
        const world_position = localPointToWorld(world_transform, vertex.position);
        const delta = vec3.sub(world_position, reference_position);
        const distance_sq = vec3.dot(delta, delta);
        if (distance_sq < best_distance_sq) {
            best_distance_sq = distance_sq;
            nearest = world_position;
        }
    }
    return nearest;
}

fn rayTriangleIntersection(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
) ?SnapTriangleHit {
    const epsilon: f32 = 0.00001;
    const edge1 = vec3.sub(v1, v0);
    const edge2 = vec3.sub(v2, v0);
    const pvec = vec3.cross(ray_direction, edge2);
    const determinant = vec3.dot(edge1, pvec);
    if (@abs(determinant) <= epsilon) return null;

    const inverse_determinant = 1.0 / determinant;
    const tvec = vec3.sub(ray_origin, v0);
    const u = vec3.dot(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) return null;

    const qvec = vec3.cross(tvec, edge1);
    const v = vec3.dot(ray_direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) return null;

    const distance = vec3.dot(edge2, qvec) * inverse_determinant;
    if (distance <= epsilon) return null;

    return .{
        .distance = distance,
        .position = vec3.add(ray_origin, vec3.scale(ray_direction, distance)),
    };
}

fn alignedRotationToSurfaceNormal(base_rotation: [4]f32, surface_normal: [3]f32) [4]f32 {
    const from = safeNormalizeOr(engine.math.quat.rotateVec3(base_rotation, .{ 0.0, 1.0, 0.0 }), .{ 0.0, 1.0, 0.0 });
    const to = safeNormalizeOr(surface_normal, from);
    const alignment = quaternionBetweenVectors(from, to);
    return quat.normalize(quat.mul(alignment, base_rotation));
}

fn quaternionBetweenVectors(from: [3]f32, to: [3]f32) [4]f32 {
    const from_normalized = safeNormalizeOr(from, .{ 0.0, 1.0, 0.0 });
    const to_normalized = safeNormalizeOr(to, from_normalized);
    const dot_value = std.math.clamp(vec3.dot(from_normalized, to_normalized), -1.0, 1.0);

    if (dot_value >= 0.9999) {
        return quat.identity();
    }
    if (dot_value <= -0.9999) {
        var axis = vec3.cross(from_normalized, .{ 1.0, 0.0, 0.0 });
        if (vec3.length(axis) <= 0.0001) {
            axis = vec3.cross(from_normalized, .{ 0.0, 0.0, 1.0 });
        }
        return quat.fromAxisAngle(axis, std.math.pi);
    }

    const axis = vec3.cross(from_normalized, to_normalized);
    return quat.normalize(.{ axis[0], axis[1], axis[2], 1.0 + dot_value });
}

fn snapScaleFromOrigin(origin: [3]f32, target: [3]f32, step: f32) [3]f32 {
    return .{
        utils.clampScale(origin[0] + @round((target[0] - origin[0]) / step) * step),
        utils.clampScale(origin[1] + @round((target[1] - origin[1]) / step) * step),
        utils.clampScale(origin[2] + @round((target[2] - origin[2]) / step) * step),
    };
}

fn rotateVec3Euler(rotation: [3]f32, vector: [3]f32) [3]f32 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn rotateX(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: [3]f32) [3]f32 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

// ── Gizmo axis click interaction ─────────────────────────────────────────────

/// Result of picking a gizmo handle under the cursor.
pub const PickedGizmoHandle = struct {
    axis: AxisConstraint,
    mode: ManipulationMode,
    distance: f32,
};

/// Match the interactive gizmo draw scale used by gizmo_pass.scaleForSelection.
fn gizmoDrawScale(camera_position: [3]f32, target_position: [3]f32) f32 {
    const dx = camera_position[0] - target_position[0];
    const dy = camera_position[1] - target_position[1];
    const dz = camera_position[2] - target_position[2];
    const distance = std.math.sqrt(dx * dx + dy * dy + dz * dz);
    return std.math.clamp(distance * 0.18, 0.7, 3.4);
}

/// Fallback world-space pick test for an axis handle segment.
fn rayToAxisHandleDistance(
    ray_origin: [3]f32,
    ray_direction: [3]f32,
    axis_start: [3]f32,
    axis_end: [3]f32,
) f32 {
    // Direction vectors
    const d = ray_direction;
    const e = vec3.sub(axis_end, axis_start);
    const w = vec3.sub(ray_origin, axis_start);

    const a = vec3.dot(d, d);
    const b = vec3.dot(d, e);
    const c = vec3.dot(e, e);
    const d_val = vec3.dot(d, w);
    const e_val = vec3.dot(e, w);

    const denom = a * c - b * b;
    if (@abs(denom) < 1e-8) {
        // Parallel lines — use distance from ray origin to segment
        const t_seg = std.math.clamp(-e_val / @max(c, 1e-8), 0.0, 1.0);
        const closest_on_seg = vec3.add(axis_start, vec3.scale(e, t_seg));
        return vec3.length(vec3.sub(closest_on_seg, ray_origin));
    }

    var t_ray = (b * e_val - c * d_val) / denom;
    var t_seg = (a * e_val - b * d_val) / denom;

    // Clamp segment parameter to [0, 1]
    t_seg = std.math.clamp(t_seg, 0.0, 1.0);
    // Recompute ray parameter for clamped segment point (must be non-negative)
    t_ray = @max((b * t_seg + d_val) / @max(a, 1e-8), 0.0);

    const closest_on_ray = vec3.add(ray_origin, vec3.scale(d, t_ray));
    const closest_on_seg = vec3.add(axis_start, vec3.scale(e, t_seg));

    return vec3.length(vec3.sub(closest_on_ray, closest_on_seg));
}

fn transformPoint4(matrix_value: engine.math.mat4.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
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
    if (@abs(clip[3]) <= 0.00001 or clip[3] <= 0.0) return null;

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    if (ndc_x < -1.2 or ndc_x > 1.2 or ndc_y < -1.2 or ndc_y > 1.2) return null;

    return .{
        state.viewport_origin[0] + (ndc_x * 0.5 + 0.5) * state.viewport_extent[0],
        state.viewport_origin[1] + (1.0 - (ndc_y * 0.5 + 0.5)) * state.viewport_extent[1],
    };
}

fn length2d(vector: [2]f32) f32 {
    return std.math.sqrt(vector[0] * vector[0] + vector[1] * vector[1]);
}

fn distancePointToSegment2d(point: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const ab = .{ b[0] - a[0], b[1] - a[1] };
    const ab_len_sq = ab[0] * ab[0] + ab[1] * ab[1];
    if (ab_len_sq <= 0.0001) return length2d(.{ point[0] - a[0], point[1] - a[1] });

    const ap = .{ point[0] - a[0], point[1] - a[1] };
    const t = std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / ab_len_sq, 0.0, 1.0);
    const closest = .{ a[0] + ab[0] * t, a[1] + ab[1] * t };
    return length2d(.{ point[0] - closest[0], point[1] - closest[1] });
}

fn buildRingBasis(normal: [3]f32) [2][3]f32 {
    const n = safeNormalizeOr(normal, .{ 0.0, 1.0, 0.0 });
    const reference = if (@abs(n[1]) < 0.9)
        [3]f32{ 0.0, 1.0, 0.0 }
    else
        [3]f32{ 1.0, 0.0, 0.0 };
    const tangent = safeNormalizeOr(vec3.cross(n, reference), .{ 1.0, 0.0, 0.0 });
    const bitangent = safeNormalizeOr(vec3.cross(n, tangent), .{ 0.0, 0.0, 1.0 });
    return .{ tangent, bitangent };
}

fn pickMoveOrScaleHandleOnScreen(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    origin: [3]f32,
    axes: [3][3]f32,
    axis_ids: [3]AxisConstraint,
    mode: ManipulationMode,
    scale: f32,
) ?PickedGizmoHandle {
    const mouse = effectiveCursorPos(layer_context);
    const origin_screen = projectWorldPointToViewport(state, layer_context, origin) orelse return null;

    const axis_pick_radius_px: f32 = 12.0;
    const center_pick_radius_px: f32 = if (mode == .translate) 14.0 else 16.0;
    const min_axis_projected_len_px: f32 = 16.0;
    var best: ?PickedGizmoHandle = null;

    for (axes, axis_ids) |axis_dir, axis_id| {
        const axis_end = vec3.add(origin, vec3.scale(axis_dir, scale));
        const axis_end_screen = projectWorldPointToViewport(state, layer_context, axis_end) orelse continue;
        if (length2d(.{ axis_end_screen[0] - origin_screen[0], axis_end_screen[1] - origin_screen[1] }) < min_axis_projected_len_px) {
            continue;
        }
        const dist = distancePointToSegment2d(mouse, origin_screen, axis_end_screen);
        if (dist <= axis_pick_radius_px and (best == null or dist < best.?.distance)) {
            best = .{ .axis = axis_id, .mode = mode, .distance = dist };
        }
    }

    const center_dist = length2d(.{ mouse[0] - origin_screen[0], mouse[1] - origin_screen[1] });
    if (center_dist <= center_pick_radius_px and (best == null or center_dist <= best.?.distance * 0.8)) {
        best = .{ .axis = .free, .mode = mode, .distance = center_dist };
    }
    return best;
}

fn pickRotateHandleOnScreen(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    origin: [3]f32,
    axes: [3][3]f32,
    axis_ids: [3]AxisConstraint,
    scale: f32,
) ?PickedGizmoHandle {
    const mouse = effectiveCursorPos(layer_context);
    const ring_radius = 0.9 * scale;
    const ring_pick_radius_px: f32 = 12.0;
    const samples: usize = 40;
    var best: ?PickedGizmoHandle = null;

    for (axes, axis_ids) |axis_normal, axis_id| {
        const basis = buildRingBasis(axis_normal);
        var previous_screen: ?[2]f32 = null;
        var min_dist = std.math.inf(f32);
        var visible_segments: usize = 0;

        var sample_index: usize = 0;
        while (sample_index <= samples) : (sample_index += 1) {
            const t = (@as(f32, @floatFromInt(sample_index)) / @as(f32, @floatFromInt(samples))) * std.math.tau;
            const ring_point = vec3.add(
                origin,
                vec3.add(
                    vec3.scale(basis[0], std.math.cos(t) * ring_radius),
                    vec3.scale(basis[1], std.math.sin(t) * ring_radius),
                ),
            );
            const screen_point = projectWorldPointToViewport(state, layer_context, ring_point);
            if (previous_screen) |previous| {
                if (screen_point) |current| {
                    visible_segments += 1;
                    min_dist = @min(min_dist, distancePointToSegment2d(mouse, previous, current));
                }
            }
            previous_screen = screen_point;
        }

        if (visible_segments == 0) continue;
        if (min_dist <= ring_pick_radius_px and (best == null or min_dist < best.?.distance)) {
            best = .{ .axis = axis_id, .mode = .rotate, .distance = min_dist };
        }
    }

    return best;
}

/// Pick the gizmo handle under the current ray for the selected entity.
/// Returns the best handle, or null if nothing was clicked.
pub fn pickGizmoHandle(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
) ?PickedGizmoHandle {
    // Only test when a manipulation tool is active AND an entity is selected
    if (state.manipulation_mode == .none) return null;
    const entity_id = layer_context.renderer.selectedEntity() orelse return null;
    if (state.editor_camera != null and entity_id == state.editor_camera.?) return null;

    const entity_transform = switch (state.manipulation_target) {
        .main_world => layer_context.world.worldTransformConst(entity_id) orelse return null,
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            runtime.world.worldTransformConst(entity_id) orelse return null
        else
            return null,
    };

    const world = switch (state.manipulation_target) {
        .main_world => layer_context.world,
        .staged_preview => if (state.ai_preview_runtime) |*runtime|
            &runtime.world
        else
            return null,
    };
    const pivot_local_offset = if (state.manipulation_entity != null and state.manipulation_entity.? == entity_id)
        state.manipulation_pivot_local_offset
    else
        computePivotLocalOffsetForEntity(state, layer_context, world, entity_id);

    const cam_transform = camera.activeCameraTransform(state, layer_context);
    const origin = pivotWorldPosition(entity_transform, pivot_local_offset);
    const scale = gizmoDrawScale(cam_transform.translation, origin);
    const threshold = scale * 0.18; // click tolerance in world units

    const rotation_euler = switch (state.transform_space) {
        .local => quat.toEuler(entity_transform.rotation),
        .world => [3]f32{ 0.0, 0.0, 0.0 },
    };

    const mode: ManipulationMode = state.manipulation_mode;

    // Build the three axis directions in world space (considering transform space)
    const axes = [3][3]f32{
        rotateVec3Euler(rotation_euler, .{ 1.0, 0.0, 0.0 }),
        rotateVec3Euler(rotation_euler, .{ 0.0, 1.0, 0.0 }),
        rotateVec3Euler(rotation_euler, .{ 0.0, 0.0, 1.0 }),
    };
    const axis_ids = [3]AxisConstraint{ .x, .y, .z };

    var best: ?PickedGizmoHandle = null;
    const ray_dir = vec3.normalize(ray.direction);

    switch (mode) {
        .translate, .scale => {
            if (pickMoveOrScaleHandleOnScreen(state, layer_context, origin, axes, axis_ids, mode, scale)) |picked_handle| {
                return picked_handle;
            }
            // Test ray against each axis line segment (length = scale in world)
            for (axes, axis_ids) |axis_dir, axis_id| {
                const axis_end = vec3.add(origin, vec3.scale(axis_dir, scale));
                const dist = rayToAxisHandleDistance(ray.origin, ray_dir, origin, axis_end);
                if (dist < threshold) {
                    if (best == null or dist < best.?.distance) {
                        best = .{ .axis = axis_id, .mode = mode, .distance = dist };
                    }
                }
            }
            // Test center region (free axis) — a sphere around origin
            const to_origin = vec3.sub(origin, ray.origin);
            const t = vec3.dot(to_origin, ray_dir);
            const closest = vec3.add(ray.origin, vec3.scale(ray_dir, @max(t, 0.0)));
            const center_dist = vec3.length(vec3.sub(closest, origin));
            if (center_dist < scale * 0.28) {
                if (best == null or center_dist < best.?.distance) {
                    best = .{ .axis = .free, .mode = mode, .distance = center_dist };
                }
            }
        },
        .rotate => {
            if (pickRotateHandleOnScreen(state, layer_context, origin, axes, axis_ids, scale)) |picked_handle| {
                return picked_handle;
            }
            // Test ray against each rotation ring (radius = 0.9 * scale)
            const ring_radius = 0.9 * scale;
            const ring_threshold = scale * 0.19;
            for (axes, axis_ids) |axis_normal, axis_id| {
                // Intersect ray with the plane of the ring
                const n_dot_d = vec3.dot(axis_normal, ray_dir);
                if (@abs(n_dot_d) < 1e-6) continue; // ray parallel to ring plane
                const t_plane = vec3.dot(vec3.sub(origin, ray.origin), axis_normal) / n_dot_d;
                if (t_plane < 0) continue;
                const hit_point = vec3.add(ray.origin, vec3.scale(ray_dir, t_plane));
                const dist_from_center = vec3.length(vec3.sub(hit_point, origin));
                const ring_dist = @abs(dist_from_center - ring_radius);
                if (ring_dist < ring_threshold) {
                    if (best == null or ring_dist < best.?.distance) {
                        best = .{ .axis = axis_id, .mode = mode, .distance = ring_dist };
                    }
                }
            }
        },
        .none => {},
    }

    return best;
}

/// Begin dragging a picked gizmo handle (mouse-hold drag mode, not keyboard mode).
pub fn beginGizmoHandleDrag(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    picked_handle: PickedGizmoHandle,
    ray: engine.scene.Ray,
) !void {
    state.manipulation_mode = picked_handle.mode;
    state.manipulation_axis = picked_handle.axis;
    state.manipulation_entity = null;
    state.manipulation_target = .main_world;
    state.manipulation_drag_active = false;
    state.manipulation_keyboard_mode = false;
    state.manipulation_started_from_ui = false;
    state.manipulation_drag_accumulator = .{ 0.0, 0.0 };
    state.manipulation_accumulated_delta = .{ 0.0, 0.0 };
    clearTransformSnapshot(state);
    try refreshTransformToolTarget(state, layer_context);
    if (state.manipulation_entity != null) {
        startGizmoDragSession(state, layer_context, picked_handle, ray);
        state.manipulation_drag_active = true;
    }
    refreshGizmoState(state, layer_context);
    try history.refreshWindowTitle(state, layer_context);
    ai_collaboration.noteManipulationBegin(state);
}

test "gizmoAxisDirection rotates constrained local axes" {
    const axis = gizmoAxisDirection(.local, .x, .{ 0.0, std.math.pi * 0.5, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), axis[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), axis[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), axis[2], 0.0001);
}

test "scale snap uses accumulated delta from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .free;
    state.manipulation_origin.scale = .{ 1.0, 1.0, 1.0 };
    state.scale_drag_sensitivity = 0.1;
    state.scale_snap_enabled = true;
    state.scale_snap_step = 0.1;

    // 使用manipulation_accumulated_delta而不是manipulation_drag_accumulator
    state.manipulation_accumulated_delta = .{ 0.4, 0.0 };
    var transform = state.manipulation_origin;
    applyQuickScale(&state, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), transform.scale[0], 0.0001);

    state.manipulation_accumulated_delta = .{ 0.6, 0.0 };
    transform = state.manipulation_origin;
    applyQuickScale(&state, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), transform.scale[2], 0.0001);
}

test "rotation snap uses accumulated drag from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .y;
    state.manipulation_origin.rotation = quat.fromEuler(.{ 0.0, 0.0, 0.0 });
    state.rotation_drag_sensitivity = 1.0;
    state.rotation_snap_enabled = true;
    state.rotation_snap_step_degrees = 45.0;

    state.manipulation_drag_accumulator = .{ 0.5, 0.0 };
    var transform = state.manipulation_origin;
    applyQuickRotate(&state, &transform);
    const euler = quat.toEuler(transform.rotation);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 4.0), euler[1], 0.0001);
}

test "translation snap uses accumulated drag from manipulation origin" {
    var state = EditorState{};
    state.manipulation_axis = .x;
    state.transform_space = .world;
    state.manipulation_origin = .{
        .translation = .{ 0.0, 0.0, 0.0 },
    };
    state.translation_drag_sensitivity = 1.0;
    state.translation_snap_enabled = true;
    state.translation_snap_step = 1.0;

    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();
    var renderer: engine.render.Renderer = undefined;
    var input = engine.core.InputState{};
    var playback = engine.core.PlaybackController{};
    var game_state = engine.core.GameState.game_start;
    var global_time: f32 = 0.0;
    var time_scale: f32 = 1.0;
    var physics_accumulator_seconds: f32 = 0.0;
    var physics_state = engine.physics.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();
    var layer_context = engine.core.LayerContext{
        .world = &world,
        .scene = &world,
        .renderer = &renderer,
        .input = &input,
        .window = undefined,
        .playback_controller = &playback,
        .game_state = &game_state,
        .global_time = &global_time,
        .time_scale = &time_scale,
        .physics_accumulator_seconds = &physics_accumulator_seconds,
        .physics_state = &physics_state,
        .frame_index = 0,
        .delta_seconds = 1.0 / 60.0,
    };

    // The helper only reads the active camera transform, so no world state is needed here.
    state.manipulation_drag_accumulator = .{ 0.4, 0.0 };
    var transform = state.manipulation_origin;
    applyQuickTranslate(&state, &layer_context, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), transform.translation[0], 0.0001);

    state.manipulation_drag_accumulator = .{ 0.6, 0.0 };
    transform = state.manipulation_origin;
    applyQuickTranslate(&state, &layer_context, &transform);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), transform.translation[0], 0.0001);
}
