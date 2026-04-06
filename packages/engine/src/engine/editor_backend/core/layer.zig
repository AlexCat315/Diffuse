const std = @import("std");
const engine = @import("guava");
const EditorState = @import("state.zig").EditorState;
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
const camera = @import("../interaction/camera.zig");
const mesh_edit = @import("../interaction/mesh_edit.zig");
const manipulation = @import("../interaction/manipulation.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const history = @import("../actions/history.zig");
const vfx_runtime = @import("../runtime/vfx.zig");
const render_queue = @import("../rendering/render_queue.zig");
const preferences = @import("preferences.zig");

fn seedPostProcessViewportState(state: *const EditorState, viewport_state: *engine.render.EditorViewportState) void {
    viewport_state.exposure_enabled = state.viewport_exposure_enabled;
    viewport_state.exposure = state.viewport_exposure;
    viewport_state.bloom_enabled = state.viewport_bloom_enabled;
    viewport_state.bloom_threshold = state.viewport_bloom_threshold;
    viewport_state.bloom_intensity = state.viewport_bloom_intensity;
    viewport_state.color_grading_enabled = state.viewport_color_grading_enabled;
    viewport_state.color_grading_saturation = state.viewport_color_grading_saturation;
    viewport_state.color_grading_contrast = state.viewport_color_grading_contrast;
    viewport_state.color_grading_gamma = state.viewport_color_grading_gamma;
    viewport_state.fxaa_enabled = state.viewport_fxaa_enabled;
    viewport_state.rt_shadows_enabled = state.viewport_rt_shadows_enabled;
    viewport_state.rt_shadow_samples = state.viewport_rt_shadow_samples;
    viewport_state.rt_shadow_strength = state.viewport_rt_shadow_strength;
    viewport_state.rt_shadow_softness = state.viewport_rt_shadow_softness;
    viewport_state.rt_shadow_resolution_scale = state.viewport_rt_shadow_resolution_scale;
    viewport_state.taa_enabled = state.viewport_taa_enabled;
    viewport_state.lut_enabled = state.viewport_lut_enabled;
    viewport_state.lut_intensity = state.viewport_lut_intensity;
    viewport_state.lut_preset = state.viewport_lut_preset;
}

pub const EditorLayer = struct {
    state: EditorState = .{},
    render_queue_state: render_queue.RenderQueueState = .{},
    post_process_viewport_state: engine.render.EditorViewportState = .{},

    pub fn asLayer(self: *EditorLayer) engine.core.Layer {
        return .{
            .name = "Editor",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_detach = onDetach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        self.state.allocator = layer_context.world.allocator;
        self.state.ai_preview_runtime = .init(layer_context.world.allocator, layer_context.world.job_system);
        self.state.preview_device = layer_context.rhi();
        self.state.icon_device = layer_context.rhi();
        self.state.asset_registry = engine.assets.AssetRegistry.init(layer_context.world.allocator);
        preferences.loadEditorPreferences(&self.state) catch |err| {
            std.log.warn("Editor: failed to load editor preferences: {s}", .{@errorName(err)});
        };
        preferences.loadAiProviderSettings(&self.state) catch |err| {
            std.log.warn("Editor: failed to load AI provider settings: {s}", .{@errorName(err)});
        };
        layer_context.renderer.setVSyncEnabled(self.state.vsync_enabled) catch |err| {
            std.log.warn("Editor: failed to apply VSync preference: {s}", .{@errorName(err)});
        };
        self.state.vsync_enabled = layer_context.renderer.vsyncEnabled();

        // Default to Material preview on startup so imported model textures are visible immediately.
        _ = @import("state.zig").setViewportShadingMode(&self.state, .material);

        self.state.scene_camera = layer_context.world.primaryCameraEntity();
        self.state.ai_chat_open = false;

        seedPostProcessViewportState(&self.state, &self.post_process_viewport_state);

        try camera.createEditorCamera(&self.state, layer_context);
        manipulation.refreshGizmoState(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        try history.resetSnapshotHistory(&self.state, layer_context);
        try content_browser.refreshAssetBrowser(&self.state, layer_context);

        // Discover project plugins via unified PluginRegistry → StyleRegistry flow.
        layer_context.renderer.discoverPlugins("project_plugins");

        // Restore persisted render style selection from EditorViewportState → StyleRegistry.
        const persisted_style = layer_context.renderer.editor_viewport_state.activeRenderStyleName();
        if (persisted_style.len > 0) {
            _ = layer_context.renderer.styleRegistry().setActiveStyle(persisted_style);
        }

        // Auto-load the project's start scene so the editor doesn't start empty.
        const start_scene = self.state.projectStartScene();
        if (start_scene.len > 0) {
            // Only attempt load if the file actually exists (avoids clearing
            // transform tools & VFX state in loadScenePath for no reason).
            if (std.fs.cwd().access(start_scene, .{})) |_| {
                std.log.info("Editor: auto-loading start scene: {s}", .{start_scene});
                const entity_count_before = layer_context.world.entities.items.len;
                history.loadScenePath(&self.state, layer_context, start_scene) catch {};
                // loadScenePath swallows deserialization errors with a bare
                // return (not error return).  If the world was cleared but
                // deserialization failed, the entity list will be empty.
                if (layer_context.world.entities.items.len == 0 and entity_count_before > 0) {
                    std.log.warn("Editor: scene load left world empty — restoring default scene", .{});
                    layer_context.world.bootstrap3D() catch |boot_err| {
                        std.log.err("Editor: failed to re-bootstrap: {s}", .{@errorName(boot_err)});
                    };
                    try camera.createEditorCamera(&self.state, layer_context);
                    manipulation.refreshGizmoState(&self.state, layer_context);
                    utils.syncInspectorNameBuffer(&self.state, layer_context);
                    try history.resetSnapshotHistory(&self.state, layer_context);
                }
            } else |_| {
                std.log.info("Editor: start scene not found, skipping auto-load: {s}", .{start_scene});
            }
            // Track the configured path so scene.save writes to the correct file.
            if (layer_context.scene_manager) |sm| {
                sm.setCurrentScenePath(start_scene) catch {};
            }
        }
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        preferences.saveEditorPreferences(&self.state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
        preferences.saveAiProviderSettings(&self.state) catch |err| {
            std.log.warn("Editor: failed to save AI provider settings: {s}", .{@errorName(err)});
        };
        asset_preview.clearPreviewTexture(&self.state);
        self.state.preview_device = null;
        self.state.icon_device = null;

        if (self.state.allocator) |allocator| {
            self.state.frozen_entities.deinit(allocator);
            self.state.frozen_entities = .empty;
            self.state.selection_locked_entities.deinit(allocator);
            self.state.selection_locked_entities = .empty;
            self.state.ai_preview_entities.deinit(allocator);
            self.state.ai_preview_entities = .empty;
            self.state.ai_preview_selected_entity = null;

            // Cleanup render queue state
            self.render_queue_state.deinit(allocator);

            if (self.state.ai_preview_runtime) |*runtime| {
                runtime.deinit();
                self.state.ai_preview_runtime = null;
            }
        }

        content_browser.clearAssetBrowser(&self.state);
        self.state.clearOwnedClipboards();
        if (self.state.asset_registry) |*registry| {
            registry.deinit();
            self.state.asset_registry = null;
        }
        history.clearSnapshotHistory(&self.state);
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));

        // Recover editor infrastructure after world.clear() (e.g. playback
        // stop, scene reload).  The snapshot/deserialize path wipes
        // editor-only entities (camera, gizmo) because they are excluded
        // from serialization.
        if (self.state.editor_camera) |ec_id| {
            if (layer_context.world.getEntityConst(ec_id) == null) {
                self.state.editor_camera = null;
            }
        }
        if (self.state.editor_camera == null) {
            camera.createEditorCamera(&self.state, layer_context) catch |err| {
                std.log.err("Editor: failed to recover editor camera: {s}", .{@errorName(err)});
            };
            manipulation.refreshGizmoState(&self.state, layer_context);
            // world.clear() also destroys the ResourceLibrary — re-discover scripts.
            history.rediscoverProjectScripts(layer_context.world);
        }

        // In editor-server mode, sync viewport state from the renderer since
        // there is no imgui viewport panel to set these fields.
        if (self.state.editor_server_mode) {
            const sv = &layer_context.renderer.scene_viewport;
            self.state.viewport_extent = .{
                @floatFromInt(sv.width),
                @floatFromInt(sv.height),
            };
            self.state.viewport_origin = .{ 0.0, 0.0 };
        }

        ai_collaboration.beginFrame(&self.state);
        history.tickDeferredSnapshot(&self.state, layer_context.world);
        try mesh_edit.syncSession(&self.state, layer_context);
        try vfx_runtime.update(layer_context);
        try history.pruneMissingSelection(&self.state, layer_context);
        utils.pruneFrozenEntities(&self.state, layer_context.world);
        utils.pruneSelectionLockEntities(&self.state, layer_context.world);
        try utils.pruneFrozenSelection(&self.state, layer_context);
        try utils.pruneLockedSelection(&self.state, layer_context);
        utils.syncInspectorNameBuffer(&self.state, layer_context);
        // Handle OS file drop (glTF/glb → import as model)
        if (layer_context.pending_file_drop) |pending_ptr| {
            if (pending_ptr.*) |dropped_path| {
                handleFileDrop(&self.state, layer_context, dropped_path);
                std.heap.c_allocator.free(dropped_path);
                pending_ptr.* = null;
            }
        }
        try content_browser.flushMaterialThumbnailRequests(&self.state, layer_context);
        try content_browser.flushModelThumbnailRequests(&self.state, layer_context);
        const mesh_edit_consumed = try mesh_edit.handleEditingShortcuts(&self.state, layer_context);
        if (!mesh_edit_consumed and !mesh_edit.isEditModeActive(&self.state)) {
            try manipulation.handleEditingShortcuts(&self.state, layer_context);
        }
        manipulation.updateActiveTransform(&self.state, layer_context);
        // In editor-server mode, handle mesh element picking (vertex/edge/face)
        // when in mesh edit mode. Uses raycasting from cursor position.
        if (self.state.editor_server_mode and mesh_edit.isEditModeActive(&self.state)) {
            const input = layer_context.input;
            if (input.wasMousePressed(.left) and !input.modifiers.alt) {
                const sv = &layer_context.renderer.scene_viewport;
                if (sv.width > 0 and sv.height > 0) {
                    const mx: u32 = @intFromFloat(std.math.clamp(input.mouse_position[0], 0.0, @as(f32, @floatFromInt(sv.width -| 1))));
                    const my: u32 = @intFromFloat(std.math.clamp(input.mouse_position[1], 0.0, @as(f32, @floatFromInt(sv.height -| 1))));
                    if (camera.activeCameraRayFromViewportPixel(&self.state, layer_context, .{ mx, my }, .{ sv.width, sv.height })) |ray| {
                        const sel_mode: engine.render.SelectionUpdateMode = if (input.modifiers.shift or input.modifiers.ctrl) .toggle else .replace;
                        _ = try mesh_edit.handleViewportSelection(&self.state, layer_context, ray, sel_mode);
                    }
                }
            }
        }
        // In editor-server mode, detect gizmo handle clicks and initiate drag
        // sessions automatically. In the imgui path this was done by the UI;
        // here we do it in the update loop using the forwarded mouse events.
        if (self.state.editor_server_mode and !self.state.manipulation_drag_active) {
            const input = layer_context.input;
            if (input.wasMousePressed(.left) and !input.modifiers.alt and self.state.manipulation_mode != .none) {
                const sv = &layer_context.renderer.scene_viewport;
                if (sv.width > 0 and sv.height > 0) {
                    const mx: u32 = @intFromFloat(std.math.clamp(input.mouse_position[0], 0.0, @as(f32, @floatFromInt(sv.width -| 1))));
                    const my: u32 = @intFromFloat(std.math.clamp(input.mouse_position[1], 0.0, @as(f32, @floatFromInt(sv.height -| 1))));
                    if (camera.activeCameraRayFromViewportPixel(&self.state, layer_context, .{ mx, my }, .{ sv.width, sv.height })) |ray| {
                        if (manipulation.pickGizmoHandle(&self.state, layer_context, ray)) |handle| {
                            manipulation.beginGizmoHandleDrag(&self.state, layer_context, handle, ray) catch |err| {
                                std.log.err("Failed to begin gizmo drag: {s}", .{@errorName(err)});
                            };
                        }
                    }
                }
            }
        }
        // Suppress entity picking while a gizmo drag is active or while
        // in mesh edit mode (so viewport.pick doesn't change entity selection).
        layer_context.renderer.suppress_entity_pick = self.state.manipulation_drag_active or mesh_edit.isEditModeActive(&self.state);
        camera.handleCameraControls(&self.state, layer_context);
        try mesh_edit.syncSession(&self.state, layer_context);
        mesh_edit.refreshOverlay(&self.state, layer_context);
        manipulation.refreshGizmoState(&self.state, layer_context);
        ai_collaboration.syncContext(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI collaboration context: {s}", .{@errorName(err)});
        };
        ai_collaboration.syncPreviewWorld(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI preview world: {s}", .{@errorName(err)});
            layer_context.renderer.setPreviewScene(null);
            layer_context.renderer.setPreviewGizmoTransform(null);
        };

        // Tick render queue (background rendering jobs, runs even when panel is closed)
        try render_queue.tickRenderQueue(&self.state, layer_context, &self.render_queue_state);
    }

    fn handleFileDrop(state: *EditorState, layer_context: *engine.core.LayerContext, path: [:0]const u8) void {
        const ext = std.fs.path.extension(path);
        if (std.mem.eql(u8, ext, ".gltf") or std.mem.eql(u8, ext, ".glb")) {
            history.importModelPath(state, layer_context, path) catch |err| {
                std.log.err("Failed to import dropped model '{s}': {}", .{ path, err });
            };
        } else {
            std.log.info("Unsupported file drop extension: '{s}' ({s})", .{ ext, path });
        }
    }
};
