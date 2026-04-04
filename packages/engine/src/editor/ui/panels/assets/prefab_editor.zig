const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const layout = @import("../../layout.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const EntityId = engine.scene.EntityId;
const PrefabResource = engine.scene.prefab.PrefabResource;

pub const PrefabEditorState = struct {
    selected_prefab_id: ?[]const u8 = null,
    selected_entity_index: ?usize = null,
    is_editing: bool = false,
    pending_save: bool = false,
    prefab_name_buffer: [256]u8 = [_]u8{0} ** 256,
    search_filter: [128]u8 = [_]u8{0} ** 128,
    show_create_dialog: bool = false,
    new_prefab_name_buffer: [128]u8 = [_]u8{0} ** 128,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.selected_prefab_id) |id| {
            allocator.free(id);
        }
        self.* = undefined;
    }
};

pub fn drawPrefabEditorWindow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *PrefabEditorState,
) !void {
    const world = layer_context.world;

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .prefab_editor, "prefab_editor_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("prefab_editor_panel");

    drawPrefabToolbar(editor_state);

    gui.separator();

    const content_region = gui.contentRegionAvail();
    const left_pane_width = content_region[0] * 0.3;

    if (gui.beginChild("prefab_list", left_pane_width, -1.0, true)) {
        drawPrefabList(world, editor_state, state.allocator orelse world.allocator);
    }
    gui.endChild();

    gui.sameLine();

    if (gui.beginChild("prefab_details", -1.0, -1.0, true)) {
        if (editor_state.selected_prefab_id) |prefab_id| {
            if (world.prefab_library.getPrefab(prefab_id)) |prefab| {
                drawPrefabDetails(editor_state, prefab);
            } else {
                gui.textWrapped("Prefab not found");
            }
        } else {
            gui.textWrapped("Select a prefab from the library");
        }
    }
    gui.endChild();
}

fn drawPrefabToolbar(
    editor_state: *PrefabEditorState,
) void {
    if (gui.button("Create Prefab")) {
        editor_state.show_create_dialog = true;
    }

    gui.sameLine();

    if (gui.button("Save All")) {}

    gui.sameLine();

    gui.text("Search:");
    gui.sameLine();
    _ = gui.inputText("##prefab_search", &editor_state.search_filter);
}

fn drawPrefabList(
    world: *engine.scene.World,
    editor_state: *PrefabEditorState,
    allocator: std.mem.Allocator,
) void {
    var filter_empty = true;
    for (editor_state.search_filter) |c| {
        if (c != 0) {
            filter_empty = false;
            break;
        }
    }

    var prefab_iter = world.prefab_library.prefabs.iterator();
    while (prefab_iter.next()) |entry| {
        const prefab_id = entry.key_ptr.*;
        const prefab = entry.value_ptr.*;

        if (!filter_empty) {
            const filter = std.mem.sliceTo(&editor_state.search_filter, 0);
            if (std.mem.indexOf(u8, prefab.name, filter) == null and
                std.mem.indexOf(u8, prefab_id, filter) == null)
            {
                continue;
            }
        }

        const is_selected = editor_state.selected_prefab_id != null and
            std.mem.eql(u8, editor_state.selected_prefab_id.?, prefab_id);

        var name_buf: [256]u8 = undefined;
        const display_name = std.fmt.bufPrint(&name_buf, "{s}##{s}", .{ prefab.name, prefab_id }) catch continue;

        if (gui.selectable(display_name, is_selected, false, 0.0, 0.0)) {
            if (editor_state.selected_prefab_id) |old_id| {
                allocator.free(old_id);
            }
            editor_state.selected_prefab_id = allocator.dupe(u8, prefab_id) catch null;
        }

        if (gui.beginPopupContextItem(null)) {
            if (gui.selectable("Delete Prefab", false, false, 0.0, 0.0)) {}
            if (gui.selectable("Duplicate Prefab", false, false, 0.0, 0.0)) {}
            gui.endPopup();
        }
    }
}

fn drawPrefabDetails(
    editor_state: *PrefabEditorState,
    prefab: *const PrefabResource,
) void {
    if (layout.beginInspectorPropertyTable("prefab_details", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("ID", null);
        gui.textWrapped(prefab.id);

        layout.drawInspectorPropertyRow("Name", null);
        gui.textWrapped(prefab.name);

        layout.drawInspectorPropertyRow("Version", null);
        var ver_buf: [16]u8 = undefined;
        gui.text(std.fmt.bufPrint(&ver_buf, "{}", .{prefab.version}) catch "?");

        layout.drawInspectorPropertyRow("Entities", null);
        var ent_buf: [16]u8 = undefined;
        gui.text(std.fmt.bufPrint(&ent_buf, "{}", .{prefab.entities.len}) catch "?");

        layout.drawInspectorPropertyRow("Source Path", null);
        if (prefab.source_path) |path| {
            gui.textWrapped(path);
        } else {
            gui.textColored(.{ 0.5, 0.5, 0.5, 1.0 }, "Not saved");
        }
    }

    gui.separator();
    gui.text("Entity List:");
    gui.separator();

    if (gui.beginChild("prefab_entity_list", -1.0, -1.0, true)) {
        for (prefab.entities, 0..) |entity, index| {
            const is_selected = editor_state.selected_entity_index != null and
                editor_state.selected_entity_index.? == index;

            var name_buf: [256]u8 = undefined;
            const display_name = std.fmt.bufPrint(&name_buf, "{s}##{}", .{ entity.name, index }) catch continue;

            if (gui.selectable(display_name, is_selected, false, 0.0, 0.0)) {
                editor_state.selected_entity_index = index;
            }
        }
    }
    gui.endChild();
}
