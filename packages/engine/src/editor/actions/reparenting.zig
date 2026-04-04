const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const history = @import("history.zig");

pub fn parentSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection = layer_context.renderer.selectedEntities();
    if (selection.len < 2) {
        return;
    }

    const parent_id = layer_context.renderer.selectedEntity() orelse return;
    if (state.editor_camera != null and parent_id == state.editor_camera.?) {
        return;
    }

    var before = try history.captureEntitySnapshots(state, layer_context.world, selection);
    var before_owned = true;
    defer if (before_owned) history.deinitEntitySnapshots(state, &before);
    const selection_before = selection;

    var changed = false;
    for (selection) |entity_id| {
        if (entity_id == parent_id) {
            continue;
        }
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        changed = (try reparentEntityViaCommandQueue(layer_context, entity_id, parent_id)) or changed;
    }

    if (changed) {
        try history.recordEntityBatchMutation(state, layer_context, &before, selection_before);
        before_owned = false;
    }
}

pub fn unparentSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection = layer_context.renderer.selectedEntities();
    try unparentEntities(state, layer_context, selection);
}

fn unparentEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
) !void {
    if (entity_ids.len == 0) {
        return;
    }

    var before = try history.captureEntitySnapshots(state, layer_context.world, entity_ids);
    var before_owned = true;
    defer if (before_owned) history.deinitEntitySnapshots(state, &before);
    const selection_before = layer_context.renderer.selectedEntities();
    var changed = false;
    for (entity_ids) |entity_id| {
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        changed = (try reparentEntityViaCommandQueue(layer_context, entity_id, null)) or changed;
    }

    if (changed) {
        try history.recordEntityBatchMutation(state, layer_context, &before, selection_before);
        before_owned = false;
    }
}

fn reparentEntityViaCommandQueue(
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !bool {
    if (layer_context.command_queue) |queue| {
        const allocator = layer_context.world.allocator;
        try queue.enqueueSetParent(entity_id, parent_id);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        if (results.len == 0) {
            return false;
        }
        if (results[0].err) |err| {
            std.log.warn("failed to reparent entity {d}: {s}", .{ entity_id, @tagName(err) });
            return false;
        }
        return results[0].changed;
    }

    const changed = layer_context.world.setParent(entity_id, parent_id) catch |err| {
        std.log.warn("failed to reparent entity {d}: {}", .{ entity_id, err });
        return false;
    };
    return changed;
}
