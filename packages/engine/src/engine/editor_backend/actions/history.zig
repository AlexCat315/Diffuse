const std = @import("std");
const engine = @import("guava");
const quat = engine.math.quat;
const vec3 = engine.math.vec3;
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");
const command_mod = @import("command.zig");
const utils = @import("../common/utils.zig");
const camera = @import("../interaction/camera.zig");
const manipulation = @import("../interaction/manipulation.zig");
const content_browser = @import("../assets/browser.zig");
const vfx_runtime = @import("../runtime/vfx.zig");
const autosave_path = state_mod.autosave_path;

pub fn executeQueuedCommands(layer_context: *engine.core.LayerContext) ![]engine.core.CommandExecutionResult {
    const queue = layer_context.command_queue orelse return error.CommandQueueUnavailable;
    return queue.executeAll(layer_context.world);
}

/// Flush the deferred history snapshot if one was requested by a previous
/// subtree delta command.  Call this once at the start of each editor frame,
/// before any interaction handling, so the snapshot is up-to-date for the next
/// history operation without causing a stutter on the frame the delta was
/// recorded.
pub fn tickDeferredSnapshot(state: *EditorState, world: *engine.scene.World) void {
    if (state.play_mode_active) {
        return;
    }
    if (state.history_snapshot_needs_refresh) {
        state.history_snapshot_needs_refresh = false;
        refreshCurrentHistorySnapshot(state, world) catch |err| {
            std.log.err("history: deferred snapshot refresh failed: {}", .{err});
        };
    }
}

pub fn captureSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    return captureSnapshotWithSource(state, layer_context, .human);
}

pub fn captureSnapshotWithLabel(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    label: []const u8,
    detail: []const u8,
    source: command_mod.TimelineSource,
) !void {
    try captureSnapshotWithTimelineDetails(state, layer_context, source, label, detail, "scene_snapshot");
}

pub fn captureSnapshotWithTimelineDetails(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    source: command_mod.TimelineSource,
    label: []const u8,
    detail: []const u8,
    command_kind: []const u8,
) !void {
    return captureSnapshotInternal(state, layer_context, source, .{
        .label = label,
        .detail = detail,
        .command_kind = command_kind,
    });
}

pub fn captureSnapshotWithSource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    source: command_mod.TimelineSource,
) !void {
    return captureSnapshotInternal(state, layer_context, source, null);
}

const TimelineOverride = struct {
    label: []const u8,
    detail: []const u8,
    command_kind: []const u8,
};

fn captureSnapshotInternal(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    source: command_mod.TimelineSource,
    timeline_override: ?TimelineOverride,
) !void {
    if (state.play_mode_active) {
        return;
    }
    const allocator = state.allocator orelse return;
    const before = state.history_world_snapshot orelse {
        try refreshCurrentHistorySnapshot(state, layer_context.world);
        return;
    };
    const after = try engine.scene.serializeWorldAlloc(allocator, layer_context.world);
    errdefer allocator.free(after);

    if (std.mem.eql(u8, before, after)) {
        allocator.free(after);
        return;
    }

    var selection_after = try command_mod.SelectionSnapshot.fromSlice(allocator, layer_context.renderer.selectedEntities());
    errdefer selection_after.deinit(allocator);
    var selection_before = try selection_after.clone(allocator);
    errdefer selection_before.deinit(allocator);

    var command: command_mod.EditorCommand = .{
        .scene_snapshot = .{
            .before = try allocator.dupe(u8, before),
            .after = after,
            .selection_before = selection_before,
            .selection_after = selection_after,
        },
    };
    errdefer command.deinit(allocator);

    try pushCommandInternal(state, command);
    if (timeline_override) |override| {
        try appendTimelineEvent(state, source, override.label, override.detail, override.command_kind);
    } else {
        try appendTimelineFromCommand(state, command, source);
    }
    try replaceHistoryWorldSnapshot(state, after);
}

pub fn appendTimelineEvent(
    state: *EditorState,
    source: command_mod.TimelineSource,
    label: []const u8,
    detail: []const u8,
    command_kind: []const u8,
) !void {
    if (state.play_mode_active) {
        return;
    }
    const allocator = state.allocator orelse return;
    try state.timeline_entries.append(allocator, .{
        .sequence = state.next_timeline_sequence,
        .timestamp_ms = std.time.milliTimestamp(),
        .source = source,
        .label = try allocator.dupe(u8, label),
        .detail = try allocator.dupe(u8, detail),
        .command_kind = try allocator.dupe(u8, command_kind),
    });
    state.next_timeline_sequence += 1;

    while (state.timeline_entries.items.len > state.max_timeline_entries) {
        var removed = state.timeline_entries.orderedRemove(0);
        removed.deinit(allocator);
    }

    if (state.ai_collaboration) |store| {
        const collaboration_source: engine.mcp.collaboration.IntentSource = switch (source) {
            .human => .human,
            .ai => .ai,
        };
        store.recordCommandTimeline(collaboration_source, label, detail, command_kind) catch |err| {
            std.log.warn("failed to record command timeline entry: {s}", .{@errorName(err)});
        };
    }
}

pub fn resetSnapshotHistory(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    clearSnapshotHistory(state);
    try refreshCurrentHistorySnapshot(state, layer_context.world);
    state.saved_command_cursor = 0;
}

pub fn clearSnapshotHistory(state: *EditorState) void {
    const allocator = state.allocator orelse return;
    clearCommandStack(allocator, &state.undo_stack);
    clearCommandStack(allocator, &state.redo_stack);
    clearTimelineEntries(allocator, &state.timeline_entries);
    state.next_timeline_sequence = 1;
    if (state.history_world_snapshot) |snapshot| {
        allocator.free(snapshot);
        state.history_world_snapshot = null;
    }
    state.saved_command_cursor = null;
}

pub fn undo(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.play_mode_active) {
        return;
    }
    const allocator = state.allocator orelse return;
    if (state.undo_stack.items.len == 0) {
        return;
    }

    try state.redo_stack.ensureUnusedCapacity(allocator, 1);
    var command = state.undo_stack.pop().?;
    errdefer command.deinit(allocator);

    try applyCommand(state, layer_context, &command, .undo);
    state.redo_stack.appendAssumeCapacity(command);
    try refreshCurrentHistorySnapshot(state, layer_context.world);
}

pub fn redo(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.play_mode_active) {
        return;
    }
    const allocator = state.allocator orelse return;
    if (state.redo_stack.items.len == 0) {
        return;
    }

    try state.undo_stack.ensureUnusedCapacity(allocator, 1);
    var command = state.redo_stack.pop().?;
    errdefer command.deinit(allocator);

    try applyCommand(state, layer_context, &command, .redo);
    state.undo_stack.appendAssumeCapacity(command);
    try refreshCurrentHistorySnapshot(state, layer_context.world);
}

pub fn timeTravelToCursor(state: *EditorState, layer_context: *engine.core.LayerContext, target_cursor: usize) !void {
    if (state.play_mode_active) {
        return;
    }
    const total = state.undo_stack.items.len + state.redo_stack.items.len;
    const clamped_target = @min(target_cursor, total);

    while (state.undo_stack.items.len > clamped_target) {
        try undo(state, layer_context);
    }
    while (state.undo_stack.items.len < clamped_target) {
        try redo(state, layer_context);
    }
}

pub fn pruneMissingSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    if (layer_context.renderer.selectedEntity()) |selected| {
        if (!layer_context.world.hasEntity(selected)) {
            try layer_context.renderer.replaceSelection(null);
        }
    }
}

pub fn deleteSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try deleteEntities(state, layer_context, layer_context.renderer.selectedEntities());
}

pub fn deleteEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    const allocator = state.allocator orelse return;
    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectSelectionRoots(allocator, layer_context.world, entity_ids, state.editor_camera, &roots);
    if (roots.items.len == 0) {
        return;
    }
    const use_scene_snapshot = entityListRequiresSceneSnapshot(layer_context.world, roots.items);

    var before = try captureEntitySnapshots(state, layer_context.world, roots.items);
    var before_owned = true;
    defer if (before_owned) deinitEntitySnapshots(state, &before);
    const selection_before = layer_context.renderer.selectedEntities();

    manipulation.clearTransformTool(state);
    var changed = false;
    if (layer_context.command_queue) |queue| {
        for (roots.items) |entity_id| {
            try queue.enqueueDeleteEntity(entity_id);
        }
        const results = try executeQueuedCommands(layer_context);
        defer allocator.free(results);
        for (results) |result| {
            changed = changed or result.changed;
        }
    } else {
        for (roots.items) |entity_id| {
            changed = layer_context.world.destroyEntity(entity_id) or changed;
        }
    }
    if (changed) {
        try layer_context.renderer.replaceSelection(null);
        if (use_scene_snapshot) {
            try captureSnapshot(state, layer_context);
        } else {
            try recordDeletedEntities(state, layer_context, &before, selection_before);
            before_owned = false;
        }
    }
}

pub fn duplicateSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try duplicateEntities(state, layer_context, layer_context.renderer.selectedEntities());
}

pub fn duplicateEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    const allocator = state.allocator orelse return;
    const selection_before = layer_context.renderer.selectedEntities();
    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectSelectionRoots(allocator, layer_context.world, entity_ids, state.editor_camera, &roots);
    if (roots.items.len == 0) {
        return;
    }

    var duplicates = std.ArrayList(engine.scene.EntityId).empty;
    defer duplicates.deinit(allocator);

    for (roots.items, 0..) |entity_id, index| {
        const duplicate_id = try layer_context.world.duplicateEntity(entity_id);
        if (layer_context.world.worldTransform(duplicate_id)) |duplicate_transform| {
            var moved = duplicate_transform;
            const stack_offset = @as(f32, @floatFromInt(index)) * 0.2;
            moved.translation[0] += 0.65 + stack_offset;
            moved.translation[1] += 0.15;
            _ = layer_context.world.setEntityWorldTransform(duplicate_id, moved);
        }
        try duplicates.append(allocator, duplicate_id);
    }

    try layer_context.renderer.replaceSelectionMany(duplicates.items);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, duplicates.items, selection_before);
}

pub fn spawnEmptyEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createEmptyEntityViaQueueOrWorld(layer_context, spawnTransform(state, layer_context));
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnCameraEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createCameraEntityViaQueueOrWorld(layer_context, spawnCameraTransform(state, layer_context));
    try layer_context.renderer.replaceSelection(entity_id);
    state.scene_camera = entity_id;
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnPrimitive(state: *EditorState, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const spawn_transform = spawnTransform(state, layer_context);
    const entity_id = try createPrimitiveEntityViaQueueOrWorld(layer_context, primitive, spawn_transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnPointLight(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    var transform = spawnTransform(state, layer_context);
    transform.translation[1] += 1.0;
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .point, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnSpotLight(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    var transform = spawnTransform(state, layer_context);
    transform.translation[1] += 1.0;
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .spot, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnDirectionalLight(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .directional, spawnTransform(state, layer_context), 3.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnVfxEntity(state: *EditorState, layer_context: *engine.core.LayerContext, kind: engine.scene.VfxKind) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createVfxEntityViaQueueOrWorld(layer_context, kind, spawnTransform(state, layer_context));
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    camera.focusSelection(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnEmptyEntityAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createEmptyEntityViaQueueOrWorld(layer_context, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnCameraEntityAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createCameraEntityViaQueueOrWorld(layer_context, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    state.scene_camera = entity_id;
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnPrimitiveAt(state: *EditorState, layer_context: *engine.core.LayerContext, primitive: engine.scene.Primitive, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createPrimitiveEntityViaQueueOrWorld(layer_context, primitive, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnPointLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .point, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnSpotLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .spot, transform, 24.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnDirectionalLightAt(state: *EditorState, layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createLightEntityViaQueueOrWorld(layer_context, .directional, transform, 1.0);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn spawnVfxEntityAt(state: *EditorState, layer_context: *engine.core.LayerContext, kind: engine.scene.VfxKind, transform: engine.scene.Transform) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const entity_id = try createVfxEntityViaQueueOrWorld(layer_context, kind, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

pub fn createFolderEntityViaQueueOrWorld(layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const name = try layer_context.world.nextAvailableName("Folder");
        defer layer_context.world.allocator.free(name);
        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = transform,
            .is_folder = true,
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createFolderEntity(transform);
}

fn createEmptyEntityViaQueueOrWorld(layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const name = try layer_context.world.nextAvailableName("Empty");
        defer layer_context.world.allocator.free(name);
        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = transform,
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createEmptyEntity(transform);
}

fn createCameraEntityViaQueueOrWorld(layer_context: *engine.core.LayerContext, transform: engine.scene.Transform) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const name = try layer_context.world.nextAvailableName("Camera");
        defer layer_context.world.allocator.free(name);
        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = transform,
            .camera = .{},
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createCameraEntity(transform);
}

pub fn createPrimitiveEntityViaQueueOrWorld(
    layer_context: *engine.core.LayerContext,
    primitive: engine.scene.Primitive,
    transform: engine.scene.Transform,
) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const mesh_handle = try layer_context.world.resources.ensurePrimitiveMesh(primitive);
        const material_handle = try layer_context.world.resources.ensureDefaultMaterial();
        const base_name = switch (primitive) {
            .cube => "Cube",
            .sphere => "Sphere",
            .plane => "Plane",
            .custom => "Mesh",
        };
        const name = try layer_context.world.nextAvailableName(base_name);
        defer layer_context.world.allocator.free(name);
        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = transform,
            .mesh = .{
                .handle = mesh_handle,
                .primitive = primitive,
            },
            .material = .{
                .handle = material_handle,
            },
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createPrimitiveEntity(primitive, transform);
}

fn createLightEntityViaQueueOrWorld(
    layer_context: *engine.core.LayerContext,
    kind: engine.scene.LightKind,
    transform: engine.scene.Transform,
    intensity: f32,
) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const base_name = switch (kind) {
            .directional => "DirectionalLight",
            .point => "PointLight",
            .spot => "SpotLight",
        };
        const name = try layer_context.world.nextAvailableName(base_name);
        defer layer_context.world.allocator.free(name);

        var light_transform = transform;
        var mesh: ?engine.scene.Mesh = null;
        var material: ?engine.scene.Material = null;

        if (kind != .directional) {
            const proxy_mesh = try layer_context.world.resources.ensurePrimitiveMesh(.sphere);
            const material_name = try std.fmt.allocPrint(layer_context.world.allocator, "{s}Material", .{name});
            defer layer_context.world.allocator.free(material_name);
            const tint: [4]f32 = switch (kind) {
                .point => .{ 1.0, 0.86, 0.55, 1.0 },
                .spot => .{ 0.65, 0.8, 1.0, 1.0 },
                .directional => .{ 1.0, 1.0, 1.0, 1.0 },
            };
            const proxy_material = try layer_context.world.resources.createMaterial(.{
                .name = material_name,
                .base_color_factor = tint,
                .base_color_texture = try layer_context.world.resources.ensureWhiteTexture(),
            });

            light_transform.scale = switch (kind) {
                .point => .{ 0.18, 0.18, 0.18 },
                .spot => .{ 0.24, 0.24, 0.24 },
                .directional => light_transform.scale,
            };
            mesh = .{
                .handle = proxy_mesh,
                .primitive = .sphere,
            };
            material = .{
                .handle = proxy_material,
                .base_color_factor = tint,
            };
        }

        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = light_transform,
            .mesh = mesh,
            .material = material,
            .light = .{
                .kind = kind,
                .intensity = intensity,
                .range = if (kind == .point) 12.0 else 10.0,
            },
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createLightEntity(kind, transform, intensity);
}

fn createVfxEntityViaQueueOrWorld(
    layer_context: *engine.core.LayerContext,
    kind: engine.scene.VfxKind,
    transform: engine.scene.Transform,
) !engine.scene.EntityId {
    if (layer_context.command_queue) |queue| {
        const base_name = switch (kind) {
            .fountain => "FountainVfx",
            .orbit => "OrbitVfx",
        };
        const name = try layer_context.world.nextAvailableName(base_name);
        defer layer_context.world.allocator.free(name);

        const mesh_handle = try layer_context.world.resources.ensurePrimitiveMesh(.sphere);
        const vfx = engine.scene.defaultVfx(kind);
        var root_transform = transform;
        root_transform.scale = switch (kind) {
            .fountain => .{ 0.18, 0.18, 0.18 },
            .orbit => .{ 0.2, 0.2, 0.2 },
        };

        try queue.enqueueCreateEntity(.{
            .name = name,
            .local_transform = root_transform,
            .mesh = .{
                .handle = mesh_handle,
                .primitive = .sphere,
            },
            .material = .{
                .shading = .unlit,
                .base_color_factor = .{ vfx.color[0], vfx.color[1], vfx.color[2], 1.0 },
            },
            .vfx = vfx,
        });
        return try executeSingleCreateResult(layer_context);
    }
    return layer_context.world.createVfxEntity(kind, transform);
}

fn executeSingleCreateResult(layer_context: *engine.core.LayerContext) !engine.scene.EntityId {
    const allocator = layer_context.world.allocator;
    const results = try executeQueuedCommands(layer_context);
    defer allocator.free(results);
    if (results.len == 0 or !results[0].ok() or results[0].entity_id == null) {
        return error.CommandExecutionFailed;
    }
    return results[0].entity_id.?;
}

pub fn spawnTransform(state: *EditorState, layer_context: *engine.core.LayerContext) engine.scene.Transform {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    const forward = engine.math.quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 });
    const base_transform: engine.scene.Transform = .{
        .translation = vec3.add(camera_transform.translation, vec3.scale(forward, 3.0)),
    };
    return resolveUnoccupiedSpawnTransform(layer_context.world, camera_transform, base_transform, 0.9);
}

fn spawnCameraTransform(state: *EditorState, layer_context: *engine.core.LayerContext) engine.scene.Transform {
    const camera_transform = camera.activeCameraTransform(state, layer_context);
    return resolveUnoccupiedSpawnTransform(layer_context.world, camera_transform, camera_transform, 1.25);
}

fn resolveUnoccupiedSpawnTransform(
    world: *engine.scene.World,
    reference_camera: engine.scene.Transform,
    base_transform: engine.scene.Transform,
    min_distance: f32,
) engine.scene.Transform {
    world.updateHierarchy();

    const right = quat.rotateVec3(reference_camera.rotation, .{ 1.0, 0.0, 0.0 });
    const up = quat.rotateVec3(reference_camera.rotation, .{ 0.0, 1.0, 0.0 });
    const offsets = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ -1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 0.0, -1.0 },
        .{ 1.4, 1.0 },
        .{ -1.4, 1.0 },
        .{ 1.4, -1.0 },
        .{ -1.4, -1.0 },
        .{ 2.0, 0.0 },
        .{ -2.0, 0.0 },
    };

    for (offsets) |offset| {
        var candidate = base_transform;
        candidate.translation = vec3.add(
            candidate.translation,
            vec3.add(
                vec3.scale(right, offset[0] * min_distance),
                vec3.scale(up, offset[1] * min_distance),
            ),
        );
        if (!spawnPositionOccupied(world, candidate.translation, min_distance)) {
            return candidate;
        }
    }

    return base_transform;
}

fn spawnPositionOccupied(world: *engine.scene.World, position: [3]f32, min_distance: f32) bool {
    const min_distance_sq = min_distance * min_distance;
    for (world.entities.items) |entity| {
        if (entity.editor_only) continue;
        const world_transform = world.worldTransformConst(entity.id) orelse entity.local_transform;
        const delta = vec3.sub(world_transform.translation, position);
        if (vec3.dot(delta, delta) < min_distance_sq) {
            return true;
        }
    }
    return false;
}

pub fn saveScene(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    saveScenePath(state, layer_context, autosave_path);
}

pub fn saveScenePath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) void {
    engine.scene.saveWorldWithRuntimeStateToPath(
        layer_context.world.allocator,
        layer_context.world,
        .{
            .global_time = layer_context.global_time.*,
            .time_scale = layer_context.time_scale.*,
            .physics_accumulator_seconds = layer_context.physics_accumulator_seconds.*,
            .playback_state = @enumFromInt(@intFromEnum(layer_context.playback_controller.state)),
            .game_state = @enumFromInt(@intFromEnum(layer_context.game_state.*)),
        },
        path,
    ) catch |err| {
        std.log.err("failed to save scene to {s}: {}", .{ path, err });
        return;
    };
    state.saved_command_cursor = state.undo_stack.items.len;
    content_browser.refreshAssetBrowser(state, layer_context) catch |err| {
        std.log.warn("failed to refresh asset browser after save: {}", .{err});
    };
}

pub fn loadScene(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    try loadScenePath(state, layer_context, autosave_path);
}

pub fn newScene(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    manipulation.clearTransformTool(state);
    vfx_runtime.clearAll(layer_context);
    layer_context.world.clear();
    try layer_context.renderer.resetSceneState();
    state.scene_camera = null;
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    state.scene_root_entity = try createSceneRootEntity(layer_context.world);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try layer_context.renderer.replaceSelection(null);
    utils.syncInspectorNameBuffer(state, layer_context);
    try resetSnapshotHistory(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

fn createSceneRootEntity(world: *engine.scene.World) !engine.scene.EntityId {
    return world.createEntity(.{
        .name = "Scene Root",
        .editor_only = true,
    });
}

pub fn loadScenePath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) !void {
    manipulation.clearTransformTool(state);
    vfx_runtime.clearAll(layer_context);
    var runtime_state = engine.scene.SceneRuntimeState{};
    engine.scene.loadWorldWithRuntimeStateFromPath(
        layer_context.world.allocator,
        layer_context.world,
        path,
        &runtime_state,
    ) catch |err| {
        std.log.err("failed to load scene from {s}: {}", .{ path, err });
        return;
    };

    layer_context.global_time.* = runtime_state.global_time;
    layer_context.time_scale.* = runtime_state.time_scale;
    layer_context.physics_accumulator_seconds.* = runtime_state.physics_accumulator_seconds;
    layer_context.playback_controller.setState(@enumFromInt(@intFromEnum(runtime_state.playback_state)));
    layer_context.game_state.* = @enumFromInt(@intFromEnum(runtime_state.game_state));

    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    state.scene_root_entity = try createSceneRootEntity(layer_context.world);
    try reparentAllRootEntitiesToSceneRoot(layer_context.world, state.scene_root_entity.?);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try layer_context.renderer.replaceSelection(null);
    utils.syncInspectorNameBuffer(state, layer_context);
    try resetSnapshotHistory(state, layer_context);
    try refreshWindowTitle(state, layer_context);

    // world.clear() inside loadWorldWithRuntimeStateFromPath destroys the
    // ResourceLibrary, wiping script handles registered by the initial
    // discoverScripts() call.  Re-discover project scripts so that
    // entity.setAssetField lookups work for script_handle fields.
    rediscoverProjectScripts(layer_context.world, state);
}

fn reparentAllRootEntitiesToSceneRoot(world: *engine.scene.World, scene_root: engine.scene.EntityId) !void {
    var root_ids = std.ArrayList(engine.scene.EntityId).empty;
    defer root_ids.deinit(world.allocator);
    for (world.entities.items) |entity| {
        if (entity.editor_only or entity.parent != null) continue;
        try root_ids.append(world.allocator, entity.id);
    }
    for (root_ids.items) |root_id| {
        _ = try world.setParentLocal(root_id, scene_root);
    }
}

pub fn importModelPath(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8) !void {
    try importModelPathAt(state, layer_context, path, spawnTransform(state, layer_context));
}

pub fn importModelPathAt(state: *EditorState, layer_context: *engine.core.LayerContext, path: []const u8, transform: engine.scene.Transform) !void {
    const report = if (state.asset_registry) |*registry|
        if (registry.recordByPath(path)) |record|
            try engine.assets.importGltfStaticModelAssetInstance(
                layer_context.world,
                registry,
                record.id,
                transform,
            )
        else
            try layer_context.world.importGltfStaticModelInstance(path, transform)
    else
        try layer_context.world.importGltfStaticModelInstance(path, transform);
    if (report.root_entity) |root_entity| {
        try layer_context.renderer.replaceSelection(root_entity);
        utils.syncInspectorNameBuffer(state, layer_context);
        camera.focusSelection(state, layer_context);
    }
    try captureSnapshot(state, layer_context);
    try refreshWindowTitle(state, layer_context);
}

pub fn refreshWindowTitle(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    _ = state;
    _ = layer_context;
}

pub fn hasUnsavedChanges(state: *const EditorState) bool {
    const saved_command_cursor = state.saved_command_cursor orelse return state.undo_stack.items.len != 0;
    return saved_command_cursor != state.undo_stack.items.len;
}

pub fn captureEntitySnapshot(
    state: *EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
) !?command_mod.EntitySnapshot {
    const allocator = state.allocator orelse world.allocator;
    return captureEntitySnapshotAlloc(allocator, world, entity_id);
}

pub fn captureEntitySnapshots(
    state: *EditorState,
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
) !std.ArrayList(command_mod.EntitySnapshot) {
    const allocator = state.allocator orelse world.allocator;
    var snapshots = std.ArrayList(command_mod.EntitySnapshot).empty;
    errdefer deinitSnapshotList(allocator, &snapshots);

    for (entity_ids) |entity_id| {
        if (selectionContainsAncestor(world, entity_ids, entity_id)) {
            continue;
        }
        if (try captureEntitySnapshot(state, world, entity_id)) |snapshot| {
            try snapshots.append(allocator, snapshot);
        }
    }
    return snapshots;
}

pub fn deinitEntitySnapshots(state: *EditorState, snapshots: *std.ArrayList(command_mod.EntitySnapshot)) void {
    const allocator = state.allocator orelse return;
    deinitSnapshotList(allocator, snapshots);
}

pub fn recordEntityMutation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    before: command_mod.EntitySnapshot,
    selection_before: []const engine.scene.EntityId,
) !void {
    if (state.play_mode_active) {
        var owned_before = before;
        const allocator = state.allocator orelse layer_context.world.allocator;
        owned_before.deinit(allocator);
        return;
    }
    const allocator = state.allocator orelse layer_context.world.allocator;
    if (entitySubtreeRequiresSceneSnapshot(layer_context.world, before.id)) {
        var owned_before = before;
        owned_before.deinit(allocator);
        try captureSnapshot(state, layer_context);
        return;
    }

    var deltas = std.ArrayList(command_mod.SubtreeDelta).empty;
    errdefer deinitDeltaList(allocator, &deltas);

    var after = try captureEntitySnapshot(state, layer_context.world, before.id) orelse {
        var owned_before = before;
        owned_before.deinit(allocator);
        return;
    };
    if (entitySnapshotsEqual(&before, &after)) {
        var owned_before = before;
        owned_before.deinit(allocator);
        after.deinit(allocator);
        return;
    }

    try deltas.append(allocator, .{
        .before = before,
        .after = after,
    });
    try pushSubtreeDeltaCommand(state, layer_context, &deltas, selection_before);
}

pub fn recordEntityBatchMutation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    before_snapshots: *std.ArrayList(command_mod.EntitySnapshot),
    selection_before: []const engine.scene.EntityId,
) !void {
    if (state.play_mode_active) {
        deinitEntitySnapshots(state, before_snapshots);
        return;
    }
    const allocator = state.allocator orelse layer_context.world.allocator;
    for (before_snapshots.items) |before| {
        if (entitySubtreeRequiresSceneSnapshot(layer_context.world, before.id)) {
            deinitEntitySnapshots(state, before_snapshots);
            try captureSnapshot(state, layer_context);
            return;
        }
    }

    var deltas = std.ArrayList(command_mod.SubtreeDelta).empty;
    errdefer deinitDeltaList(allocator, &deltas);

    for (before_snapshots.items) |before| {
        var after = try captureEntitySnapshot(state, layer_context.world, before.id) orelse {
            var owned_before = before;
            owned_before.deinit(allocator);
            continue;
        };
        if (entitySnapshotsEqual(&before, &after)) {
            var owned_before = before;
            owned_before.deinit(allocator);
            after.deinit(allocator);
            continue;
        }
        try deltas.append(allocator, .{
            .before = before,
            .after = after,
        });
    }

    before_snapshots.deinit(allocator);
    before_snapshots.* = .empty;

    if (deltas.items.len == 0) {
        return;
    }
    try pushSubtreeDeltaCommand(state, layer_context, &deltas, selection_before);
}

pub fn recordCreatedEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    selection_before: []const engine.scene.EntityId,
) !void {
    if (state.play_mode_active) {
        return;
    }
    const allocator = state.allocator orelse layer_context.world.allocator;
    if (entityListRequiresSceneSnapshot(layer_context.world, entity_ids)) {
        try captureSnapshot(state, layer_context);
        return;
    }

    var deltas = std.ArrayList(command_mod.SubtreeDelta).empty;
    errdefer deinitDeltaList(allocator, &deltas);

    for (entity_ids) |entity_id| {
        if (try captureEntitySnapshot(state, layer_context.world, entity_id)) |snapshot| {
            try deltas.append(allocator, .{ .after = snapshot });
        }
    }

    if (deltas.items.len == 0) {
        return;
    }
    try pushSubtreeDeltaCommand(state, layer_context, &deltas, selection_before);
}

pub fn recordDeletedEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    before_snapshots: *std.ArrayList(command_mod.EntitySnapshot),
    selection_before: []const engine.scene.EntityId,
) !void {
    if (state.play_mode_active) {
        deinitEntitySnapshots(state, before_snapshots);
        return;
    }
    const allocator = state.allocator orelse layer_context.world.allocator;
    var deltas = std.ArrayList(command_mod.SubtreeDelta).empty;
    errdefer deinitDeltaList(allocator, &deltas);

    for (before_snapshots.items) |snapshot| {
        try deltas.append(allocator, .{ .before = snapshot });
    }
    before_snapshots.deinit(allocator);
    before_snapshots.* = .empty;

    if (deltas.items.len == 0) {
        return;
    }
    try pushSubtreeDeltaCommand(state, layer_context, &deltas, selection_before);
}

const ApplyDirection = enum {
    undo,
    redo,
};

fn clearCommandStack(allocator: std.mem.Allocator, stack: *std.ArrayList(command_mod.EditorCommand)) void {
    for (stack.items) |*command| {
        command.deinit(allocator);
    }
    stack.deinit(allocator);
    stack.* = .empty;
}

fn clearTimelineEntries(allocator: std.mem.Allocator, timeline: *std.ArrayList(command_mod.TimelineEntry)) void {
    for (timeline.items) |*entry| {
        entry.deinit(allocator);
    }
    timeline.deinit(allocator);
    timeline.* = .empty;
}

pub fn refreshSnapshotBaseline(state: *EditorState, world: *engine.scene.World) !void {
    if (state.play_mode_active) {
        return;
    }
    try refreshCurrentHistorySnapshot(state, world);
}

pub fn restorePlayModeSnapshot(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const snapshot = state.history_world_snapshot orelse return;
    manipulation.clearTransformTool(state);
    vfx_runtime.clearAll(layer_context);
    try engine.scene.deserializeWorldFromSlice(layer_context.world.allocator, layer_context.world, snapshot);
    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    // Refresh baseline snapshot to match the restored world (including new
    // editor camera) so subsequent undo/redo operations have a consistent
    // baseline.  The undo/redo command stacks are intentionally preserved.
    try refreshCurrentHistorySnapshot(state, layer_context.world);
    try refreshWindowTitle(state, layer_context);
}

fn pushCommand(state: *EditorState, command: command_mod.EditorCommand, source: command_mod.TimelineSource) !void {
    try pushCommandInternal(state, command);
    try appendTimelineFromCommand(state, command, source);
}

fn pushCommandInternal(state: *EditorState, command: command_mod.EditorCommand) !void {
    const allocator = state.allocator orelse return;
    clearCommandStack(allocator, &state.redo_stack);
    if (state.saved_command_cursor) |saved_command_cursor| {
        if (saved_command_cursor > state.undo_stack.items.len) {
            state.saved_command_cursor = null;
        }
    }

    try state.undo_stack.append(allocator, command);

    while (state.undo_stack.items.len > state.max_history_commands) {
        var removed = state.undo_stack.orderedRemove(0);
        removed.deinit(allocator);
        if (state.saved_command_cursor) |saved_command_cursor| {
            state.saved_command_cursor = if (saved_command_cursor == 0) null else saved_command_cursor - 1;
        }
    }
}

fn appendTimelineFromCommand(state: *EditorState, command: command_mod.EditorCommand, source: command_mod.TimelineSource) !void {
    const label = switch (source) {
        .human => state.text(.history_timeline_label_scene_edited),
        .ai => state.text(.history_timeline_label_ai_scene_edited),
    };
    const detail = switch (command) {
        .scene_snapshot => state.text(.history_timeline_kind_scene_snapshot),
        .subtree_delta => state.text(.history_timeline_kind_subtree_delta),
    };
    const kind = switch (command) {
        .scene_snapshot => "scene_snapshot",
        .subtree_delta => "subtree_delta",
    };
    try appendTimelineEvent(state, source, label, detail, kind);
}

fn pushSubtreeDeltaCommand(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    deltas: *std.ArrayList(command_mod.SubtreeDelta),
    selection_before: []const engine.scene.EntityId,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    var command: command_mod.EditorCommand = .{
        .subtree_delta = .{
            .deltas = deltas.*,
            .selection_before = try command_mod.SelectionSnapshot.fromSlice(allocator, selection_before),
            .selection_after = try command_mod.SelectionSnapshot.fromSlice(allocator, layer_context.renderer.selectedEntities()),
        },
    };
    deltas.* = .empty;
    errdefer command.deinit(allocator);

    try pushCommand(state, command, .human);
    // Defer the expensive full-world serialization to the next frame to avoid
    // a stutter on mouse release.  The snapshot will be refreshed at the start
    // of the next editor update before any new history operations.
    state.history_snapshot_needs_refresh = true;
}

fn applyCommand(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    command: *command_mod.EditorCommand,
    direction: ApplyDirection,
) !void {
    switch (command.*) {
        .scene_snapshot => |*scene_snapshot| {
            try applySceneSnapshot(
                state,
                layer_context,
                if (direction == .undo) scene_snapshot.before else scene_snapshot.after,
                if (direction == .undo) &scene_snapshot.selection_before else &scene_snapshot.selection_after,
            );
        },
        .subtree_delta => |*subtree_delta| {
            try applySubtreeDeltaCommand(
                state,
                layer_context,
                subtree_delta,
                if (direction == .undo) &subtree_delta.selection_before else &subtree_delta.selection_after,
                direction,
            );
        },
    }
}

fn applySceneSnapshot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    snapshot: []const u8,
    selection: *const command_mod.SelectionSnapshot,
) !void {
    manipulation.clearTransformTool(state);
    vfx_runtime.clearAll(layer_context);
    try engine.scene.deserializeWorldFromSlice(layer_context.world.allocator, layer_context.world, snapshot);
    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    state.editor_camera = null;
    try camera.createEditorCamera(state, layer_context);
    if (!state.editor_camera_active) {
        if (state.scene_camera) |scene_camera_id| {
            _ = layer_context.world.setPrimaryCamera(scene_camera_id);
        }
    }
    try restoreSelection(state, layer_context, selection);
    try refreshWindowTitle(state, layer_context);
}

fn applySubtreeDeltaCommand(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    command: *const command_mod.SubtreeDeltaCommand,
    selection: *const command_mod.SelectionSnapshot,
    direction: ApplyDirection,
) !void {
    manipulation.clearTransformTool(state);
    vfx_runtime.clearAll(layer_context);

    for (command.deltas.items) |*delta| {
        const target = if (direction == .undo) delta.before else delta.after;
        const opposite = if (direction == .undo) delta.after else delta.before;

        if (target) |*snapshot| {
            try restoreEntitySnapshot(layer_context.world, snapshot);
        } else if (opposite) |*snapshot| {
            _ = layer_context.world.destroyEntity(snapshot.id);
        }
    }

    try layer_context.renderer.resetSceneState();
    state.scene_camera = layer_context.world.primaryCameraEntity();
    try restoreSelection(state, layer_context, selection);
    try refreshWindowTitle(state, layer_context);
}

fn refreshCurrentHistorySnapshot(state: *EditorState, world: *engine.scene.World) !void {
    const allocator = state.allocator orelse world.allocator;
    const snapshot = try engine.scene.serializeWorldAlloc(allocator, world);
    errdefer allocator.free(snapshot);
    try replaceHistoryWorldSnapshot(state, snapshot);
    allocator.free(snapshot);
}

fn replaceHistoryWorldSnapshot(state: *EditorState, snapshot: []const u8) !void {
    const allocator = state.allocator orelse return;
    const snapshot_copy = try allocator.dupe(u8, snapshot);
    errdefer allocator.free(snapshot_copy);
    if (state.history_world_snapshot) |current| {
        allocator.free(current);
    }
    state.history_world_snapshot = snapshot_copy;
}

fn restoreSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selection: *const command_mod.SelectionSnapshot,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    var valid_selection = std.ArrayList(engine.scene.EntityId).empty;
    defer valid_selection.deinit(allocator);

    for (selection.entity_ids.items) |entity_id| {
        if (layer_context.world.hasEntity(entity_id)) {
            try valid_selection.append(allocator, entity_id);
        }
    }

    switch (valid_selection.items.len) {
        0 => try layer_context.renderer.replaceSelection(null),
        1 => try layer_context.renderer.replaceSelection(valid_selection.items[0]),
        else => try layer_context.renderer.replaceSelectionMany(valid_selection.items),
    }
    utils.syncInspectorNameBuffer(state, layer_context);
}

fn restoreEntitySnapshot(world: *engine.scene.World, snapshot: *const command_mod.EntitySnapshot) !void {
    if (world.getEntity(snapshot.id)) |entity| {
        if (entity.parent != snapshot.parent) {
            _ = try world.setParentLocal(snapshot.id, snapshot.parent);
        }
        if (!std.mem.eql(u8, entity.name, snapshot.name)) {
            _ = try world.renameEntity(snapshot.id, snapshot.name);
        }
        entity.local_transform = snapshot.local_transform;
        entity.camera = snapshot.camera;
        entity.mesh = snapshot.mesh;
        entity.material = snapshot.material;
        entity.light = snapshot.light;
        entity.vfx = snapshot.vfx;
        entity.visible = snapshot.visible;
        entity.editor_only = snapshot.editor_only;
        entity.is_folder = snapshot.is_folder;
        world.markDirty(snapshot.id);
    } else {
        _ = try world.createEntityWithId(snapshot.id, .{
            .name = snapshot.name,
            .parent = snapshot.parent,
            .local_transform = snapshot.local_transform,
            .camera = snapshot.camera,
            .mesh = snapshot.mesh,
            .material = snapshot.material,
            .light = snapshot.light,
            .vfx = snapshot.vfx,
            .visible = snapshot.visible,
            .editor_only = snapshot.editor_only,
            .is_folder = snapshot.is_folder,
        });
    }

    var keep_ids = std.ArrayList(engine.scene.EntityId).empty;
    defer keep_ids.deinit(world.allocator);

    for (snapshot.children.items) |*child| {
        try restoreEntitySnapshot(world, child);
        try keep_ids.append(world.allocator, child.id);
    }

    var removed_children = std.ArrayList(engine.scene.EntityId).empty;
    defer removed_children.deinit(world.allocator);

    for (world.entities.items) |entity| {
        if (entity.parent == snapshot.id and !entity.editor_only and !containsEntityId(keep_ids.items, entity.id)) {
            try removed_children.append(world.allocator, entity.id);
        }
    }

    for (removed_children.items) |entity_id| {
        _ = world.destroyEntity(entity_id);
    }
}

fn captureEntitySnapshotAlloc(
    allocator: std.mem.Allocator,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
) !?command_mod.EntitySnapshot {
    const entity = world.getEntityConst(entity_id) orelse return null;
    if (entity.editor_only) {
        return null;
    }

    var snapshot = command_mod.EntitySnapshot{
        .id = entity.id,
        .name = try allocator.dupe(u8, entity.name),
        .parent = entity.parent,
        .local_transform = entity.local_transform,
        .camera = entity.camera,
        .mesh = entity.mesh,
        .material = entity.material,
        .light = entity.light,
        .vfx = entity.vfx,
        .visible = entity.visible,
        .editor_only = entity.editor_only,
        .is_folder = entity.is_folder,
    };
    errdefer snapshot.deinit(allocator);

    for (world.entities.items) |child| {
        if (child.parent != entity_id or child.editor_only) {
            continue;
        }
        if (try captureEntitySnapshotAlloc(allocator, world, child.id)) |child_snapshot| {
            try snapshot.children.append(allocator, child_snapshot);
        }
    }

    return snapshot;
}

fn deinitSnapshotList(allocator: std.mem.Allocator, snapshots: *std.ArrayList(command_mod.EntitySnapshot)) void {
    for (snapshots.items) |*snapshot| {
        snapshot.deinit(allocator);
    }
    snapshots.deinit(allocator);
    snapshots.* = .empty;
}

fn deinitDeltaList(allocator: std.mem.Allocator, deltas: *std.ArrayList(command_mod.SubtreeDelta)) void {
    for (deltas.items) |*delta| {
        delta.deinit(allocator);
    }
    deltas.deinit(allocator);
    deltas.* = .empty;
}

fn entitySnapshotsEqual(a: *const command_mod.EntitySnapshot, b: *const command_mod.EntitySnapshot) bool {
    if (a.id != b.id or
        !std.mem.eql(u8, a.name, b.name) or
        a.parent != b.parent or
        !std.meta.eql(a.local_transform, b.local_transform) or
        !std.meta.eql(a.camera, b.camera) or
        !std.meta.eql(a.mesh, b.mesh) or
        !std.meta.eql(a.material, b.material) or
        !std.meta.eql(a.light, b.light) or
        !std.meta.eql(a.vfx, b.vfx) or
        a.visible != b.visible or
        a.editor_only != b.editor_only or
        a.is_folder != b.is_folder or
        a.children.items.len != b.children.items.len)
    {
        return false;
    }

    for (a.children.items, b.children.items) |*left, *right| {
        if (!entitySnapshotsEqual(left, right)) {
            return false;
        }
    }
    return true;
}

fn containsEntityId(entity_ids: []const engine.scene.EntityId, entity_id: engine.scene.EntityId) bool {
    for (entity_ids) |candidate| {
        if (candidate == entity_id) {
            return true;
        }
    }
    return false;
}

fn entityListRequiresSceneSnapshot(
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
) bool {
    for (entity_ids) |entity_id| {
        if (entitySubtreeRequiresSceneSnapshot(world, entity_id)) {
            return true;
        }
    }
    return false;
}

fn entitySubtreeRequiresSceneSnapshot(
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    if (entity.animator != null or
        entity.skinned_mesh != null or
        world.animatorTargets(entity_id) != null or
        world.animatorGraph(entity_id) != null or
        world.skinnedMeshTargets(entity_id) != null)
    {
        return true;
    }

    for (entity.children.items) |child_id| {
        if (entitySubtreeRequiresSceneSnapshot(world, child_id)) {
            return true;
        }
    }

    return false;
}

fn collectSelectionRoots(
    allocator: std.mem.Allocator,
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
    editor_camera: ?engine.scene.EntityId,
    out_roots: *std.ArrayList(engine.scene.EntityId),
) !void {
    for (entity_ids) |entity_id| {
        if (editor_camera != null and entity_id == editor_camera.?) {
            continue;
        }
        if (!world.hasEntity(entity_id) or selectionContainsAncestor(world, entity_ids, entity_id)) {
            continue;
        }
        try out_roots.append(allocator, entity_id);
    }
}

fn selectionContainsAncestor(
    world: *const engine.scene.World,
    entity_ids: []const engine.scene.EntityId,
    entity_id: engine.scene.EntityId,
) bool {
    var current = world.parentEntity(entity_id);
    while (current) |current_id| {
        for (entity_ids) |candidate| {
            if (candidate == current_id) {
                return true;
            }
        }
        current = world.parentEntity(current_id);
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════
//  Script re-discovery after scene load
// ═══════════════════════════════════════════════════════════════════

/// Re-discover script files under the configured scripts directory and register them in the
/// ResourceLibrary.  This is needed because world.clear() (called during
/// scene loading) destroys the entire ResourceLibrary, including script
/// handles that were registered by Application.discoverScripts() at startup.
pub fn rediscoverProjectScripts(world: *engine.scene.World, state: *const EditorState) void {
    const allocator = world.allocator;
    const scripts_dir = state.scriptsDir();

    // Open scripts directory relative to project root (or CWD as fallback).
    const project_path = state.projectPath();
    var owned_base: ?std.fs.Dir = if (project_path.len > 0)
        (std.fs.openDirAbsolute(project_path, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close();
    const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

    var dir = base_dir.openDir(scripts_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const is_zig = std.mem.endsWith(u8, entry.path, ".zig");
        const is_cs = std.mem.endsWith(u8, entry.path, ".cs");
        if (!is_zig and !is_cs) continue;

        const full_path = std.fs.path.join(allocator, &.{ scripts_dir, entry.path }) catch continue;
        defer allocator.free(full_path);

        // Skip if already registered (e.g. restored from scene file)
        if (world.resources.scriptHandleByAssetId(full_path) != null) continue;

        const source = base_dir.readFileAlloc(allocator, full_path, 1024 * 1024) catch continue;
        defer allocator.free(source);

        const language: engine.script.ScriptLanguage = if (is_cs) .csharp else .zig;
        const handle = world.resources.createScript(.{
            .source = source,
            .language = language,
            .entry_fn = "main",
            .description = full_path,
            .source_path = full_path,
            .artifact_path = "",
        }) catch continue;

        // Bind an AssetRecord so scriptHandleByAssetId(full_path) returns the handle.
        const record: engine.assets.AssetRecord = .{
            .id = allocator.dupe(u8, full_path) catch continue,
            .type = .script,
            .source_path = allocator.dupe(u8, full_path) catch continue,
            .source_hash = engine.assets.hashStringAlloc(allocator, full_path) catch continue,
            .import_settings_hash = engine.assets.defaultImportSettingsHashAlloc(allocator, .script) catch continue,
            .import_version = @as(engine.assets.AssetType, .script).importVersion(),
            .dependency_ids = allocator.alloc([]u8, 0) catch continue,
            .outputs = allocator.alloc(engine.assets.AssetOutput, 0) catch continue,
            .metadata = .{
                .display_name = allocator.dupe(u8, std.fs.path.basename(full_path)) catch continue,
                .importer = allocator.dupe(u8, @as(engine.assets.AssetType, .script).importerName()) catch continue,
                .source_extension = allocator.dupe(u8, std.fs.path.extension(full_path)) catch continue,
            },
        };
        _ = world.resources.bindScriptAssetRecord(handle, record) catch continue;
        count += 1;
    }
    if (count > 0) {
        std.log.info("Editor: re-discovered {d} project script(s) after scene load", .{count});
    }
}
