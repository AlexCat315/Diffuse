const std = @import("std");
const engine = @import("guava");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const EditorState = @import("state.zig").EditorState;
const utils = @import("../common/utils.zig");
const ai_collaboration = @import("../ai_native/collaboration.zig");
const camera = @import("../interaction/camera.zig");
const mesh_edit = @import("../interaction/mesh_edit.zig");
const manipulation = @import("../interaction/manipulation.zig");
const viewport = @import("../ui/viewport.zig");
const icon_cache = @import("../ui/icon_cache.zig");
const content_browser = @import("../assets/browser.zig");
const asset_preview = @import("../assets/preview.zig");
const history = @import("../actions/history.zig");
const vfx_runtime = @import("../runtime/vfx.zig");
const layout = @import("../ui/layout.zig");
const animation_editor = @import("../ui/panels/tools/animation_editor.zig");
const sequencer_panel = @import("../ui/panels/tools/sequencer_panel.zig");
const editor_utilities = @import("../ui/panels/debug/editor_utilities.zig");
const prefab_browser = @import("../ui/panels/assets/prefab_browser.zig");
const particle_editor = @import("../ui/panels/tools/particle_editor.zig");
const script_editor = @import("../ui/panels/tools/script_editor.zig");
const physics_visualization = @import("../ui/panels/rendering/physics_visualization.zig");
const post_process_editor = @import("../ui/panels/rendering/post_process_editor.zig");
const prefab_editor = @import("../ui/panels/assets/prefab_editor.zig");
const camera_bookmarks = @import("../ui/panels/viewport/camera_bookmarks.zig");
const rhi_stats = @import("../ui/panels/debug/rhi_stats.zig");
const plugin_manager = @import("../ui/panels/debug/plugin_manager.zig");
const script_debugger = @import("../ui/panels/debug/script_debugger.zig");
const style_inspector = @import("../ui/panels/rendering/style_inspector.zig");
const render_queue = @import("../ui/panels/rendering/render_queue.zig");
const audio_mixer = @import("../ui/panels/debug/audio_mixer.zig");
const preferences = @import("preferences.zig");

fn initEditorStyle() void {
    const p = theme.Palette;
    const br = theme.BorderRadius;

    // ── Text ──────────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.text), p.text_primary);
    gui.setStyleColor(@intFromEnum(gui.Col.text_disabled), p.text_muted);

    // ── Backgrounds ───────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.window_bg), p.bg.panel);
    gui.setStyleColor(@intFromEnum(gui.Col.child_bg), p.bg.child_bg);
    gui.setStyleColor(@intFromEnum(gui.Col.popup_bg), p.bg.popup_bg);
    gui.setStyleColor(@intFromEnum(gui.Col.modal_window_dim_bg), p.bg.modal_bg);

    // ── Borders & Separators ──────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.border), p.bg.panel_border);
    gui.setStyleColor(@intFromEnum(gui.Col.separator), p.separator);
    gui.setStyleColor(@intFromEnum(gui.Col.separator_hovered), p.interactive.accent_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.separator_active), p.interactive.accent);

    // ── Frames (inputs, combos, sliders) ──────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg), p.interactive.frame_bg);
    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg_hovered), p.interactive.frame_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.frame_bg_active), p.interactive.frame_active);

    // ── Title Bars ────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.title_bg), p.bg.title_bar);
    gui.setStyleColor(@intFromEnum(gui.Col.title_bg_active), p.bg.title_bar);
    gui.setStyleColor(@intFromEnum(gui.Col.title_bg_collapsed), p.bg.menu_bar);

    // ── Menu Bar ──────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.menu_bar_bg), p.bg.menu_bar);

    // ── Scrollbars ────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_bg), p.bg.dock_area);
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab), p.layer.scrollbar_grab);
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab_hovered), p.layer.scrollbar_grab_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.scrollbar_grab_active), p.layer.scrollbar_grab_active);

    // ── Headers (tree nodes, collapsing headers) ──────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.header), p.selection.bg);
    gui.setStyleColor(@intFromEnum(gui.Col.header_hovered), p.selection.hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.header_active), p.selection.border);

    // ── Buttons ───────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.button), p.interactive.button_bg);
    gui.setStyleColor(@intFromEnum(gui.Col.button_hovered), p.interactive.button_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.button_active), p.interactive.accent);

    // ── Tabs ──────────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.tab), p.layer.tab);
    gui.setStyleColor(@intFromEnum(gui.Col.tab_hovered), p.layer.tab_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.tab_active), p.layer.tab_active);
    gui.setStyleColor(@intFromEnum(gui.Col.tab_unfocused), p.layer.tab_unfocused);
    gui.setStyleColor(@intFromEnum(gui.Col.tab_unfocused_active), p.layer.tab_unfocused_active);

    // ── Docking & Drag-Drop ───────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.docking_preview), p.selection.bg);
    gui.setStyleColor(@intFromEnum(gui.Col.drag_drop_target), p.ai.accent);
    gui.setStyleColor(@intFromEnum(gui.Col.nav_highlight), p.ai.accent);
    gui.setStyleColor(@intFromEnum(gui.Col.text_selected_bg), p.selection.bg);

    // ── Widgets ───────────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.slider_grab), p.interactive.accent);
    gui.setStyleColor(@intFromEnum(gui.Col.slider_grab_active), p.interactive.accent_active);
    gui.setStyleColor(@intFromEnum(gui.Col.check_mark), p.interactive.accent);

    // ── Resize Grips ──────────────────────────────────────────────────────
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip), p.layer.resize_grip);
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip_hovered), p.interactive.accent_hovered);
    gui.setStyleColor(@intFromEnum(gui.Col.resize_grip_active), p.ai.accent);

    // ── Style Variables (UE style: tighter, squarer) ──────────────────────
    gui.setStyleVarFloat(100, 1.0); // WindowBorderSize
    gui.setStyleVarFloat(101, 1.0); // FrameBorderSize
    gui.setStyleVarFloat(102, br.control); // FrameRounding
}

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
    animation_editor_state: ?animation_editor.AnimationEditorState = null,
    sequencer_editor_state: ?sequencer_panel.SequencerEditorState = null,
    render_queue_state: render_queue.RenderQueueState = .{},
    particle_editor_state: particle_editor.ParticleEditorState = .{},
    script_editor_state: ?script_editor.ScriptEditorState = null,
    script_debugger_state: script_debugger.ScriptDebuggerState = .{},
    post_process_editor_state: ?post_process_editor.PostProcessPipelineEditorState = null,
    post_process_viewport_state: engine.render.EditorViewportState = .{},
    prefab_editor_state: prefab_editor.PrefabEditorState = .{},
    physics_viz_settings: physics_visualization.PhysicsVisualizationSettings = .{},
    physics_debug_draw_mode: physics_visualization.PhysicsDebugDrawMode = .off,
    camera_bookmark_manager: ?camera_bookmarks.CameraBookmarkManager = null,

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
        try gui.init(layer_context.window, layer_context.rhi());

        initEditorStyle();
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

        self.state.dock_layout_initialized = false;
        self.state.scene_camera = layer_context.world.primaryCameraEntity();
        self.state.ai_chat_open = false;

        // Initialize animation editor state
        self.animation_editor_state = try animation_editor.createAnimationEditorState(layer_context.world.allocator);

        // Initialize sequencer editor state
        self.sequencer_editor_state = try sequencer_panel.createSequencerEditorState(layer_context.world.allocator);

        // Initialize tool panel states
        self.script_editor_state = script_editor.ScriptEditorState.init(layer_context.world.allocator);
        self.post_process_editor_state = post_process_editor.PostProcessPipelineEditorState.init(layer_context.world.allocator);
        seedPostProcessViewportState(&self.state, &self.post_process_viewport_state);
        self.camera_bookmark_manager = camera_bookmarks.CameraBookmarkManager.init(layer_context.world.allocator);

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
    }

    fn onDetach(context: *anyopaque) void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));
        preferences.saveEditorPreferences(&self.state) catch |err| {
            std.log.warn("Editor: failed to save editor preferences: {s}", .{@errorName(err)});
        };
        preferences.saveAiProviderSettings(&self.state) catch |err| {
            std.log.warn("Editor: failed to save AI provider settings: {s}", .{@errorName(err)});
        };
        icon_cache.clearIconCache(&self.state);
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

            // Cleanup animation editor state
            if (self.animation_editor_state) |*editor_state| {
                animation_editor.destroyAnimationEditorState(editor_state, allocator);
                self.animation_editor_state = null;
            }

            // Cleanup sequencer editor state
            if (self.sequencer_editor_state) |*seq_state| {
                sequencer_panel.destroySequencerEditorState(seq_state, allocator);
                self.sequencer_editor_state = null;
            }

            // Cleanup render queue state
            self.render_queue_state.deinit(allocator);

            // Cleanup tool panel states
            if (self.script_editor_state) |*s| {
                s.deinit();
                self.script_editor_state = null;
            }
            if (self.post_process_editor_state) |*s| {
                s.deinit();
                self.post_process_editor_state = null;
            }
            if (self.camera_bookmark_manager) |*m| {
                m.deinit();
                self.camera_bookmark_manager = null;
            }
            self.particle_editor_state.deinit();
            self.prefab_editor_state.deinit(allocator);

            if (self.state.ai_preview_runtime) |*runtime| {
                runtime.deinit();
                self.state.ai_preview_runtime = null;
            }
        }

        layout.releaseLayoutTemplates(&self.state);
        content_browser.clearAssetBrowser(&self.state);
        self.state.clearOwnedClipboards();
        if (self.state.asset_registry) |*registry| {
            registry.deinit();
            self.state.asset_registry = null;
        }
        history.clearSnapshotHistory(&self.state);
        gui.shutdown();
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) !void {
        const self: *EditorLayer = @ptrCast(@alignCast(context));

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
        gui.beginDockspace();
        if (!self.state.dock_layout_initialized) {
            std.log.info("Editor: Initializing default dock layout", .{});
            gui.resetDefaultLayout();
            gui.saveLayout();
            self.state.dock_layout_initialized = true;
        }
        try viewport.drawEditorUi(&self.state, &self.post_process_viewport_state, layer_context);
        try content_browser.flushMaterialThumbnailRequests(&self.state, layer_context);
        try content_browser.flushModelThumbnailRequests(&self.state, layer_context);
        const mesh_edit_consumed = try mesh_edit.handleEditingShortcuts(&self.state, layer_context);
        if (!mesh_edit_consumed and !mesh_edit.isEditModeActive(&self.state)) {
            try manipulation.handleEditingShortcuts(&self.state, layer_context);
        }
        manipulation.updateActiveTransform(&self.state, layer_context);
        camera.handleCameraControls(&self.state, layer_context);
        try viewport.handleViewportSelection(&self.state, layer_context);
        try mesh_edit.syncSession(&self.state, layer_context);
        manipulation.refreshGizmoState(&self.state, layer_context);
        ai_collaboration.syncContext(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI collaboration context: {s}", .{@errorName(err)});
        };
        ai_collaboration.syncPreviewWorld(&self.state, layer_context) catch |err| {
            std.log.warn("failed to sync AI preview world: {s}", .{@errorName(err)});
            layer_context.renderer.setPreviewScene(null);
            layer_context.renderer.setPreviewGizmoTransform(null);
        };

        // Draw animation editor window if open
        if (self.state.animation_editor_open) {
            if (self.animation_editor_state) |*editor_state| {
                try animation_editor.drawAnimationEditorWindow(&self.state, layer_context, editor_state);
            }
        }

        // Draw sequencer window if open
        if (self.state.sequencer_open) {
            if (self.sequencer_editor_state) |*seq_state| {
                try sequencer_panel.drawSequencerWindow(&self.state, layer_context, seq_state);
            }
        }

        // Draw render queue window if open + tick the queue
        if (self.state.render_queue_open) {
            try render_queue.drawRenderQueueWindow(&self.state, layer_context, &self.render_queue_state);
        }
        try render_queue.tickRenderQueue(&self.state, layer_context, &self.render_queue_state);

        if (self.state.prefab_browser_open) {
            try prefab_browser.drawPrefabBrowserWindow(&self.state, layer_context);
        }

        if (layer_context.editor_utility_runtime) |utility_runtime| {
            if (utility_runtime.takeHostOpenRequest()) {
                self.state.editor_utilities_open = true;
            }
        }

        if (self.state.editor_utilities_open) {
            try editor_utilities.drawEditorUtilitiesWindow(&self.state, layer_context);
        }

        // Draw migrated tool panels
        if (self.state.particle_editor_open) {
            try particle_editor.drawParticleEditorWindow(&self.state, layer_context, &self.particle_editor_state);
        }
        if (self.state.script_editor_open) {
            if (self.script_editor_state) |*es| {
                // Handle pending open/create requests from the asset browser
                if (self.state.pending_new_script_path) |new_path| {
                    if (self.state.pending_new_script_template) |template| {
                        // Write template to file, then open
                        if (std.fs.cwd().createFile(new_path, .{})) |file| {
                            file.writeAll(template) catch {};
                            file.close();
                            es.loadFromFile(new_path) catch {};
                            content_browser.refreshAssetBrowser(&self.state, layer_context) catch {};
                        } else |_| {}
                    }
                    self.state.pending_new_script_path = null;
                    self.state.pending_new_script_template = null;
                }
                if (self.state.pending_script_open_path) |open_path| {
                    es.loadFromFile(open_path) catch {};
                    self.state.pending_script_open_path = null;
                }
                try script_editor.drawScriptEditorWindow(&self.state, layer_context, es);
            }
        }
        if (self.state.physics_visualization_open) {
            try physics_visualization.drawPhysicsVisualizationWindow(&self.state, &self.physics_viz_settings, &self.physics_debug_draw_mode);
        }
        if (self.state.post_process_editor_open) {
            if (self.post_process_editor_state) |*es| {
                try post_process_editor.drawPostProcessPipelineEditorWindow(&self.state, layer_context, es, &self.post_process_viewport_state);
            }
        }
        if (self.state.prefab_editor_open) {
            try prefab_editor.drawPrefabEditorWindow(&self.state, layer_context, &self.prefab_editor_state);
        }
        if (self.state.camera_bookmarks_open) {
            if (self.camera_bookmark_manager) |*bm| {
                try camera_bookmarks.drawCameraBookmarkWindow(&self.state, layer_context, bm);
            }
        }
        if (self.state.rhi_stats_open) {
            rhi_stats.drawRhiStatsWindow(&self.state, layer_context);
        }
        if (self.state.plugin_manager_open) {
            plugin_manager.drawPluginManagerWindow(&self.state, layer_context);
        }
        if (self.state.script_debugger_open) {
            try script_debugger.drawScriptDebuggerWindow(&self.state, layer_context, &self.script_debugger_state);
        }
        if (self.state.style_inspector_open) {
            style_inspector.drawStyleInspectorWindow(&self.state, layer_context);
        }
        if (self.state.audio_mixer_open) {
            audio_mixer.drawAudioMixerWindow(&self.state, layer_context);
        }
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
