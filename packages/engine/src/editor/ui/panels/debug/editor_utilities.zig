const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;
const layout = @import("../../layout.zig");

pub fn drawEditorUtilitiesWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    var open = state.editor_utilities_open;
    const open_window = gui.beginWindowOpen("AI Utilities###editor_utilities_panel", &open);
    floating_window_blocker.registerCurrentWindow("editor_utilities_panel");
    if (!open_window) {
        gui.endWindow();
        state.editor_utilities_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.editor_utilities_open = open;
    }

    layout.beginSectionBody();
    defer layout.endSectionBody();

    const runtime = layer_context.editor_utility_runtime orelse {
        gui.textWrapped("Editor utility runtime is not available.");
        return;
    };

    const snapshots = try runtime.listAlloc(layer_context.world.allocator);
    defer engine.script.freeEditorUtilitySnapshots(layer_context.world.allocator, snapshots);

    if (snapshots.len == 0) {
        gui.textWrapped("No editor utilities are loaded. Use MCP compile_editor_utility to add one.");
        return;
    }

    gui.text("Loaded Utilities");
    const registry_height = @min(260.0, @max(148.0, gui.contentRegionAvail()[1] * 0.42));
    if (gui.beginChild("editor_utilities_registry", 0.0, registry_height, true)) {
        defer gui.endChild();
        try drawRegistry(runtime, snapshots);
    }

    gui.dummy(0.0, 8.0);
    gui.text("Panel Content");
    gui.separator();

    var open_count: usize = 0;
    for (snapshots) |snapshot| {
        if (!snapshot.open) {
            continue;
        }
        open_count += 1;

        gui.pushIdU64(@intFromEnum(snapshot.handle));
        defer gui.popId();

        if (gui.collapsingHeader(snapshot.name, true)) {
            if (snapshot.description.len != 0) {
                gui.textWrapped(snapshot.description);
            }
            if (snapshot.source_path.len != 0) {
                gui.labelText("Source", snapshot.source_path);
            }
            gui.labelText("Status", statusLabel(snapshot.status));
            if (snapshot.last_error.len != 0 and snapshot.status != .ready) {
                gui.textWrapped(snapshot.last_error);
            }
            gui.separator();
            _ = runtime.drawUtilityInCurrentWindow(snapshot.handle, .{
                .world = layer_context.world,
                .allocator = layer_context.world.allocator,
                .command_queue = layer_context.command_queue,
                .delta_seconds = layer_context.delta_seconds,
                .selection = layer_context.renderer.selectedEntities(),
                .selection_api = .{
                    .context = layer_context,
                    .select_entity = editorUtilitySelectEntity,
                    .clear_selection = editorUtilityClearSelection,
                },
            });
        }

        gui.dummy(0.0, 6.0);
    }

    if (open_count == 0) {
        gui.textWrapped("No utility panels are currently open. Toggle Open above to render one here.");
    }
}

fn drawRegistry(
    runtime: *engine.script.EditorUtilityRuntime,
    snapshots: anytype,
) !void {
    for (snapshots, 0..) |snapshot, index| {
        gui.pushIdU64(@intFromEnum(snapshot.handle));
        defer gui.popId();

        if (index != 0) {
            gui.separator();
        }

        gui.text(snapshot.name);
        if (snapshot.description.len != 0) {
            gui.textWrapped(snapshot.description);
        }
        if (snapshot.source_path.len != 0) {
            gui.labelText("Source", snapshot.source_path);
        }
        gui.labelText("Status", statusLabel(snapshot.status));

        var is_open = snapshot.open;
        if (gui.checkbox("Open", &is_open)) {
            runtime.setOpen(snapshot.handle, is_open);
        }
        gui.sameLine();
        if (gui.button("Unload")) {
            _ = runtime.remove(snapshot.handle);
            continue;
        }

        if (snapshot.last_error.len != 0 and snapshot.status != .ready) {
            gui.textWrapped(snapshot.last_error);
        }
    }
}

fn statusLabel(status: engine.script.EditorUtilityStatus) []const u8 {
    return switch (status) {
        .ready => "ready",
        .load_error => "load_error",
        .init_error => "init_error",
        .update_error => "update_error",
    };
}

fn editorUtilitySelectEntity(context_ptr: *anyopaque, entity_id: engine.scene.EntityId, additive: bool) void {
    const layer_context: *engine.core.LayerContext = @ptrCast(@alignCast(context_ptr));
    if (additive) {
        layer_context.renderer.toggleSelection(entity_id) catch {};
    } else {
        layer_context.renderer.replaceSelection(entity_id) catch {};
    }
}

fn editorUtilityClearSelection(context_ptr: *anyopaque) void {
    const layer_context: *engine.core.LayerContext = @ptrCast(@alignCast(context_ptr));
    layer_context.renderer.replaceSelection(null) catch {};
}
