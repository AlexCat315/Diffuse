const std = @import("std");
const engine = @import("guava");
const text_mod = @import("../common/text.zig");
const command_mod = @import("../actions/command.zig");
const input_mod = engine.core;

pub const autosave_path = "assets/scenes/editor_autosave.guava_scene";
pub const entity_drag_payload = "guava.scene.entity";
pub const asset_model_drag_payload = "guava.asset.model";
pub const asset_material_drag_payload = "guava.asset.material";
pub const asset_texture_drag_payload = "guava.asset.texture";
pub const place_actor_drag_payload = "guava.editor.place_actor";

// 缓冲区大小常量，避免硬编码
pub const inspector_name_buffer_size = 256;
pub const inspector_filter_buffer_size = 128;
pub const hierarchy_rename_buffer_size = 256;
pub const scene_filter_buffer_size = 128;
pub const hierarchy_filter_buffer_size = 128;
pub const place_actor_filter_buffer_size = 128;
pub const asset_filter_buffer_size = 128;
pub const settings_filter_buffer_size = 128;
pub const asset_directory_buffer_size = 256;
pub const layout_template_name_buffer_size = 128;
pub const render_output_path_buffer_size = 256;
pub const render_output_status_buffer_size = 256;
pub const build_game_output_buffer_size = 4096;
pub const project_root_buffer_size = 512;
pub const project_name_buffer_size = 128;

pub const AssetKind = enum {
    scene,
    model,
    material,
    texture,
    shader,
    script,
    directory,
    unknown,
};

pub const AssetEntry = struct {
    id: []u8,
    path: []u8,
    display_path: []u8,
    name: []u8,
    kind: AssetKind,
    is_directory: bool = false,
};

pub const IconTextureEntry = struct {
    path: []u8,
    width: u32,
    height: u32,
    tint: [4]u8,
    has_tint: bool,
    texture: engine.rhi.Texture,
};

pub const ImageThumbnailEntry = struct {
    path: []u8,
    texture: engine.rhi.Texture,
};

pub const ManipulationMode = enum {
    none,
    translate,
    rotate,
    scale,
};

pub const PlaybackState = engine.core.PlaybackState;

pub const TransformSpace = @import("guava").editor_rpc.schema.types.TransformSpace;

pub const TransformPivotMode = enum {
    origin,
    bounds_center,
    median_point,
    active_element,
    cursor,
    individual_origins,
};

pub const ManipulationEntityOrigin = struct {
    entity_id: engine.scene.EntityId,
    world_transform: engine.scene.Transform,
    pivot_local_offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const TranslationSnapTarget = enum {
    grid,
    surface,
    vertex,
};

pub const MeshEditMode = enum {
    object,
    edit,
};

pub const MeshElementSelectionMode = enum {
    vertex,
    edge,
    face,
};

pub const MeshShortcutBinding = struct {
    key: input_mod.InputKey,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn matches(self: MeshShortcutBinding, input: *const input_mod.InputState) bool {
        return input.wasKeyPressed(self.key) and
            input.modifiers.ctrl == self.ctrl and
            input.modifiers.shift == self.shift and
            input.modifiers.alt == self.alt;
    }
};

pub const MeshEditShortcutConfig = struct {
    extrude: MeshShortcutBinding = .{ .key = .e },
    inset: MeshShortcutBinding = .{ .key = .i },
    bevel: MeshShortcutBinding = .{ .key = .b },
    loop_cut: MeshShortcutBinding = .{ .key = .r, .ctrl = true },
    merge: MeshShortcutBinding = .{ .key = .m },
    duplicate: MeshShortcutBinding = .{ .key = .d, .shift = true },
    separate: MeshShortcutBinding = .{ .key = .p },
    recalc_normals: MeshShortcutBinding = .{ .key = .n, .shift = true },
    pivot_to_selection: MeshShortcutBinding = .{ .key = .period },
};

pub const ManipulationTarget = enum {
    main_world,
    staged_preview,
};

pub const GizmoDragMode = enum {
    none,
    mouse_delta,
    move_plane,
    move_axis,
    rotate_ring,
    uniform_scale,
    axis_scale,
};

pub const GizmoDragSession = struct {
    mode: GizmoDragMode = .none,
    picked_mode: ManipulationMode = .none,
    picked_axis: engine.math.axis.Axis3 = .free,
    plane_origin: [3]f32 = .{ 0.0, 0.0, 0.0 },
    plane_normal: [3]f32 = .{ 0.0, 0.0, -1.0 },
    handle_axis_world: [3]f32 = .{ 1.0, 0.0, 0.0 },
    drag_start_ray_origin: [3]f32 = .{ 0.0, 0.0, 0.0 },
    drag_start_ray_direction: [3]f32 = .{ 0.0, 0.0, -1.0 },
    drag_start_point: [3]f32 = .{ 0.0, 0.0, 0.0 },
    drag_start_vector: [3]f32 = .{ 1.0, 0.0, 0.0 },
    drag_start_distance: f32 = 1.0,
    draw_scale: f32 = 1.0,
};

pub const HierarchyCategory = enum {
    all,
    cameras,
    lights,
    geometry,
    objects,
};

pub const PlaceActorCategory = enum {
    basics,
    lights,
    shapes,
    vfx,
};

pub const PlaceActorKind = enum {
    empty,
    camera,
    cube,
    sphere,
    plane,
    textured_cube,
    textured_sphere,
    textured_plane,
    point_light,
    spot_light,
    directional_light,
    vfx_fountain,
    vfx_orbit,
};

pub const LayoutTemplateEntry = struct {
    name: []u8,
    path: []u8,
};

pub const LeftPanelTab = enum {
    scene,
    place_actors,
};

pub const BottomWorkspaceTab = enum {
    content_browser,
    console,
    command_timeline,
    ai_assistant,
};

pub const FpsDisplayMode = enum {
    viewport,
    status_bar,
    none,
};

pub const SettingsTab = enum {
    general,
    shortcuts,
};

pub const SettingsCategory = enum {
    general,
    interface,
    editor,
    inspector,
    theme,
    viewport,
    rendering,
    camera,
    shortcuts,
    ai,
    assistant,
    advanced,
};

pub const BrowserViewMode = enum {
    grid,
    list,
};

pub const AssetSortMode = enum {
    name_asc,
    name_desc,
    kind_asc,
    kind_desc,
};

pub const ViewportRenderMode = enum {
    textured,
    wireframe,
    unlit,
};

pub const ViewportPipelineMode = enum {
    raster,
    path_trace,
};

pub const BuildGameStatus = enum {
    idle,
    building,
    success,
    failed,
};

pub const LaunchGameStatus = enum {
    idle,
    building,
    launching,
    running,
    failed,
};

pub const ViewportShadingMode = @import("guava").editor_rpc.schema.types.ViewportShadingMode;

pub fn viewportShadingMode(state: *const EditorState) ViewportShadingMode {
    if (state.viewport_pipeline_mode == .path_trace) {
        return .rendered;
    }
    return switch (state.viewport_render_mode) {
        .textured => .material,
        .wireframe => .wireframe,
        .unlit => .solid,
    };
}

pub fn setViewportShadingMode(state: *EditorState, mode: ViewportShadingMode) bool {
    const entering_rendered = state.viewport_pipeline_mode != .path_trace and mode == .rendered;
    switch (mode) {
        .solid => {
            state.viewport_pipeline_mode = .raster;
            state.viewport_render_mode = .unlit;
        },
        .material => {
            state.viewport_pipeline_mode = .raster;
            state.viewport_render_mode = .textured;
        },
        .rendered => {
            state.viewport_pipeline_mode = .path_trace;
            state.viewport_render_mode = .textured;
        },
        .wireframe => {
            state.viewport_pipeline_mode = .raster;
            state.viewport_render_mode = .wireframe;
        },
    }
    return entering_rendered;
}

pub const ViewportLutPreset = engine.render.EditorViewportLutPreset;

pub const ViewportViewPreset = enum {
    perspective,
    top,
    side,
    custom,
};

pub const RenderOutputResolutionPreset = enum {
    viewport,
    hd_1080,
    dci_2k,
    uhd_4k,
    custom,
};

pub const RenderOutputFormat = enum {
    png,
    exr,
};

pub const RenderOutputStatus = enum {
    idle,
    queued,
    rendering,
    writing,
    success,
    failure,
};

pub const RenderOutputJobStage = enum {
    idle,
    resize_and_render,
    export_pending,
    restore_pending,
};

pub const VideoCodec = enum {
    h264,
    h265,
    prores,
};

fn renderOutputFormatExtension(format: RenderOutputFormat) []const u8 {
    return switch (format) {
        .png => ".png",
        .exr => ".exr",
    };
}

fn lastPathSeparatorIndex(path: []const u8) ?usize {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    if (slash) |lhs| {
        if (backslash) |rhs| {
            return @max(lhs, rhs);
        }
        return lhs;
    }
    return backslash;
}

fn allocRenderOutputPath(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    format: RenderOutputFormat,
    frame_number: ?u32,
) ![]u8 {
    if (base_path.len == 0) return error.InvalidPath;

    const extension = renderOutputFormatExtension(format);
    if (base_path[base_path.len - 1] == '/' or base_path[base_path.len - 1] == '\\') {
        return if (frame_number) |frame|
            std.fmt.allocPrint(allocator, "{s}frame_{d:0>4}{s}", .{ base_path, frame, extension })
        else
            std.fmt.allocPrint(allocator, "{s}frame{s}", .{ base_path, extension });
    }

    var stem = base_path;
    if (std.mem.lastIndexOfScalar(u8, base_path, '.')) |dot| {
        if (lastPathSeparatorIndex(base_path)) |separator| {
            if (dot > separator) {
                stem = base_path[0..dot];
            }
        } else {
            stem = base_path[0..dot];
        }
    }

    return if (frame_number) |frame|
        std.fmt.allocPrint(allocator, "{s}_{d:0>4}{s}", .{ stem, frame, extension })
    else
        std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, extension });
}

fn writeFixedBuffer(buffer: []u8, value: []const u8) void {
    @memset(buffer, 0);
    const copy_len = @min(value.len, buffer.len - 1);
    @memcpy(buffer[0..copy_len], value[0..copy_len]);
}

fn fixedBufferSlice(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

pub const AxisConstraint = engine.math.axis.Axis3;

pub const PendingViewportDropSource = enum {
    asset,
    place_actor,
};

pub const ActiveDragPayloadKind = enum {
    entity,
    asset_model,
    asset_material,
    asset_texture,
    place_actor,
};

pub const ActiveDragPayload = struct {
    kind: ActiveDragPayloadKind,
    entity_id: ?engine.scene.EntityId = null,
    asset_index: ?usize = null,
    actor_kind: ?PlaceActorKind = null,
};

pub const PendingViewportDrop = struct {
    source_kind: PendingViewportDropSource,
    asset_index: ?usize = null,
    actor_kind: ?PlaceActorKind = null,
    pixel: ?[2]u32 = null,
    target_entity: ?engine.scene.EntityId = null,
    world_position: ?[3]f32 = null,
};

pub const MeshComponentClipboard = struct {
    component: engine.scene.Mesh,
    asset_id: ?[]u8 = null,

    fn deinit(self: *MeshComponentClipboard, allocator: std.mem.Allocator) void {
        if (self.asset_id) |asset_id| {
            allocator.free(asset_id);
        }
        self.* = undefined;
    }
};

pub const MaterialComponentClipboard = struct {
    component: engine.scene.Material,
    asset_id: ?[]u8 = null,

    fn deinit(self: *MaterialComponentClipboard, allocator: std.mem.Allocator) void {
        if (self.asset_id) |asset_id| {
            allocator.free(asset_id);
        }
        self.* = undefined;
    }
};

pub const AiPreviewRuntime = struct {
    world: engine.scene.World,
    transaction_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, job_system: anytype) AiPreviewRuntime {
        return .{
            .world = engine.scene.World.init(allocator, job_system),
        };
    }

    pub fn clear(self: *AiPreviewRuntime) void {
        self.world.clear();
        self.transaction_id = null;
    }

    pub fn deinit(self: *AiPreviewRuntime) void {
        self.world.deinit();
        self.* = undefined;
    }
};

pub const max_ai_providers: usize = 8;

pub const AiProviderType = enum {
    openai,
    anthropic,
    ollama,
    custom,
};

/// Per-provider configuration stored in EditorState.
pub const AiProviderConfig = struct {
    provider_type: AiProviderType = .openai,
    name: [64]u8 = [_]u8{0} ** 64,
    endpoint: [256]u8 = [_]u8{0} ** 256,
    model: [128]u8 = [_]u8{0} ** 128,
    api_key: [256]u8 = [_]u8{0} ** 256,

    /// Returns the human-readable name as a slice (up to the first NUL).
    /// Falls back to "New Provider" when the name buffer is empty.
    pub fn displayName(self: *const AiProviderConfig) []const u8 {
        const len = std.mem.indexOfScalar(u8, self.name[0..], 0) orelse self.name.len;
        return if (len > 0) self.name[0..len] else "New Provider";
    }
};

pub const EditorState = struct {
    allocator: ?std.mem.Allocator = null,
    ai_collaboration: ?*engine.mcp.collaboration.Store = null,
    ai_snapshot_store: ?*engine.mcp.resources.SnapshotStore = null,
    ai_tool_bridge: ?*engine.mcp.tools.Bridge = null,
    ai_collaboration_bridge: ?*engine.mcp.collaboration.Bridge = null,
    ai_preview_runtime: ?AiPreviewRuntime = null,
    ai_preview_entities: std.ArrayList(engine.scene.EntityId) = .empty,
    ai_preview_selected_entity: ?engine.scene.EntityId = null,
    editor_camera: ?engine.scene.EntityId = null,
    scene_camera: ?engine.scene.EntityId = null,
    scene_root_entity: ?engine.scene.EntityId = null,
    inspector_name_entity: ?engine.scene.EntityId = null,
    inspector_name_buffer: [inspector_name_buffer_size]u8 = [_]u8{0} ** inspector_name_buffer_size,
    inspector_filter_buffer: [inspector_filter_buffer_size]u8 = [_]u8{0} ** inspector_filter_buffer_size,
    hierarchy_rename_entity: ?engine.scene.EntityId = null,
    hierarchy_rename_buffer: [256]u8 = [_]u8{0} ** 256,
    hierarchy_rename_focus_pending: bool = false,
    editor_camera_active: bool = true,
    camera_drag_active: bool = false,
    focus_pivot: [3]f32 = .{ 0.0, 1.1, 0.0 },
    yaw: f32 = 0.0,
    pitch: f32 = -0.12, // startup view: face teddy slightly from above
    orbit_distance: f32 = 3.4, // startup view: close enough to read texture detail
    look_sensitivity: f32 = 0.008,
    orbit_sensitivity: f32 = 0.01,
    pan_sensitivity: f32 = 0.01,
    wheel_speed: f32 = 1.2,
    move_speed: f32 = 6.0,
    camera_boost_multiplier: f32 = 3.5,
    translation_drag_sensitivity: f32 = 0.0025,
    rotation_drag_sensitivity: f32 = 0.01,
    scale_drag_sensitivity: f32 = 0.01,
    mesh_edit_mode: MeshEditMode = .object,
    mesh_edit_entity: ?engine.scene.EntityId = null,
    mesh_edit_selection_mode: MeshElementSelectionMode = .face,
    mesh_edit_selected_elements: std.ArrayList(u32) = .empty,
    mesh_edit_shortcuts: MeshEditShortcutConfig = .{},
    mesh_modal_drag_sensitivity: f32 = 0.005,
    mesh_modal_fine_scale: f32 = 0.25,
    transform_pivot_mode: TransformPivotMode = .origin,
    transform_cursor_world_position: [3]f32 = .{ 0.0, 0.0, 0.0 },
    transform_cursor_place_mode: bool = false,
    translation_snap_enabled: bool = false,
    translation_snap_target: TranslationSnapTarget = .grid,
    surface_snap_align_rotation_to_normal: bool = false,
    translation_snap_step: f32 = 10.0,
    rotation_snap_enabled: bool = false,
    rotation_snap_step_degrees: f32 = 15.0,
    scale_snap_enabled: bool = false,
    scale_snap_step: f32 = 0.1,
    manipulation_mode: ManipulationMode = .none,
    manipulation_axis: AxisConstraint = .free,
    manipulation_entity: ?engine.scene.EntityId = null,
    manipulation_origin: engine.scene.Transform = .{},
    manipulation_pivot_local_offset: [3]f32 = .{ 0.0, 0.0, 0.0 },
    manipulation_selection_signature: u64 = 0,
    manipulation_group_origins: std.ArrayList(ManipulationEntityOrigin) = .empty,
    manipulation_batch_snapshot: std.ArrayList(command_mod.EntitySnapshot) = .empty,
    manipulation_drag_active: bool = false,
    manipulation_keyboard_mode: bool = false, // Blender-style: keyboard activates, mouse moves freely, click confirms
    manipulation_started_from_ui: bool = false, // 记录拖拽是否从UI元素开始，防止事件穿透
    manipulation_drag_accumulator: [2]f32 = .{ 0.0, 0.0 },
    manipulation_accumulated_delta: [2]f32 = .{ 0.0, 0.0 }, // 用于记录单次操作中鼠标的累计X/Y偏移
    gizmo_drag_session: GizmoDragSession = .{},
    manipulation_snapshot: ?command_mod.EntitySnapshot = null,
    transform_component_clipboard: ?engine.scene.Transform = null,
    mesh_component_clipboard: ?MeshComponentClipboard = null,
    material_component_clipboard: ?MaterialComponentClipboard = null,
    camera_component_clipboard: ?engine.scene.Camera = null,
    light_component_clipboard: ?engine.scene.Light = null,
    vfx_component_clipboard: ?engine.scene.Vfx = null,
    playback_state: PlaybackState = .stopped,
    play_mode_active: bool = false,
    transform_space: TransformSpace = .local,
    manipulation_target: ManipulationTarget = .main_world,
    undo_stack: std.ArrayList(command_mod.EditorCommand) = .empty,
    redo_stack: std.ArrayList(command_mod.EditorCommand) = .empty,
    timeline_entries: std.ArrayList(command_mod.TimelineEntry) = .empty,
    next_timeline_sequence: u64 = 1,
    max_timeline_entries: usize = 256,
    timeline_preview_sequence: ?u64 = null,
    timeline_preview_target_cursor: ?usize = null,
    timeline_hover_preview_confirm_mode: bool = true,
    max_history_commands: usize = 64,
    saved_command_cursor: ?usize = null,
    history_world_snapshot: ?[]u8 = null,
    history_snapshot_needs_refresh: bool = false,
    project_root_buffer: [project_root_buffer_size]u8 = [_]u8{0} ** project_root_buffer_size,
    project_content_root_buffer: [project_root_buffer_size]u8 = [_]u8{0} ** project_root_buffer_size,
    project_name_buffer: [project_name_buffer_size]u8 = [_]u8{0} ** project_name_buffer_size,
    project_start_scene_buffer: [project_root_buffer_size]u8 = [_]u8{0} ** project_root_buffer_size,
    asset_registry: ?engine.assets.AssetRegistry = null,
    asset_entries: std.ArrayList(AssetEntry) = .empty,
    asset_directories: std.ArrayList([]u8) = .empty,
    selected_asset_index: ?usize = null,
    // Asset rename state
    asset_rename_index: ?usize = null,
    asset_rename_buffer: [256]u8 = [_]u8{0} ** 256,
    asset_rename_focus_pending: bool = false,
    // Folder rename state
    folder_rename_active: bool = false,
    folder_rename_original: [256]u8 = [_]u8{0} ** 256,
    folder_rename_buffer: [256]u8 = [_]u8{0} ** 256,
    folder_rename_focus_pending: bool = false,
    // New folder state
    new_folder_pending: bool = false,
    new_folder_focus_pending: bool = false,
    new_folder_name_buffer: [256]u8 = [_]u8{0} ** 256,
    scene_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    hierarchy_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    hierarchy_category: HierarchyCategory = .all,
    place_actor_category: PlaceActorCategory = .basics,
    place_actor_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    place_actor_texture_picker_primitive: ?engine.scene.Primitive = null,
    place_actor_texture_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    asset_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    asset_directory_buffer: [256]u8 = [_]u8{0} ** 256,
    asset_thumbnail_size: f32 = 96.0,
    browser_view_mode: BrowserViewMode = .grid,
    // Asset type filter (null = show all)
    asset_kind_filter: ?AssetKind = null,
    // Sort mode
    asset_sort_mode: AssetSortMode = .name_asc,
    // Multi-selection (bitset indexed by asset index; up to 4096 assets)
    asset_selected_set: std.StaticBitSet(4096) = std.StaticBitSet(4096).initEmpty(),
    asset_last_selected_index: ?usize = null,
    // Clipboard for copy/cut/paste
    asset_clipboard_paths: std.ArrayList([]u8) = .empty,
    asset_clipboard_is_cut: bool = false,

    // Material thumbnail render queue (asset IDs pending render)
    material_thumbnail_queue: std.ArrayList([]const u8) = .empty,

    // Model thumbnail render queue (file paths pending 3D render)
    model_thumbnail_queue: std.ArrayList([]const u8) = .empty,

    left_panel_tab: LeftPanelTab = .scene,
    bottom_workspace_tab: BottomWorkspaceTab = .content_browser,
    bottom_drawer_open: bool = true,
    bottom_drawer_height: f32 = 380.0,
    shell_show_left_sidebar: bool = true,
    shell_show_right_sidebar: bool = true,
    shell_left_sidebar_width: f32 = 320.0,
    shell_right_sidebar_width: f32 = 380.0,
    shell_dense_mode: bool = false,
    ghost_highlight_enabled: bool = true,
    ghost_highlight_pulse_speed: f32 = 1.85,
    ghost_highlight_alpha_min: f32 = 0.30,
    ghost_highlight_alpha_max: f32 = 0.92,
    ghost_highlight_show_preview_selection_only: bool = false,
    fps_display_mode: FpsDisplayMode = .viewport,
    vsync_enabled: bool = true,
    fps_overlay_display_fps: f32 = 0.0,
    fps_overlay_display_frame_ms: f32 = 0.0,
    fps_overlay_display_refresh_hz: ?f32 = null,
    fps_overlay_last_sample_time: f64 = -1.0,
    console_show_errors: bool = true,
    console_show_warnings: bool = true,
    console_show_info: bool = true,
    console_show_debug: bool = true,
    console_auto_scroll: bool = true,
    settings_open: bool = false,
    settings_category: SettingsCategory = .general,
    settings_filter_buffer: [settings_filter_buffer_size]u8 = [_]u8{0} ** settings_filter_buffer_size,
    settings_advanced_mode: bool = false,
    settings_tab: SettingsTab = .general,
    settings_section_general_open: bool = true,
    settings_section_interface_open: bool = true,
    settings_section_viewport_open: bool = true,
    settings_section_ai_open: bool = true,
    render_settings_open: bool = false,
    material_editor_open: bool = false,
    material_editor_preview_primitive: engine.scene.Primitive = .sphere,
    editor_utilities_open: bool = false,
    animation_editor_open: bool = false,
    sequencer_open: bool = false,
    render_queue_open: bool = false,
    ai_chat_open: bool = false,
    ai_provider_settings_open: bool = false,
    ai_providers: [max_ai_providers]AiProviderConfig = [_]AiProviderConfig{.{}} ** max_ai_providers,
    ai_provider_count: usize = 1,
    ai_active_provider: usize = 0,
    ai_provider_api_key_visible: bool = false,
    ai_provider_type: AiProviderType = .openai,
    layout_template_name_buffer: [128]u8 = [_]u8{0} ** 128,
    layout_templates: std.ArrayList(LayoutTemplateEntry) = .empty,
    layout_templates_loaded: bool = false,
    viewport_render_mode: ViewportRenderMode = .textured,
    viewport_pipeline_mode: ViewportPipelineMode = .raster,
    viewport_path_trace_samples: u32 = 8,
    viewport_path_trace_bounces: u32 = 3,
    viewport_path_trace_resolution_scale: f32 = 0.75,
    render_output_resolution_preset: RenderOutputResolutionPreset = .hd_1080,
    render_output_format: RenderOutputFormat = .png,
    render_output_width: u32 = 1920,
    render_output_height: u32 = 1080,
    render_output_samples: u32 = 256,
    render_output_bounces: u32 = 8,
    render_output_path_trace_denoise: bool = true,
    render_output_path_trace_write_aovs: bool = true,
    render_output_sequence_enabled: bool = false,
    render_output_sequence_start_frame: u32 = 0,
    render_output_sequence_frame_count: u32 = 10,
    render_output_sequence_fps: u32 = 24,
    render_output_path_buffer: [render_output_path_buffer_size]u8 = [_]u8{0} ** render_output_path_buffer_size,
    render_output_status_buffer: [render_output_status_buffer_size]u8 = [_]u8{0} ** render_output_status_buffer_size,
    render_output_status: RenderOutputStatus = .idle,
    render_output_job_stage: RenderOutputJobStage = .idle,
    render_output_job_is_sequence: bool = false,
    render_output_job_total_frames: u32 = 1,
    render_output_job_frame_index: u32 = 0,
    render_output_job_started_playback: bool = false,
    render_output_restore_samples: u32 = 4,
    render_output_restore_bounces: u32 = 2,
    render_output_restore_resolution_scale: f32 = 0.75,
    // Cinematic Sequence-driven render output
    render_output_use_cinematic_sequence: bool = false,
    render_output_cinematic_sequence_path: [256]u8 = [_]u8{0} ** 256,
    render_output_cinematic_sequence: ?*engine.cinematic.Sequence = null,
    render_output_cinematic_applied_frame: u32 = std.math.maxInt(u32),
    // FFmpeg video encoding after sequence render
    render_output_encode_video: bool = false,
    render_output_video_codec: VideoCodec = .h264,
    viewport_view_preset: ViewportViewPreset = .perspective,
    viewport_show_grid: bool = true,
    viewport_show_bones: bool = false,
    viewport_show_collision: bool = false,
    // 曝光作为编辑器视口后处理参数，默认关闭以保持现有观感不变。
    viewport_exposure_enabled: bool = false,
    viewport_exposure: f32 = 1.0,
    // Bloom 作为 HDR 预览后处理参数，默认关闭，避免改变现有项目观感。
    viewport_bloom_enabled: bool = false,
    viewport_bloom_threshold: f32 = 1.1,
    viewport_bloom_intensity: f32 = 0.22,
    // Color Grading 作为视口预览参数，不写回场景资源。
    viewport_color_grading_enabled: bool = false,
    viewport_color_grading_saturation: f32 = 1.0,
    viewport_color_grading_contrast: f32 = 1.0,
    viewport_color_grading_gamma: f32 = 1.0,
    viewport_fxaa_enabled: bool = false,
    viewport_rt_shadows_enabled: bool = false,
    viewport_rt_shadow_samples: u32 = 8,
    viewport_rt_shadow_strength: f32 = 0.85,
    viewport_rt_shadow_softness: f32 = 0.015,
    viewport_rt_shadow_resolution_scale: f32 = 1.0,
    viewport_taa_enabled: bool = false,
    viewport_lut_enabled: bool = false,
    viewport_lut_intensity: f32 = 1.0,
    viewport_lut_preset: ViewportLutPreset = .neutral,
    viewport_hovered: bool = false,
    viewport_focused: bool = false,
    viewport_has_image: bool = false,
    viewport_overlay_hovered: bool = false,
    viewport_origin: [2]f32 = .{ 0.0, 0.0 },
    viewport_extent: [2]f32 = .{ 1.0, 1.0 }, // 使用 1x1 作为安全默认值，防止除零错误
    viewport_selection_press_active: bool = false,
    viewport_selection_press_mouse: [2]f32 = .{ 0.0, 0.0 },
    viewport_context_menu_pending: bool = false,
    viewport_context_menu_mouse: [2]f32 = .{ 0.0, 0.0 },
    active_drag_payload: ?ActiveDragPayload = null,
    pending_viewport_drop: ?PendingViewportDrop = null,

    // Prefab 编辑器状态
    prefab_browser_open: bool = false,
    particle_editor_open: bool = false,
    physics_visualization_open: bool = false,
    post_process_editor_open: bool = false,
    rhi_stats_open: bool = false,
    plugin_manager_open: bool = false,
    style_inspector_open: bool = false,
    prefab_editor_open: bool = false,
    camera_bookmarks_open: bool = false,
    script_editor_open: bool = false,
    script_debugger_open: bool = false,
    // Pending request to open a script file in the Script Editor (set by browser, consumed by layer)
    pending_script_open_path: ?[]const u8 = null,
    // Pending request to create a new script file (path to write, then open)
    pending_new_script_path: ?[]const u8 = null,
    pending_new_script_template: ?[]const u8 = null,

    // Build Game state
    build_game_status: BuildGameStatus = .idle,
    build_game_output: [build_game_output_buffer_size]u8 = [_]u8{0} ** build_game_output_buffer_size,
    build_game_output_len: usize = 0,
    build_game_thread: ?std.Thread = null,

    // Launch Game state
    launch_game_status: LaunchGameStatus = .idle,
    launch_game_output: [build_game_output_buffer_size]u8 = [_]u8{0} ** build_game_output_buffer_size,
    launch_game_output_len: usize = 0,
    launch_game_thread: ?std.Thread = null,

    // Audio Mixer panel
    audio_mixer_open: bool = false,
    selected_prefab_id: ?[]const u8 = null,
    editing_prefab_id: ?[]const u8 = null,
    prefab_browser_search_buffer: [128]u8 = [_]u8{0} ** 128,
    prefab_instance_show_overrides: bool = true,

    playback_toolbar_window_initialized: bool = false,
    playback_toolbar_offset: [2]f32 = .{ 0.0, 0.0 },
    playback_toolbar_custom_position: bool = false,
    playback_toolbar_drag_active: bool = false,
    playback_toolbar_drag_offset: [2]f32 = .{ 0.0, 0.0 },
    top_bar_drag_active: bool = false,
    top_bar_drag_offset: [2]f32 = .{ 0.0, 0.0 },
    preview_device: ?*engine.rhi.LegacyDevice = null,
    icon_device: ?*engine.rhi.LegacyDevice = null,
    preview_texture: ?engine.rhi.Texture = null,
    preview_texture_key: ?[]u8 = null,
    preview_texture_size: [2]u32 = .{ 0, 0 },
    icon_textures: std.ArrayList(IconTextureEntry) = .empty,
    image_thumbnail_textures: std.ArrayListUnmanaged(ImageThumbnailEntry) = .empty,
    image_thumbnail_device: ?*engine.rhi.LegacyDevice = null,
    image_thumbnail_failed: std.ArrayListUnmanaged([]u8) = .empty,
    frozen_entities: std.ArrayList(engine.scene.EntityId) = .empty,
    selection_locked_entities: std.ArrayList(engine.scene.EntityId) = .empty,
    view_cube_transition_active: bool = false,
    view_cube_transition_elapsed: f32 = 0.0,
    view_cube_transition_duration: f32 = 0.22,
    view_cube_transition_start_yaw: f32 = 0.0,
    view_cube_transition_start_pitch: f32 = 0.0,
    view_cube_transition_target_yaw: f32 = 0.0,
    view_cube_transition_target_pitch: f32 = 0.0,
    view_cube_transition_target_orthographic: bool = false,

    pub fn text(self: *const EditorState, id: text_mod.MessageId) []const u8 {
        _ = self;
        return text_mod.text(id);
    }

    pub fn windowLabel(self: *const EditorState, buffer: []u8, id: text_mod.MessageId, stable_id: []const u8) ![]const u8 {
        _ = self;
        return text_mod.panelLabel(buffer, id, stable_id);
    }

    pub fn renderOutputPath(self: *const EditorState) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.render_output_path_buffer[0..], 0) orelse self.render_output_path_buffer.len;
        return self.render_output_path_buffer[0..end];
    }

    pub fn renderOutputFrameNumber(self: *const EditorState, frame_index: u32) u32 {
        return self.render_output_sequence_start_frame + frame_index;
    }

    pub fn renderOutputResolvedPathAlloc(self: *const EditorState, allocator: std.mem.Allocator, frame_number: ?u32) ![]u8 {
        return allocRenderOutputPath(allocator, self.renderOutputPath(), self.render_output_format, frame_number);
    }

    pub fn renderOutputStatusText(self: *const EditorState) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.render_output_status_buffer[0..], 0) orelse self.render_output_status_buffer.len;
        return self.render_output_status_buffer[0..end];
    }

    pub fn projectPath(self: *const EditorState) []const u8 {
        return fixedBufferSlice(self.project_root_buffer[0..]);
    }

    pub fn projectContentPath(self: *const EditorState) []const u8 {
        return fixedBufferSlice(self.project_content_root_buffer[0..]);
    }

    pub fn projectName(self: *const EditorState) []const u8 {
        return fixedBufferSlice(self.project_name_buffer[0..]);
    }

    pub fn projectStartScene(self: *const EditorState) []const u8 {
        return fixedBufferSlice(self.project_start_scene_buffer[0..]);
    }

    pub fn hasProjectContext(self: *const EditorState) bool {
        return self.projectPath().len > 0;
    }

    pub fn setProjectContext(self: *EditorState, project_root: []const u8, project_name: []const u8, content_dir: []const u8, start_scene: ?[]const u8) void {
        writeFixedBuffer(self.project_root_buffer[0..], project_root);
        writeFixedBuffer(self.project_name_buffer[0..], project_name);

        var content_path_buffer: [project_root_buffer_size]u8 = undefined;
        const content_path = std.fmt.bufPrint(&content_path_buffer, "{s}/{s}", .{ project_root, content_dir }) catch project_root;
        writeFixedBuffer(self.project_content_root_buffer[0..], content_path);

        if (start_scene) |scene_path| {
            if (std.fs.path.isAbsolute(scene_path)) {
                writeFixedBuffer(self.project_start_scene_buffer[0..], scene_path);
            } else {
                var scene_buffer: [project_root_buffer_size]u8 = undefined;
                const absolute_scene_path = std.fmt.bufPrint(&scene_buffer, "{s}/{s}", .{ project_root, scene_path }) catch scene_path;
                writeFixedBuffer(self.project_start_scene_buffer[0..], absolute_scene_path);
            }
        } else {
            @memset(self.project_start_scene_buffer[0..], 0);
        }
    }

    pub fn ensureRenderOutputDefaults(self: *EditorState) void {
        if (self.renderOutputPath().len != 0) {
            return;
        }

        const default_path = "renders_test_out/frame.png";
        @memcpy(self.render_output_path_buffer[0..default_path.len], default_path);
    }

    pub fn setMeshComponentClipboard(self: *EditorState, world: *engine.scene.World, component: engine.scene.Mesh) !void {
        const allocator = self.allocator orelse world.allocator;
        self.clearMeshComponentClipboard();

        var asset_id_copy: ?[]u8 = null;
        errdefer if (asset_id_copy) |asset_id| allocator.free(asset_id);

        if (component.handle) |handle| {
            if (world.assets().meshAssetId(handle)) |asset_id| {
                asset_id_copy = try allocator.dupe(u8, asset_id);
            }
        }

        self.mesh_component_clipboard = .{
            .component = component,
            .asset_id = asset_id_copy,
        };
    }

    pub fn resolveMeshComponentClipboard(self: *const EditorState, world: *engine.scene.World) !?engine.scene.Mesh {
        const clipboard = self.mesh_component_clipboard orelse return null;
        var component = clipboard.component;

        if (component.handle != null) {
            if (clipboard.asset_id) |asset_id| {
                if (world.assets().meshHandleByAssetId(asset_id)) |handle| {
                    component.handle = handle;
                } else if (component.primitive != .custom) {
                    component.handle = try world.assets().ensurePrimitiveMesh(component.primitive);
                } else {
                    return null;
                }
            } else if (component.primitive != .custom) {
                component.handle = try world.assets().ensurePrimitiveMesh(component.primitive);
            } else {
                return null;
            }
        }

        return component;
    }

    pub fn setMaterialComponentClipboard(self: *EditorState, world: *engine.scene.World, component: engine.scene.Material) !void {
        const allocator = self.allocator orelse world.allocator;
        self.clearMaterialComponentClipboard();

        var asset_id_copy: ?[]u8 = null;
        errdefer if (asset_id_copy) |asset_id| allocator.free(asset_id);

        if (component.handle) |handle| {
            if (world.assets().materialAssetId(handle)) |asset_id| {
                asset_id_copy = try allocator.dupe(u8, asset_id);
            }
        }

        self.material_component_clipboard = .{
            .component = component,
            .asset_id = asset_id_copy,
        };
    }

    pub fn resolveMaterialComponentClipboard(self: *const EditorState, world: *engine.scene.World) ?engine.scene.Material {
        const clipboard = self.material_component_clipboard orelse return null;
        var component = clipboard.component;

        if (component.handle != null) {
            component.handle = if (clipboard.asset_id) |asset_id|
                world.assets().materialHandleByAssetId(asset_id)
            else
                null;
        }

        return component;
    }

    pub fn clearOwnedClipboards(self: *EditorState) void {
        self.clearMeshComponentClipboard();
        self.clearMaterialComponentClipboard();
    }

    fn clearMeshComponentClipboard(self: *EditorState) void {
        const allocator = self.allocator orelse {
            self.mesh_component_clipboard = null;
            return;
        };
        if (self.mesh_component_clipboard) |*clipboard| {
            clipboard.deinit(allocator);
            self.mesh_component_clipboard = null;
        }
    }

    fn clearMaterialComponentClipboard(self: *EditorState) void {
        const allocator = self.allocator orelse {
            self.material_component_clipboard = null;
            return;
        };
        if (self.material_component_clipboard) |*clipboard| {
            clipboard.deinit(allocator);
            self.material_component_clipboard = null;
        }
    }

    pub fn setSelectedPrefabId(self: *EditorState, prefab_id: ?[]const u8) !void {
        const allocator = self.allocator orelse return error.AllocatorNotInitialized;
        if (self.selected_prefab_id) |existing| {
            allocator.free(existing);
            self.selected_prefab_id = null;
        }
        if (prefab_id) |id| {
            self.selected_prefab_id = try allocator.dupe(u8, id);
        }
    }

    pub fn setEditingPrefabId(self: *EditorState, prefab_id: ?[]const u8) !void {
        const allocator = self.allocator orelse return error.AllocatorNotInitialized;
        if (self.editing_prefab_id) |existing| {
            allocator.free(existing);
            self.editing_prefab_id = null;
        }
        if (prefab_id) |id| {
            self.editing_prefab_id = try allocator.dupe(u8, id);
        }
    }

    pub fn deinit(self: *EditorState) void {
        const allocator = self.allocator orelse return;
        if (self.ai_preview_runtime) |*runtime| {
            runtime.deinit();
            self.ai_preview_runtime = null;
        }
        self.ai_preview_entities.deinit(allocator);
        self.ai_preview_entities = .empty;
        self.ai_preview_selected_entity = null;
        self.clearOwnedClipboards();
        self.mesh_edit_selected_elements.deinit(allocator);
        self.mesh_edit_selected_elements = .empty;
        self.mesh_edit_entity = null;
        if (self.manipulation_snapshot) |*snapshot| {
            snapshot.deinit(allocator);
            self.manipulation_snapshot = null;
        }
        for (self.manipulation_batch_snapshot.items) |*snapshot| {
            snapshot.deinit(allocator);
        }
        self.manipulation_batch_snapshot.deinit(allocator);
        self.manipulation_batch_snapshot = .empty;
        self.manipulation_group_origins.deinit(allocator);
        self.manipulation_group_origins = .empty;

        for (self.undo_stack.items) |*command| {
            command.deinit(allocator);
        }
        self.undo_stack.deinit(allocator);

        for (self.redo_stack.items) |*command| {
            command.deinit(allocator);
        }
        self.redo_stack.deinit(allocator);

        for (self.timeline_entries.items) |*entry| {
            entry.deinit(allocator);
        }
        self.timeline_entries.deinit(allocator);

        if (self.history_world_snapshot) |snapshot| {
            allocator.free(snapshot);
            self.history_world_snapshot = null;
        }

        // 释放 asset_entries 中的每个条目
        for (self.asset_entries.items) |entry| {
            allocator.free(entry.id);
            allocator.free(entry.path);
            allocator.free(entry.display_path);
            allocator.free(entry.name);
        }
        self.asset_entries.deinit(allocator);

        // 释放 asset_directories 中的每个目录路径
        for (self.asset_directories.items) |dir| {
            allocator.free(dir);
        }
        self.asset_directories.deinit(allocator);

        // 释放 material_thumbnail_queue 中的每个资产 ID
        for (self.material_thumbnail_queue.items) |asset_id| {
            allocator.free(asset_id);
        }
        self.material_thumbnail_queue.deinit(allocator);

        // 释放 model_thumbnail_queue 中的每个路径
        for (self.model_thumbnail_queue.items) |path| {
            allocator.free(path);
        }
        self.model_thumbnail_queue.deinit(allocator);

        // 释放 layout_templates 中的每个模板条目
        for (self.layout_templates.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.path);
        }
        self.layout_templates.deinit(allocator);

        // 释放 icon_textures 中的每个条目（纹理由 RHI 管理，只释放路径）
        for (self.icon_textures.items) |entry| {
            allocator.free(entry.path);
        }
        self.icon_textures.deinit(allocator);

        // 释放 image_thumbnail_textures
        if (self.image_thumbnail_device) |device| {
            for (self.image_thumbnail_textures.items) |*entry| {
                device.releaseTexture(&entry.texture);
                allocator.free(entry.path);
            }
        } else {
            for (self.image_thumbnail_textures.items) |entry| {
                allocator.free(entry.path);
            }
        }
        self.image_thumbnail_textures.deinit(allocator);
        for (self.image_thumbnail_failed.items) |p| {
            allocator.free(p);
        }
        self.image_thumbnail_failed.deinit(allocator);

        // 释放 frozen_entities 和 selection_locked_entities（只是 EntityId 数组，无需释放内部）
        self.frozen_entities.deinit(allocator);
        self.selection_locked_entities.deinit(allocator);

        // 释放 preview_texture_key
        if (self.preview_texture_key) |key| {
            allocator.free(key);
            self.preview_texture_key = null;
        }

        // 释放 asset_registry（如果存在）
        if (self.asset_registry) |*registry| {
            registry.deinit();
            self.asset_registry = null;
        }

        // 释放 Prefab 相关状态
        if (self.selected_prefab_id) |id| {
            allocator.free(id);
            self.selected_prefab_id = null;
        }
        if (self.editing_prefab_id) |id| {
            allocator.free(id);
            self.editing_prefab_id = null;
        }

        // 注意：preview_device 和 icon_device 是外部指针，不在此释放
        // preview_texture 由 RHI 管理，不在此释放
    }
};

pub const AnimationEditorState = struct {
    selected_clip: ?engine.assets.handles.AnimationClipHandle = null,
    selected_graph: ?*engine.animation.animation_graph.AnimationGraph = null,
    timeline_scale: f32 = 1.0,
    timeline_offset: f32 = 0.0,
    current_time: f32 = 0.0,
    is_playing: bool = false,
    selected_track: ?u32 = null,
    selected_keyframe: ?u32 = null,
    selected_bone: ?u32 = null,
    show_bone_hierarchy: bool = true,
    show_skinning: bool = true,
    bone_filter_buffer: [128]u8 = [_]u8{0} ** 128,
    last_updated_clip: ?engine.assets.handles.AnimationClipHandle = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.selected_graph) |graph| {
            graph.deinit(allocator);
            allocator.destroy(graph);
        }
        self.* = undefined;
    }
};

test "viewport drop defaults and payload constants stay stable" {
    try std.testing.expectEqualStrings("guava.asset.model", asset_model_drag_payload);
    try std.testing.expectEqualStrings("guava.asset.material", asset_material_drag_payload);
    try std.testing.expectEqualStrings("guava.asset.texture", asset_texture_drag_payload);
    try std.testing.expectEqualStrings("guava.editor.place_actor", place_actor_drag_payload);

    const state = EditorState{};
    try std.testing.expectEqual(ViewportViewPreset.perspective, state.viewport_view_preset);
    try std.testing.expectEqual(PlaceActorCategory.basics, state.place_actor_category);
    try std.testing.expectEqual(FpsDisplayMode.viewport, state.fps_display_mode);
    try std.testing.expect(state.vsync_enabled);
    try std.testing.expect(!state.translation_snap_enabled);
    try std.testing.expectEqual(@as(f32, 10.0), state.translation_snap_step);
    try std.testing.expect(!state.rotation_snap_enabled);
    try std.testing.expectEqual(@as(f32, 15.0), state.rotation_snap_step_degrees);
    try std.testing.expect(!state.scale_snap_enabled);
    try std.testing.expectEqual(@as(f32, 0.1), state.scale_snap_step);
    try std.testing.expectEqual(@as(f32, 3.5), state.camera_boost_multiplier);
    try std.testing.expectEqual(@as(f32, 0.0025), state.translation_drag_sensitivity);
    try std.testing.expectEqual(@as(f32, 0.01), state.rotation_drag_sensitivity);
    try std.testing.expectEqual(@as(f32, 0.01), state.scale_drag_sensitivity);
    try std.testing.expectEqual(MeshEditMode.object, state.mesh_edit_mode);
    try std.testing.expectEqual(@as(?engine.scene.EntityId, null), state.mesh_edit_entity);
    try std.testing.expectEqual(MeshElementSelectionMode.face, state.mesh_edit_selection_mode);
    try std.testing.expectEqual(@as(usize, 0), state.mesh_edit_selected_elements.items.len);
    try std.testing.expectEqual(TransformPivotMode.origin, state.transform_pivot_mode);
    try std.testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, state.transform_cursor_world_position);
    try std.testing.expect(!state.transform_cursor_place_mode);
    try std.testing.expectEqual(TranslationSnapTarget.grid, state.translation_snap_target);
    try std.testing.expect(!state.surface_snap_align_rotation_to_normal);
    try std.testing.expect(!state.manipulation_drag_active);
    try std.testing.expectEqual([3]f32{ 0.0, 0.0, 0.0 }, state.manipulation_pivot_local_offset);
    try std.testing.expectEqual(@as(u64, 0), state.manipulation_selection_signature);
    try std.testing.expectEqual(@as(usize, 0), state.manipulation_group_origins.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.manipulation_batch_snapshot.items.len);
    try std.testing.expectEqual([2]f32{ 0.0, 0.0 }, state.manipulation_drag_accumulator);
    try std.testing.expectEqual(GizmoDragMode.none, state.gizmo_drag_session.mode);
    try std.testing.expect(state.pending_viewport_drop == null);

    const pending = PendingViewportDrop{
        .source_kind = .asset,
        .asset_index = 7,
    };
    try std.testing.expectEqual(PendingViewportDropSource.asset, pending.source_kind);
    try std.testing.expectEqual(@as(?usize, 7), pending.asset_index);
    try std.testing.expectEqual(@as(?PlaceActorKind, null), pending.actor_kind);
    try std.testing.expectEqual(@as(?[2]u32, null), pending.pixel);
    try std.testing.expectEqual(@as(?engine.scene.EntityId, null), pending.target_entity);
    try std.testing.expectEqual(@as(?[3]f32, null), pending.world_position);
}

test "render output path resolution normalizes extension and sequence suffix" {
    var state = EditorState{};
    const png_path = "renders_test_out/frame";
    @memcpy(state.render_output_path_buffer[0..png_path.len], png_path);

    const single_png = try state.renderOutputResolvedPathAlloc(std.testing.allocator, null);
    defer std.testing.allocator.free(single_png);
    try std.testing.expectEqualStrings("renders_test_out/frame.png", single_png);

    state.render_output_format = .exr;
    const exr_sequence = try state.renderOutputResolvedPathAlloc(std.testing.allocator, 12);
    defer std.testing.allocator.free(exr_sequence);
    try std.testing.expectEqualStrings("renders_test_out/frame_0012.exr", exr_sequence);

    @memset(state.render_output_path_buffer[0..], 0);
    const directory_path = "renders_test_out/";
    @memcpy(state.render_output_path_buffer[0..directory_path.len], directory_path);
    const directory_sequence = try state.renderOutputResolvedPathAlloc(std.testing.allocator, 3);
    defer std.testing.allocator.free(directory_sequence);
    try std.testing.expectEqualStrings("renders_test_out/frame_0003.exr", directory_sequence);
}
