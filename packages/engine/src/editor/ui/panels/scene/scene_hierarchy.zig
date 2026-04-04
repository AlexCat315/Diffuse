const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const utils = @import("../../../common/utils.zig");
const history = @import("../../../actions/history.zig");
const content_browser = @import("../../../assets/browser.zig");
const inspector = @import("inspector.zig");
const camera = @import("../../../interaction/camera.zig");
const ui_icons = @import("../../icons.zig");
const layout = @import("../../layout.zig");
const prefab_mod = @import("guava").scene.prefab;
const theme = @import("../../theme.zig");
const icon_button = @import("../../components/icon_button.zig");
const toggle_button = @import("../../components/toggle_button.zig");

fn collectVisibleChildren(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    parent_id: engine.scene.EntityId,
    out: *std.ArrayList(engine.scene.EntityId),
) !void {
    for (layer_context.world.entities.items) |child| {
        if (child.editor_only or child.parent != parent_id) continue;
        if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, child.id)) continue;
        try out.append(state.allocator orelse layer_context.world.allocator, child.id);
    }
}

fn entityDragPreviewTypeLabel(state: *const EditorState, entity: *const engine.scene.Entity) []const u8 {
    if (entity.is_folder) {
        return state.text(.folder);
    }
    if (entity.camera != null) {
        return state.text(.camera);
    }
    if (entity.light != null) {
        return state.text(.light);
    }
    if (entity.vfx != null) {
        return state.text(.vfx);
    }
    if (entity.mesh != null) {
        return state.text(.mesh);
    }
    return state.text(.empty);
}

fn drawHierarchyDragPreview(state: *EditorState, entity: *const engine.scene.Entity, icon_texture: *engine.rhi.Texture) void {
    if (!gui.beginDragDropSourceU64(state_mod.entity_drag_payload, entity.id)) {
        return;
    }
    defer gui.endDragDropSource();

    state.active_drag_payload = .{
        .kind = .entity,
        .entity_id = entity.id,
    };

    var preview_buffer: [320]u8 = undefined;
    const preview_text = std.fmt.bufPrint(
        &preview_buffer,
        "{s}\n{s}",
        .{ entity.name, entityDragPreviewTypeLabel(state, entity) },
    ) catch entity.name;

    gui.image(icon_texture, theme.Size.drag_preview_icon, theme.Size.drag_preview_icon);
    gui.sameLine();
    gui.text(preview_text);
}

const place_actors = @import("place_actors.zig");

pub fn drawSceneWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .scene, "scene_panel");
    gui.setNextWindowSizeConstraints(.{ theme.Size.panel_min_width, theme.Size.panel_min_height }, .{ std.math.floatMax(f32), std.math.floatMax(f32) });
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    // Tab bar: Scene / Place Actors
    if (gui.beginTabBar("##scene_left_panel_tabs")) {
        if (gui.beginTabItem(state.text(.scene))) {
            state.left_panel_tab = .scene;
            gui.endTabItem();
        }
        if (gui.beginTabItem(state.text(.place_actors))) {
            state.left_panel_tab = .place_actors;
            gui.endTabItem();
        }
        gui.endTabBar();
    }

    switch (state.left_panel_tab) {
        .scene => try drawSceneContent(state, layer_context),
        .place_actors => try place_actors.drawPlaceActorsContent(state, layer_context),
    }
}

fn drawSceneContent(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    syncHierarchyRenameState(state, layer_context);

    // Filter bar
    layout.beginSectionBody();
    const controls_width = gui.contentRegionAvail()[0];
    if (controls_width >= theme.Spacing.hierarchy_filter_compact_threshold) {
        var selection_count_buffer: [32]u8 = undefined;
        const selection_count_text = try std.fmt.bufPrint(&selection_count_buffer, "{d}", .{layer_context.renderer.selectedEntities().len});
        gui.setNextItemWidth(controls_width - theme.Spacing.hierarchy_filter_right_margin);
        _ = gui.inputTextWithHint("##scene_filter", state.text(.scene_filter), state.scene_filter_buffer[0..]);
        gui.sameLineEx(0.0, theme.Spacing.hierarchy_selection_count_spacing);
        gui.pushStyleColor(.text, theme.Palette.hierarchy.filter_text);
        gui.text(selection_count_text);
        gui.popStyleColor(1);
        if (gui.isItemHovered()) {
            gui.setTooltip(state.text(.selection_count));
        }
    } else {
        gui.setNextItemWidth(-1.0);
        _ = gui.inputTextWithHint("##scene_filter", state.text(.scene_filter), state.scene_filter_buffer[0..]);
    }
    layout.drawSidebarSectionGap();
    layout.endSectionBody();

    // Drop targets
    var dropped_root: u64 = 0;
    if (gui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_root)) {
        _ = try handleHierarchyEntityDrop(state, layer_context, dropped_root, null);
    }
    var dropped_model: u64 = 0;
    if (gui.acceptDragDropPayloadU64(state_mod.asset_model_drag_payload, &dropped_model)) {
        const asset_index: usize = @intCast(dropped_model);
        if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .model) {
            try history.importModelPath(state, layer_context, state.asset_entries.items[asset_index].path);
        }
    }
    layout.drawSidebarSectionDivider();

    // Tree — start from the scene root entity so all guide lines have a
    // single unified parent chain.  The scene root itself is hidden (editor_only).
    const scene_root = state.scene_root_entity orelse {
        // Fallback for legacy scenes without a scene root: collect top-level
        // entities and draw them as before.
        var root_entities = std.ArrayList(engine.scene.EntityId).empty;
        defer root_entities.deinit(state.allocator orelse layer_context.world.allocator);
        for (layer_context.world.entities.items) |entity| {
            if (entity.editor_only or entity.parent != null) continue;
            if (!utils.shouldShowEntityInSceneTree(state, layer_context.world, entity.id)) continue;
            try root_entities.append(state.allocator orelse layer_context.world.allocator, entity.id);
        }
        for (root_entities.items, 0..) |entity_id, i| {
            var ancestor_has_next: [theme.Size.hierarchy_max_depth]bool = .{false} ** theme.Size.hierarchy_max_depth;
            ancestor_has_next[0] = i < root_entities.items.len - 1;
            drawHierarchyNodeImpl(state, layer_context, entity_id, 0, &ancestor_has_next) catch |err| switch (err) {
                error.HierarchyMutated => return,
                else => return err,
            };
        }
        if (try drawSceneWindowContextMenu(state, layer_context)) {
            return;
        }
        return;
    };

    // Draw children of the scene root as depth-0 nodes
    var ancestor_has_next: [theme.Size.hierarchy_max_depth]bool = .{false} ** theme.Size.hierarchy_max_depth;
    var root_children = std.ArrayList(engine.scene.EntityId).empty;
    defer root_children.deinit(state.allocator orelse layer_context.world.allocator);
    try collectVisibleChildren(state, layer_context, scene_root, &root_children);
    for (root_children.items, 0..) |child_id, i| {
        ancestor_has_next[0] = i < root_children.items.len - 1;
        drawHierarchyNodeImpl(state, layer_context, child_id, 0, &ancestor_has_next) catch |err| switch (err) {
            error.HierarchyMutated => return,
            else => return err,
        };
    }

    if (try drawSceneWindowContextMenu(state, layer_context)) {
        return;
    }
}

pub fn drawHierarchyNode(state: *EditorState, layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) anyerror!void {
    var ancestor_has_next: [theme.Size.hierarchy_max_depth]bool = .{false} ** theme.Size.hierarchy_max_depth;
    try drawHierarchyNodeImpl(state, layer_context, entity_id, 0, &ancestor_has_next);
}

fn drawHierarchyNodeImpl(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    depth: i32,
    ancestor_has_next: *[theme.Size.hierarchy_max_depth]bool,
) anyerror!void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;
    if (entity.editor_only) return;

    const is_selected = utils.isEntitySelected(state, layer_context, entity_id);
    const filter_active = utils.zeroTerminatedSlice(state.scene_filter_buffer[0..]).len != 0 or
        utils.zeroTerminatedSlice(state.hierarchy_filter_buffer[0..]).len != 0 or
        state.hierarchy_category != .all;
    const has_visible_children = utils.hasVisibleSceneTreeChildren(state, layer_context.world, entity_id);
    const leaf = !has_visible_children;
    const rename_active = state.hierarchy_rename_entity != null and state.hierarchy_rename_entity.? == entity_id;

    const icon_texture = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.entityIconPath(entity),
        theme.Size.hierarchy_icon,
        theme.hierarchyIconTint(.{ .selected = is_selected, .frozen = false, .visible = entity.visible }),
    );

    const chevron_down_tex = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.hierarchy.chevron_down,
        theme.Size.hierarchy_icon,
        theme.Palette.hierarchy.active_icon,
    );
    const chevron_right_tex = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.hierarchy.chevron_right,
        theme.Size.hierarchy_icon,
        theme.Palette.hierarchy.active_icon,
    );
    const eye_tex = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.hierarchy.eye,
        theme.Size.hierarchy_icon,
        theme.Palette.hierarchy.active_icon,
    );
    const eye_off_tex = try ui_icons.ensureTintedIconTexture(
        state,
        layer_context,
        ui_icons.paths.hierarchy.eye_off,
        theme.Size.hierarchy_icon,
        theme.Palette.hierarchy.active_icon,
    );

    // Calculate has_next_sibling — must account for filtered/hidden entities,
    // not just editor_only.  A node is "last" only if no VISIBLE sibling follows it.
    const has_next_sibling = blk: {
        if (entity.parent) |parent_id| {
            var found_self = false;
            for (layer_context.world.entities.items) |sibling| {
                if (sibling.parent != parent_id) continue;
                if (found_self) {
                    if (!sibling.editor_only and
                        utils.shouldShowEntityInSceneTree(state, layer_context.world, sibling.id))
                        break :blk true;
                }
                if (sibling.id == entity_id) found_self = true;
            }
        }
        break :blk false;
    };

    var visible_clicked: bool = false;
    const tree_result = gui.treeNodeEntity(
        entity_id,
        entity.name,
        icon_texture,
        theme.Size.hierarchy_icon,
        is_selected,
        leaf,
        filter_active and has_visible_children,
        if (rename_active) state.hierarchy_rename_buffer[0..] else null,
        rename_active and state.hierarchy_rename_focus_pending,
        depth,
        ancestor_has_next,
        has_next_sibling,
        has_visible_children,
        entity.visible,
        &visible_clicked,
        chevron_down_tex,
        chevron_right_tex,
        eye_tex,
        eye_off_tex,
        theme.Size.hierarchy_icon,
    );
    const is_open = tree_result.open;

    // Handle visibility toggle
    if (visible_clicked) {
        _ = try setEntityVisibleViaCommandQueue(state, layer_context, entity_id, !entity.visible);
    }

    if (rename_active) {
        state.hierarchy_rename_focus_pending = false;
    }

    // Click handling
    if (tree_result.clicked) {
        if (state.hierarchy_rename_entity != null and state.hierarchy_rename_entity.? != entity_id) {
            cancelHierarchyRename(state);
        }
        const multi_select = layer_context.input.modifiers.shift or layer_context.input.modifiers.ctrl or layer_context.input.modifiers.super;
        if (multi_select) {
            try layer_context.renderer.toggleSelection(entity_id);
        } else {
            try layer_context.renderer.replaceSelection(entity_id);
        }
        utils.syncInspectorNameBuffer(state, layer_context);
        if (!multi_select and layer_context.input.wasMouseDoubleClicked(.left)) {
            if (is_selected) {
                beginHierarchyRename(state, layer_context.world, entity_id);
            } else {
                camera.focusSelection(state, layer_context);
            }
        }
    }

    // Drag & drop
    if (!rename_active) {
        drawHierarchyDragPreview(state, entity, icon_texture);
        var dropped_child: u64 = 0;
        if (gui.acceptDragDropPayloadU64(state_mod.entity_drag_payload, &dropped_child)) {
            if (try handleHierarchyEntityDrop(state, layer_context, dropped_child, entity_id)) {
                return error.HierarchyMutated;
            }
        }
        var dropped_material: u64 = 0;
        if (gui.acceptDragDropPayloadU64(state_mod.asset_material_drag_payload, &dropped_material)) {
            const asset_index: usize = @intCast(dropped_material);
            if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .material) {
                _ = try content_browser.applyMaterialAssetToEntity(state, layer_context, &state.asset_entries.items[asset_index], entity_id);
            }
        }
        var dropped_texture: u64 = 0;
        if (gui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &dropped_texture)) {
            const asset_index: usize = @intCast(dropped_texture);
            if (asset_index < state.asset_entries.items.len and state.asset_entries.items[asset_index].kind == .texture) {
                if (entity.material == null) {
                    try inspector.addMaterialComponent(state, layer_context, entity);
                }
                if (try inspector.assignTextureEntryToMaterial(state, layer_context, entity, &state.asset_entries.items[asset_index])) {
                    try history.captureSnapshot(state, layer_context);
                }
            }
        }
    }

    // Context menu
    var popup_id_buffer: [48]u8 = undefined;
    const popup_id = try std.fmt.bufPrint(&popup_id_buffer, "{d}_context", .{entity_id});
    if (gui.beginPopupContextItem(popup_id)) {
        defer gui.endPopup();
        if (!is_selected) {
            try layer_context.renderer.replaceSelection(entity_id);
            utils.syncInspectorNameBuffer(state, layer_context);
        }
        if (try drawHierarchyNodeContextMenu(state, layer_context, entity_id, is_selected)) {
            return error.HierarchyMutated;
        }
    }

    // Rename finish
    if (rename_active and tree_result.rename_finished) {
        if (tree_result.rename_committed) {
            try commitHierarchyRename(state, layer_context, entity_id);
        }
        cancelHierarchyRename(state);
    }

    // Recurse children
    if (has_visible_children and is_open) {
        const child_depth = depth + 1;
        var visible_children = std.ArrayList(engine.scene.EntityId).empty;
        defer visible_children.deinit(state.allocator orelse layer_context.world.allocator);
        try collectVisibleChildren(state, layer_context, entity_id, &visible_children);
        for (visible_children.items, 0..) |child_id, i| {
            if (child_depth < theme.Size.hierarchy_max_depth) {
                ancestor_has_next[@intCast(child_depth)] = i < visible_children.items.len - 1;
            }
            drawHierarchyNodeImpl(state, layer_context, child_id, child_depth, ancestor_has_next) catch |err| switch (err) {
                error.HierarchyMutated => return error.HierarchyMutated,
                else => return err,
            };
        }
    }
}

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

pub fn reparentEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    child_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !void {
    _ = try reparentEntities(state, layer_context, &.{child_id}, parent_id, false);
}

fn handleHierarchyEntityDrop(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    dragged_entity_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) !bool {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const selection = layer_context.renderer.selectedEntities();
    const preserve_selection = selection.len > 1 and sliceContainsEntity(selection, dragged_entity_id);

    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(allocator);
    try collectDraggedEntityRoots(
        allocator,
        layer_context.world,
        selection,
        dragged_entity_id,
        state.editor_camera,
        &roots,
    );
    return reparentEntities(state, layer_context, roots.items, parent_id, preserve_selection);
}

fn reparentEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
    preserve_selection: bool,
) !bool {
    if (entity_ids.len == 0) {
        return false;
    }
    if (parent_id) |resolved_parent_id| {
        if (utils.isEntityFrozen(state, resolved_parent_id) or utils.isEntitySelectionLocked(state, resolved_parent_id)) {
            return false;
        }
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    var before = try history.captureEntitySnapshots(state, layer_context.world, entity_ids);
    var before_owned = true;
    defer if (before_owned) history.deinitEntitySnapshots(state, &before);
    const selection_before = layer_context.renderer.selectedEntities();
    var moved = std.ArrayList(engine.scene.EntityId).empty;
    defer moved.deinit(allocator);

    for (entity_ids) |entity_id| {
        if (state.editor_camera != null and entity_id == state.editor_camera.?) {
            continue;
        }
        if (!layer_context.world.hasEntity(entity_id)) {
            continue;
        }
        if (utils.isEntityFrozen(state, entity_id) or utils.isEntitySelectionLocked(state, entity_id)) {
            continue;
        }
        if (wouldCreateHierarchyCycle(layer_context.world, entity_id, parent_id)) {
            continue;
        }

        const changed = try reparentEntityViaCommandQueue(layer_context, entity_id, parent_id);
        if (!changed) {
            continue;
        }
        try moved.append(allocator, entity_id);
    }

    if (moved.items.len == 0) {
        return false;
    }

    if (!preserve_selection) {
        try layer_context.renderer.replaceSelection(moved.items[0]);
    }
    utils.syncInspectorNameBuffer(state, layer_context);
    try history.recordEntityBatchMutation(state, layer_context, &before, selection_before);
    before_owned = false;
    return true;
}

fn collectDraggedEntityRoots(
    allocator: std.mem.Allocator,
    world: *const engine.scene.World,
    selection: []const engine.scene.EntityId,
    dragged_entity_id: engine.scene.EntityId,
    editor_camera: ?engine.scene.EntityId,
    out_roots: *std.ArrayList(engine.scene.EntityId),
) !void {
    if (selection.len > 1 and sliceContainsEntity(selection, dragged_entity_id)) {
        try collectSelectionRoots(allocator, world, selection, editor_camera, out_roots);
        return;
    }

    if (editor_camera != null and dragged_entity_id == editor_camera.?) {
        return;
    }
    if (!world.hasEntity(dragged_entity_id)) {
        return;
    }
    try out_roots.append(allocator, dragged_entity_id);
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
        if (sliceContainsEntity(entity_ids, current_id)) {
            return true;
        }
        current = world.parentEntity(current_id);
    }
    return false;
}

fn wouldCreateHierarchyCycle(
    world: *const engine.scene.World,
    child_id: engine.scene.EntityId,
    parent_id: ?engine.scene.EntityId,
) bool {
    var current = parent_id;
    while (current) |current_id| {
        if (current_id == child_id) {
            return true;
        }
        current = world.parentEntity(current_id);
    }
    return false;
}

fn sliceContainsEntity(entity_ids: []const engine.scene.EntityId, entity_id: engine.scene.EntityId) bool {
    for (entity_ids) |candidate| {
        if (candidate == entity_id) {
            return true;
        }
    }
    return false;
}

fn beginHierarchyRename(state: *EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) void {
    const entity = world.getEntityConst(entity_id) orelse return;
    @memset(state.hierarchy_rename_buffer[0..], 0);
    const copy_len = @min(entity.name.len, state.hierarchy_rename_buffer.len - 1);
    @memcpy(state.hierarchy_rename_buffer[0..copy_len], entity.name[0..copy_len]);
    state.hierarchy_rename_entity = entity_id;
    state.hierarchy_rename_focus_pending = true;
}

fn beginSelectedHierarchyRename(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (layer_context.renderer.selectedEntities().len != 1) {
        return;
    }
    const selected = layer_context.renderer.selectedEntity() orelse return;
    if (!utils.isEntitySelectionLocked(state, selected) and
        !utils.isEntityFrozen(state, selected) and
        utils.shouldShowEntityInSceneTree(state, layer_context.world, selected))
    {
        beginHierarchyRename(state, layer_context.world, selected);
    }
}

fn cancelHierarchyRename(state: *EditorState) void {
    state.hierarchy_rename_entity = null;
    state.hierarchy_rename_focus_pending = false;
    @memset(state.hierarchy_rename_buffer[0..], 0);
}

fn syncHierarchyRenameState(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const rename_entity = state.hierarchy_rename_entity orelse return;
    if (layer_context.renderer.selectedEntities().len != 1 or
        layer_context.renderer.selectedEntity() != rename_entity or
        !layer_context.world.hasEntity(rename_entity) or
        utils.isEntityFrozen(state, rename_entity) or
        utils.isEntitySelectionLocked(state, rename_entity) or
        !utils.shouldShowEntityInSceneTree(state, layer_context.world, rename_entity))
    {
        cancelHierarchyRename(state);
    }
}

fn commitHierarchyRename(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) !void {
    const next_name = utils.zeroTerminatedSlice(state.hierarchy_rename_buffer[0..]);
    if (next_name.len == 0) {
        return;
    }
    if (try renameHierarchyEntityViaCommandQueue(state, layer_context, entity_id, next_name)) {
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}

fn renameHierarchyEntityViaCommandQueue(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    next_name: []const u8,
) !bool {
    const allocator = state.allocator orelse layer_context.world.allocator;
    if (layer_context.command_queue) |queue| {
        var before = try history.captureEntitySnapshot(state, layer_context.world, entity_id) orelse return false;
        var before_owned = true;
        defer if (before_owned) before.deinit(allocator);

        try queue.enqueueRenameEntity(entity_id, next_name);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        if (results.len == 0 or !results[0].changed) {
            return false;
        }

        try history.recordEntityMutation(state, layer_context, before, &.{entity_id});
        before_owned = false;
        try history.refreshWindowTitle(state, layer_context);
        return true;
    }

    if (try layer_context.world.renameEntity(entity_id, next_name)) {
        try history.captureSnapshot(state, layer_context);
        try history.refreshWindowTitle(state, layer_context);
        return true;
    }
    return false;
}

fn setEntityVisibleViaCommandQueue(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    visible: bool,
) !bool {
    const allocator = state.allocator orelse layer_context.world.allocator;
    if (layer_context.command_queue) |queue| {
        try queue.enqueueSetVisible(entity_id, visible);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        if (results.len == 0) {
            return false;
        }
        if (results[0].changed) {
            try history.captureSnapshot(state, layer_context);
        }
        return results[0].changed;
    }

    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    if (entity.visible == visible) {
        return false;
    }
    entity.visible = visible;
    try history.captureSnapshot(state, layer_context);
    return true;
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

fn drawSceneWindowContextMenu(state: *EditorState, layer_context: *engine.core.LayerContext) !bool {
    if (!gui.beginPopupContextWindow("scene_tree_window_context", false)) {
        return false;
    }
    defer gui.endPopup();

    if (gui.beginMenu(state.text(.create))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.folder), null, false, true)) {
            try createFolderEntity(state, layer_context);
            return true;
        }
        if (gui.menuItem(state.text(.empty), null, false, true)) {
            try history.spawnEmptyEntity(state, layer_context);
            return true;
        }
        if (gui.menuItem(state.text(.camera), null, false, true)) {
            try history.spawnCameraEntity(state, layer_context);
            return true;
        }
        if (gui.menuItem(state.text(.cube), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .cube);
            return true;
        }
        if (gui.menuItem(state.text(.sphere), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .sphere);
            return true;
        }
        if (gui.menuItem(state.text(.plane), null, false, true)) {
            try history.spawnPrimitive(state, layer_context, .plane);
            return true;
        }
        if (gui.menuItem(state.text(.point_light), null, false, true)) {
            try history.spawnPointLight(state, layer_context);
            return true;
        }
        if (gui.menuItem(state.text(.spot_light), null, false, true)) {
            try history.spawnSpotLightAt(state, layer_context, .{});
            return true;
        }
        if (gui.menuItem(state.text(.directional_light), null, false, true)) {
            try history.spawnDirectionalLightAt(state, layer_context, .{});
            return true;
        }
        if (gui.menuItem(state.text(.vfx_fountain), null, false, true)) {
            try history.spawnVfxEntity(state, layer_context, .fountain);
            return true;
        }
        if (gui.menuItem(state.text(.vfx_orbit), null, false, true)) {
            try history.spawnVfxEntity(state, layer_context, .orbit);
            return true;
        }
    }
    return false;
}

fn drawHierarchyNodeContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    is_selected: bool,
) !bool {
    const single_target = [_]engine.scene.EntityId{entity_id};
    const targets = if (is_selected and layer_context.renderer.selectedEntities().len > 1)
        layer_context.renderer.selectedEntities()
    else
        single_target[0..];
    const can_rename = targets.len == 1 and !utils.isEntityFrozen(state, entity_id) and !utils.isEntitySelectionLocked(state, entity_id);
    const all_frozen = allEntitiesFrozen(state, targets);
    const all_locked = allEntitiesLocked(state, targets);
    const has_parent = anyEntityHasParent(layer_context.world, targets);

    // 获取实体信息用于 Prefab 菜单
    const entity = layer_context.world.getEntity(entity_id) orelse return false;
    const is_prefab_instance = entity.prefab_instance_override != null;
    const is_prefab_child = entity.prefab_entity_id != null and !is_prefab_instance;

    if (gui.menuItem(state.text(.rename), null, false, can_rename)) {
        beginHierarchyRename(state, layer_context.world, entity_id);
        return false;
    }
    if (gui.menuItem(state.text(.duplicate), null, false, true)) {
        try history.duplicateEntities(state, layer_context, targets);
        return true;
    } else if (gui.menuItem(state.text(.delete), null, false, true)) {
        try history.deleteEntities(state, layer_context, targets);
        return true;
    }
    gui.separator();

    // Prefab 相关菜单
    if (is_prefab_instance or is_prefab_child) {
        if (gui.beginMenu(state.text(.prefab))) {
            defer gui.endMenu();

            if (is_prefab_instance) {
                // Prefab 实例根实体的选项
                if (gui.menuItem(state.text(.update_prefab_instance), null, false, true)) {
                    if (entity.prefab_instance_override) |override| {
                        _ = try layer_context.world.updateAllPrefabInstances(override.prefab_id);
                    }
                }
                if (gui.menuItem(state.text(.break_prefab_connection), null, false, true)) {
                    try breakPrefabConnection(state, layer_context, entity_id);
                    return true;
                }
                if (gui.menuItem(state.text(.select_prefab_asset), null, false, true)) {
                    if (entity.prefab_instance_override) |override| {
                        try state.setSelectedPrefabId(override.prefab_id);
                        state.prefab_browser_open = true;
                    }
                }
            } else if (is_prefab_child) {
                // Prefab 子实体的选项
                if (gui.menuItem(state.text(.add_override), null, false, true)) {
                    try addPrefabOverride(state, layer_context, entity_id);
                }
                if (gui.menuItem(state.text(.revert_override), null, false, entity.prefab_instance_override != null)) {
                    try layer_context.world.revertPrefabOverride(entity_id);
                }
            }
        }
        gui.separator();
    } else {
        // 普通实体可以转换为 Prefab 实例
        if (gui.beginMenu(state.text(.convert_to_prefab))) {
            defer gui.endMenu();

            // 显示可用的 Prefab 列表
            var it = layer_context.world.prefab_library.prefabs.iterator();
            while (it.next()) |entry| {
                const prefab_id = entry.key_ptr.*;
                const prefab = entry.value_ptr.*;

                if (gui.menuItem(prefab.name, null, false, true)) {
                    try convertToPrefabInstance(state, layer_context, entity_id, prefab_id);
                    return true;
                }
            }

            if (layer_context.world.prefab_library.prefabs.count() == 0) {
                _ = gui.menuItem(state.text(.no_prefabs_available), null, false, false);
            }
        }
        gui.separator();
    }

    if (gui.menuItem(state.text(if (all_frozen) .unfreeze else .freeze), null, false, true)) {
        try setFrozenForEntities(state, layer_context, targets, !all_frozen);
        return false;
    }
    if (gui.menuItem(state.text(if (all_locked) .unlock else .lock), null, false, true)) {
        try setLockedForEntities(state, layer_context, targets, !all_locked);
        return false;
    }
    if (gui.menuItem(state.text(.unparent), null, false, has_parent)) {
        try unparentEntities(state, layer_context, targets);
        return true;
    }
    return false;
}

/// 断开 Prefab 连接（将实例转换为普通实体）
pub fn breakPrefabConnection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) !void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;

    // 清除 Prefab 实例覆盖数据
    if (entity.prefab_instance_override) |*override| {
        override.deinit(state.allocator.?);
        entity.prefab_instance_override = null;
    }

    // 清除所有子实体的 prefab_entity_id
    try clearPrefabEntityIdsRecursive(layer_context.world, entity_id);

    try history.captureSnapshot(state, layer_context);
}

/// 递归清除 Prefab 实体 ID
fn clearPrefabEntityIdsRecursive(world: *engine.scene.World, entity_id: engine.scene.EntityId) !void {
    const entity = world.getEntity(entity_id) orelse return;

    // 清除当前实体的 prefab_entity_id
    entity.prefab_entity_id = null;

    // 递归处理子实体
    for (entity.children.items) |child_id| {
        try clearPrefabEntityIdsRecursive(world, child_id);
    }
}

/// 添加 Prefab 覆盖
pub fn addPrefabOverride(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
) !void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;
    const allocator = state.allocator.?;

    // 创建新的覆盖数据
    const override = prefab_mod.PrefabInstanceOverride{
        .prefab_id = try allocator.dupe(u8, entity.prefab_instance_override.?.prefab_id),
        .prefab_version = entity.prefab_instance_override.?.prefab_version,
        .root_prefab_entity_id = entity.prefab_entity_id orelse 0,
        .override_mask = .{
            .local_transform = true,
        },
        .local_transform_override = entity.local_transform,
    };

    // 释放旧的覆盖数据（如果存在）
    if (entity.prefab_instance_override) |*old_override| {
        old_override.deinit(allocator);
    }

    entity.prefab_instance_override = override;
    try history.captureSnapshot(state, layer_context);
}

/// 将实体转换为 Prefab 实例
fn convertToPrefabInstance(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    prefab_id: []const u8,
) !void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;
    const allocator = state.allocator.?;

    // 获取 Prefab
    const prefab = layer_context.world.getPrefab(prefab_id) orelse return;

    // 创建 Prefab 实例覆盖数据
    const override = prefab_mod.PrefabInstanceOverride{
        .prefab_id = try allocator.dupe(u8, prefab_id),
        .prefab_version = prefab.version,
        .root_prefab_entity_id = 0,
    };

    entity.prefab_instance_override = override;
    entity.prefab_entity_id = 0; // 根实体

    try history.captureSnapshot(state, layer_context);
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

fn setFrozenForEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    frozen: bool,
) !void {
    var changed = false;
    for (entity_ids) |entity_id| {
        changed = (try utils.setEntityFrozen(state, entity_id, frozen)) or changed;
    }
    if (!changed) {
        return;
    }
    if (frozen) {
        try utils.pruneFrozenSelection(state, layer_context);
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}

fn setLockedForEntities(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_ids: []const engine.scene.EntityId,
    locked: bool,
) !void {
    var changed = false;
    for (entity_ids) |entity_id| {
        changed = (try utils.setEntitySelectionLocked(state, entity_id, locked)) or changed;
    }
    if (!changed) {
        return;
    }
    if (locked) {
        try utils.pruneLockedSelection(state, layer_context);
        utils.syncInspectorNameBuffer(state, layer_context);
    }
}

fn allEntitiesFrozen(state: *const EditorState, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (!utils.isEntityFrozen(state, entity_id)) {
            return false;
        }
    }
    return entity_ids.len > 0;
}

fn allEntitiesLocked(state: *const EditorState, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (!utils.isEntitySelectionLocked(state, entity_id)) {
            return false;
        }
    }
    return entity_ids.len > 0;
}

fn anyEntityHasParent(world: *const engine.scene.World, entity_ids: []const engine.scene.EntityId) bool {
    for (entity_ids) |entity_id| {
        if (world.parentEntity(entity_id) != null) {
            return true;
        }
    }
    return false;
}

fn createFolderEntity(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selection_before = layer_context.renderer.selectedEntities();
    const transform = history.spawnTransform(state, layer_context);
    const entity_id = try history.createFolderEntityViaQueueOrWorld(layer_context, transform);
    try layer_context.renderer.replaceSelection(entity_id);
    utils.syncInspectorNameBuffer(state, layer_context);
    try history.recordCreatedEntities(state, layer_context, &.{entity_id}, selection_before);
}

test "collectDraggedEntityRoots keeps only selection roots during multi-drag" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{ .name = "Root" });
    const child = try world.createEntity(.{ .name = "Child", .parent = root });
    const sibling = try world.createEntity(.{ .name = "Sibling" });

    var roots = std.ArrayList(engine.scene.EntityId).empty;
    defer roots.deinit(std.testing.allocator);

    try collectDraggedEntityRoots(std.testing.allocator, &world, &.{ child, root, sibling }, child, null, &roots);
    try std.testing.expectEqualSlices(engine.scene.EntityId, &.{ root, sibling }, roots.items);
}

test "wouldCreateHierarchyCycle rejects descendant drop targets" {
    var world = engine.scene.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{ .name = "Root" });
    const child = try world.createEntity(.{ .name = "Child", .parent = root });
    const grandchild = try world.createEntity(.{ .name = "GrandChild", .parent = child });
    const sibling = try world.createEntity(.{ .name = "Sibling" });

    try std.testing.expect(wouldCreateHierarchyCycle(&world, root, grandchild));
    try std.testing.expect(wouldCreateHierarchyCycle(&world, child, grandchild));
    try std.testing.expect(!wouldCreateHierarchyCycle(&world, grandchild, root));
    try std.testing.expect(!wouldCreateHierarchyCycle(&world, sibling, grandchild));
}
