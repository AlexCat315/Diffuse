const std = @import("std");
const engine = @import("guava");
const handles = engine.assets.handles;
const gui = @import("../../gui.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const state_mod = @import("../../../core/state.zig");
const utils = @import("../../../common/utils.zig");
const history = @import("../../../actions/history.zig");
const manipulation = @import("../../../interaction/manipulation.zig");
const camera = @import("../../../interaction/camera.zig");
const content_browser = @import("../../../assets/browser.zig");
const vfx_runtime = @import("../../../runtime/vfx.zig");
const scene_hierarchy = @import("scene_hierarchy.zig");
const layout = @import("../../layout.zig");
const script_parameter_reflection = engine.script.parameter_reflection_mod;
const theme = @import("../../theme.zig");
const toggle_button = @import("../../components/toggle_button.zig");
const property_row = @import("../../components/property_row.zig");

/// Inspector 数据源：决定当前属性面板从哪个 World 读写数据
const InspectorSource = enum {
    /// 主世界（正常编辑状态）
    main_world,
    /// AI 暂存预览世界（显示 AI 修改效果，改动仅影响 preview）
    ai_preview,
};

/// 根据当前选中实体和 AI preview 状态，判断 Inspector 的数据源
fn resolveInspectorSource(state: *const EditorState, entity_id: engine.scene.EntityId) InspectorSource {
    for (state.ai_preview_entities.items) |preview_id| {
        if (preview_id == entity_id) return .ai_preview;
    }
    if (state.ai_preview_selected_entity) |sel| {
        if (sel == entity_id) return .ai_preview;
    }
    return .main_world;
}

/// 绘制 AI Preview 来源 badge（紫色胶囊）
fn drawAiPreviewBadge() void {
    gui.pushStyleColor(.text, theme.Palette.inspector.ai_preview_badge);
    gui.pushStyleColor(.button, theme.Palette.inspector.ai_preview_bg);
    gui.pushStyleColor(.button_hovered, theme.Palette.inspector.ai_preview_bg);
    gui.pushStyleColor(.button_active, theme.Palette.inspector.ai_preview_bg);
    gui.pushStyleVarFloat(.frame_rounding, theme.BorderRadius.badge);
    _ = gui.buttonEx("  ◆ AI Preview  ", 0.0, 0.0);
    gui.popStyleVar(1);
    gui.popStyleColor(4);
    if (gui.isItemHovered()) {
        gui.setTooltip("正在显示 AI 暂存预览数据。Apply 后写入主世界，Discard 还原。");
    }
}

const EditRowResult = struct {
    changed: bool = false,
    committed: bool = false,
};

const ActionRowResult = enum {
    none,
    first,
    second,
};

const TransformResetTarget = enum {
    translation,
    rotation,
    scale,
    all,
};

var transform_grid_mode: property_row.GridMode = .table;

const AxisStyle = struct {
    background: [4]f32,
    text: [4]f32,
};

const axis_x_style = AxisStyle{
    .background = theme.Spacing.inspector_axis_x_bg,
    .text = theme.Spacing.inspector_axis_text,
};
const axis_y_style = AxisStyle{
    .background = theme.Spacing.inspector_axis_y_bg,
    .text = theme.Spacing.inspector_axis_text,
};
const axis_z_style = AxisStyle{
    .background = theme.Spacing.inspector_axis_z_bg,
    .text = theme.Spacing.inspector_axis_text,
};

fn inspectorFilter(state: *const EditorState) []const u8 {
    return utils.zeroTerminatedSlice(state.inspector_filter_buffer[0..]);
}

fn inspectorSectionMatches(filter: []const u8, label: []const u8) bool {
    return filter.len == 0 or utils.containsAsciiInsensitive(label, filter);
}

fn beginInspectorSectionBody() void {
    layout.beginSectionBody();
}

fn endInspectorSectionBody() void {
    layout.endSectionBody();
}

fn beginInspectorPropertyGrid(id: []const u8) bool {
    return property_row.beginGrid(id, 0.38);
}

fn endInspectorPropertyGrid() void {
    property_row.endGrid();
}

fn drawInspectorTextRow(label: []const u8, value: []const u8) void {
    property_row.textRow(label, value);
}

fn drawInspectorInputTextRow(label: []const u8, widget_id: []const u8, hint: []const u8, buffer: []u8) bool {
    return property_row.inputTextRow(label, widget_id, hint, buffer);
}

fn drawInspectorCheckboxRow(label: []const u8, widget_id: []const u8, value: *bool) bool {
    return property_row.checkboxRow(label, widget_id, value);
}

fn drawInspectorFloatRow(
    label: []const u8,
    widget_id: []const u8,
    value: *f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) bool {
    return property_row.dragFloatRow(label, widget_id, value, speed, min_value, max_value);
}

fn drawInspectorFloat3Row(
    label: []const u8,
    widget_id: []const u8,
    value: *[3]f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) bool {
    return property_row.dragFloat3Row(label, widget_id, value, speed, min_value, max_value);
}

fn beginInspectorComboRow(label: []const u8, widget_id: []const u8, preview: []const u8) bool {
    return property_row.beginComboRow(label, widget_id, preview);
}

fn drawInspectorPropertyLabel(label: []const u8, label_color: ?[4]f32) void {
    property_row.drawLabel(label, label_color);
}

fn currentPropertyGridMode() property_row.GridMode {
    return property_row.currentGridMode();
}

pub fn drawInspectorWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .details, "details_panel");
    // 检查器面板需要足够宽度显示属性名 + 输入控件
    gui.setNextWindowSizeConstraints(.{ theme.Spacing.inspector_summary_min_width, theme.Spacing.inspector_summary_min_height }, .{ std.math.floatMax(f32), std.math.floatMax(f32) });
    _ = gui.beginWindow(title);
    defer gui.endWindow();

    const selected = layer_context.renderer.selectedEntity() orelse {
        gui.text(state.text(.no_entity_selected));
        return;
    };
    const selection_count = layer_context.renderer.selectedEntities().len;

    // ── 判断数据源：主世界 or AI preview world ──────────────────────────
    const inspector_source = resolveInspectorSource(state, selected);
    const active_world: *const engine.scene.World = switch (inspector_source) {
        .ai_preview => if (state.ai_preview_runtime) |*rt| &rt.world else &layer_context.world.*,
        .main_world => layer_context.world,
    };

    const entity = active_world.getEntityConst(selected) orelse
        layer_context.world.getEntityConst(selected) orelse {
        gui.text(state.text(.selection_is_stale));
        return;
    };
    // 对 main world 写操作仍需可变指针；preview 模式下 transform 写回走 collaboration 路径
    const entity_mut: ?*engine.scene.Entity = if (inspector_source == .main_world)
        layer_context.world.getEntity(selected)
    else
        null;
    const world_transform = active_world.worldTransformConst(selected) orelse entity.local_transform;

    // ── AI Preview badge ─────────────────────────────────────────────────
    if (inspector_source == .ai_preview) {
        drawAiPreviewBadge();
        gui.sameLine();
    }

    var selection_count_buffer: [32]u8 = undefined;
    const selection_count_text = try std.fmt.bufPrint(&selection_count_buffer, "{d}", .{selection_count});
    var entity_id_buffer: [32]u8 = undefined;
    const entity_id_text = try std.fmt.bufPrint(&entity_id_buffer, "{d}", .{selected});
    if (beginInspectorPropertyGrid("inspector_summary_grid")) {
        defer endInspectorPropertyGrid();
        drawInspectorTextRow(state.text(.selection_count), selection_count_text);
        drawInspectorTextRow(state.text(.entity_id), entity_id_text);
        // Entity name stays readable in both table and stacked fallback layouts.
        drawInspectorPropertyLabel(entity.name, theme.Spacing.inspector_entity_name_text_color);
        // 在 AI preview 模式下，不允许直接重命名（改动应走 AI command path）
        if (inspector_source == .main_world) {
            _ = gui.inputTextWithHint("##inspector_entity_name", state.text(.name), state.inspector_name_buffer[0..]);
            if (gui.isItemDeactivatedAfterEdit()) {
                const next_name = utils.zeroTerminatedSlice(state.inspector_name_buffer[0..]);
                if (next_name.len > 0) {
                    if (try renameEntityViaCommandQueue(state, layer_context, selected, next_name)) {
                        utils.syncInspectorNameBuffer(state, layer_context);
                        try history.refreshWindowTitle(state, layer_context);
                    }
                }
            }
        } else {
            gui.pushStyleColor(.text, theme.Spacing.inspector_ai_preview_text_color);
            gui.text(entity.name);
            gui.popStyleColor(1);
        }
        _ = drawInspectorInputTextRow(
            state.text(.search_components),
            "##inspector_filter",
            state.text(.search_components),
            state.inspector_filter_buffer[0..],
        );
    }
    layout.drawSidebarSectionDivider();
    const filter = inspectorFilter(state);

    if (inspectorSectionMatches(filter, state.text(.identity)) and gui.collapsingHeader(state.text(.identity), filter.len != 0)) {
        beginInspectorSectionBody();
        defer endInspectorSectionBody();
        gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
        if (beginInspectorPropertyGrid("identity_properties")) {
            defer endInspectorPropertyGrid();
            if (entity.parent) |parent_id| {
                if (layer_context.world.getEntityConst(parent_id)) |parent| {
                    drawInspectorTextRow(state.text(.parent), parent.name);
                } else {
                    drawInspectorTextRow(state.text(.parent), state.text(.root));
                }
            } else {
                drawInspectorTextRow(state.text(.parent), state.text(.root));
            }

            var editor_only = entity.editor_only;
            if (inspector_source == .main_world) {
                if (drawInspectorCheckboxRow(state.text(.editor_only), "##identity_editor_only", &editor_only)) {
                    if (entity_mut) |em| em.editor_only = editor_only;
                    try history.captureSnapshot(state, layer_context);
                }
            } else {
                drawInspectorTextRow(state.text(.editor_only), if (editor_only) "true (preview)" else "false (preview)");
            }
        }

        if (entity.parent != null) {
            gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
            defer gui.popStyleVar(1);
            if (gui.buttonEx(state.text(.unparent_selected), 0.0, 0.0)) {
                try scene_hierarchy.unparentSelection(state, layer_context);
                return;
            }
        }
    }

    // Prefab 组件显示
    if (entity.prefab_instance_override != null or entity.prefab_entity_id != null) {
        if (inspectorSectionMatches(filter, state.text(.prefab)) and gui.collapsingHeader(state.text(.prefab), filter.len != 0)) {
            beginInspectorSectionBody();
            defer endInspectorSectionBody();
            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);

            if (try drawPrefabHeaderContextMenu(state, layer_context, selected, entity)) {
                return;
            }

            if (beginInspectorPropertyGrid("prefab_properties")) {
                defer endInspectorPropertyGrid();

                if (entity.prefab_instance_override) |override| {
                    drawInspectorTextRow(state.text(.prefab_instance), override.prefab_id);

                    var version_buffer: [32]u8 = undefined;
                    const version_text = try std.fmt.bufPrint(&version_buffer, "{d}", .{override.prefab_version});
                    drawInspectorTextRow("Version", version_text);

                    // 显示覆盖信息
                    if (state.prefab_instance_show_overrides) {
                        const mask = override.override_mask;
                        var has_overrides = false;

                        if (mask.local_transform) {
                            gui.text("• Transform overridden");
                            has_overrides = true;
                        }
                        if (mask.name) {
                            gui.text("• Name overridden");
                            has_overrides = true;
                        }
                        if (mask.visible) {
                            gui.text("• Visibility overridden");
                            has_overrides = true;
                        }
                        if (mask.mesh) {
                            gui.text("• Mesh overridden");
                            has_overrides = true;
                        }
                        if (mask.material) {
                            gui.text("• Material overridden");
                            has_overrides = true;
                        }

                        if (!has_overrides) {
                            gui.text("No overrides");
                        }
                    }
                } else if (entity.prefab_entity_id) |prefab_entity_id| {
                    var id_buffer: [32]u8 = undefined;
                    const id_text = try std.fmt.bufPrint(&id_buffer, "{d}", .{prefab_entity_id});
                    drawInspectorTextRow("Prefab Entity ID", id_text);
                    gui.text("Part of Prefab instance");
                }
            }

            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);

            // Prefab 操作按钮
            gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
            defer gui.popStyleVar(1);

            if (entity.prefab_instance_override != null) {
                if (gui.buttonEx(state.text(.update_prefab_instance), theme.Spacing.inspector_prefab_button_width, 0.0)) {
                    if (entity.prefab_instance_override) |override| {
                        _ = try layer_context.world.updateAllPrefabInstances(override.prefab_id);
                    }
                }
                gui.sameLine();
                if (gui.buttonEx(state.text(.break_prefab_connection), theme.Spacing.inspector_prefab_button_width, 0.0)) {
                    try scene_hierarchy.breakPrefabConnection(state, layer_context, selected);
                    return;
                }
            } else if (entity.prefab_entity_id != null) {
                if (gui.buttonEx(state.text(.add_override), theme.Spacing.inspector_prefab_button_width, 0.0)) {
                    try scene_hierarchy.addPrefabOverride(state, layer_context, selected);
                }
            }
        }
    }

    if (inspectorSectionMatches(filter, state.text(.transform))) {
        const transform_open = gui.collapsingHeader(state.text(.transform), filter.len != 0);
        if (try drawTransformHeaderContextMenu(state, layer_context, selected, entity, world_transform)) {
            return;
        }
        if (transform_open) {
            beginInspectorSectionBody();
            defer endInspectorSectionBody();
            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
            gui.alignTextToFramePadding();
            gui.text(state.text(.coordinate_space));
            gui.sameLine();
            if (toggle_button.draw(.{
                .label = state.text(.local_space),
                .active = state.transform_space == .local,
                .width = theme.Spacing.inspector_toggle_width,
            })) {
                state.transform_space = .local;
            }
            gui.sameLine();
            if (toggle_button.draw(.{
                .label = state.text(.world_space),
                .active = state.transform_space == .world,
                .width = theme.Spacing.inspector_toggle_width,
            })) {
                state.transform_space = .world;
            }
            gui.dummy(0.0, theme.Spacing.inspector_section_gap);

            const transform_grid_available_width = gui.contentRegionAvail()[0];
            const transform_grid_use_table = transform_grid_available_width >= theme.Size.transform_grid_min_width and gui.beginTable("transform_grid", 4);
            transform_grid_mode = if (transform_grid_use_table) .table else .stacked;
            defer {
                if (transform_grid_use_table) {
                    gui.endTable();
                }
            }
            if (transform_grid_use_table) {
                gui.tableSetupColumn("##transform_label", false, theme.Size.transform_label_width);
                gui.tableSetupColumn("##transform_x", true, 1.0);
                gui.tableSetupColumn("##transform_y", true, 1.0);
                gui.tableSetupColumn("##transform_z", true, 1.0);

                gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1 + theme.Spacing.x2, theme.Spacing.x1 });
                defer gui.popStyleVar(1);

                var editable_translation = if (state.transform_space == .world) world_transform.translation else entity.local_transform.translation;
                const translation_result = try drawTransformTableRow("Pos", "translation", &editable_translation, theme.Size.transform_drag_speed, theme.Size.transform_drag_min, theme.Size.transform_drag_max);
                if (translation_result.changed) {
                    if (inspector_source == .ai_preview) {
                        // 写回 preview world：通过 collaboration 路径
                        var updated = world_transform;
                        updated.translation = editable_translation;
                        try applyPreviewTransformUpdate(state, layer_context, selected, updated);
                    } else if (state.transform_space == .world) {
                        var updated = world_transform;
                        updated.translation = editable_translation;
                        try applyWorldTransformUpdate(state, layer_context, selected, updated);
                    } else {
                        var updated = entity.local_transform;
                        updated.translation = editable_translation;
                        try applyLocalTransformUpdate(state, layer_context, selected, updated);
                    }
                    if (translation_result.committed and inspector_source == .main_world) {
                        try history.captureSnapshotWithLabel(state, layer_context, "Move Entity", "translation via inspector", .human);
                    }
                }

                var editable_rotation = if (state.transform_space == .world) engine.math.quat.toEuler(world_transform.rotation) else engine.math.quat.toEuler(entity.local_transform.rotation);
                const rotation_result = try drawTransformTableRow("Rot", "rotation", &editable_rotation, theme.Size.rotation_drag_speed, -std.math.tau, std.math.tau);
                if (rotation_result.changed) {
                    if (inspector_source == .ai_preview) {
                        var updated = world_transform;
                        updated.rotation = engine.math.quat.fromEuler(editable_rotation);
                        try applyPreviewTransformUpdate(state, layer_context, selected, updated);
                    } else if (state.transform_space == .world) {
                        var updated = world_transform;
                        updated.rotation = engine.math.quat.fromEuler(editable_rotation);
                        try applyWorldTransformUpdate(state, layer_context, selected, updated);
                    } else {
                        var updated = entity.local_transform;
                        updated.rotation = engine.math.quat.fromEuler(editable_rotation);
                        try applyLocalTransformUpdate(state, layer_context, selected, updated);
                    }
                    if (rotation_result.committed and inspector_source == .main_world) {
                        try history.captureSnapshotWithLabel(state, layer_context, "Rotate Entity", "rotation via inspector", .human);
                    }
                }

                var editable_scale = if (state.transform_space == .world) world_transform.scale else entity.local_transform.scale;
                const scale_result = try drawTransformTableRow("Scl", "scale", &editable_scale, theme.Size.scale_drag_speed, theme.Size.scale_drag_min, theme.Size.scale_drag_max);
                if (scale_result.changed) {
                    editable_scale = .{
                        utils.clampScale(editable_scale[0]),
                        utils.clampScale(editable_scale[1]),
                        utils.clampScale(editable_scale[2]),
                    };
                    if (inspector_source == .ai_preview) {
                        var updated = world_transform;
                        updated.scale = editable_scale;
                        try applyPreviewTransformUpdate(state, layer_context, selected, updated);
                    } else if (state.transform_space == .world) {
                        var updated = world_transform;
                        updated.scale = editable_scale;
                        try applyWorldTransformUpdate(state, layer_context, selected, updated);
                    } else {
                        var updated = entity.local_transform;
                        updated.scale = editable_scale;
                        try applyLocalTransformUpdate(state, layer_context, selected, updated);
                    }
                    if (scale_result.committed and inspector_source == .main_world) {
                        try history.captureSnapshotWithLabel(state, layer_context, "Scale Entity", "scale via inspector", .human);
                    }
                }
            }
            transform_grid_mode = .table;
        }
    }

    if (inspectorSectionMatches(filter, state.text(.components)) and gui.collapsingHeader(state.text(.components), filter.len != 0)) {
        beginInspectorSectionBody();
        defer endInspectorSectionBody();
        gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
        if (entity_mut) |em| {
            if (try drawAddComponentControls(state, layer_context, selected, em)) {
                return;
            }
        }
    }

    if (entity.mesh) |mesh_component| {
        if (inspectorSectionMatches(filter, state.text(.mesh))) {
            const mesh_open = gui.collapsingHeader(state.text(.mesh), filter.len != 0);
            if (try drawMeshHeaderContextMenu(state, layer_context, selected, mesh_component)) {
                return;
            }
            if (mesh_open) {
                beginInspectorSectionBody();
                defer endInspectorSectionBody();
                gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
                if (mesh_component.handle) |mesh_handle| {
                    if (layer_context.world.assets().mesh(mesh_handle)) |mesh_resource| {
                        if (beginInspectorPropertyGrid("mesh_properties")) {
                            defer endInspectorPropertyGrid();
                            drawInspectorTextRow(state.text(.primitive), utils.primitiveLabel(state, mesh_component.primitive));
                            drawInspectorTextRow(state.text(.resource), mesh_resource.name);

                            var vertices_buffer: [32]u8 = undefined;
                            const vertices_text = try std.fmt.bufPrint(&vertices_buffer, "{d}", .{mesh_resource.vertices.len});
                            drawInspectorTextRow(state.text(.vertices), vertices_text);

                            var indices_buffer: [32]u8 = undefined;
                            const indices_text = try std.fmt.bufPrint(&indices_buffer, "{d}", .{mesh_resource.indices.len});
                            drawInspectorTextRow(state.text(.indices), indices_text);

                            var triangles_buffer: [32]u8 = undefined;
                            const triangles_text = try std.fmt.bufPrint(&triangles_buffer, "{d}", .{mesh_resource.indices.len / 3});
                            drawInspectorTextRow(state.text(.triangles), triangles_text);
                        }
                    } else {
                        gui.text(state.text(.mesh_component_has_no_bound_resource));
                    }
                } else {
                    gui.text(state.text(.mesh_component_has_no_bound_resource));
                }
            }
        }
    }

    // 材质 section：读路径用 entity（const），写路径用 entity_mut（可写）
    const entity_material_write = entity_mut;
    if (entity.material) |*material_component| {
        if (inspectorSectionMatches(filter, state.text(.material))) {
            const material_open = gui.collapsingHeader(state.text(.material), filter.len != 0);
            if (try drawMaterialHeaderContextMenu(state, layer_context, selected, material_component.*)) {
                return;
            }
            if (material_open) {
                beginInspectorSectionBody();
                defer endInspectorSectionBody();
                gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
                var effective_shading = material_component.shading;
                var effective_color = material_component.base_color_factor;
                var material_usage_count: usize = 0;
                var material_texture_handle: ?engine.assets.TextureHandle = null;
                var resource_text: []const u8 = state.text(.embedded);
                var scope_label: []const u8 = state.text(.scope);
                var scope_value: []const u8 = state.text(.instance);
                var texture_text: []const u8 = state.text(.none);
                var shared_by_buffer: [32]u8 = undefined;
                if (material_component.handle) |material_handle| {
                    material_usage_count = materialUsageCount(state, layer_context.world, material_handle);
                    if (layer_context.world.assets().material(material_handle)) |material_resource| {
                        effective_shading = material_resource.shading;
                        effective_color = material_resource.base_color_factor;
                        material_texture_handle = material_resource.base_color_texture;
                        resource_text = material_resource.name;
                        if (material_usage_count > 1) {
                            scope_label = state.text(.shared_by);
                            scope_value = try std.fmt.bufPrint(&shared_by_buffer, "{d}", .{material_usage_count});
                        } else {
                            scope_label = state.text(.scope);
                            scope_value = state.text(.instance);
                        }
                        if (material_texture_handle) |texture_handle| {
                            if (layer_context.world.assets().texture(texture_handle)) |texture_resource| {
                                texture_text = texture_resource.name;
                            }
                        }
                    }
                }

                if (material_component.handle == null or material_usage_count > 1) {
                    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
                    defer gui.popStyleVar(1);
                    if (gui.buttonEx(state.text(.make_material_instance), 0.0, 0.0)) {
                        if (entity_material_write) |em| {
                            _ = try ensureEditableMaterialResource(state, layer_context, em);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                    if (material_component.handle != null and material_usage_count > 1) {
                        gui.sameLine();
                        gui.textWrapped(state.text(.editing_now_will_affect_all_users_until_instanced));
                    }
                }

                if (content_browser.selectedAssetCanUseAsTexture(state)) {
                    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
                    defer gui.popStyleVar(1);
                    if (gui.buttonEx(state.text(.assign_selected_texture), 0.0, 0.0)) {
                        if (entity_material_write) |em| {
                            if (try assignSelectedTextureToMaterial(state, layer_context, em)) {
                                try history.captureSnapshot(state, layer_context);
                            }
                        }
                    }
                    gui.sameLine();
                } else if (material_texture_handle != null) {
                    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
                    defer gui.popStyleVar(1);
                    if (gui.buttonEx(state.text(.clear_texture), 0.0, 0.0)) {
                        if (entity_material_write) |em| {
                            if (try ensureEditableMaterialResource(state, layer_context, em)) |material_resource| {
                                material_resource.base_color_texture = null;
                                if (em.material) |*mc| mc.handle = materialHandleForEntity(state, em);
                                try history.captureSnapshot(state, layer_context);
                            }
                        }
                    }
                    gui.sameLine();
                } else {
                    gui.text("");
                    gui.sameLine();
                }
                gui.text(state.text(.texture));

                if (beginInspectorPropertyGrid("material_properties")) {
                    defer endInspectorPropertyGrid();
                    drawInspectorTextRow(state.text(.resource), resource_text);
                    drawInspectorTextRow(scope_label, scope_value);
                    if (try drawMaterialTextureSlotRow(state, layer_context, entity_material_write, texture_text)) {
                        try history.captureSnapshot(state, layer_context);
                    }

                    if (beginInspectorComboRow(state.text(.shading), "##material_shading", utils.shadingLabel(state, effective_shading))) {
                        defer gui.endCombo();
                        if (gui.menuItem(state.text(.unlit), null, effective_shading == .unlit, true)) {
                            effective_shading = .unlit;
                        }
                        if (gui.menuItem(state.text(.lambert), null, effective_shading == .lambert, true)) {
                            effective_shading = .lambert;
                        }
                        if (gui.menuItem(state.text(.pbr), null, effective_shading == .pbr_metallic_roughness, true)) {
                            effective_shading = .pbr_metallic_roughness;
                        }
                    }

                    var base_color_rgb: [3]f32 = .{ effective_color[0], effective_color[1], effective_color[2] };
                    if (drawInspectorFloat3Row(state.text(.base_color), "##material_base_color", &base_color_rgb, 0.01, 0.0, 1.0)) {
                        effective_color[0] = std.math.clamp(base_color_rgb[0], 0.0, 1.0);
                        effective_color[1] = std.math.clamp(base_color_rgb[1], 0.0, 1.0);
                        effective_color[2] = std.math.clamp(base_color_rgb[2], 0.0, 1.0);
                        if (entity_material_write) |em| {
                            if (em.material) |*mc| mc.base_color_factor = effective_color;
                            if (try ensureEditableMaterialResource(state, layer_context, em)) |material_resource| {
                                material_resource.base_color_factor = effective_color;
                                if (em.material) |*mc| mc.handle = materialHandleForEntity(state, em);
                            }
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var alpha = effective_color[3];
                    if (drawInspectorFloatRow(state.text(.opacity), "##material_opacity", &alpha, 0.01, 0.0, 1.0)) {
                        effective_color[3] = std.math.clamp(alpha, 0.0, 1.0);
                        if (entity_material_write) |em| {
                            if (em.material) |*mc| mc.base_color_factor = effective_color;
                            if (try ensureEditableMaterialResource(state, layer_context, em)) |material_resource| {
                                material_resource.base_color_factor = effective_color;
                                if (em.material) |*mc| mc.handle = materialHandleForEntity(state, em);
                            }
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                }

                if (effective_shading != material_component.shading) {
                    if (entity_material_write) |em| {
                        if (try ensureEditableMaterialResource(state, layer_context, em)) |material_resource| {
                            material_resource.shading = effective_shading;
                            if (em.material) |*mc| {
                                mc.shading = effective_shading;
                                mc.handle = materialHandleForEntity(state, em);
                            }
                        }
                    }
                    try history.captureSnapshot(state, layer_context);
                }
            }
        }
    }

    if (entity.camera) |*camera_component| {
        if (inspectorSectionMatches(filter, state.text(.camera))) {
            const camera_open = gui.collapsingHeader(state.text(.camera), filter.len != 0);
            if (try drawCameraHeaderContextMenu(state, layer_context, selected, camera_component.*)) {
                return;
            }
            if (camera_open) {
                beginInspectorSectionBody();
                defer endInspectorSectionBody();
                gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
                if (camera_component.is_primary) {
                    gui.text(state.text(.primary_scene_camera));
                } else {
                    gui.pushStyleVarVec2(.item_spacing, .{ theme.Spacing.x1, theme.Spacing.x1 });
                    defer gui.popStyleVar(1);
                    if (gui.buttonEx(state.text(.make_primary_camera), 0.0, 0.0)) {
                        _ = layer_context.world.setPrimaryCamera(selected);
                        state.scene_camera = selected;
                        try history.captureSnapshot(state, layer_context);
                    }
                    gui.sameLine();
                }
                if (gui.buttonEx("Use This Camera", 0.0, 0.0)) {
                    _ = camera.lookThroughCamera(state, layer_context, selected);
                }

                switch (drawActionRow2(state.text(.use_perspective), state.text(.use_orthographic), theme.Spacing.inspector_projection_toggle_width)) {
                    .first => {
                        if (entity_mut) |em| {
                            if (em.camera) |*cc| cc.projection = .{ .perspective = .{} };
                        }
                        try history.captureSnapshot(state, layer_context);
                    },
                    .second => {
                        if (entity_mut) |em| {
                            if (em.camera) |*cc| cc.projection = .{ .orthographic = .{} };
                        }
                        try history.captureSnapshot(state, layer_context);
                    },
                    .none => {},
                }

                if (beginInspectorPropertyGrid("camera_properties")) {
                    defer endInspectorPropertyGrid();

                    switch (camera_component.projection) {
                        .perspective => |projection| {
                            var edited = projection;
                            var fov_degrees = engine.math.angle.radiansToDegrees(edited.fov_y_radians);
                            if (drawInspectorFloatRow(state.text(.fov_y), "##camera_fov_y", &fov_degrees, theme.Spacing.inspector_camera_fov_speed, theme.Spacing.inspector_camera_fov_min, theme.Spacing.inspector_camera_fov_max)) {
                                edited.fov_y_radians = engine.math.angle.degreesToRadians(fov_degrees);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .perspective = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }

                            if (drawInspectorFloatRow(state.text(.near_clip), "##camera_perspective_near_clip", &edited.near_clip, theme.Spacing.inspector_camera_near_speed, theme.Spacing.inspector_camera_near_min, theme.Spacing.inspector_camera_near_max)) {
                                edited.near_clip = std.math.clamp(edited.near_clip, theme.Spacing.inspector_camera_near_min, theme.Spacing.inspector_camera_near_max);
                                edited.far_clip = @max(edited.far_clip, edited.near_clip + 0.01);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .perspective = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }

                            if (drawInspectorFloatRow(state.text(.far_clip), "##camera_perspective_far_clip", &edited.far_clip, theme.Spacing.inspector_camera_far_speed, theme.Spacing.inspector_camera_far_min, theme.Spacing.inspector_camera_far_max)) {
                                edited.near_clip = @min(edited.near_clip, edited.far_clip - 0.01);
                                edited.far_clip = std.math.clamp(edited.far_clip, edited.near_clip + 0.01, theme.Spacing.inspector_camera_far_max);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .perspective = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }
                        },
                        .orthographic => |projection| {
                            var edited = projection;
                            if (drawInspectorFloatRow(state.text(.size), "##camera_orthographic_size", &edited.size, theme.Spacing.inspector_camera_ortho_speed, theme.Spacing.inspector_camera_ortho_min, theme.Spacing.inspector_camera_ortho_max)) {
                                edited.size = std.math.clamp(edited.size, theme.Spacing.inspector_camera_ortho_min, theme.Spacing.inspector_camera_ortho_max);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .orthographic = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }

                            if (drawInspectorFloatRow(state.text(.near_clip), "##camera_orthographic_near_clip", &edited.near_clip, theme.Spacing.inspector_camera_ortho_clip_speed, theme.Spacing.inspector_camera_ortho_clip_min, theme.Spacing.inspector_camera_ortho_clip_max)) {
                                edited.near_clip = std.math.clamp(edited.near_clip, theme.Spacing.inspector_camera_ortho_clip_min, edited.far_clip - 0.01);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .orthographic = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }

                            if (drawInspectorFloatRow(state.text(.far_clip), "##camera_orthographic_far_clip", &edited.far_clip, theme.Spacing.inspector_camera_ortho_clip_speed, theme.Spacing.inspector_camera_ortho_clip_min, theme.Spacing.inspector_camera_ortho_clip_max)) {
                                edited.far_clip = std.math.clamp(edited.far_clip, edited.near_clip + 0.01, theme.Spacing.inspector_camera_ortho_clip_max);
                                if (entity_mut) |em| {
                                    if (em.camera) |*cc| cc.projection = .{ .orthographic = edited };
                                }
                                if (gui.isItemDeactivatedAfterEdit()) {
                                    try history.captureSnapshot(state, layer_context);
                                }
                            }
                        },
                    }
                }
            }
        }
    }

    if (entity.light) |*light| {
        if (inspectorSectionMatches(filter, state.text(.light))) {
            const light_open = gui.collapsingHeader(state.text(.light), filter.len != 0);
            if (try drawLightHeaderContextMenu(state, layer_context, selected, light.*)) {
                return;
            }
            if (light_open) {
                beginInspectorSectionBody();
                defer endInspectorSectionBody();
                gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
                if (beginInspectorPropertyGrid("light_properties")) {
                    defer endInspectorPropertyGrid();
                    const current_kind_label = switch (light.kind) {
                        .directional => state.text(.directional),
                        .point => state.text(.point),
                        .spot => state.text(.spot),
                    };
                    if (beginInspectorComboRow(state.text(.type), "##light_type", current_kind_label)) {
                        defer gui.endCombo();
                        if (gui.menuItem(state.text(.directional), null, light.kind == .directional, true)) {
                            if (entity_mut) |em| {
                                if (em.light) |*l| l.kind = .directional;
                            }
                            try history.captureSnapshot(state, layer_context);
                        }
                        if (gui.menuItem(state.text(.point), null, light.kind == .point, true)) {
                            if (entity_mut) |em| {
                                if (em.light) |*l| l.kind = .point;
                            }
                            try history.captureSnapshot(state, layer_context);
                        }
                        if (gui.menuItem(state.text(.spot), null, light.kind == .spot, true)) {
                            if (entity_mut) |em| {
                                if (em.light) |*l| l.kind = .spot;
                            }
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var light_color = light.color;
                    if (drawInspectorFloat3Row(state.text(.color), "##light_color", &light_color, 0.01, 0.0, 10.0)) {
                        if (entity_mut) |em| {
                            if (em.light) |*l| l.color = light_color;
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var intensity = light.intensity;
                    if (drawInspectorFloatRow(state.text(.intensity), "##light_intensity", &intensity, theme.Spacing.inspector_light_intensity_speed, theme.Spacing.inspector_light_intensity_min, theme.Spacing.inspector_light_intensity_max)) {
                        if (entity_mut) |em| {
                            if (em.light) |*l| l.intensity = intensity;
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    if (light.kind != .directional) {
                        var range = light.range;
                        if (drawInspectorFloatRow(state.text(.range), "##light_range", &range, theme.Spacing.inspector_light_range_speed, theme.Spacing.inspector_light_range_min, theme.Spacing.inspector_light_range_max)) {
                            if (entity_mut) |em| {
                                if (em.light) |*l| l.range = range;
                            }
                            if (gui.isItemDeactivatedAfterEdit()) {
                                try history.captureSnapshot(state, layer_context);
                            }
                        }
                    }
                }
            }
        }
    }

    if (entity.vfx) |*vfx_component| {
        if (inspectorSectionMatches(filter, state.text(.vfx))) {
            const vfx_open = gui.collapsingHeader(state.text(.vfx), filter.len != 0);
            if (try drawVfxHeaderContextMenu(state, layer_context, selected, vfx_component.*)) {
                return;
            }
            if (vfx_open) {
                beginInspectorSectionBody();
                defer endInspectorSectionBody();
                gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
                const vfx_write_opt: ?*engine.scene.Vfx = if (entity_mut) |em| (if (em.vfx) |*vfx| vfx else null) else null;
                if (beginInspectorPropertyGrid("vfx_properties")) {
                    defer endInspectorPropertyGrid();

                    const current_kind_label = switch (vfx_component.kind) {
                        .fountain => state.text(.fountain),
                        .orbit => state.text(.orbit),
                    };
                    if (beginInspectorComboRow(state.text(.type), "##vfx_type", current_kind_label)) {
                        defer gui.endCombo();
                        if (gui.menuItem(state.text(.fountain), null, vfx_component.kind == .fountain, true)) {
                            if (vfx_write_opt) |vw| vw.* = engine.scene.Vfx{
                                .kind = .fountain,
                                .looping = vfx_component.looping,
                                .emission_rate = vfx_component.emission_rate,
                                .particle_lifetime = vfx_component.particle_lifetime,
                                .speed = vfx_component.speed,
                                .max_particles = vfx_component.max_particles,
                                .radius = vfx_component.radius,
                                .spread = vfx_component.spread,
                                .size = vfx_component.size,
                                .color = vfx_component.color,
                            };
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                        if (gui.menuItem(state.text(.orbit), null, vfx_component.kind == .orbit, true)) {
                            if (vfx_write_opt) |vw| vw.* = engine.scene.Vfx{
                                .kind = .orbit,
                                .looping = vfx_component.looping,
                                .emission_rate = vfx_component.emission_rate,
                                .particle_lifetime = vfx_component.particle_lifetime,
                                .speed = vfx_component.speed,
                                .max_particles = vfx_component.max_particles,
                                .radius = vfx_component.radius,
                                .spread = vfx_component.spread,
                                .size = vfx_component.size,
                                .color = vfx_component.color,
                            };
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var looping = vfx_component.looping;
                    if (drawInspectorCheckboxRow(state.text(.looping), "##vfx_looping", &looping)) {
                        if (vfx_write_opt) |vw| vw.looping = looping;
                        vfx_runtime.clearEmitterRuntime(layer_context, selected);
                        try history.captureSnapshot(state, layer_context);
                    }

                    var emission_rate = vfx_component.emission_rate;
                    if (drawInspectorFloatRow(state.text(.emission_rate), "##vfx_emission_rate", &emission_rate, 0.25, 0.0, 200.0)) {
                        if (vfx_write_opt) |vw| vw.emission_rate = std.math.clamp(emission_rate, 0.0, 200.0);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var lifetime = vfx_component.particle_lifetime;
                    if (drawInspectorFloatRow(state.text(.particle_lifetime), "##vfx_particle_lifetime", &lifetime, 0.01, 0.1, 10.0)) {
                        if (vfx_write_opt) |vw| vw.particle_lifetime = std.math.clamp(lifetime, 0.1, 10.0);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var speed = vfx_component.speed;
                    if (drawInspectorFloatRow(state.text(.speed), "##vfx_speed", &speed, 0.05, 0.05, 20.0)) {
                        if (vfx_write_opt) |vw| vw.speed = std.math.clamp(speed, 0.05, 20.0);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var max_particles = @as(f32, @floatFromInt(vfx_component.max_particles));
                    if (drawInspectorFloatRow(state.text(.max_particles), "##vfx_max_particles", &max_particles, 1.0, 1.0, 128.0)) {
                        if (vfx_write_opt) |vw| vw.max_particles = @intFromFloat(std.math.clamp(@round(max_particles), 1.0, 128.0));
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var radius = vfx_component.radius;
                    if (drawInspectorFloatRow(state.text(.radius), "##vfx_radius", &radius, 0.01, 0.01, 8.0)) {
                        if (vfx_write_opt) |vw| vw.radius = std.math.clamp(radius, 0.01, 8.0);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var spread = vfx_component.spread;
                    if (drawInspectorFloatRow(state.text(.spread), "##vfx_spread", &spread, 0.01, 0.0, 2.5)) {
                        if (vfx_write_opt) |vw| vw.spread = std.math.clamp(spread, 0.0, 2.5);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var size = vfx_component.size;
                    if (drawInspectorFloatRow(state.text(.size), "##vfx_size", &size, 0.005, 0.02, 1.0)) {
                        if (vfx_write_opt) |vw| vw.size = std.math.clamp(size, 0.02, 1.0);
                        if (gui.isItemDeactivatedAfterEdit()) {
                            vfx_runtime.clearEmitterRuntime(layer_context, selected);
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var color = vfx_component.color;
                    if (drawInspectorFloat3Row(state.text(.color), "##vfx_color", &color, 0.01, 0.0, 1.0)) {
                        const clamped_color = [3]f32{
                            std.math.clamp(color[0], 0.0, 1.0),
                            std.math.clamp(color[1], 0.0, 1.0),
                            std.math.clamp(color[2], 0.0, 1.0),
                        };
                        if (vfx_write_opt) |vw| vw.color = clamped_color;
                        if (entity_mut) |em| {
                            if (em.material) |*mat| {
                                mat.shading = .unlit;
                                mat.base_color_factor = .{ clamped_color[0], clamped_color[1], clamped_color[2], 1.0 };
                            }
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                }
            }
        }
    }

    if (entity.script) |*script_component| {
        if (inspectorSectionMatches(filter, "Script") and gui.collapsingHeader("Script", filter.len != 0)) {
            beginInspectorSectionBody();
            defer endInspectorSectionBody();
            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);

            if (beginInspectorPropertyGrid("script_properties")) {
                defer endInspectorPropertyGrid();

                // ── Script selector combo ──
                const lib = layer_context.world.assets();
                var current_label: []const u8 = "(none)";
                if (script_component.script_handle) |handle| {
                    if (lib.scriptAssetId(handle)) |aid| {
                        current_label = aid;
                    } else if (lib.script(handle)) |res| {
                        if (res.source_path.len > 0) {
                            current_label = res.source_path;
                        } else if (res.description.len > 0) {
                            current_label = res.description;
                        } else {
                            current_label = "(script)";
                        }
                    }
                }

                if (beginInspectorComboRow("Script", "##script_select", current_label)) {
                    defer gui.endCombo();

                    // "(none)" option
                    if (gui.menuItem("(none)", null, script_component.script_handle == null, true)) {
                        if (entity_mut) |em| {
                            if (em.script) |*sc| {
                                sc.script_handle = null;
                                sc.instance_id = null;
                            }
                        }
                        if (layer_context.script_runtime) |runtime| {
                            runtime.reconcileWorld(layer_context.world);
                        }
                        try history.captureSnapshot(state, layer_context);
                    }

                    // List all registered scripts
                    for (lib.scripts.items, 0..) |script_res, idx| {
                        const h = handles.scriptHandle(idx);
                        var label_buf: [128]u8 = undefined;
                        const label: []const u8 = blk: {
                            if (lib.scriptAssetId(h)) |aid| {
                                break :blk aid;
                            }
                            if (script_res.source_path.len > 0) {
                                // Show just the filename portion
                                const name = if (std.mem.lastIndexOfScalar(u8, script_res.source_path, '/')) |i|
                                    script_res.source_path[i + 1 ..]
                                else
                                    script_res.source_path;
                                break :blk name;
                            }
                            if (script_res.description.len > 0) {
                                break :blk script_res.description;
                            }
                            break :blk std.fmt.bufPrint(&label_buf, "script_{d}", .{idx}) catch "(script)";
                        };
                        const is_selected = if (script_component.script_handle) |cur| cur == h else false;
                        if (gui.menuItem(label, null, is_selected, true)) {
                            if (entity_mut) |em| {
                                if (em.script) |*sc| {
                                    sc.script_handle = h;
                                    sc.language = .zig;
                                    sc.instance_id = null;
                                }
                            }
                            if (layer_context.script_runtime) |runtime| {
                                runtime.reconcileWorld(layer_context.world);
                            }
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                }

                drawInspectorTextRow("Language", scriptLanguageLabel(script_component.language));

                var enabled = script_component.enabled;
                if (drawInspectorCheckboxRow("Enabled", "##script_enabled", &enabled)) {
                    if (entity_mut) |em| {
                        if (em.script) |*sc| sc.enabled = enabled;
                    }
                    if (layer_context.script_runtime) |runtime| {
                        runtime.reconcileWorld(layer_context.world);
                    }
                }
            }

            // Browse button — load a .zig script from disk
            if (gui.button("Browse Script...")) {
                if (loadScriptFromFilePicker(layer_context)) |handle| {
                    if (entity_mut) |em| {
                        if (em.script) |*sc| {
                            sc.script_handle = handle;
                            sc.language = .zig;
                            sc.instance_id = null;
                        }
                    }
                    if (layer_context.script_runtime) |runtime| {
                        runtime.reconcileWorld(layer_context.world);
                    }
                    history.captureSnapshot(state, layer_context) catch {};
                }
            }

            if (script_component.script_handle) |_| {
                gui.sameLine();
                if (gui.button("Detach")) {
                    if (entity_mut) |em| {
                        if (em.script) |*sc| {
                            sc.script_handle = null;
                            sc.instance_id = null;
                        }
                    }
                    if (layer_context.script_runtime) |runtime| {
                        runtime.reconcileWorld(layer_context.world);
                    }
                    history.captureSnapshot(state, layer_context) catch {};
                }
            }

            if (script_component.script_handle) |handle| {
                if (layer_context.world.assets().script(handle)) |resource| {
                    if (resource.source_path.len != 0) {
                        gui.textColored(.{ 0.5, 0.8, 0.5, 1.0 }, resource.source_path);
                    }
                    if (resource.description.len != 0 and resource.description.len != resource.source_path.len) {
                        gui.textWrapped(resource.description);
                    }
                    if (resource.user_data.len != 0) {
                        if (entity_mut) |em| {
                            if (em.script) |*sc| {
                                try drawReflectedScriptParameters(state, layer_context, selected, sc, resource.user_data);
                            }
                        }
                    }
                } else {
                    gui.textColored(.{ 1.0, 0.4, 0.4, 1.0 }, "Script handle is stale.");
                }
            }
        }
    }

    if (entity.audio_source) |*audio_src| {
        if (inspectorSectionMatches(filter, state.text(.audio_source)) and gui.collapsingHeader(state.text(.audio_source), filter.len != 0)) {
            beginInspectorSectionBody();
            defer endInspectorSectionBody();
            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);

            if (beginInspectorPropertyGrid("audio_source_properties")) {
                defer endInspectorPropertyGrid();

                var volume = audio_src.volume;
                if (drawInspectorFloatRow(state.text(.audio_volume), "##audio_volume", &volume, theme.Spacing.inspector_audio_volume_speed, theme.Spacing.inspector_audio_volume_min, theme.Spacing.inspector_audio_volume_max)) {
                    if (entity_mut) |em| {
                        if (em.audio_source) |*as| as.volume = volume;
                    }
                    if (gui.isItemDeactivatedAfterEdit()) {
                        try history.captureSnapshot(state, layer_context);
                    }
                }

                const audio_buses = [_]engine.scene.AudioBus{ .master, .music, .sfx };
                if (beginInspectorComboRow(state.text(.audio_bus), "##audio_bus", utils.audioBusLabel(state, audio_src.bus))) {
                    defer gui.endCombo();
                    for (audio_buses) |candidate_bus| {
                        const is_selected = audio_src.bus == candidate_bus;
                        if (gui.selectable(utils.audioBusLabel(state, candidate_bus), is_selected, false, 0.0, 0.0)) {
                            if (entity_mut) |em| {
                                if (em.audio_source) |*as| as.bus = candidate_bus;
                            }
                            try history.captureSnapshot(state, layer_context);
                        }
                        if (is_selected) {
                            gui.setItemDefaultFocus();
                        }
                    }
                }

                var spatial = audio_src.spatial;
                if (drawInspectorCheckboxRow(state.text(.audio_spatial), "##audio_spatial", &spatial)) {
                    if (entity_mut) |em| {
                        if (em.audio_source) |*as| as.spatial = spatial;
                    }
                    try history.captureSnapshot(state, layer_context);
                }

                var looping = audio_src.looping;
                if (drawInspectorCheckboxRow(state.text(.audio_looping), "##audio_looping", &looping)) {
                    if (entity_mut) |em| {
                        if (em.audio_source) |*as| as.looping = looping;
                    }
                    try history.captureSnapshot(state, layer_context);
                }

                var play_on_awake = audio_src.play_on_awake;
                if (drawInspectorCheckboxRow(state.text(.audio_play_on_awake), "##audio_play_on_awake", &play_on_awake)) {
                    if (entity_mut) |em| {
                        if (em.audio_source) |*as| as.play_on_awake = play_on_awake;
                    }
                    try history.captureSnapshot(state, layer_context);
                }

                if (audio_src.spatial) {
                    var min_dist = audio_src.min_distance;
                    if (drawInspectorFloatRow(state.text(.audio_min_distance), "##audio_min_dist", &min_dist, theme.Spacing.inspector_audio_min_dist_speed, theme.Spacing.inspector_audio_min_dist_min, theme.Spacing.inspector_audio_min_dist_max)) {
                        if (entity_mut) |em| {
                            if (em.audio_source) |*as| as.min_distance = min_dist;
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var max_dist = audio_src.max_distance;
                    if (drawInspectorFloatRow(state.text(.audio_max_distance), "##audio_max_dist", &max_dist, theme.Spacing.inspector_audio_max_dist_speed, theme.Spacing.inspector_audio_max_dist_min, theme.Spacing.inspector_audio_max_dist_max)) {
                        if (entity_mut) |em| {
                            if (em.audio_source) |*as| as.max_distance = max_dist;
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }

                    var doppler = audio_src.doppler_factor;
                    if (drawInspectorFloatRow(state.text(.audio_doppler_factor), "##audio_doppler", &doppler, theme.Spacing.inspector_audio_doppler_speed, theme.Spacing.inspector_audio_doppler_min, theme.Spacing.inspector_audio_doppler_max)) {
                        if (entity_mut) |em| {
                            if (em.audio_source) |*as| as.doppler_factor = doppler;
                        }
                        if (gui.isItemDeactivatedAfterEdit()) {
                            try history.captureSnapshot(state, layer_context);
                        }
                    }
                }
            }

            if (gui.beginPopupContextItem("audio_source_context")) {
                defer gui.endPopup();
                if (gui.menuItem(state.text(.remove_audio_source_component), null, false, true)) {
                    if (entity_mut) |em| {
                        if (em.audio_source) |audio_source| {
                            if (audio_source.clip_asset_path) |path| {
                                if (path.len != 0) {
                                    layer_context.world.allocator.free(path);
                                }
                            }
                        }
                        em.audio_source = null;
                    }
                    try history.captureSnapshot(state, layer_context);
                    return;
                }
            }
        }
    }

    if (entity.audio_listener) |*audio_lst| {
        if (inspectorSectionMatches(filter, state.text(.audio_listener)) and gui.collapsingHeader(state.text(.audio_listener), filter.len != 0)) {
            beginInspectorSectionBody();
            defer endInspectorSectionBody();
            gui.dummy(0.0, theme.Spacing.inspector_section_dummy);

            if (beginInspectorPropertyGrid("audio_listener_properties")) {
                defer endInspectorPropertyGrid();

                var enabled = audio_lst.enabled;
                if (drawInspectorCheckboxRow(state.text(.audio_listener_enabled), "##audio_listener_enabled", &enabled)) {
                    if (entity_mut) |em| {
                        if (em.audio_listener) |*al| al.enabled = enabled;
                    }
                    try history.captureSnapshot(state, layer_context);
                }
            }

            if (gui.beginPopupContextItem("audio_listener_context")) {
                defer gui.endPopup();
                if (gui.menuItem(state.text(.remove_audio_listener_component), null, false, true)) {
                    if (entity_mut) |em| em.audio_listener = null;
                    try history.captureSnapshot(state, layer_context);
                    return;
                }
            }
        }
    }

    if (inspectorSectionMatches(filter, state.text(.actions)) and gui.collapsingHeader(state.text(.actions), filter.len != 0)) {
        beginInspectorSectionBody();
        defer endInspectorSectionBody();
        const action_columns = layout.responsiveButtonColumns(3, theme.Spacing.inspector_action_button_min_width);
        const action_button_width = layout.responsiveButtonWidth(action_columns);

        if (gui.buttonEx(state.text(.focus), action_button_width, 0.0)) {
            camera.focusSelection(state, layer_context);
        }
        layout.advanceResponsiveRow(1, action_columns);
        if (gui.buttonEx(state.text(.duplicate), action_button_width, 0.0)) {
            try history.duplicateSelection(state, layer_context);
            return;
        }
        layout.advanceResponsiveRow(2, action_columns);
        if (gui.buttonEx(state.text(.delete), action_button_width, 0.0)) {
            try history.deleteSelection(state, layer_context);
            return;
        }

        gui.dummy(0.0, theme.Spacing.inspector_section_gap);
        if (gui.buttonEx(state.text(.move), action_button_width, 0.0)) {
            try manipulation.activateTransformTool(state, layer_context, .translate);
        }
        layout.advanceResponsiveRow(1, action_columns);
        if (gui.buttonEx(state.text(.rotate), action_button_width, 0.0)) {
            try manipulation.activateTransformTool(state, layer_context, .rotate);
        }
        layout.advanceResponsiveRow(2, action_columns);
        if (gui.buttonEx(state.text(.scale), action_button_width, 0.0)) {
            try manipulation.activateTransformTool(state, layer_context, .scale);
        }
    }
}

fn drawAddComponentControls(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *engine.scene.Entity,
) !bool {
    const has_missing_component = entity.mesh == null or entity.material == null or entity.camera == null or entity.light == null or entity.vfx == null or entity.audio_source == null or entity.audio_listener == null or entity.script == null;
    if (!has_missing_component) {
        gui.text(state.text(.none));
        return false;
    }

    if (entity.script == null and gui.menuItem("Script", null, false, true)) {
        entity.script = .{};
        try history.captureSnapshot(state, layer_context);
        return true;
    }

    if (entity.mesh == null) {
        if (gui.beginMenu(state.text(.mesh))) {
            defer gui.endMenu();
            if (gui.menuItem(state.text(.add_cube_mesh), null, false, true)) {
                try setPrimitiveMeshComponent(state, layer_context, entity, .cube);
                return true;
            }
            if (gui.menuItem(state.text(.add_sphere_mesh), null, false, true)) {
                try setPrimitiveMeshComponent(state, layer_context, entity, .sphere);
                return true;
            }
            if (gui.menuItem(state.text(.add_plane_mesh), null, false, true)) {
                try setPrimitiveMeshComponent(state, layer_context, entity, .plane);
                return true;
            }
        }
    }

    if (entity.material == null and gui.menuItem(state.text(.add_material_component), null, false, true)) {
        try addMaterialComponent(state, layer_context, entity);
        return true;
    }

    if (entity.camera == null and gui.menuItem(state.text(.add_camera_component), null, false, true)) {
        try addCameraComponent(state, layer_context, selected, entity);
        return true;
    }

    if (entity.light == null and gui.beginMenu(state.text(.light))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.add_directional_light), null, false, true)) {
            try setLightComponent(state, layer_context, entity, .directional);
            return true;
        }
        if (gui.menuItem(state.text(.add_point_light), null, false, true)) {
            try setLightComponent(state, layer_context, entity, .point);
            return true;
        }
        if (gui.menuItem(state.text(.add_spot_light), null, false, true)) {
            try setLightComponent(state, layer_context, entity, .spot);
            return true;
        }
    }

    if (entity.vfx == null and gui.beginMenu(state.text(.vfx))) {
        defer gui.endMenu();
        if (gui.menuItem(state.text(.vfx_fountain), null, false, true)) {
            try setVfxComponent(state, layer_context, selected, entity, .fountain);
            return true;
        }
        if (gui.menuItem(state.text(.vfx_orbit), null, false, true)) {
            try setVfxComponent(state, layer_context, selected, entity, .orbit);
            return true;
        }
    }

    if (entity.audio_source == null and gui.menuItem(state.text(.add_audio_source_component), null, false, true)) {
        entity.audio_source = .{};
        try history.captureSnapshot(state, layer_context);
        return true;
    }

    if (entity.audio_listener == null and gui.menuItem(state.text(.add_audio_listener_component), null, false, true)) {
        entity.audio_listener = .{};
        try history.captureSnapshot(state, layer_context);
        return true;
    }

    return false;
}

fn scriptLanguageLabel(language: engine.scene.ScriptLanguage) []const u8 {
    return switch (language) {
        .zig => "zig",
        .csharp => "csharp",
    };
}

/// Open a macOS file picker, read the selected script file, register it as a
/// ScriptResource in the world's asset library, and return its handle.
fn loadScriptFromFilePicker(layer_context: *engine.core.LayerContext) ?handles.ScriptHandle {
    const allocator = layer_context.world.allocator;

    // macOS native file dialog
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "/usr/bin/osascript",
            "-e",
            "POSIX path of (choose file of type {\"zig\"} with prompt \"Select Script\")",
        },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) return null;

    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return null;

    // Check if this path is already registered
    const lib = layer_context.world.assets();
    for (lib.scripts.items, 0..) |res, idx| {
        if (std.mem.eql(u8, res.source_path, path)) {
            return handles.scriptHandle(idx);
        }
    }

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(contents);

    return lib.createScript(.{
        .source = contents,
        .language = .zig,
        .entry_fn = "main",
        .description = path,
        .source_path = path,
    }) catch null;
}

fn drawReflectedScriptParameters(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    script_component: *engine.scene.Script,
    schema_json: []const u8,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const definitions = script_parameter_reflection.parseMetadataAlloc(allocator, schema_json) catch {
        gui.textWrapped("Failed to parse reflected parameter metadata.");
        return;
    };
    defer script_parameter_reflection.deinitDefinitions(allocator, definitions);
    if (definitions.len == 0) {
        gui.textWrapped("This script does not expose reflected public variables.");
        return;
    }

    const values = script_parameter_reflection.parseValuesAlloc(allocator, definitions, script_component.parameters) catch {
        gui.textWrapped("Failed to parse current script parameter values.");
        return;
    };
    defer allocator.free(values);

    var edited = false;
    var committed = false;

    if (beginInspectorPropertyGrid("script_reflected_parameters")) {
        defer endInspectorPropertyGrid();

        for (definitions, values, 0..) |definition, *value, index| {
            var widget_id_buffer: [80]u8 = undefined;
            const widget_id = try std.fmt.bufPrint(&widget_id_buffer, "##script_param_{d}", .{index});

            switch (definition.kind) {
                .float => {
                    var current = value.float;
                    if (drawInspectorFloatRow(definition.name, widget_id, &current, definition.step, definition.min, definition.max)) {
                        value.* = .{ .float = std.math.clamp(current, definition.min, definition.max) };
                        edited = true;
                        committed = committed or gui.isItemDeactivatedAfterEdit();
                    }
                },
                .boolean => {
                    var current = value.boolean;
                    if (drawInspectorCheckboxRow(definition.name, widget_id, &current)) {
                        value.* = .{ .boolean = current };
                        edited = true;
                        committed = true;
                    }
                },
                .integer => {
                    var current = @as(f32, @floatFromInt(value.integer));
                    if (drawInspectorFloatRow(definition.name, widget_id, &current, definition.step, definition.min, definition.max)) {
                        const clamped = std.math.clamp(current, definition.min, definition.max);
                        value.* = .{ .integer = @as(i32, @intFromFloat(@round(clamped))) };
                        edited = true;
                        committed = committed or gui.isItemDeactivatedAfterEdit();
                    }
                },
            }
        }
    }

    if (!edited) {
        return;
    }

    const next_payload = try script_parameter_reflection.buildValuesJsonAlloc(allocator, definitions, values);
    errdefer allocator.free(next_payload);
    replaceOwnedScriptParameters(allocator, &script_component.parameters, next_payload);

    if (layer_context.script_runtime) |runtime| {
        _ = try runtime.applyEntityScriptParameters(layer_context.world, entity_id);
    }
    if (committed) {
        try history.captureSnapshot(state, layer_context);
    }
}

fn replaceOwnedScriptParameters(allocator: std.mem.Allocator, target: *[]const u8, next: []u8) void {
    if (target.*.len != 0) {
        allocator.free(target.*);
    }
    target.* = next;
}

fn drawTransformHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *const engine.scene.Entity,
    world_transform: engine.scene.Transform,
) !bool {
    if (!gui.beginPopupContextItem("transform_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        state.transform_component_clipboard = entity.local_transform;
    }
    if (gui.menuItem(state.text(.paste), null, false, state.transform_component_clipboard != null)) {
        if (state.transform_component_clipboard) |clipboard| {
            if (!transformsEqual(entity.local_transform, clipboard)) {
                if (layer_context.world.getEntity(selected)) |em| {
                    em.local_transform = clipboard;
                    try history.captureSnapshot(state, layer_context);
                }
                return true;
            }
        }
    }
    if (gui.menuItem(state.text(.reset_all), null, false, true)) {
        try resetTransformTarget(state, layer_context, selected, entity, world_transform, .all);
        return true;
    }
    return false;
}

fn drawMeshHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    mesh_component: engine.scene.Mesh,
) !bool {
    if (!gui.beginPopupContextItem("mesh_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        try state.setMeshComponentClipboard(layer_context.world, mesh_component);
    }
    if (gui.menuItem(state.text(.paste), null, false, state.mesh_component_clipboard != null)) {
        if (try state.resolveMeshComponentClipboard(layer_context.world)) |clipboard| {
            if (layer_context.world.getEntity(selected)) |em| {
                em.mesh = clipboard;
                if (em.material == null) {
                    const material_handle = try layer_context.world.assets().ensureDefaultMaterial();
                    em.material = .{ .handle = material_handle };
                }
                try history.captureSnapshot(state, layer_context);
            }
            return true;
        } else {
            std.log.warn("mesh clipboard could not be resolved in the current asset library", .{});
        }
    }
    if (gui.menuItem(state.text(.remove_mesh_component), null, false, true)) {
        if (layer_context.world.getEntity(selected)) |em| {
            try clearMeshComponent(state, layer_context, em);
        }
        return true;
    }
    return false;
}

fn drawMaterialHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    material_component: engine.scene.Material,
) !bool {
    if (!gui.beginPopupContextItem("material_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        try state.setMaterialComponentClipboard(layer_context.world, material_component);
    }
    if (gui.menuItem(state.text(.paste), null, false, state.material_component_clipboard != null)) {
        if (state.resolveMaterialComponentClipboard(layer_context.world)) |clipboard| {
            if (layer_context.world.getEntity(selected)) |em| {
                em.material = clipboard;
                try history.captureSnapshot(state, layer_context);
            }
            return true;
        } else {
            std.log.warn("material clipboard could not be resolved in the current asset library", .{});
        }
    }
    if (gui.menuItem(state.text(.remove_material_component), null, false, true)) {
        if (layer_context.world.getEntity(selected)) |em| {
            try removeMaterialComponent(state, layer_context, em);
        }
        return true;
    }
    return false;
}

fn drawCameraHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    camera_component: engine.scene.Camera,
) !bool {
    if (!gui.beginPopupContextItem("camera_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        state.camera_component_clipboard = camera_component;
    }
    if (gui.menuItem(state.text(.paste), null, false, state.camera_component_clipboard != null)) {
        if (state.camera_component_clipboard) |clipboard| {
            if (layer_context.world.getEntity(selected)) |em| {
                var pasted = clipboard;
                pasted.is_primary = false;
                em.camera = pasted;
                if (layer_context.world.primaryCameraEntity() == null) {
                    _ = layer_context.world.setPrimaryCamera(selected);
                }
                state.scene_camera = layer_context.world.primaryCameraEntity();
                try history.captureSnapshot(state, layer_context);
            }
            return true;
        }
    }
    if (gui.menuItem(state.text(.remove_camera_component), null, false, true)) {
        if (layer_context.world.getEntity(selected)) |em| {
            try removeCameraComponent(state, layer_context, selected, em);
        }
        return true;
    }
    return false;
}

fn drawLightHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    light_component: engine.scene.Light,
) !bool {
    if (!gui.beginPopupContextItem("light_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        state.light_component_clipboard = light_component;
    }
    if (gui.menuItem(state.text(.paste), null, false, state.light_component_clipboard != null)) {
        if (state.light_component_clipboard) |clipboard| {
            if (layer_context.world.getEntity(selected)) |em| {
                em.light = clipboard;
                try history.captureSnapshot(state, layer_context);
            }
            return true;
        }
    }
    if (gui.menuItem(state.text(.remove_light_component), null, false, true)) {
        if (layer_context.world.getEntity(selected)) |em| {
            try removeLightComponent(state, layer_context, em);
        }
        return true;
    }
    return false;
}

fn drawVfxHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    vfx_component: engine.scene.Vfx,
) !bool {
    if (!gui.beginPopupContextItem("vfx_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (gui.menuItem(state.text(.copy), null, false, true)) {
        state.vfx_component_clipboard = vfx_component;
    }
    if (gui.menuItem(state.text(.paste), null, false, state.vfx_component_clipboard != null)) {
        if (state.vfx_component_clipboard) |clipboard| {
            if (layer_context.world.getEntity(selected)) |em| {
                em.vfx = clipboard;
                if (em.material) |*material| {
                    material.shading = .unlit;
                    material.base_color_factor = .{ clipboard.color[0], clipboard.color[1], clipboard.color[2], 1.0 };
                }
                vfx_runtime.clearEmitterRuntime(layer_context, selected);
                try history.captureSnapshot(state, layer_context);
            }
            return true;
        }
    }
    if (gui.menuItem(state.text(.remove_vfx_component), null, false, true)) {
        if (layer_context.world.getEntity(selected)) |em| {
            try removeVfxComponent(state, layer_context, selected, em);
        }
        return true;
    }
    return false;
}

fn drawPrefabHeaderContextMenu(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *const engine.scene.Entity,
) !bool {
    if (!gui.beginPopupContextItem("prefab_header_context")) {
        return false;
    }
    defer gui.endPopup();

    if (entity.prefab_instance_override) |override| {
        if (gui.menuItem(state.text(.update_prefab_instance), null, false, true)) {
            _ = try layer_context.world.updateAllPrefabInstances(override.prefab_id);
        }
        if (gui.menuItem(state.text(.break_prefab_connection), null, false, true)) {
            try scene_hierarchy.breakPrefabConnection(state, layer_context, selected);
            return true;
        }
        if (gui.menuItem(state.text(.select_prefab_asset), null, false, true)) {
            try state.setSelectedPrefabId(override.prefab_id);
            state.prefab_browser_open = true;
        }
    } else if (entity.prefab_entity_id != null) {
        if (gui.menuItem(state.text(.add_override), null, false, true)) {
            try scene_hierarchy.addPrefabOverride(state, layer_context, selected);
        }
        if (gui.menuItem(state.text(.revert_override), null, false, entity.prefab_instance_override != null)) {
            try layer_context.world.revertPrefabOverride(selected);
        }
    }
    return false;
}

fn resetTransformTarget(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *const engine.scene.Entity,
    world_transform: engine.scene.Transform,
    target: TransformResetTarget,
) !void {
    if (state.transform_space == .world) {
        var updated = world_transform;
        applyResetToTransform(&updated, target);
        if (!transformsEqual(updated, world_transform)) {
            try applyWorldTransformUpdate(state, layer_context, selected, updated);
            try history.captureSnapshot(state, layer_context);
        }
        return;
    }

    var updated = entity.local_transform;
    applyResetToTransform(&updated, target);
    if (!transformsEqual(entity.local_transform, updated)) {
        try applyLocalTransformUpdate(state, layer_context, selected, updated);
        try history.captureSnapshot(state, layer_context);
    }
}

fn renameEntityViaCommandQueue(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    next_name: []const u8,
) !bool {
    if (layer_context.command_queue) |queue| {
        var before = try history.captureEntitySnapshot(state, layer_context.world, entity_id) orelse return false;
        const allocator = state.allocator orelse layer_context.world.allocator;
        var before_owned = true;
        defer if (before_owned) before.deinit(allocator);

        try queue.enqueueRenameEntityWithSource(entity_id, next_name, .human);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        if (results.len == 0 or !results[0].changed) {
            return false;
        }

        try history.recordEntityMutation(state, layer_context, before, &.{entity_id});
        before_owned = false;
        return true;
    }

    if (try layer_context.world.renameEntity(entity_id, next_name)) {
        try history.captureSnapshot(state, layer_context);
        return true;
    }
    return false;
}

fn applyWorldTransformUpdate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    transform: engine.scene.Transform,
) !void {
    _ = state;
    if (layer_context.command_queue) |queue| {
        const allocator = layer_context.world.allocator;
        try queue.enqueueSetWorldTransformWithSource(entity_id, transform, .human);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        return;
    }
    _ = layer_context.world.setEntityWorldTransform(entity_id, transform);
}

fn applyLocalTransformUpdate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    transform: engine.scene.Transform,
) !void {
    _ = state;
    if (layer_context.command_queue) |queue| {
        const allocator = layer_context.world.allocator;
        try queue.enqueueSetLocalTransformWithSource(entity_id, transform, .human);
        const results = try history.executeQueuedCommands(layer_context);
        defer allocator.free(results);
        return;
    }
    _ = layer_context.world.setEntityLocalTransform(entity_id, transform);
}

fn applyResetToTransform(transform: *engine.scene.Transform, target: TransformResetTarget) void {
    switch (target) {
        .translation => transform.translation = .{ 0.0, 0.0, 0.0 },
        .rotation => transform.rotation = engine.math.quat.identity(),
        .scale => transform.scale = .{ 1.0, 1.0, 1.0 },
        .all => transform.* = .{},
    }
}

fn transformsEqual(a: engine.scene.Transform, b: engine.scene.Transform) bool {
    return std.meta.eql(a.translation, b.translation) and
        std.meta.eql(a.rotation, b.rotation) and
        std.meta.eql(a.scale, b.scale);
}

fn drawActionRow2(first: []const u8, second: []const u8, min_button_width: f32) ActionRowResult {
    const columns = layout.responsiveButtonColumns(2, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    return .none;
}

fn drawTransformTableRow(
    row_label: []const u8,
    id_prefix: []const u8,
    values: *[3]f32,
    speed: f32,
    min_value: f32,
    max_value: f32,
) !EditRowResult {
    var result = EditRowResult{};

    if (transform_grid_mode == .stacked) {
        gui.alignTextToFramePadding();
        gui.text(row_label);
        gui.dummy(0.0, theme.Spacing.inspector_axis_spacing);

        const x_result = try drawAxisDragField(id_prefix, "x", "X", &values[0], axis_x_style, speed, min_value, max_value);
        result.changed = result.changed or x_result.changed;
        result.committed = result.committed or x_result.committed;

        gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
        const y_result = try drawAxisDragField(id_prefix, "y", "Y", &values[1], axis_y_style, speed, min_value, max_value);
        result.changed = result.changed or y_result.changed;
        result.committed = result.committed or y_result.committed;

        gui.dummy(0.0, theme.Spacing.inspector_section_dummy);
        const z_result = try drawAxisDragField(id_prefix, "z", "Z", &values[2], axis_z_style, speed, min_value, max_value);
        result.changed = result.changed or z_result.changed;
        result.committed = result.committed or z_result.committed;
        return result;
    }

    gui.tableNextRow();
    gui.tableNextColumn();
    gui.alignTextToFramePadding();
    gui.text(row_label);

    gui.tableNextColumn();
    const x_result = try drawAxisDragField(id_prefix, "x", "X", &values[0], axis_x_style, speed, min_value, max_value);
    result.changed = result.changed or x_result.changed;
    result.committed = result.committed or x_result.committed;

    gui.tableNextColumn();
    const y_result = try drawAxisDragField(id_prefix, "y", "Y", &values[1], axis_y_style, speed, min_value, max_value);
    result.changed = result.changed or y_result.changed;
    result.committed = result.committed or y_result.committed;

    gui.tableNextColumn();
    const z_result = try drawAxisDragField(id_prefix, "z", "Z", &values[2], axis_z_style, speed, min_value, max_value);
    result.changed = result.changed or z_result.changed;
    result.committed = result.committed or z_result.committed;

    return result;
}

/// AI preview 模式下将 transform 变动写回 preview world（通过 collaboration 路径）
fn applyPreviewTransformUpdate(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    new_world_transform: engine.scene.Transform,
) !void {
    const runtime = if (state.ai_preview_runtime) |*rt| rt else return;
    _ = runtime.world.setEntityWorldTransform(entity_id, new_world_transform);
    runtime.world.updateHierarchy();
    if (state.ai_collaboration) |store| {
        _ = try store.updateStagedEntityWorldTransform(
            state.allocator orelse layer_context.world.allocator,
            entity_id,
            new_world_transform,
            .human,
        );
    }
}

fn drawAxisDragField(
    id_prefix: []const u8,
    axis_suffix: []const u8,
    axis_label: []const u8,
    value: *f32,
    style: AxisStyle,
    speed: f32,
    min_value: f32,
    max_value: f32,
) !EditRowResult {
    var result = EditRowResult{};
    const axis_width = @max(gui.frameHeight() - theme.Spacing.x1, theme.Spacing.inspector_axis_width_min);

    gui.pushStyleVarVec2(.item_spacing, .{ 0.0, 0.0 });
    gui.pushStyleVarFloat(.frame_rounding, theme.Spacing.inspector_axis_frame_rounding);
    defer gui.popStyleVar(2);

    var axis_id_buffer: [48]u8 = undefined;
    const axis_id = try std.fmt.bufPrint(&axis_id_buffer, "{s}##{s}_{s}_axis", .{ axis_label, id_prefix, axis_suffix });
    gui.pushStyleColor(.text, style.text);
    gui.pushStyleColor(.button, style.background);
    gui.pushStyleColor(.button_hovered, style.background);
    gui.pushStyleColor(.button_active, style.background);
    _ = gui.buttonEx(axis_id, axis_width, gui.frameHeight());
    gui.popStyleColor(4);

    gui.sameLine();

    var drag_id_buffer: [40]u8 = undefined;
    const drag_id = try std.fmt.bufPrint(&drag_id_buffer, "##{s}_{s}", .{ id_prefix, axis_suffix });
    gui.setNextItemWidth(-1.0);
    if (gui.dragFloat(drag_id, value, speed, min_value, max_value)) {
        result.changed = true;
    }
    result.committed = gui.isItemDeactivatedAfterEdit();
    return result;
}

pub fn setPrimitiveMeshComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    primitive: engine.scene.Primitive,
) !void {
    const mesh_handle = try layer_context.world.assets().ensurePrimitiveMesh(primitive);
    const material_handle = try layer_context.world.assets().ensureDefaultMaterial();
    entity.mesh = .{
        .handle = mesh_handle,
        .primitive = primitive,
    };
    if (entity.material) |*material| {
        if (material.handle == null) {
            material.handle = material_handle;
        }
    } else {
        entity.material = .{
            .handle = material_handle,
        };
    }
    try history.captureSnapshot(state, layer_context);
}

pub fn clearMeshComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !void {
    if (entity.mesh == null and entity.material == null) {
        return;
    }
    entity.mesh = null;
    entity.material = null;
    try history.captureSnapshot(state, layer_context);
}

pub fn addMaterialComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !void {
    if (entity.material != null) {
        return;
    }
    const material_handle = try layer_context.world.assets().ensureDefaultMaterial();
    entity.material = .{
        .handle = material_handle,
    };
    try history.captureSnapshot(state, layer_context);
}

pub fn removeMaterialComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !void {
    if (entity.material == null) {
        return;
    }
    entity.material = null;
    try history.captureSnapshot(state, layer_context);
}

pub fn addCameraComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *engine.scene.Entity,
) !void {
    if (entity.camera != null) {
        return;
    }
    const had_primary = layer_context.world.primaryCameraEntity() != null;
    entity.camera = .{};
    if (!had_primary) {
        _ = layer_context.world.setPrimaryCamera(selected);
    }
    state.scene_camera = layer_context.world.primaryCameraEntity();
    try history.captureSnapshot(state, layer_context);
}

pub fn removeCameraComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *engine.scene.Entity,
) !void {
    _ = selected;
    if (entity.camera == null) {
        return;
    }
    entity.camera = null;
    state.scene_camera = layer_context.world.primaryCameraEntity();
    try history.captureSnapshot(state, layer_context);
}

pub fn setLightComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    kind: engine.scene.LightKind,
) !void {
    entity.light = .{
        .kind = kind,
        .intensity = switch (kind) {
            .directional => 4.0,
            .point => 24.0,
            .spot => 18.0,
        },
        .range = switch (kind) {
            .directional => 10.0,
            .point => 12.0,
            .spot => 14.0,
        },
    };
    try history.captureSnapshot(state, layer_context);
}

pub fn removeLightComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !void {
    if (entity.light == null) {
        return;
    }
    entity.light = null;
    try history.captureSnapshot(state, layer_context);
}

pub fn setVfxComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *engine.scene.Entity,
    kind: engine.scene.VfxKind,
) !void {
    const vfx = switch (kind) {
        .fountain => engine.scene.Vfx{
            .kind = .fountain,
            .looping = true,
            .emission_rate = 18.0,
            .particle_lifetime = 1.2,
            .speed = 2.6,
            .max_particles = 28,
            .radius = 0.42,
            .spread = 0.38,
            .size = 0.11,
            .color = .{ 1.0, 0.58, 0.26 },
        },
        .orbit => engine.scene.Vfx{
            .kind = .orbit,
            .looping = true,
            .emission_rate = 12.0,
            .particle_lifetime = 1.8,
            .speed = 1.2,
            .max_particles = 20,
            .radius = 0.72,
            .spread = 0.18,
            .size = 0.1,
            .color = .{ 0.42, 0.82, 1.0 },
        },
    };
    entity.vfx = vfx;
    if (entity.mesh == null) {
        const mesh_handle = try layer_context.world.assets().ensurePrimitiveMesh(.sphere);
        entity.mesh = .{
            .handle = mesh_handle,
            .primitive = .sphere,
        };
        entity.local_transform.scale = .{ 0.18, 0.18, 0.18 };
    }
    if (entity.material == null) {
        entity.material = .{};
    }
    if (entity.material) |*material| {
        material.shading = .unlit;
        material.base_color_factor = .{ vfx.color[0], vfx.color[1], vfx.color[2], 1.0 };
    }
    vfx_runtime.clearEmitterRuntime(layer_context, selected);
    try history.captureSnapshot(state, layer_context);
}

pub fn removeVfxComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    selected: engine.scene.EntityId,
    entity: *engine.scene.Entity,
) !void {
    if (entity.vfx == null) {
        return;
    }
    entity.vfx = null;
    vfx_runtime.clearEmitterRuntime(layer_context, selected);
    try history.captureSnapshot(state, layer_context);
}

pub fn ensureEditableMaterialResource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !?*engine.assets.MaterialResource {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const material_component = if (entity.material) |*value| value else return null;

    if (material_component.handle) |material_handle| {
        if (materialUsageCount(state, layer_context.world, material_handle) <= 1) {
            const material_resource = layer_context.world.assets().material(material_handle) orelse return null;
            return @constCast(material_resource);
        }

        const source = layer_context.world.assets().material(material_handle) orelse return null;
        const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
        defer allocator.free(instance_name);

        const new_handle = try layer_context.world.assets().createMaterial(.{
            .name = instance_name,
            .shading = source.shading,
            .base_color_factor = source.base_color_factor,
            .base_color_texture = source.base_color_texture,
            .metallic_roughness_texture = source.metallic_roughness_texture,
            .normal_texture = source.normal_texture,
            .occlusion_texture = source.occlusion_texture,
            .emissive_texture = source.emissive_texture,
            .emissive_factor = source.emissive_factor,
            .metallic_factor = source.metallic_factor,
            .roughness_factor = source.roughness_factor,
            .alpha_cutoff = source.alpha_cutoff,
            .double_sided = source.double_sided,
            .use_ibl = source.use_ibl,
            .ibl_intensity = source.ibl_intensity,
            .inheritance = .{
                .parent_material_handle = material_handle,
                .parent_material_name_hint = source.name,
                .generation = source.inheritance.generation + 1,
            },
            .graph = source.graph,
        });
        material_component.handle = new_handle;
        material_component.shading = source.shading;
        material_component.base_color_factor = source.base_color_factor;
        material_component.emissive_factor = source.emissive_factor;
        material_component.metallic_factor = source.metallic_factor;
        material_component.roughness_factor = source.roughness_factor;
        material_component.alpha_cutoff = source.alpha_cutoff;
        material_component.double_sided = source.double_sided;
        return @constCast(layer_context.world.assets().material(new_handle).?);
    }

    const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
    defer allocator.free(instance_name);

    const new_handle = try layer_context.world.assets().createMaterial(.{
        .name = instance_name,
        .shading = material_component.shading,
        .base_color_factor = material_component.base_color_factor,
        .emissive_factor = material_component.emissive_factor,
        .metallic_factor = material_component.metallic_factor,
        .roughness_factor = material_component.roughness_factor,
        .alpha_cutoff = material_component.alpha_cutoff,
        .double_sided = material_component.double_sided,
        .inheritance = .{},
    });
    material_component.handle = new_handle;
    return @constCast(layer_context.world.assets().material(new_handle).?);
}

pub fn materialHandleForEntity(_: *const EditorState, entity: *const engine.scene.Entity) ?engine.assets.MaterialHandle {
    if (entity.material) |material_component| {
        return material_component.handle;
    }
    return null;
}

pub fn materialUsageCount(_: *const EditorState, world: *const engine.scene.World, handle: engine.assets.MaterialHandle) usize {
    // 缓存实现：可在状态中添加 material_usage_cache
    // 目前先实现直接计数，但只在必要时调用
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.material) |material| {
            if (material.handle) |candidate| {
                if (candidate == handle) {
                    count += 1;
                }
            }
        }
    }
    return count;
}

pub fn assignSelectedTextureToMaterial(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !bool {
    const entry = content_browser.selectedAsset(state) orelse return false;
    return assignTextureEntryToMaterial(state, layer_context, entity, entry);
}

pub fn assignTextureEntryToMaterial(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
    entry: *const state_mod.AssetEntry,
) !bool {
    if (entry.kind != .texture) {
        return false;
    }

    const texture_handle = try importTextureAsset(state, layer_context, entry.id, entry.path);
    if (try ensureEditableMaterialResource(state, layer_context, entity)) |material_resource| {
        material_resource.base_color_texture = texture_handle;
        if (entity.material) |*material_component| {
            material_component.handle = materialHandleForEntity(state, entity);
        }
        return true;
    }
    return false;
}

fn drawMaterialTextureSlotRow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: ?*engine.scene.Entity,
    texture_text: []const u8,
) !bool {
    drawInspectorPropertyLabel(state.text(.texture), null);
    const clicked = gui.buttonEx(texture_text, -1.0, 0.0);

    var changed = false;
    if (entity) |target_entity| {
        if (clicked and content_browser.selectedAssetCanUseAsTexture(state)) {
            changed = (try assignSelectedTextureToMaterial(state, layer_context, target_entity)) or changed;
        }
        changed = (try acceptDroppedTextureAssetForMaterialSlot(state, layer_context, target_entity)) or changed;
    }
    return changed;
}

fn acceptDroppedTextureAssetForMaterialSlot(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !bool {
    var dropped_texture: u64 = 0;
    if (!gui.acceptDragDropPayloadU64(state_mod.asset_texture_drag_payload, &dropped_texture)) {
        return false;
    }

    const asset_index: usize = @intCast(dropped_texture);
    if (asset_index >= state.asset_entries.items.len) {
        return false;
    }
    return assignTextureEntryToMaterial(state, layer_context, entity, &state.asset_entries.items[asset_index]);
}

pub fn importTextureAsset(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    asset_id: []const u8,
    path: []const u8,
) !engine.assets.TextureHandle {
    if (state.asset_registry) |*registry| {
        if (registry.recordById(asset_id) != null) {
            return engine.assets.loadTextureAsset(
                state.allocator orelse layer_context.world.allocator,
                layer_context.world.assets(),
                registry,
                asset_id,
            );
        }
    }

    for (layer_context.world.assets().textures.items, 0..) |texture, index| {
        if (std.mem.eql(u8, texture.name, path)) {
            return @enumFromInt(index + 1);
        }
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    const encoded = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var decoded = try engine.assets.decodeImageRgba8(allocator, encoded);
    defer decoded.deinit();
    utils.swizzleRgbaToBgra(decoded.pixels);

    return layer_context.world.assets().createTexture(.{
        .name = path,
        .width = decoded.width,
        .height = decoded.height,
        .pixels = decoded.pixels,
    });
}
