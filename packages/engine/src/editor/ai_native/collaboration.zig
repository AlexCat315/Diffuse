const std = @import("std");
const engine = @import("guava");
const camera = @import("../interaction/camera.zig");
const history = @import("../actions/history.zig");
const state_mod = @import("../core/state.zig");

const collaboration_mod = engine.mcp.collaboration;
const EditorState = state_mod.EditorState;

pub fn beginFrame(state: *EditorState) void {
    state.active_drag_payload = null;
}

pub fn syncContext(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const store = state.ai_collaboration orelse {
        layer_context.renderer.clearAiFocusEntities();
        return;
    };
    const viewport_size = layer_context.renderer.sceneViewportSize();
    const center_ray = if (viewport_size[0] > 0 and viewport_size[1] > 0)
        camera.activeCameraRayFromViewportPixel(
            state,
            layer_context,
            .{ viewport_size[0] / 2, viewport_size[1] / 2 },
            viewport_size,
        )
    else
        null;

    try store.updateContext(.{
        .primary_selection = layer_context.renderer.selectedEntity(),
        .selected_entities = layer_context.renderer.selectedEntities(),
        .staged_preview_selection = state.ai_preview_selected_entity,
        .manipulation_mode = mapManipulationMode(state.manipulation_mode),
        .manipulation_entity = state.manipulation_entity,
        .transform_space = mapTransformSpace(state.transform_space),
        .viewport_size = viewport_size,
        .viewport_hovered = state.viewport_hovered,
        .viewport_focused = state.viewport_focused,
        .camera_transform = camera.activeCameraTransform(state, layer_context),
        .camera_projection = snapshotCameraProjection(camera.activeCameraComponent(state, layer_context)),
        .viewport_center_ray = center_ray,
        .drag_payload = buildDragPayload(state, layer_context),
        .selected_asset = buildSelectedAsset(state),
        .pending_viewport_drop = buildPendingViewportDrop(state),
    });

    syncGhostHighlight(state, layer_context, store);
}

pub fn syncPreviewWorld(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const runtime = if (state.ai_preview_runtime) |*resolved| resolved else {
        layer_context.renderer.setPreviewScene(null);
        layer_context.renderer.setPreviewGizmoTransform(null);
        layer_context.renderer.clearPreviewEntityFilter();
        layer_context.renderer.clearAiFocusEntities();
        return;
    };

    const store = state.ai_collaboration orelse {
        runtime.clear();
        clearPreviewEntities(state);
        layer_context.renderer.setPreviewScene(null);
        layer_context.renderer.setPreviewGizmoTransform(null);
        layer_context.renderer.clearPreviewEntityFilter();
        layer_context.renderer.clearAiFocusEntities();
        return;
    };
    const allocator = state.allocator orelse layer_context.world.allocator;

    var snapshot = try store.copyPreviewWorldSnapshotAlloc(allocator);
    defer snapshot.deinit(allocator);
    const preview_entity_ids = try store.copyPreviewEntityIdsAlloc(allocator);
    defer allocator.free(preview_entity_ids);

    if (!snapshot.active or snapshot.encoded_world == null) {
        runtime.clear();
        clearPreviewEntities(state);
        layer_context.renderer.setPreviewScene(null);
        layer_context.renderer.setPreviewGizmoTransform(null);
        layer_context.renderer.clearPreviewEntityFilter();
        layer_context.renderer.clearAiFocusEntities();
        return;
    }

    if (runtime.transaction_id != snapshot.transaction_id) {
        runtime.clear();
        try engine.scene.deserializeWorldFromSlice(allocator, &runtime.world, snapshot.encoded_world.?);
        runtime.transaction_id = snapshot.transaction_id;
    }

    try replacePreviewEntities(state, allocator, preview_entity_ids);
    if (state.ai_preview_selected_entity) |entity_id| {
        if (!containsPreviewEntity(state, entity_id)) {
            state.ai_preview_selected_entity = null;
        }
    }

    syncActiveCameraIntoPreview(state, layer_context, &runtime.world);
    runtime.world.updateHierarchy();
    layer_context.renderer.setPreviewScene(&runtime.world);
    try layer_context.renderer.setPreviewEntityFilter(state.ai_preview_entities.items);
    syncPreviewGizmoTransform(state, layer_context);
}

pub fn trySelectPreviewEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    ray: engine.scene.Ray,
    mode: engine.render.SelectionUpdateMode,
) !bool {
    const runtime = if (state.ai_preview_runtime) |*resolved| resolved else return false;
    if (runtime.transaction_id == null or state.ai_preview_entities.items.len == 0) {
        return false;
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    const candidates = try runtime.world.queryRenderableRayBounds(allocator, ray.origin, ray.direction, 4096.0);
    defer allocator.free(candidates);

    var picked: ?engine.scene.EntityId = null;
    for (candidates) |candidate| {
        picked = mapPreviewSelectableEntity(state, &runtime.world, candidate.id) orelse continue;
        break;
    }
    if (picked == null) {
        return false;
    }

    const next_selected = switch (mode) {
        .replace => picked,
        .toggle => if (state.ai_preview_selected_entity != null and state.ai_preview_selected_entity.? == picked.?)
            null
        else
            picked,
    };
    state.ai_preview_selected_entity = next_selected;

    if (next_selected) |entity_id| {
        if (layer_context.world.hasEntity(entity_id)) {
            try layer_context.renderer.replaceSelection(entity_id);
        } else {
            try layer_context.renderer.replaceSelection(null);
        }
    } else {
        try layer_context.renderer.replaceSelection(null);
    }

    syncPreviewGizmoTransform(state, layer_context);
    notePreviewSelection(state, next_selected);
    return true;
}

fn mapPreviewSelectableEntity(
    state: *const EditorState,
    preview_world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
) ?engine.scene.EntityId {
    var current_id: ?engine.scene.EntityId = entity_id;
    var guard: usize = 0;
    while (current_id) |resolved_id| : (guard += 1) {
        if (guard > preview_world.entities.items.len) {
            return null;
        }
        if (containsPreviewEntity(state, resolved_id)) {
            return resolved_id;
        }
        const entity = preview_world.getEntityConst(resolved_id) orelse return null;
        current_id = entity.parent;
    }
    return null;
}

pub fn commitPreviewEntityTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    transform: engine.scene.Transform,
) !bool {
    const runtime = if (state.ai_preview_runtime) |*resolved| resolved else return false;
    const store = state.ai_collaboration orelse return false;
    _ = runtime.world.setEntityWorldTransform(entity_id, transform);
    runtime.world.updateHierarchy();
    const changed = try store.updateStagedEntityWorldTransform(
        state.allocator orelse layer_context.world.allocator,
        entity_id,
        transform,
        .human,
    );
    syncPreviewGizmoTransform(state, layer_context);
    return changed;
}

pub fn cancelPreviewEntityTransform(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    transform: engine.scene.Transform,
) void {
    const runtime = if (state.ai_preview_runtime) |*resolved| resolved else return;
    _ = runtime.world.setEntityWorldTransform(entity_id, transform);
    runtime.world.updateHierarchy();
    if (state.ai_preview_selected_entity != null and state.ai_preview_selected_entity.? == entity_id) {
        syncPreviewGizmoTransform(state, layer_context);
    }
}

pub fn clearPreviewSelectionState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    clearPreviewSelection(state, layer_context);
}

pub fn noteManipulationBegin(state: *EditorState) void {
    noteManipulationEvent(state, "manipulation_begin");
}

pub fn noteManipulationCommit(state: *EditorState, entity_id: engine.scene.EntityId) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={d} mode={s} target={s}",
        .{ entity_id, @tagName(mapManipulationMode(state.manipulation_mode)), @tagName(state.manipulation_target) },
    ) catch "manipulation commit";
    store.recordIntent(.human, "manipulation_commit", detail) catch |err| {
        std.log.warn("failed to record manipulation commit: {s}", .{@errorName(err)});
    };
}

pub fn noteManipulationCancel(state: *EditorState, entity_id: ?engine.scene.EntityId) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={any} mode={s} target={s}",
        .{ entity_id, @tagName(mapManipulationMode(state.manipulation_mode)), @tagName(state.manipulation_target) },
    ) catch "manipulation cancel";
    store.recordIntent(.human, "manipulation_cancel", detail) catch |err| {
        std.log.warn("failed to record manipulation cancel: {s}", .{@errorName(err)});
    };
}

fn noteManipulationEvent(state: *EditorState, action: []const u8) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(
        &detail_buffer,
        "entity={any} mode={s} target={s}",
        .{ state.manipulation_entity, @tagName(mapManipulationMode(state.manipulation_mode)), @tagName(state.manipulation_target) },
    ) catch action;
    store.recordIntent(.human, action, detail) catch |err| {
        std.log.warn("failed to record manipulation intent: {s}", .{@errorName(err)});
    };
}

fn syncActiveCameraIntoPreview(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    preview_world: *engine.scene.World,
) void {
    const active_camera_id = if (state.editor_camera_active)
        state.editor_camera
    else
        layer_context.world.primaryCameraEntity();
    const camera_id = active_camera_id orelse return;
    const source_entity = layer_context.world.getEntityConst(camera_id) orelse return;
    const source_camera = source_entity.camera orelse return;
    const preview_entity = preview_world.getEntity(camera_id) orelse return;

    preview_entity.local_transform = source_entity.local_transform;
    preview_entity.camera = source_camera;
    preview_world.markDirty(camera_id);
    _ = preview_world.setPrimaryCamera(camera_id);
}

fn clearPreviewSelection(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    state.ai_preview_selected_entity = null;
    layer_context.renderer.setPreviewGizmoTransform(null);
}

fn clearPreviewEntities(state: *EditorState) void {
    state.ai_preview_entities.clearRetainingCapacity();
    state.ai_preview_selected_entity = null;
}

fn replacePreviewEntities(state: *EditorState, allocator: std.mem.Allocator, entity_ids: []const engine.scene.EntityId) !void {
    state.ai_preview_entities.clearRetainingCapacity();
    try state.ai_preview_entities.appendSlice(allocator, entity_ids);
}

fn containsPreviewEntity(state: *const EditorState, entity_id: engine.scene.EntityId) bool {
    for (state.ai_preview_entities.items) |preview_entity_id| {
        if (preview_entity_id == entity_id) {
            return true;
        }
    }
    return false;
}

fn syncPreviewGizmoTransform(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const runtime = if (state.ai_preview_runtime) |*resolved| resolved else {
        layer_context.renderer.setPreviewGizmoTransform(null);
        return;
    };
    const entity_id = state.ai_preview_selected_entity orelse {
        layer_context.renderer.setPreviewGizmoTransform(null);
        return;
    };
    const transform = runtime.world.worldTransformConst(entity_id) orelse {
        layer_context.renderer.setPreviewGizmoTransform(null);
        return;
    };
    layer_context.renderer.setPreviewGizmoTransform(transform);
}

fn notePreviewSelection(state: *EditorState, entity_id: ?engine.scene.EntityId) void {
    const store = state.ai_collaboration orelse return;
    var detail_buffer: [128]u8 = undefined;
    const detail = std.fmt.bufPrint(&detail_buffer, "entity={any}", .{entity_id}) catch "preview selection";
    store.recordIntent(.human, "preview_selection_changed", detail) catch |err| {
        std.log.warn("failed to record preview selection intent: {s}", .{@errorName(err)});
    };
}

fn syncGhostHighlight(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    store: *collaboration_mod.Store,
) void {
    if (!state.ghost_highlight_enabled) {
        layer_context.renderer.clearAiFocusEntities();
        return;
    }

    const snapshot = store.overlaySnapshot();
    if (!snapshot.active) {
        layer_context.renderer.clearAiFocusEntities();
        return;
    }

    var focus_entities: [16]engine.scene.EntityId = .{0} ** 16;
    var count: usize = 0;

    if (state.ai_preview_selected_entity) |selected_entity| {
        focus_entities[count] = selected_entity;
        count += 1;
    }

    for (state.ai_preview_entities.items) |entity_id| {
        if (count >= focus_entities.len) break;
        var exists = false;
        for (focus_entities[0..count]) |existing| {
            if (existing == entity_id) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            focus_entities[count] = entity_id;
            count += 1;
        }
    }

    if (count == 0) {
        layer_context.renderer.clearAiFocusEntities();
        return;
    }

    layer_context.renderer.setAiFocusEntities(focus_entities[0..count]);
}

fn previewEntityLabel(state: *const EditorState, entity_id: engine.scene.EntityId) ?[]const u8 {
    const runtime = state.ai_preview_runtime orelse return null;
    const entity = runtime.world.getEntityConst(entity_id) orelse return null;
    return entity.name;
}

fn buildDragPayload(state: *EditorState, layer_context: *engine.core.LayerContext) ?collaboration_mod.DragPayload {
    const active = state.active_drag_payload orelse return null;
    var payload = switch (active.kind) {
        .entity => collaboration_mod.DragPayload{ .kind = .entity, .entity_id = active.entity_id },
        .asset_model => collaboration_mod.DragPayload{ .kind = .asset_model },
        .asset_material => collaboration_mod.DragPayload{ .kind = .asset_material },
        .asset_texture => collaboration_mod.DragPayload{ .kind = .asset_texture },
        .place_actor => collaboration_mod.DragPayload{ .kind = .place_actor },
    };

    if (active.entity_id) |entity_id| {
        if (layer_context.world.getEntityConst(entity_id)) |entity| {
            payload.asset_name.set(entity.name);
        }
    }
    if (active.asset_index) |asset_index| {
        if (asset_index < state.asset_entries.items.len) {
            const entry = state.asset_entries.items[asset_index];
            payload.asset_name.set(entry.name);
            payload.asset_path.set(entry.path);
        }
    }
    if (active.actor_kind) |actor_kind| {
        payload.actor_kind.set(placeActorKindLabel(actor_kind));
    }

    return payload;
}

fn buildSelectedAsset(state: *EditorState) ?collaboration_mod.SelectedAsset {
    const selected_index = state.selected_asset_index orelse return null;
    if (selected_index >= state.asset_entries.items.len) {
        return null;
    }
    const entry = state.asset_entries.items[selected_index];
    var asset = collaboration_mod.SelectedAsset{};
    asset.kind.set(assetKindLabel(entry.kind));
    asset.id.set(entry.id);
    asset.name.set(entry.name);
    asset.path.set(entry.path);
    return asset;
}

fn buildPendingViewportDrop(state: *EditorState) ?collaboration_mod.PendingViewportDrop {
    const pending = state.pending_viewport_drop orelse return null;
    var drop = switch (pending.source_kind) {
        .asset => collaboration_mod.PendingViewportDrop{ .kind = .asset },
        .place_actor => collaboration_mod.PendingViewportDrop{ .kind = .place_actor },
    };

    if (pending.asset_index) |asset_index| {
        if (asset_index < state.asset_entries.items.len) {
            drop.asset_name.set(state.asset_entries.items[asset_index].name);
        }
    }
    if (pending.actor_kind) |actor_kind| {
        drop.actor_kind.set(placeActorKindLabel(actor_kind));
    }
    if (pending.pixel) |pixel| {
        drop.pixel = pixel;
        drop.has_pixel = true;
    }
    if (pending.world_position) |world_position| {
        drop.world_position = world_position;
        drop.has_world_position = true;
    }
    drop.target_entity = pending.target_entity;
    return drop;
}

fn mapManipulationMode(mode: state_mod.ManipulationMode) collaboration_mod.ManipulationMode {
    return switch (mode) {
        .none => .none,
        .translate => .translate,
        .rotate => .rotate,
        .scale => .scale,
    };
}

fn mapTransformSpace(space: state_mod.TransformSpace) collaboration_mod.TransformSpace {
    return switch (space) {
        .local => .local,
        .world => .world,
    };
}

fn snapshotCameraProjection(camera_component: engine.scene.Camera) collaboration_mod.CameraProjection {
    return switch (camera_component.projection) {
        .perspective => |projection| .{
            .kind = .perspective,
            .fov_y_radians = projection.fov_y_radians,
            .near_clip = projection.near_clip,
            .far_clip = projection.far_clip,
        },
        .orthographic => |projection| .{
            .kind = .orthographic,
            .orthographic_size = projection.size,
            .near_clip = projection.near_clip,
            .far_clip = projection.far_clip,
        },
    };
}

fn assetKindLabel(kind: state_mod.AssetKind) []const u8 {
    return switch (kind) {
        .scene => "scene",
        .model => "model",
        .material => "material",
        .texture => "texture",
        .shader => "shader",
        .script => "script",
        .directory => "directory",
        .unknown => "file",
    };
}

fn placeActorKindLabel(kind: state_mod.PlaceActorKind) []const u8 {
    return switch (kind) {
        .empty => "empty",
        .camera => "camera",
        .cube => "cube",
        .sphere => "sphere",
        .plane => "plane",
        .textured_cube => "textured_cube",
        .textured_sphere => "textured_sphere",
        .textured_plane => "textured_plane",
        .point_light => "point_light",
        .spot_light => "spot_light",
        .directional_light => "directional_light",
        .vfx_fountain => "vfx_fountain",
        .vfx_orbit => "vfx_orbit",
    };
}
