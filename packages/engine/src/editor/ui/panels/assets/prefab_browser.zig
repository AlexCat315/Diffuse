const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const layout = @import("../../layout.zig");
const prefab_mod = engine.scene.prefab;
const quat = engine.math.quat;

const BrowserText = enum {
    create_prefab,
    instantiate_prefab,
    save_prefab,
    delete_prefab,
    selected_prefab,
    instantiate,
    edit_prefab,
    refresh_prefabs,
};

/// Prefab 浏览器窗口
pub fn drawPrefabBrowserWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .prefab_browser, "prefab_browser_popup");
    var open = state.prefab_browser_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.prefab_browser_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("prefab_browser_popup");

    if (!open) {
        return;
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    // 搜索框
    _ = gui.inputText("##search", &state.prefab_browser_search_buffer);

    gui.separator();

    // 获取所有 Prefab
    const prefab_count = layer_context.world.prefab_library.prefabs.count();
    if (prefab_count == 0) {
        gui.text(state.text(.no_prefabs_available));
        gui.separator();

        // 创建新 Prefab 按钮
        if (gui.button(browserText(state, .create_prefab))) {
            try createPrefabFromSelection(state, layer_context);
        }
        return;
    }

    // Prefab 列表
    if (gui.beginChild("prefab_list", 0.0, gui.contentRegionAvail()[1] * 0.6, false)) {
        defer gui.endChild();

        var it = layer_context.world.prefab_library.prefabs.iterator();
        const search_text = trimmedBuffer(&state.prefab_browser_search_buffer);
        while (it.next()) |entry| {
            const prefab_id = entry.key_ptr.*;
            const prefab = entry.value_ptr.*;

            if (search_text.len != 0 and
                !containsIgnoreCase(prefab.name, search_text) and
                !containsIgnoreCase(prefab_id, search_text))
            {
                continue;
            }

            // 检查是否被选中
            const is_selected = state.selected_prefab_id != null and
                std.mem.eql(u8, state.selected_prefab_id.?, prefab_id);

            // 显示 Prefab 行
            if (gui.selectable(
                prefab.name,
                is_selected,
                false,
                0.0,
                0.0,
            )) {
                try state.setSelectedPrefabId(prefab_id);
            }

            // 右键上下文菜单
            if (gui.beginPopupContextItem("prefab_context")) {
                defer gui.endPopup();

                if (gui.menuItem(browserText(state, .instantiate_prefab), null, false, true)) {
                    _ = try layer_context.world.instantiatePrefab(prefab_id, .{
                        .name_prefix = "Instance",
                        .transform = .{
                            .translation = .{ 0.0, 0.0, 0.0 },
                            .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
                            .scale = .{ 1.0, 1.0, 1.0 },
                        },
                    });
                }

                if (gui.menuItem(browserText(state, .save_prefab), null, false, true)) {
                    try savePrefabWithDefaultPath(state, layer_context, prefab_id);
                }

                gui.separator();

                if (gui.menuItem(browserText(state, .delete_prefab), null, false, true)) {
                    try deletePrefab(state, layer_context, prefab_id);
                    return;
                }
            }
        }
    }

    gui.separator();

    // 选中 Prefab 的操作按钮
    if (state.selected_prefab_id) |selected_id| {
        gui.text(browserText(state, .selected_prefab));
        gui.sameLine();
        gui.text(selected_id);

        gui.separator();

        // 实例化按钮
        if (gui.button(browserText(state, .instantiate))) {
            _ = try layer_context.world.instantiatePrefab(selected_id, .{
                .name_prefix = "Instance",
                .transform = .{
                    .translation = .{ 0.0, 0.0, 0.0 },
                    .rotation = .{ 0.0, 0.0, 0.0, 1.0 },
                    .scale = .{ 1.0, 1.0, 1.0 },
                },
            });
        }

        gui.sameLine();

        // 编辑按钮
        if (gui.button(browserText(state, .edit_prefab))) {
            try state.setEditingPrefabId(selected_id);
        }

        // 保存按钮
        gui.sameLine();
        if (gui.button(browserText(state, .save_prefab))) {
            try savePrefabWithDefaultPath(state, layer_context, selected_id);
        }
    }

    // 底部操作栏
    gui.separator();
    if (gui.button(browserText(state, .create_prefab))) {
        try createPrefabFromSelection(state, layer_context);
    }

    gui.sameLine();

    if (gui.button(browserText(state, .refresh_prefabs))) {
        try refreshPrefabsFromDisk(state, layer_context);
    }
}

/// 创建选中实体的 Prefab
pub fn createPrefabFromSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const selected = layer_context.renderer.selectedEntity() orelse {
        return error.NoEntitySelected;
    };
    const entity = layer_context.world.getEntityConst(selected) orelse return error.EntityNotFound;
    const allocator = state.allocator orelse layer_context.world.allocator;

    const sanitized_name = try sanitizePrefabIdSegmentAlloc(allocator, entity.name);
    defer allocator.free(sanitized_name);
    const prefab_id = try std.fmt.allocPrint(allocator, "prefab://assets/prefabs/{s}/v1", .{sanitized_name});
    defer allocator.free(prefab_id);

    try layer_context.world.createPrefab(selected, prefab_id);
    try state.setSelectedPrefabId(prefab_id);
    try savePrefabWithDefaultPath(state, layer_context, prefab_id);
}

/// 实例化 Prefab 到场景中
pub fn instantiatePrefabAtSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    _ = state;
    _ = layer_context.world.instantiatePrefab(prefab_id, .{
        .name_prefix = "Instance",
    });
}

/// 将选中的实体转换为 Prefab 实例
pub fn convertToPrefabInstance(
    _: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    // 获取 Prefab
    _ = layer_context.world.getPrefab(prefab_id) orelse {
        return error.PrefabNotFound;
    };

    // 实例化 Prefab
    const instance_id = try layer_context.world.instantiatePrefab(prefab_id, .{
        .name_prefix = "",
    });

    // 标记为 Prefab 实例
    const entity = layer_context.world.getEntity(instance_id).?;
    entity.prefab_entity_id = 0; // 根实体
}

/// 显示 Prefab 覆盖编辑器
pub fn drawPrefabOverrideEditor(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.world.EntityId,
) !void {
    const entity = layer_context.world.getEntity(entity_id) orelse return;

    if (entity.prefab_instance_override == null) {
        // 没有覆盖，显示"添加覆盖"按钮
        if (gui.button(state.text(.add_override))) {
            // 创建新的覆盖数据
            const override = prefab_mod.PrefabInstanceOverride{
                .prefab_id = try state.allocator.dupe(u8, "prefab://unknown"),
                .prefab_version = 1,
                .root_prefab_entity_id = entity.prefab_entity_id orelse 0,
                .override_mask = .{},
            };
            entity.prefab_instance_override = override;
        }
        return;
    }

    const override = entity.prefab_instance_override.?;

    gui.text(state.text(.prefab_override));
    gui.text(override.prefab_id);

    gui.separator();

    // 变换覆盖
    if (gui.collapsingHeader(state.text(.transform), .{})) {
        const transform_changed = gui.dragFloat3(
            state.text(.translation),
            &entity.local_transform.translation,
            0.1,
        );

        var rotation = quat.toEuler(entity.local_transform.rotation);
        const rotation_changed = gui.dragFloat3(state.text(.rotation), &rotation, 0.1);

        const scale_changed = gui.dragFloat3(
            state.text(.scale),
            &entity.local_transform.scale,
            0.1,
        );

        if (rotation_changed) {
            entity.local_transform.rotation = quat.fromEuler(rotation);
        }

        if (transform_changed or rotation_changed or scale_changed) {
            override.override_mask.local_transform = true;
            override.local_transform_override = entity.local_transform;
        }
    }

    // 可见性覆盖
    if (gui.collapsingHeader(state.text(.visibility), .{})) {
        const visible_changed = gui.checkbox(
            state.text(.visible),
            &entity.visible,
        );

        if (visible_changed) {
            override.override_mask.visible = true;
            override.visible_override = entity.visible;
        }
    }

    gui.separator();

    // 恢复覆盖按钮
    if (gui.button(state.text(.revert_override))) {
        try layer_context.world.revertPrefabOverride(entity_id);
    }
}

fn savePrefabWithDefaultPath(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const path = try defaultPrefabPathAlloc(allocator, prefab_id);
    defer allocator.free(path);
    try layer_context.world.savePrefab(prefab_id, path);
}

fn deletePrefab(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    prefab_id: []const u8,
) !void {
    const selected_matches = state.selected_prefab_id != null and std.mem.eql(u8, state.selected_prefab_id.?, prefab_id);
    const editing_matches = state.editing_prefab_id != null and std.mem.eql(u8, state.editing_prefab_id.?, prefab_id);

    try layer_context.world.removePrefab(prefab_id);

    if (selected_matches) {
        try state.setSelectedPrefabId(null);
    }
    if (editing_matches) {
        try state.setEditingPrefabId(null);
    }
}

fn refreshPrefabsFromDisk(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const RefreshEntry = struct {
        id: []u8,
        path: []u8,
    };

    var entries = std.ArrayList(RefreshEntry).empty;
    defer {
        for (entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.path);
        }
        entries.deinit(allocator);
    }

    var it = layer_context.world.prefab_library.prefabs.valueIterator();
    while (it.next()) |prefab_ptr| {
        const prefab = prefab_ptr.*;
        if (prefab.source_path) |path| {
            try entries.append(allocator, .{
                .id = try allocator.dupe(u8, prefab.id),
                .path = try allocator.dupe(u8, path),
            });
        }
    }

    for (entries.items) |entry| {
        _ = layer_context.world.prefab_library.removePrefab(entry.id);
        _ = try layer_context.world.loadPrefab(entry.path);
    }
}

fn defaultPrefabPathAlloc(allocator: std.mem.Allocator, prefab_id: []const u8) ![]u8 {
    var relative = if (std.mem.startsWith(u8, prefab_id, "prefab://"))
        prefab_id["prefab://".len..]
    else
        prefab_id;

    if (std.mem.startsWith(u8, relative, "assets/prefabs/")) {
        relative = relative["assets/prefabs/".len..];
    }

    return try std.fmt.allocPrint(allocator, "assets/prefabs/{s}.prefab.json", .{relative});
}

fn sanitizePrefabIdSegmentAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    for (value) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try buffer.append(allocator, std.ascii.toLower(char));
        } else if (char == ' ' or char == '_' or char == '-') {
            if (buffer.items.len == 0 or buffer.items[buffer.items.len - 1] == '-') {
                continue;
            }
            try buffer.append(allocator, '-');
        }
    }

    if (buffer.items.len == 0) {
        return try allocator.dupe(u8, "prefab");
    }

    return try buffer.toOwnedSlice(allocator);
}

fn trimmedBuffer(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matched = false;
                break;
            }
        }
        if (matched) {
            return true;
        }
    }

    return false;
}

fn browserText(state: *const EditorState, id: BrowserText) []const u8 {
    return switch (state.language) {
        .en_us => switch (id) {
            .create_prefab => "Create Prefab",
            .instantiate_prefab => "Instantiate Prefab",
            .save_prefab => "Save Prefab",
            .delete_prefab => "Delete Prefab",
            .selected_prefab => "Selected Prefab:",
            .instantiate => "Instantiate",
            .edit_prefab => "Edit Prefab",
            .refresh_prefabs => "Refresh Prefabs",
        },
        .zh_cn => switch (id) {
            .create_prefab => "创建预制体",
            .instantiate_prefab => "实例化预制体",
            .save_prefab => "保存预制体",
            .delete_prefab => "删除预制体",
            .selected_prefab => "当前预制体:",
            .instantiate => "实例化",
            .edit_prefab => "编辑预制体",
            .refresh_prefabs => "刷新预制体",
        },
    };
}
