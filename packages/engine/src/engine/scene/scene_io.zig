const std = @import("std");
const asset_registry = @import("../assets/registry.zig");
const assets_handles = @import("../assets/handles.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const rhi_types = @import("../rhi/types.zig");
const script_types = @import("../script/types.zig");
const components = @import("components.zig");
const world_mod = @import("world.zig");

const current_scene_version: u32 = 6;
const runtime_scene_file_version: u32 = 7;

const SceneHeader = struct {
    version: u32 = 1,
};

const SceneFile = struct {
    version: u32 = current_scene_version,
    scene_id: []const u8,
    environment_asset_id: ?[]const u8 = null,
    asset_records: []asset_registry.AssetRecord,
    meshes: []MeshRecord,
    textures: []TextureRecord,
    materials: []MaterialRecord,
    skeletons: []SkeletonRecord = &.{},
    skins: []SkinRecord = &.{},
    animation_clips: []AnimationClipRecord = &.{},
    scripts: []ScriptRecord = &.{},
    entities: []EntityRecord,
};

pub const SceneRuntimeState = struct {
    global_time: f32 = 0.0,
    time_scale: f32 = 1.0,
    physics_accumulator_seconds: f32 = 0.0,
    playback_state: SceneRuntimePlaybackState = .stopped,
    game_state: SceneRuntimeGameState = .game_start,
};

pub const SceneRuntimePlaybackState = enum(u32) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

pub const SceneRuntimeGameState = enum(u32) {
    game_start = 0,
    playing = 1,
    paused = 2,
    game_over = 3,
    quit = 4,
};

const SceneRuntimeFile = struct {
    version: u32 = runtime_scene_file_version,
    scene: SceneFile,
    runtime_state: SceneRuntimeState = .{},
};

const MeshRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    primitive_type: rhi_types.PrimitiveType,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const TextureRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels_hex: []const u8,
};

const MaterialRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    shading: components.ShadingModel,
    base_color_factor: [4]f32,
    base_color_texture_asset_id: ?[]const u8 = null,
    metallic_roughness_texture_asset_id: ?[]const u8 = null,
    normal_texture_asset_id: ?[]const u8 = null,
    occlusion_texture_asset_id: ?[]const u8 = null,
    emissive_texture_asset_id: ?[]const u8 = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 0.0,
    roughness_factor: f32 = 0.5,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
};

const SkeletonJointRecord = struct {
    name: []const u8,
    node_entity_index: u32,
    parent_joint_index: ?u32 = null,
    rest_local_transform: components.Transform = .{},
};

const SkeletonRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    joints: []const SkeletonJointRecord,
};

const SkinRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    skeleton_asset_id: []const u8,
    joint_entity_indices: []const u32,
    inverse_bind_matrices: []const [16]f32,
};

const AnimationClipVec3TrackRecord = struct {
    target_entity_index: u32,
    interpolation: @import("../assets/animation_clip_resource.zig").Interpolation = .linear,
    times: []const f32,
    values: []const [3]f32,
};

const AnimationClipQuatTrackRecord = struct {
    target_entity_index: u32,
    interpolation: @import("../assets/animation_clip_resource.zig").Interpolation = .linear,
    times: []const f32,
    values: []const [4]f32,
};

const AnimationClipRecord = struct {
    asset_id: []const u8,
    name: []const u8,
    duration: f32,
    translation_tracks: []const AnimationClipVec3TrackRecord = &.{},
    rotation_tracks: []const AnimationClipQuatTrackRecord = &.{},
    scale_tracks: []const AnimationClipVec3TrackRecord = &.{},
};

const ScriptRecord = struct {
    asset_id: []const u8,
    language: components.ScriptLanguage,
    entry_fn: []const u8 = "main",
    description: []const u8 = "",
    source_path: []const u8 = "",
    artifact_path: []const u8 = "",
    last_modified: i128 = 0,
    source: []const u8,
    bytecode_hex: []const u8 = "",
    user_data: []const u8 = "",
};

const MeshComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    primitive: components.Primitive = .custom,
};

const SkinnedMeshComponentRecord = struct {
    mesh_asset_id: ?[]const u8 = null,
    primitive: components.Primitive = .custom,
    skeleton_asset_id: ?[]const u8 = null,
    skin_asset_id: ?[]const u8 = null,
};

const MaterialComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
};

const ScriptComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    language: components.ScriptLanguage = .zig,
    enabled: bool = true,
    parameters: []const u8 = "",
};

const AudioSourceComponentRecord = struct {
    clip_asset_path: ?[]const u8 = null,
    bus: components.AudioBus = .sfx,
    volume: f32 = 1.0,
    spatial: bool = false,
    looping: bool = false,
    play_on_awake: bool = true,
    min_distance: f32 = 1.0,
    max_distance: f32 = 100.0,
    doppler_factor: f32 = 1.0,
};

const AudioListenerComponentRecord = struct {
    enabled: bool = true,
};

const NavAgentComponentRecord = struct {
    radius: f32 = 0.6,
    height: f32 = 2.0,
    max_acceleration: f32 = 8.0,
    max_speed: f32 = 3.5,
    target: ?[3]f32 = null,
};

const AnimatorComponentRecord = struct {
    skeleton_asset_id: ?[]const u8 = null,
    default_clip_asset_id: ?[]const u8 = null,
    time_seconds: f32 = 0.0,
    next_clip_asset_id: ?[]const u8 = null,
    next_time_seconds: f32 = 0.0,
    blend_duration_seconds: f32 = 0.0,
    blend_time_seconds: f32 = 0.0,
    speed: f32 = 1.0,
    playing: bool = true,
    looping: bool = true,
};

const AnimationGraphParameterRecord = struct {
    name: []const u8,
    type: @import("../animation/animation_graph.zig").ParameterType,
    float_value: f32 = 0.0,
    bool_value: bool = false,
    int_value: i32 = 0,
};

const AnimationGraphParameterValueRecord = struct {
    type: @import("../animation/animation_graph.zig").ParameterType,
    float_value: f32 = 0.0,
    bool_value: bool = false,
    int_value: i32 = 0,
};

const AnimationGraphStateRecord = struct {
    name: []const u8,
    clip_asset_id: ?[]const u8 = null,
    speed: f32 = 1.0,
    loop: bool = true,
    duration_seconds: f32 = 0.0,
};

const AnimationGraphBlendSpacePoint1DRecord = struct {
    position: f32,
    clip_asset_id: []const u8,
};

const AnimationGraphBlendSpacePoint2DRecord = struct {
    position: [2]f32,
    clip_asset_id: []const u8,
};

const AnimationGraphBlendSpace1DRecord = struct {
    name: []const u8,
    points: []const AnimationGraphBlendSpacePoint1DRecord = &.{},
};

const AnimationGraphBlendSpace2DRecord = struct {
    name: []const u8,
    points: []const AnimationGraphBlendSpacePoint2DRecord = &.{},
};

const AnimationGraphTransitionConditionKind = enum {
    time_remaining,
    time_elapsed,
    parameter,
};

const AnimationGraphTransitionConditionComparison = enum {
    less,
    greater,
    equal,
};

const AnimationGraphTransitionConditionRecord = struct {
    kind: AnimationGraphTransitionConditionKind,
    threshold: f32 = 0.0,
    parameter_name: ?[]const u8 = null,
    comparison: AnimationGraphTransitionConditionComparison = .greater,
};

const AnimationGraphTransitionRecord = struct {
    from_state: u32,
    to_state: u32,
    duration: f32 = 0.2,
    conditions: []const AnimationGraphTransitionConditionRecord = &.{},
};

const AnimationGraphRecord = struct {
    name: []const u8,
    default_state: ?u32 = null,
    states: []const AnimationGraphStateRecord = &.{},
    blend_spaces_1d: []const AnimationGraphBlendSpace1DRecord = &.{},
    blend_spaces_2d: []const AnimationGraphBlendSpace2DRecord = &.{},
    transitions: []const AnimationGraphTransitionRecord = &.{},
    parameters: []const AnimationGraphParameterRecord = &.{},
};

const AnimationGraphInstanceRecord = struct {
    current_state: u32 = 0,
    next_state: ?u32 = null,
    transition_time: f32 = 0.0,
    transition_duration: f32 = 0.0,
    state_time: f32 = 0.0,
    parameters: []const AnimationGraphParameterValueRecord = &.{},
};

const RigidbodyRecord = struct {
    motion_type: components.RigidbodyMotionType = .dynamic,
    mass: f32 = 1.0,
    linear_velocity: [3]f32 = .{ 0.0, 0.0, 0.0 },
    gravity_scale: f32 = 1.0,
    linear_damping: f32 = 0.04,
    allow_sleep: bool = true,
};

const BoxColliderRecord = struct {
    half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 },
    center: [3]f32 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
};

const SphereColliderRecord = struct {
    radius: f32 = 0.5,
    center: [3]f32 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
};

const MeshColliderRecord = struct {
    use_attached_mesh: bool = true,
    is_trigger: bool = false,
};

const CapsuleColliderRecord = struct {
    radius: f32 = 0.4,
    half_height: f32 = 0.5,
    center: [3]f32 = .{ 0.0, 0.0, 0.0 },
    is_trigger: bool = false,
    layer_id: u16 = 0,
    layer_group: u16 = 0xFFFF,
};

const CharacterControllerRecord = struct {
    max_slope_angle: f32 = 0.872,
    max_strength: f32 = 100.0,
    padding: f32 = 0.02,
    mass: f32 = 70.0,
    up_direction: [3]f32 = .{ 0.0, 1.0, 0.0 },
};

const TagRecord = struct {
    name: []const u8 = "",
};

const EntityRecord = struct {
    name: []const u8,
    parent: ?u32 = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?MeshComponentRecord = null,
    skinned_mesh: ?SkinnedMeshComponentRecord = null,
    animator: ?AnimatorComponentRecord = null,
    animator_targets: ?[]const u32 = null,
    skinned_mesh_targets: ?[]const u32 = null,
    animation_graph: ?AnimationGraphRecord = null,
    animation_graph_instance: ?AnimationGraphInstanceRecord = null,
    rigidbody: ?RigidbodyRecord = null,
    box_collider: ?BoxColliderRecord = null,
    sphere_collider: ?SphereColliderRecord = null,
    mesh_collider: ?MeshColliderRecord = null,
    capsule_collider: ?CapsuleColliderRecord = null,
    character_controller: ?CharacterControllerRecord = null,
    tag: ?TagRecord = null,
    material: ?MaterialComponentRecord = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?ScriptComponentRecord = null,
    audio_source: ?AudioSourceComponentRecord = null,
    audio_listener: ?AudioListenerComponentRecord = null,
    nav_agent: ?NavAgentComponentRecord = null,
    visible: bool = true,
    editor_only: bool = false,
    dont_destroy_on_load: bool = false,
    is_folder: bool = false,
};

const LegacySceneFile = struct {
    version: u32 = 2,
    meshes: []LegacyMeshRecord,
    textures: []LegacyTextureRecord,
    materials: []LegacyMaterialRecord,
    entities: []LegacyEntityRecord,
};

const LegacyMeshRecord = struct {
    name: []const u8,
    primitive_type: rhi_types.PrimitiveType,
    vertices: []const mesh_mod.Vertex,
    indices: []const u32,
};

const LegacyTextureRecord = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels_hex: []const u8,
};

const LegacyMaterialRecord = struct {
    name: []const u8,
    shading: components.ShadingModel,
    base_color_factor: [4]f32,
    base_color_texture: ?u32 = null,
};

const LegacyMeshComponentRecord = struct {
    resource: ?u32 = null,
    primitive: components.Primitive = .custom,
};

const LegacyMaterialComponentRecord = struct {
    resource: ?u32 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const LegacyEntityRecord = struct {
    name: []const u8,
    parent: ?u32 = null,
    transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?LegacyMeshComponentRecord = null,
    material: ?LegacyMaterialComponentRecord = null,
    light: ?components.Light = null,
    visible: bool = true,
    editor_only: bool = false,
};

const TextureBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.TextureHandle,
};

const MaterialBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.MaterialHandle,
};

const MeshBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.MeshHandle,
};

const SkeletonBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.SkeletonHandle,
};

const SkinBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.SkinHandle,
};

const AnimationClipBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.AnimationClipHandle,
};

const ScriptBinding = struct {
    asset_id: []const u8,
    handle: assets_handles.ScriptHandle,
};

pub fn serializeWorldAlloc(allocator: std.mem.Allocator, world: *const world_mod.World) ![]u8 {
    return try buildSceneFileAlloc(allocator, world, null);
}

pub fn serializeWorldSubsetAlloc(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    root_entity_ids: []const world_mod.EntityId,
) ![]u8 {
    var included_entities = std.AutoHashMap(world_mod.EntityId, void).init(allocator);
    defer included_entities.deinit();

    for (root_entity_ids) |root_id| {
        try collectEntitySubtreeIds(world, root_id, &included_entities);
    }

    return try buildSceneFileAlloc(allocator, world, &included_entities);
}

pub fn serializeWorldWithRuntimeStateAlloc(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    runtime_state: SceneRuntimeState,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scene = try buildSceneFileFiltered(arena, world, null);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var legacy_writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = legacy_writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(SceneRuntimeFile{
        .scene = scene,
        .runtime_state = runtime_state,
    }, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

fn buildSceneFileAlloc(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    included_entities: ?*const std.AutoHashMap(world_mod.EntityId, void),
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scene = try buildSceneFileFiltered(arena, world, included_entities);

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var legacy_writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = legacy_writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(scene, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

pub fn deserializeWorldFromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var header_parse = try std.json.parseFromSlice(SceneHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    switch (header_parse.value.version) {
        1, 2 => try deserializeLegacyWorldFromSlice(allocator, world, source),
        3, 4, 5, 6 => try deserializeWorldV4FromSlice(allocator, world, source),
        runtime_scene_file_version => {
            var parsed = try std.json.parseFromSlice(SceneRuntimeFile, allocator, source, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            try deserializeWorldFromSceneFile(allocator, world, &parsed.value.scene);
        },
        else => return error.UnsupportedSceneVersion,
    }
}

pub fn appendWorldFromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var header_parse = try std.json.parseFromSlice(SceneHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    switch (header_parse.value.version) {
        3, 4, 5, 6 => try appendWorldV4FromSlice(allocator, world, source),
        runtime_scene_file_version => {
            var parsed = try std.json.parseFromSlice(SceneRuntimeFile, allocator, source, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            try applySceneFileToWorld(allocator, world, &parsed.value.scene, false, false);
        },
        else => return error.UnsupportedSceneVersion,
    }
}

pub fn deserializeWorldWithRuntimeStateFromSlice(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    source: []const u8,
    runtime_state: ?*SceneRuntimeState,
) !void {
    var header_parse = try std.json.parseFromSlice(SceneHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    if (header_parse.value.version == runtime_scene_file_version) {
        var parsed = try std.json.parseFromSlice(SceneRuntimeFile, allocator, source, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try deserializeWorldFromSceneFile(allocator, world, &parsed.value.scene);
        if (runtime_state) |state| {
            state.* = parsed.value.runtime_state;
        }
        return;
    }

    try deserializeWorldFromSlice(allocator, world, source);
    if (runtime_state) |state| {
        state.* = .{};
    }
}

pub fn saveWorldToPath(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    path: []const u8,
) !void {
    const encoded = try serializeWorldAlloc(allocator, world);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = encoded,
    });
}

pub fn loadWorldFromPath(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    path: []const u8,
) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(source);
    try deserializeWorldFromSlice(allocator, world, source);
}

pub fn saveWorldWithRuntimeStateToPath(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    runtime_state: SceneRuntimeState,
    path: []const u8,
) !void {
    const encoded = try serializeWorldWithRuntimeStateAlloc(allocator, world, runtime_state);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = encoded,
    });
}

pub fn loadWorldWithRuntimeStateFromPath(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    path: []const u8,
    runtime_state: ?*SceneRuntimeState,
) !void {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(source);
    try deserializeWorldWithRuntimeStateFromSlice(allocator, world, source, runtime_state);
}

fn buildSceneFile(allocator: std.mem.Allocator, world: *const world_mod.World) !SceneFile {
    return buildSceneFileFiltered(allocator, world, null);
}

fn buildSceneFileFiltered(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    included_entities: ?*const std.AutoHashMap(world_mod.EntityId, void),
) !SceneFile {
    var mesh_records = std.ArrayList(MeshRecord).empty;
    defer mesh_records.deinit(allocator);
    var texture_records = std.ArrayList(TextureRecord).empty;
    defer texture_records.deinit(allocator);
    var material_records = std.ArrayList(MaterialRecord).empty;
    defer material_records.deinit(allocator);
    var skeleton_records = std.ArrayList(SkeletonRecord).empty;
    defer skeleton_records.deinit(allocator);
    var skin_records = std.ArrayList(SkinRecord).empty;
    defer skin_records.deinit(allocator);
    var animation_clip_records = std.ArrayList(AnimationClipRecord).empty;
    defer animation_clip_records.deinit(allocator);
    var script_records = std.ArrayList(ScriptRecord).empty;
    defer script_records.deinit(allocator);
    var asset_records = std.ArrayList(asset_registry.AssetRecord).empty;
    defer asset_records.deinit(allocator);
    var entity_records = std.ArrayList(EntityRecord).empty;
    defer entity_records.deinit(allocator);

    var mesh_asset_ids = std.AutoHashMap(assets_handles.MeshHandle, []const u8).init(allocator);
    defer mesh_asset_ids.deinit();
    var texture_asset_ids = std.AutoHashMap(assets_handles.TextureHandle, []const u8).init(allocator);
    defer texture_asset_ids.deinit();
    var material_asset_ids = std.AutoHashMap(assets_handles.MaterialHandle, []const u8).init(allocator);
    defer material_asset_ids.deinit();
    var skeleton_asset_ids = std.AutoHashMap(assets_handles.SkeletonHandle, []const u8).init(allocator);
    defer skeleton_asset_ids.deinit();
    var skin_asset_ids = std.AutoHashMap(assets_handles.SkinHandle, []const u8).init(allocator);
    defer skin_asset_ids.deinit();
    var animation_clip_asset_ids = std.AutoHashMap(assets_handles.AnimationClipHandle, []const u8).init(allocator);
    defer animation_clip_asset_ids.deinit();
    var script_asset_ids = std.AutoHashMap(assets_handles.ScriptHandle, []const u8).init(allocator);
    defer script_asset_ids.deinit();
    var entity_indices = std.AutoHashMap(world_mod.EntityId, u32).init(allocator);
    defer entity_indices.deinit();

    var exported_entity_index: u32 = 0;
    for (world.entities.items) |entity| {
        if (!shouldExportEntity(&entity, included_entities)) {
            continue;
        }
        try entity_indices.put(entity.id, exported_entity_index);
        exported_entity_index += 1;
    }

    for (world.entities.items) |entity| {
        if (!shouldExportEntity(&entity, included_entities)) {
            continue;
        }

        const mesh_component = if (entity.mesh) |mesh|
            MeshComponentRecord{
                .asset_id = if (mesh.handle) |mesh_handle|
                    try ensureMeshRecord(
                        allocator,
                        world,
                        mesh_handle,
                        &mesh_asset_ids,
                        &mesh_records,
                        &asset_records,
                        &texture_asset_ids,
                        &texture_records,
                        &material_asset_ids,
                        &material_records,
                    )
                else
                    null,
                .primitive = mesh.primitive,
            }
        else
            null;

        const material_component = if (entity.material) |material|
            MaterialComponentRecord{
                .asset_id = if (material.handle) |material_handle|
                    try ensureMaterialRecord(
                        allocator,
                        world,
                        material_handle,
                        &material_asset_ids,
                        &material_records,
                        &asset_records,
                        &texture_asset_ids,
                        &texture_records,
                    )
                else
                    null,
                .shading = material.shading,
                .base_color_factor = material.base_color_factor,
                .emissive_factor = material.emissive_factor,
                .metallic_factor = material.metallic_factor,
                .roughness_factor = material.roughness_factor,
                .alpha_cutoff = material.alpha_cutoff,
                .double_sided = material.double_sided,
            }
        else
            null;

        const skinned_mesh_component = if (entity.skinned_mesh) |skinned_mesh|
            SkinnedMeshComponentRecord{
                .mesh_asset_id = if (skinned_mesh.mesh_handle) |mesh_handle|
                    try ensureMeshRecord(
                        allocator,
                        world,
                        mesh_handle,
                        &mesh_asset_ids,
                        &mesh_records,
                        &asset_records,
                        &texture_asset_ids,
                        &texture_records,
                        &material_asset_ids,
                        &material_records,
                    )
                else
                    null,
                .primitive = skinned_mesh.primitive,
                .skeleton_asset_id = if (skinned_mesh.skeleton_handle) |skeleton_handle|
                    try ensureSkeletonRecord(
                        allocator,
                        world,
                        skeleton_handle,
                        &skeleton_asset_ids,
                        &skeleton_records,
                        &asset_records,
                    )
                else
                    null,
                .skin_asset_id = if (skinned_mesh.skin_handle) |skin_handle|
                    try ensureSkinRecord(
                        allocator,
                        world,
                        skin_handle,
                        &skin_asset_ids,
                        &skin_records,
                        &asset_records,
                        &skeleton_asset_ids,
                        &skeleton_records,
                    )
                else
                    null,
            }
        else
            null;

        const animator_component = if (entity.animator) |animator|
            AnimatorComponentRecord{
                .skeleton_asset_id = if (animator.skeleton_handle) |skeleton_handle|
                    try ensureSkeletonRecord(
                        allocator,
                        world,
                        skeleton_handle,
                        &skeleton_asset_ids,
                        &skeleton_records,
                        &asset_records,
                    )
                else
                    null,
                .default_clip_asset_id = if (animator.default_clip_handle) |clip_handle|
                    try ensureAnimationClipRecord(
                        allocator,
                        world,
                        clip_handle,
                        &animation_clip_asset_ids,
                        &animation_clip_records,
                        &asset_records,
                    )
                else
                    null,
                .time_seconds = animator.time_seconds,
                .next_clip_asset_id = if (animator.next_clip_handle) |clip_handle|
                    try ensureAnimationClipRecord(
                        allocator,
                        world,
                        clip_handle,
                        &animation_clip_asset_ids,
                        &animation_clip_records,
                        &asset_records,
                    )
                else
                    null,
                .next_time_seconds = animator.next_time_seconds,
                .blend_duration_seconds = animator.blend_duration_seconds,
                .blend_time_seconds = animator.blend_time_seconds,
                .speed = animator.speed,
                .playing = animator.playing,
                .looping = animator.looping,
            }
        else
            null;

        const animator_targets = if (world.animatorTargets(entity.id)) |targets|
            try mapEntityIdsToIndices(allocator, &entity_indices, targets)
        else
            null;

        const skinned_mesh_targets = if (world.skinnedMeshTargets(entity.id)) |targets|
            try mapEntityIdsToIndices(allocator, &entity_indices, targets)
        else
            null;

        const animation_graph = if (world.animatorGraph(entity.id)) |graph|
            try buildAnimationGraphRecord(
                allocator,
                world,
                graph,
                &animation_clip_asset_ids,
                &animation_clip_records,
                &asset_records,
            )
        else
            null;

        const script_component = if (entity.script) |script|
            ScriptComponentRecord{
                .asset_id = if (script.script_handle) |script_handle|
                    try ensureScriptRecord(
                        allocator,
                        world,
                        script_handle,
                        &script_asset_ids,
                        &script_records,
                        &asset_records,
                    )
                else
                    null,
                .language = script.language,
                .enabled = script.enabled,
                .parameters = script.parameters,
            }
        else
            null;

        try entity_records.append(allocator, .{
            .name = entity.name,
            .parent = if (entity.parent) |parent_id| entity_indices.get(parent_id) else null,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = mesh_component,
            .skinned_mesh = skinned_mesh_component,
            .animator = animator_component,
            .animator_targets = animator_targets,
            .skinned_mesh_targets = skinned_mesh_targets,
            .animation_graph = animation_graph,
            .rigidbody = if (entity.rigidbody) |body| .{
                .motion_type = body.motion_type,
                .mass = body.mass,
                .linear_velocity = body.linear_velocity,
                .gravity_scale = body.gravity_scale,
                .linear_damping = body.linear_damping,
                .allow_sleep = body.allow_sleep,
            } else null,
            .box_collider = if (entity.box_collider) |collider| .{
                .half_extents = collider.half_extents,
                .center = collider.center,
                .is_trigger = collider.is_trigger,
            } else null,
            .sphere_collider = if (entity.sphere_collider) |collider| .{
                .radius = collider.radius,
                .center = collider.center,
                .is_trigger = collider.is_trigger,
            } else null,
            .mesh_collider = if (entity.mesh_collider) |collider| .{
                .use_attached_mesh = collider.use_attached_mesh,
                .is_trigger = collider.is_trigger,
            } else null,
            .capsule_collider = if (entity.capsule_collider) |collider| .{
                .radius = collider.radius,
                .half_height = collider.half_height,
                .center = collider.center,
                .is_trigger = collider.is_trigger,
                .layer_id = collider.layer_id,
                .layer_group = collider.layer_group,
            } else null,
            .character_controller = if (entity.character_controller) |ctrl| .{
                .max_slope_angle = ctrl.max_slope_angle,
                .max_strength = ctrl.max_strength,
                .padding = ctrl.padding,
                .mass = ctrl.mass,
                .up_direction = ctrl.up_direction,
            } else null,
            .tag = if (entity.tag) |*t| blk: {
                const s = t.asSlice();
                break :blk if (s.len > 0) TagRecord{ .name = s } else null;
            } else null,
            .material = material_component,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = script_component,
            .audio_source = if (entity.audio_source) |as| AudioSourceComponentRecord{
                .clip_asset_path = as.clip_asset_path,
                .bus = as.bus,
                .volume = as.volume,
                .spatial = as.spatial,
                .looping = as.looping,
                .play_on_awake = as.play_on_awake,
                .min_distance = as.min_distance,
                .max_distance = as.max_distance,
                .doppler_factor = as.doppler_factor,
            } else null,
            .audio_listener = if (entity.audio_listener) |al| AudioListenerComponentRecord{
                .enabled = al.enabled,
            } else null,
            .nav_agent = if (entity.nav_agent) |agent| NavAgentComponentRecord{
                .radius = agent.radius,
                .height = agent.height,
                .max_acceleration = agent.max_acceleration,
                .max_speed = agent.max_speed,
                .target = agent.target,
            } else null,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .dont_destroy_on_load = entity.dont_destroy_on_load,
            .is_folder = entity.is_folder,
        });
    }

    if (world.resources.sceneEnvironmentAssetId()) |environment_asset_id| {
        if (world.resources.asset_registry.recordById(environment_asset_id)) |asset_record| {
            _ = try ensureSceneAssetRecord(&asset_records, allocator, asset_record.*);
        }
    }

    const scene_id = try makeSceneIdAlloc(
        allocator,
        entity_records.items,
        mesh_records.items,
        material_records.items,
        texture_records.items,
        skeleton_records.items,
        skin_records.items,
        animation_clip_records.items,
        script_records.items,
    );

    return .{
        .scene_id = scene_id,
        .environment_asset_id = world.resources.sceneEnvironmentAssetId(),
        .asset_records = try asset_records.toOwnedSlice(allocator),
        .meshes = try mesh_records.toOwnedSlice(allocator),
        .textures = try texture_records.toOwnedSlice(allocator),
        .materials = try material_records.toOwnedSlice(allocator),
        .skeletons = try skeleton_records.toOwnedSlice(allocator),
        .skins = try skin_records.toOwnedSlice(allocator),
        .animation_clips = try animation_clip_records.toOwnedSlice(allocator),
        .scripts = try script_records.toOwnedSlice(allocator),
        .entities = try entity_records.toOwnedSlice(allocator),
    };
}

fn shouldExportEntity(
    entity: *const world_mod.Entity,
    included_entities: ?*const std.AutoHashMap(world_mod.EntityId, void),
) bool {
    if (entity.editor_only) {
        return false;
    }
    if (included_entities) |filter| {
        return filter.contains(entity.id);
    }
    return true;
}

fn collectEntitySubtreeIds(
    world: *const world_mod.World,
    root_id: world_mod.EntityId,
    included_entities: *std.AutoHashMap(world_mod.EntityId, void),
) !void {
    const root = world.getEntityConst(root_id) orelse return;
    if (root.editor_only) {
        return;
    }

    if (!included_entities.contains(root_id)) {
        try included_entities.put(root_id, {});
    }

    for (root.children.items) |child_id| {
        try collectEntitySubtreeIds(world, child_id, included_entities);
    }
}

fn deserializeWorldFromSceneFile(allocator: std.mem.Allocator, world: *world_mod.World, scene: *const SceneFile) anyerror!void {
    try applySceneFileToWorld(allocator, world, scene, true, true);
}

fn deserializeWorldV4FromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(SceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 3 and scene.version != 4 and scene.version != 5 and scene.version != current_scene_version) {
        return error.UnsupportedSceneVersion;
    }

    try applySceneFileToWorld(allocator, world, &scene, true, true);
}

fn appendWorldV4FromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(SceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 3 and scene.version != 4 and scene.version != 5 and scene.version != current_scene_version) {
        return error.UnsupportedSceneVersion;
    }

    try applySceneFileToWorld(allocator, world, &scene, false, false);
}

fn applySceneFileToWorld(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    clear_existing: bool,
    apply_environment_asset: bool,
) anyerror!void {
    if (clear_existing) {
        world.clear();
    }

    if (apply_environment_asset) {
        if (scene.environment_asset_id) |environment_asset_id| {
            if (findAssetRecord(scene.asset_records, environment_asset_id) != null) {
                _ = try world.resources.setSceneEnvironmentAssetId(environment_asset_id);
            }
        }
    }

    var texture_bindings = std.ArrayList(TextureBinding).empty;
    defer texture_bindings.deinit(allocator);
    for (scene.textures) |texture| {
        const decoded_pixels = try decodeHexAlloc(allocator, texture.pixels_hex);
        defer allocator.free(decoded_pixels);

        const handle = try world.resources.createTexture(.{
            .name = texture.name,
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = decoded_pixels,
        });
        try bindTextureAssetFromScene(allocator, world, scene, texture.asset_id, texture.name, handle);
        applyBuiltinTextureHandle(&world.resources, texture.name, handle);
        try texture_bindings.append(allocator, .{
            .asset_id = texture.asset_id,
            .handle = handle,
        });
    }

    var material_bindings = std.ArrayList(MaterialBinding).empty;
    defer material_bindings.deinit(allocator);
    for (scene.materials) |material| {
        const handle = try world.resources.createMaterial(.{
            .name = material.name,
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
            .base_color_texture = if (material.base_color_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
            .metallic_roughness_texture = if (material.metallic_roughness_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
            .normal_texture = if (material.normal_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
            .occlusion_texture = if (material.occlusion_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
            .emissive_texture = if (material.emissive_texture_asset_id) |texture_asset_id|
                findTextureHandle(texture_bindings.items, texture_asset_id) orelse return error.TextureAssetNotFound
            else
                null,
            .emissive_factor = material.emissive_factor,
            .metallic_factor = material.metallic_factor,
            .roughness_factor = material.roughness_factor,
            .alpha_cutoff = material.alpha_cutoff,
            .double_sided = material.double_sided,
            .use_ibl = material.use_ibl,
            .ibl_intensity = material.ibl_intensity,
        });
        try bindMaterialAssetFromScene(allocator, world, scene, material.asset_id, material.name, handle);
        applyBuiltinMaterialHandle(&world.resources, material.name, handle);
        try material_bindings.append(allocator, .{
            .asset_id = material.asset_id,
            .handle = handle,
        });
    }

    var mesh_bindings = std.ArrayList(MeshBinding).empty;
    defer mesh_bindings.deinit(allocator);
    for (scene.meshes) |mesh| {
        const handle = try world.resources.createMesh(.{
            .name = mesh.name,
            .vertices = mesh.vertices,
            .indices = mesh.indices,
            .primitive_type = mesh.primitive_type,
        });
        try bindMeshAssetFromScene(allocator, world, scene, mesh.asset_id, mesh.name, handle);
        applyBuiltinMeshHandle(&world.resources, mesh.name, handle);
        try mesh_bindings.append(allocator, .{
            .asset_id = mesh.asset_id,
            .handle = handle,
        });
    }

    var skeleton_bindings = std.ArrayList(SkeletonBinding).empty;
    defer skeleton_bindings.deinit(allocator);
    for (scene.skeletons) |skeleton| {
        const joint_descs = try allocator.alloc(@import("../assets/skeleton_resource.zig").JointDesc, skeleton.joints.len);
        defer allocator.free(joint_descs);
        for (skeleton.joints, 0..) |joint, index| {
            joint_descs[index] = .{
                .name = joint.name,
                .node_entity_index = joint.node_entity_index,
                .parent_joint_index = joint.parent_joint_index,
                .rest_local_transform = joint.rest_local_transform,
            };
        }

        const handle = try world.resources.createSkeleton(.{
            .name = skeleton.name,
            .joints = joint_descs,
        });
        try bindSkeletonAssetFromScene(allocator, world, scene, skeleton.asset_id, skeleton.name, handle);
        try skeleton_bindings.append(allocator, .{
            .asset_id = skeleton.asset_id,
            .handle = handle,
        });
    }

    var skin_bindings = std.ArrayList(SkinBinding).empty;
    defer skin_bindings.deinit(allocator);
    for (scene.skins) |skin| {
        const skeleton_handle = findSkeletonHandle(skeleton_bindings.items, skin.skeleton_asset_id) orelse return error.SkeletonAssetNotFound;
        const handle = try world.resources.createSkin(.{
            .name = skin.name,
            .skeleton = skeleton_handle,
            .joint_entity_indices = skin.joint_entity_indices,
            .inverse_bind_matrices = skin.inverse_bind_matrices,
        });
        try bindSkinAssetFromScene(allocator, world, scene, skin.asset_id, skin.name, handle);
        try skin_bindings.append(allocator, .{
            .asset_id = skin.asset_id,
            .handle = handle,
        });
    }

    var animation_clip_bindings = std.ArrayList(AnimationClipBinding).empty;
    defer animation_clip_bindings.deinit(allocator);
    for (scene.animation_clips) |clip| {
        const translation_descs = try allocator.alloc(@import("../assets/animation_clip_resource.zig").Vec3TrackDesc, clip.translation_tracks.len);
        defer allocator.free(translation_descs);
        for (clip.translation_tracks, 0..) |track, index| {
            translation_descs[index] = .{
                .target_entity_index = track.target_entity_index,
                .interpolation = track.interpolation,
                .times = track.times,
                .values = track.values,
            };
        }

        const rotation_descs = try allocator.alloc(@import("../assets/animation_clip_resource.zig").QuatTrackDesc, clip.rotation_tracks.len);
        defer allocator.free(rotation_descs);
        for (clip.rotation_tracks, 0..) |track, index| {
            rotation_descs[index] = .{
                .target_entity_index = track.target_entity_index,
                .interpolation = track.interpolation,
                .times = track.times,
                .values = track.values,
            };
        }

        const scale_descs = try allocator.alloc(@import("../assets/animation_clip_resource.zig").Vec3TrackDesc, clip.scale_tracks.len);
        defer allocator.free(scale_descs);
        for (clip.scale_tracks, 0..) |track, index| {
            scale_descs[index] = .{
                .target_entity_index = track.target_entity_index,
                .interpolation = track.interpolation,
                .times = track.times,
                .values = track.values,
            };
        }

        const handle = try world.resources.createAnimationClip(.{
            .name = clip.name,
            .duration = clip.duration,
            .translation_tracks = translation_descs,
            .rotation_tracks = rotation_descs,
            .scale_tracks = scale_descs,
        });
        try bindAnimationClipAssetFromScene(allocator, world, scene, clip.asset_id, clip.name, handle);
        try animation_clip_bindings.append(allocator, .{
            .asset_id = clip.asset_id,
            .handle = handle,
        });
    }

    var script_bindings = std.ArrayList(ScriptBinding).empty;
    defer script_bindings.deinit(allocator);
    for (scene.scripts) |script| {
        const handle = if (world.resources.scriptHandleByAssetId(script.asset_id)) |existing|
            existing
        else blk: {
            const decoded_bytecode = try decodeHexAlloc(allocator, script.bytecode_hex);
            defer allocator.free(decoded_bytecode);

            const created = try world.resources.createScript(.{
                .source = script.source,
                .language = scriptResourceLanguage(script.language),
                .entry_fn = script.entry_fn,
                .description = script.description,
                .source_path = script.source_path,
                .artifact_path = script.artifact_path,
                .last_modified = script.last_modified,
                .bytecode = decoded_bytecode,
                .user_data = script.user_data,
            });
            try bindScriptAssetFromScene(
                allocator,
                world,
                scene,
                script.asset_id,
                if (script.description.len != 0) script.description else script.entry_fn,
                created,
            );
            break :blk created;
        };
        try script_bindings.append(allocator, .{
            .asset_id = script.asset_id,
            .handle = handle,
        });
    }

    const entity_ids = try allocator.alloc(world_mod.EntityId, scene.entities.len);
    defer allocator.free(entity_ids);

    for (scene.entities, 0..) |entity, index| {
        entity_ids[index] = try world.createEntity(.{
            .name = entity.name,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh_component|
                .{
                    .handle = if (mesh_component.asset_id) |mesh_asset_id|
                        findMeshHandle(mesh_bindings.items, mesh_asset_id) orelse return error.MeshAssetNotFound
                    else
                        null,
                    .primitive = mesh_component.primitive,
                }
            else
                null,
            .skinned_mesh = if (entity.skinned_mesh) |skinned_mesh_component|
                .{
                    .mesh_handle = if (skinned_mesh_component.mesh_asset_id) |mesh_asset_id|
                        findMeshHandle(mesh_bindings.items, mesh_asset_id) orelse return error.MeshAssetNotFound
                    else
                        null,
                    .primitive = skinned_mesh_component.primitive,
                    .skeleton_handle = if (skinned_mesh_component.skeleton_asset_id) |skeleton_asset_id|
                        findSkeletonHandle(skeleton_bindings.items, skeleton_asset_id) orelse return error.SkeletonAssetNotFound
                    else
                        null,
                    .skin_handle = if (skinned_mesh_component.skin_asset_id) |skin_asset_id|
                        findSkinHandle(skin_bindings.items, skin_asset_id) orelse return error.SkinAssetNotFound
                    else
                        null,
                }
            else
                null,
            .animator = if (entity.animator) |animator_component|
                .{
                    .skeleton_handle = if (animator_component.skeleton_asset_id) |skeleton_asset_id|
                        findSkeletonHandle(skeleton_bindings.items, skeleton_asset_id) orelse return error.SkeletonAssetNotFound
                    else
                        null,
                    .default_clip_handle = if (animator_component.default_clip_asset_id) |clip_asset_id|
                        findAnimationClipHandle(animation_clip_bindings.items, clip_asset_id) orelse return error.AnimationClipAssetNotFound
                    else
                        null,
                    .time_seconds = animator_component.time_seconds,
                    .next_clip_handle = if (animator_component.next_clip_asset_id) |clip_asset_id|
                        findAnimationClipHandle(animation_clip_bindings.items, clip_asset_id) orelse return error.AnimationClipAssetNotFound
                    else
                        null,
                    .next_time_seconds = animator_component.next_time_seconds,
                    .blend_duration_seconds = animator_component.blend_duration_seconds,
                    .blend_time_seconds = animator_component.blend_time_seconds,
                    .speed = animator_component.speed,
                    .playing = animator_component.playing,
                    .looping = animator_component.looping,
                }
            else
                null,
            .rigidbody = if (entity.rigidbody) |body|
                .{
                    .motion_type = body.motion_type,
                    .mass = body.mass,
                    .linear_velocity = body.linear_velocity,
                    .gravity_scale = body.gravity_scale,
                    .linear_damping = body.linear_damping,
                    .allow_sleep = body.allow_sleep,
                }
            else
                null,
            .box_collider = if (entity.box_collider) |collider|
                .{
                    .half_extents = collider.half_extents,
                    .center = collider.center,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .sphere_collider = if (entity.sphere_collider) |collider|
                .{
                    .radius = collider.radius,
                    .center = collider.center,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .mesh_collider = if (entity.mesh_collider) |collider|
                .{
                    .use_attached_mesh = collider.use_attached_mesh,
                    .is_trigger = collider.is_trigger,
                }
            else
                null,
            .capsule_collider = if (entity.capsule_collider) |collider|
                .{
                    .radius = collider.radius,
                    .half_height = collider.half_height,
                    .center = collider.center,
                    .is_trigger = collider.is_trigger,
                    .layer_id = collider.layer_id,
                    .layer_group = collider.layer_group,
                }
            else
                null,
            .character_controller = if (entity.character_controller) |ctrl|
                .{
                    .max_slope_angle = ctrl.max_slope_angle,
                    .max_strength = ctrl.max_strength,
                    .padding = ctrl.padding,
                    .mass = ctrl.mass,
                    .up_direction = ctrl.up_direction,
                }
            else
                null,
            .tag = if (entity.tag) |t|
                (if (t.name.len > 0) components.Tag.fromSlice(t.name) else null)
            else
                null,
            .material = if (entity.material) |material_component|
                .{
                    .handle = if (material_component.asset_id) |material_asset_id|
                        findMaterialHandle(material_bindings.items, material_asset_id) orelse return error.MaterialAssetNotFound
                    else
                        null,
                    .shading = material_component.shading,
                    .base_color_factor = material_component.base_color_factor,
                    .emissive_factor = material_component.emissive_factor,
                    .metallic_factor = material_component.metallic_factor,
                    .roughness_factor = material_component.roughness_factor,
                    .alpha_cutoff = material_component.alpha_cutoff,
                    .double_sided = material_component.double_sided,
                }
            else
                null,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = if (entity.script) |script_component|
                .{
                    .script_handle = if (script_component.asset_id) |script_asset_id|
                        findScriptHandle(script_bindings.items, script_asset_id) orelse return error.ScriptAssetNotFound
                    else
                        null,
                    .language = script_component.language,
                    .enabled = script_component.enabled,
                    .parameters = script_component.parameters,
                }
            else
                null,
            .audio_source = if (entity.audio_source) |as_rec|
                .{
                    .clip_asset_path = as_rec.clip_asset_path,
                    .bus = as_rec.bus,
                    .volume = as_rec.volume,
                    .spatial = as_rec.spatial,
                    .looping = as_rec.looping,
                    .play_on_awake = as_rec.play_on_awake,
                    .min_distance = as_rec.min_distance,
                    .max_distance = as_rec.max_distance,
                    .doppler_factor = as_rec.doppler_factor,
                }
            else
                null,
            .audio_listener = if (entity.audio_listener) |al_rec|
                .{
                    .enabled = al_rec.enabled,
                }
            else
                null,
            .nav_agent = if (entity.nav_agent) |agent_rec|
                .{
                    .radius = agent_rec.radius,
                    .height = agent_rec.height,
                    .max_acceleration = agent_rec.max_acceleration,
                    .max_speed = agent_rec.max_speed,
                    .target = agent_rec.target,
                    ._crowd_idx = null,
                    ._registered = false,
                }
            else
                null,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .dont_destroy_on_load = entity.dont_destroy_on_load,
            .is_folder = entity.is_folder,
        });
    }

    for (scene.entities, 0..) |entity, index| {
        if (entity.parent) |parent_index| {
            if (parent_index >= entity_ids.len) {
                return error.ParentIndexOutOfBounds;
            }
            _ = try world.setParentLocal(entity_ids[index], entity_ids[parent_index]);
        }
    }

    for (scene.entities, 0..) |entity, index| {
        if (entity.animator_targets) |target_indices| {
            const target_ids = try mapEntityIndicesToIds(allocator, entity_ids, target_indices);
            defer allocator.free(target_ids);
            try world.bindAnimatorTargets(entity_ids[index], target_ids);
        }

        if (entity.skinned_mesh_targets) |target_indices| {
            const target_ids = try mapEntityIndicesToIds(allocator, entity_ids, target_indices);
            defer allocator.free(target_ids);
            try world.bindSkinnedMeshTargets(entity_ids[index], target_ids);
        }
    }

    for (scene.entities, 0..) |entity, index| {
        const graph_record = entity.animation_graph orelse continue;
        var graph = try buildAnimationGraphFromRecord(allocator, world, graph_record, animation_clip_bindings.items);
        defer graph.deinit();
        try world.bindAnimatorGraph(entity_ids[index], &graph);
    }
}

fn deserializeLegacyWorldFromSlice(allocator: std.mem.Allocator, world: *world_mod.World, source: []const u8) !void {
    var parsed = try std.json.parseFromSlice(LegacySceneFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const scene = parsed.value;
    if (scene.version != 1 and scene.version != 2) {
        return error.UnsupportedSceneVersion;
    }

    world.clear();

    const texture_handles = try allocator.alloc(assets_handles.TextureHandle, scene.textures.len);
    defer allocator.free(texture_handles);
    for (scene.textures, 0..) |texture, index| {
        const decoded_pixels = try decodeHexAlloc(allocator, texture.pixels_hex);
        defer allocator.free(decoded_pixels);

        const handle = try world.resources.createTexture(.{
            .name = texture.name,
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = decoded_pixels,
        });
        texture_handles[index] = handle;
        applyBuiltinTextureHandle(&world.resources, texture.name, handle);
    }

    const material_handles = try allocator.alloc(assets_handles.MaterialHandle, scene.materials.len);
    defer allocator.free(material_handles);
    for (scene.materials, 0..) |material, index| {
        const handle = try world.resources.createMaterial(.{
            .name = material.name,
            .shading = material.shading,
            .base_color_factor = material.base_color_factor,
            .base_color_texture = if (material.base_color_texture) |texture_index|
                texture_handles[texture_index]
            else
                null,
        });
        material_handles[index] = handle;
        applyBuiltinMaterialHandle(&world.resources, material.name, handle);
    }

    const mesh_handles = try allocator.alloc(assets_handles.MeshHandle, scene.meshes.len);
    defer allocator.free(mesh_handles);
    for (scene.meshes, 0..) |mesh, index| {
        const handle = try world.resources.createMesh(.{
            .name = mesh.name,
            .vertices = mesh.vertices,
            .indices = mesh.indices,
            .primitive_type = mesh.primitive_type,
        });
        mesh_handles[index] = handle;
        applyBuiltinMeshHandle(&world.resources, mesh.name, handle);
    }

    const entity_ids = try allocator.alloc(world_mod.EntityId, scene.entities.len);
    defer allocator.free(entity_ids);

    for (scene.entities, 0..) |entity, index| {
        entity_ids[index] = try world.createEntity(.{
            .name = entity.name,
            .local_transform = entity.transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh_component|
                .{
                    .handle = if (mesh_component.resource) |mesh_index| mesh_handles[mesh_index] else null,
                    .primitive = mesh_component.primitive,
                }
            else
                null,
            .material = if (entity.material) |material_component|
                .{
                    .handle = if (material_component.resource) |material_index| material_handles[material_index] else null,
                    .shading = material_component.shading,
                    .base_color_factor = material_component.base_color_factor,
                }
            else
                null,
            .light = entity.light,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
        });
    }

    for (scene.entities, 0..) |entity, index| {
        if (entity.parent) |parent_index| {
            if (parent_index >= entity_ids.len) {
                return error.ParentIndexOutOfBounds;
            }
            _ = try world.setParentLocal(entity_ids[index], entity_ids[parent_index]);
        }
    }
}

fn ensureMeshRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MeshHandle,
    mesh_asset_ids: *std.AutoHashMap(assets_handles.MeshHandle, []const u8),
    mesh_records: *std.ArrayList(MeshRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
    material_asset_ids: *std.AutoHashMap(assets_handles.MaterialHandle, []const u8),
    material_records: *std.ArrayList(MaterialRecord),
) ![]const u8 {
    _ = texture_asset_ids;
    _ = texture_records;
    _ = material_asset_ids;
    _ = material_records;

    if (mesh_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const mesh = world.resources.mesh(handle) orelse return error.MeshNotFound;
    const asset_record = try ensureMeshAssetRecord(allocator, world, handle, mesh);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try mesh_records.append(allocator, .{
        .asset_id = asset_id,
        .name = mesh.name,
        .primitive_type = mesh.primitive_type,
        .vertices = mesh.vertices,
        .indices = mesh.indices,
    });
    try mesh_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureMaterialRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MaterialHandle,
    material_asset_ids: *std.AutoHashMap(assets_handles.MaterialHandle, []const u8),
    material_records: *std.ArrayList(MaterialRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
) ![]const u8 {
    if (material_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const material = world.resources.material(handle) orelse return error.MaterialNotFound;
    const base_color_texture_asset_id = if (material.base_color_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;
    const metallic_roughness_texture_asset_id = if (material.metallic_roughness_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;
    const normal_texture_asset_id = if (material.normal_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;
    const occlusion_texture_asset_id = if (material.occlusion_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;
    const emissive_texture_asset_id = if (material.emissive_texture) |texture_handle|
        try ensureTextureRecord(allocator, world, texture_handle, texture_asset_ids, texture_records, asset_records)
    else
        null;

    const asset_record = try ensureMaterialAssetRecord(allocator, world, handle, material, base_color_texture_asset_id);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try material_records.append(allocator, .{
        .asset_id = asset_id,
        .name = material.name,
        .shading = material.shading,
        .base_color_factor = material.base_color_factor,
        .base_color_texture_asset_id = base_color_texture_asset_id,
        .metallic_roughness_texture_asset_id = metallic_roughness_texture_asset_id,
        .normal_texture_asset_id = normal_texture_asset_id,
        .occlusion_texture_asset_id = occlusion_texture_asset_id,
        .emissive_texture_asset_id = emissive_texture_asset_id,
        .emissive_factor = material.emissive_factor,
        .metallic_factor = material.metallic_factor,
        .roughness_factor = material.roughness_factor,
        .alpha_cutoff = material.alpha_cutoff,
        .double_sided = material.double_sided,
        .use_ibl = material.use_ibl,
        .ibl_intensity = material.ibl_intensity,
    });
    try material_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureTextureRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.TextureHandle,
    texture_asset_ids: *std.AutoHashMap(assets_handles.TextureHandle, []const u8),
    texture_records: *std.ArrayList(TextureRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) ![]const u8 {
    if (texture_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const texture = world.resources.texture(handle) orelse return error.TextureNotFound;
    const asset_record = try ensureTextureAssetRecord(allocator, world, handle, texture);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try texture_records.append(allocator, .{
        .asset_id = asset_id,
        .name = texture.name,
        .width = texture.width,
        .height = texture.height,
        .format = texture.format,
        .pixels_hex = try encodeHexAlloc(allocator, texture.pixels),
    });
    try texture_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureSkeletonRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.SkeletonHandle,
    skeleton_asset_ids: *std.AutoHashMap(assets_handles.SkeletonHandle, []const u8),
    skeleton_records: *std.ArrayList(SkeletonRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) ![]const u8 {
    if (skeleton_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const skeleton = world.resources.skeleton(handle) orelse return error.SkeletonNotFound;
    const asset_record = try ensureSkeletonAssetRecord(allocator, world, handle, skeleton);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    const joints = try allocator.alloc(SkeletonJointRecord, skeleton.joints.len);
    for (skeleton.joints, 0..) |joint, index| {
        joints[index] = .{
            .name = joint.name,
            .node_entity_index = joint.node_entity_index,
            .parent_joint_index = joint.parent_joint_index,
            .rest_local_transform = joint.rest_local_transform,
        };
    }

    try skeleton_records.append(allocator, .{
        .asset_id = asset_id,
        .name = skeleton.name,
        .joints = joints,
    });
    try skeleton_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureSkinRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.SkinHandle,
    skin_asset_ids: *std.AutoHashMap(assets_handles.SkinHandle, []const u8),
    skin_records: *std.ArrayList(SkinRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    skeleton_asset_ids: *std.AutoHashMap(assets_handles.SkeletonHandle, []const u8),
    skeleton_records: *std.ArrayList(SkeletonRecord),
) ![]const u8 {
    if (skin_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const skin = world.resources.skin(handle) orelse return error.SkinNotFound;
    const skeleton_asset_id = try ensureSkeletonRecord(
        allocator,
        world,
        skin.skeleton,
        skeleton_asset_ids,
        skeleton_records,
        asset_records,
    );

    const asset_record = try ensureSkinAssetRecord(allocator, world, handle, skin, skeleton_asset_id);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try skin_records.append(allocator, .{
        .asset_id = asset_id,
        .name = skin.name,
        .skeleton_asset_id = skeleton_asset_id,
        .joint_entity_indices = skin.joint_entity_indices,
        .inverse_bind_matrices = skin.inverse_bind_matrices,
    });
    try skin_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureAnimationClipRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.AnimationClipHandle,
    animation_clip_asset_ids: *std.AutoHashMap(assets_handles.AnimationClipHandle, []const u8),
    animation_clip_records: *std.ArrayList(AnimationClipRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) ![]const u8 {
    if (animation_clip_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const clip = world.resources.animationClip(handle) orelse return error.AnimationClipNotFound;
    const asset_record = try ensureAnimationClipAssetRecord(allocator, world, handle, clip);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    const translation_tracks = try allocator.alloc(AnimationClipVec3TrackRecord, clip.translation_tracks.len);
    for (clip.translation_tracks, 0..) |track, index| {
        translation_tracks[index] = .{
            .target_entity_index = track.target_entity_index,
            .interpolation = track.interpolation,
            .times = track.times,
            .values = track.values,
        };
    }

    const rotation_tracks = try allocator.alloc(AnimationClipQuatTrackRecord, clip.rotation_tracks.len);
    for (clip.rotation_tracks, 0..) |track, index| {
        rotation_tracks[index] = .{
            .target_entity_index = track.target_entity_index,
            .interpolation = track.interpolation,
            .times = track.times,
            .values = track.values,
        };
    }

    const scale_tracks = try allocator.alloc(AnimationClipVec3TrackRecord, clip.scale_tracks.len);
    for (clip.scale_tracks, 0..) |track, index| {
        scale_tracks[index] = .{
            .target_entity_index = track.target_entity_index,
            .interpolation = track.interpolation,
            .times = track.times,
            .values = track.values,
        };
    }

    try animation_clip_records.append(allocator, .{
        .asset_id = asset_id,
        .name = clip.name,
        .duration = clip.duration,
        .translation_tracks = translation_tracks,
        .rotation_tracks = rotation_tracks,
        .scale_tracks = scale_tracks,
    });
    try animation_clip_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureScriptRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.ScriptHandle,
    script_asset_ids: *std.AutoHashMap(assets_handles.ScriptHandle, []const u8),
    script_records: *std.ArrayList(ScriptRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) ![]const u8 {
    if (script_asset_ids.get(handle)) |asset_id| {
        return asset_id;
    }

    const script = world.resources.script(handle) orelse return error.ScriptNotFound;
    const asset_record = try ensureScriptAssetRecord(allocator, world, handle, script);
    const asset_id = try ensureSceneAssetRecord(asset_records, allocator, asset_record);

    try script_records.append(allocator, .{
        .asset_id = asset_id,
        .language = scriptComponentLanguage(script.language),
        .entry_fn = script.entry_fn,
        .description = script.description,
        .source_path = script.source_path,
        .artifact_path = script.artifact_path,
        .last_modified = script.last_modified,
        .source = script.source,
        .bytecode_hex = try encodeHexAlloc(allocator, script.bytecode),
        .user_data = script.user_data,
    });
    try script_asset_ids.put(handle, asset_id);
    return asset_id;
}

fn ensureSceneAssetRecord(
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
    allocator: std.mem.Allocator,
    record: asset_registry.AssetRecord,
) ![]const u8 {
    for (asset_records.items) |existing| {
        if (std.mem.eql(u8, existing.id, record.id)) {
            return existing.id;
        }
    }
    try asset_records.append(allocator, record);
    return asset_records.items[asset_records.items.len - 1].id;
}

fn ensureMeshAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MeshHandle,
    mesh: *const @import("../assets/mesh_resource.zig").MeshResource,
) !asset_registry.AssetRecord {
    if (world.resources.meshAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedMeshAssetRecord(allocator, mesh, asset_id);
    }
    return makeEmbeddedMeshAssetRecord(allocator, mesh, null);
}

fn ensureMaterialAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.MaterialHandle,
    material: *const @import("../assets/material_resource.zig").MaterialResource,
    texture_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    if (world.resources.materialAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedMaterialAssetRecord(allocator, material, texture_asset_id, asset_id);
    }
    return makeEmbeddedMaterialAssetRecord(allocator, material, texture_asset_id, null);
}

fn ensureTextureAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.TextureHandle,
    texture: *const @import("../assets/texture_resource.zig").TextureResource,
) !asset_registry.AssetRecord {
    if (world.resources.textureAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedTextureAssetRecord(allocator, texture, asset_id);
    }
    return makeEmbeddedTextureAssetRecord(allocator, texture, null);
}

fn ensureSkeletonAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.SkeletonHandle,
    skeleton: *const @import("../assets/skeleton_resource.zig").SkeletonResource,
) !asset_registry.AssetRecord {
    if (world.resources.skeletonAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedSkeletonAssetRecord(allocator, skeleton, asset_id);
    }
    return makeEmbeddedSkeletonAssetRecord(allocator, skeleton, null);
}

fn ensureSkinAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.SkinHandle,
    skin: *const @import("../assets/skin_resource.zig").SkinResource,
    skeleton_asset_id: []const u8,
) !asset_registry.AssetRecord {
    if (world.resources.skinAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedSkinAssetRecord(allocator, skin, skeleton_asset_id, asset_id);
    }
    return makeEmbeddedSkinAssetRecord(allocator, skin, skeleton_asset_id, null);
}

fn ensureAnimationClipAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.AnimationClipHandle,
    clip: *const @import("../assets/animation_clip_resource.zig").AnimationClipResource,
) !asset_registry.AssetRecord {
    if (world.resources.animationClipAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedAnimationClipAssetRecord(allocator, clip, asset_id);
    }
    return makeEmbeddedAnimationClipAssetRecord(allocator, clip, null);
}

fn ensureScriptAssetRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    handle: assets_handles.ScriptHandle,
    script: *const @import("../assets/script_resource.zig").ScriptResource,
) !asset_registry.AssetRecord {
    if (world.resources.scriptAssetId(handle)) |asset_id| {
        if (world.resources.assetRecordById(asset_id)) |record| {
            return try record.clone(allocator);
        }
        return makeEmbeddedScriptAssetRecord(allocator, script, asset_id);
    }
    return makeEmbeddedScriptAssetRecord(allocator, script, null);
}

fn makeEmbeddedMeshAssetRecord(
    allocator: std.mem.Allocator,
    mesh: *const @import("../assets/mesh_resource.zig").MeshResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const vertices_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.sliceAsBytes(mesh.vertices));
    defer allocator.free(vertices_hash);
    const indices_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.sliceAsBytes(mesh.indices));
    defer allocator.free(indices_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.mesh.v1", &.{
            mesh.name,
            vertices_hash,
            indices_hash,
            @tagName(mesh.primitive_type),
        });

    return .{
        .id = asset_id,
        .type = .mesh,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/meshes/{s}", .{mesh.name}),
        .source_hash = try asset_registry.hashStringAlloc(allocator, vertices_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .mesh),
        .import_version = asset_registry.AssetType.mesh.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, mesh.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.mesh.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedTextureAssetRecord(
    allocator: std.mem.Allocator,
    texture: *const @import("../assets/texture_resource.zig").TextureResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const pixels_hash = try asset_registry.hashBytesAlloc(allocator, texture.pixels);
    defer allocator.free(pixels_hash);

    var width_buffer: [16]u8 = undefined;
    var height_buffer: [16]u8 = undefined;
    const width_text = try std.fmt.bufPrint(&width_buffer, "{d}", .{texture.width});
    const height_text = try std.fmt.bufPrint(&height_buffer, "{d}", .{texture.height});

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.texture.v1", &.{
            texture.name,
            width_text,
            height_text,
            @tagName(texture.format),
            pixels_hash,
        });

    return .{
        .id = asset_id,
        .type = .texture,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/textures/{s}", .{texture.name}),
        .source_hash = try allocator.dupe(u8, pixels_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .texture),
        .import_version = asset_registry.AssetType.texture.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, texture.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.texture.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedMaterialAssetRecord(
    allocator: std.mem.Allocator,
    material: *const @import("../assets/material_resource.zig").MaterialResource,
    texture_asset_id: ?[]const u8,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const factor_hash = try asset_registry.hashBytesAlloc(allocator, std.mem.asBytes(&material.base_color_factor));
    defer allocator.free(factor_hash);

    const texture_part = texture_asset_id orelse "none";
    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.material.v1", &.{
            material.name,
            @tagName(material.shading),
            factor_hash,
            texture_part,
        });

    const dependency_ids = if (texture_asset_id) |resolved|
        try cloneStringList(allocator, &.{resolved})
    else
        try allocator.alloc([]u8, 0);

    return .{
        .id = asset_id,
        .type = .material,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/materials/{s}", .{material.name}),
        .source_hash = try asset_registry.hashStringAlloc(allocator, factor_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .material),
        .import_version = asset_registry.AssetType.material.importVersion(),
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, material.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.material.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedScriptAssetRecord(
    allocator: std.mem.Allocator,
    script: *const @import("../assets/script_resource.zig").ScriptResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const source_hash = try asset_registry.hashBytesAlloc(allocator, script.source);
    defer allocator.free(source_hash);
    const bytecode_hash = try asset_registry.hashBytesAlloc(allocator, script.bytecode);
    defer allocator.free(bytecode_hash);
    const user_data_hash = try asset_registry.hashBytesAlloc(allocator, script.user_data);
    defer allocator.free(user_data_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.script.v1", &.{
            @tagName(script.language),
            script.entry_fn,
            source_hash,
            bytecode_hash,
            user_data_hash,
            script.source_path,
        });

    return .{
        .id = asset_id,
        .type = .script,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/scripts/{s}", .{script.entry_fn}),
        .source_hash = try allocator.dupe(u8, source_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .script),
        .import_version = asset_registry.AssetType.script.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, if (script.description.len != 0) script.description else script.entry_fn),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.script.importerName()),
            .source_extension = try allocator.dupe(u8, scriptSourceExtension(script)),
        },
    };
}

fn makeEmbeddedSkeletonAssetRecord(
    allocator: std.mem.Allocator,
    skeleton: *const @import("../assets/skeleton_resource.zig").SkeletonResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const skeleton_hash = try hashSkeletonAlloc(allocator, skeleton);
    defer allocator.free(skeleton_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.skeleton.v1", &.{
            skeleton.name,
            skeleton_hash,
        });

    return .{
        .id = asset_id,
        .type = .skeleton,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/skeletons/{s}", .{skeleton.name}),
        .source_hash = try allocator.dupe(u8, skeleton_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .skeleton),
        .import_version = asset_registry.AssetType.skeleton.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, skeleton.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.skeleton.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedSkinAssetRecord(
    allocator: std.mem.Allocator,
    skin: *const @import("../assets/skin_resource.zig").SkinResource,
    skeleton_asset_id: []const u8,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const skin_hash = try hashSkinAlloc(allocator, skin, skeleton_asset_id);
    defer allocator.free(skin_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.skin.v1", &.{
            skin.name,
            skeleton_asset_id,
            skin_hash,
        });

    const dependency_ids = try allocator.alloc([]u8, 1);
    dependency_ids[0] = try allocator.dupe(u8, skeleton_asset_id);

    return .{
        .id = asset_id,
        .type = .skin,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/skins/{s}", .{skin.name}),
        .source_hash = try allocator.dupe(u8, skin_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .skin),
        .import_version = asset_registry.AssetType.skin.importVersion(),
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, skin.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.skin.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn makeEmbeddedAnimationClipAssetRecord(
    allocator: std.mem.Allocator,
    clip: *const @import("../assets/animation_clip_resource.zig").AnimationClipResource,
    forced_asset_id: ?[]const u8,
) !asset_registry.AssetRecord {
    const clip_hash = try hashAnimationClipAlloc(allocator, clip);
    defer allocator.free(clip_hash);

    const asset_id = if (forced_asset_id) |id|
        try allocator.dupe(u8, id)
    else
        try asset_registry.makeDerivedAssetIdAlloc(allocator, "guava.scene.animation-clip.v1", &.{
            clip.name,
            clip_hash,
        });

    return .{
        .id = asset_id,
        .type = .animation_clip,
        .source_path = try std.fmt.allocPrint(allocator, "scene://embedded/animation_clips/{s}", .{clip.name}),
        .source_hash = try allocator.dupe(u8, clip_hash),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .animation_clip),
        .import_version = asset_registry.AssetType.animation_clip.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, clip.name),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.animation_clip.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn buildAnimationGraphRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    graph: *const @import("../animation/animation_graph.zig").AnimationGraph,
    animation_clip_asset_ids: *std.AutoHashMap(assets_handles.AnimationClipHandle, []const u8),
    animation_clip_records: *std.ArrayList(AnimationClipRecord),
    asset_records: *std.ArrayList(asset_registry.AssetRecord),
) !AnimationGraphRecord {
    const states = try allocator.alloc(AnimationGraphStateRecord, graph.states.items.len);
    for (graph.states.items, 0..) |state, index| {
        states[index] = .{
            .name = state.name,
            .clip_asset_id = if (state.clip_handle) |clip_handle|
                try ensureAnimationClipRecord(
                    allocator,
                    world,
                    clip_handle,
                    animation_clip_asset_ids,
                    animation_clip_records,
                    asset_records,
                )
            else
                null,
            .speed = state.speed,
            .loop = state.loop,
            .duration_seconds = state.duration_seconds,
        };
    }

    const blend_spaces_1d = try allocator.alloc(AnimationGraphBlendSpace1DRecord, graph.blend_spaces_1d.items.len);
    for (graph.blend_spaces_1d.items, 0..) |blend_space, blend_space_index| {
        const points = try allocator.alloc(AnimationGraphBlendSpacePoint1DRecord, blend_space.points.len);
        for (blend_space.points, 0..) |point, point_index| {
            points[point_index] = .{
                .position = point.position,
                .clip_asset_id = try ensureAnimationClipRecord(
                    allocator,
                    world,
                    point.clip_handle,
                    animation_clip_asset_ids,
                    animation_clip_records,
                    asset_records,
                ),
            };
        }
        blend_spaces_1d[blend_space_index] = .{
            .name = blend_space.name,
            .points = points,
        };
    }

    const blend_spaces_2d = try allocator.alloc(AnimationGraphBlendSpace2DRecord, graph.blend_spaces_2d.items.len);
    for (graph.blend_spaces_2d.items, 0..) |blend_space, blend_space_index| {
        const points = try allocator.alloc(AnimationGraphBlendSpacePoint2DRecord, blend_space.points.len);
        for (blend_space.points, 0..) |point, point_index| {
            points[point_index] = .{
                .position = point.position,
                .clip_asset_id = try ensureAnimationClipRecord(
                    allocator,
                    world,
                    point.clip_handle,
                    animation_clip_asset_ids,
                    animation_clip_records,
                    asset_records,
                ),
            };
        }
        blend_spaces_2d[blend_space_index] = .{
            .name = blend_space.name,
            .points = points,
        };
    }

    const transitions = try allocator.alloc(AnimationGraphTransitionRecord, graph.transitions.items.len);
    for (graph.transitions.items, 0..) |transition, transition_index| {
        const conditions = try allocator.alloc(AnimationGraphTransitionConditionRecord, transition.conditions.len);
        for (transition.conditions, 0..) |condition, condition_index| {
            conditions[condition_index] = switch (condition) {
                .time_remaining => |threshold| .{
                    .kind = .time_remaining,
                    .threshold = threshold,
                },
                .time_elapsed => |threshold| .{
                    .kind = .time_elapsed,
                    .threshold = threshold,
                },
                .parameter => |parameter| .{
                    .kind = .parameter,
                    .threshold = parameter.value,
                    .parameter_name = parameter.name,
                    .comparison = switch (parameter.comparison) {
                        .less => .less,
                        .greater => .greater,
                        .equal => .equal,
                    },
                },
            };
        }

        transitions[transition_index] = .{
            .from_state = transition.from_state,
            .to_state = transition.to_state,
            .duration = transition.duration,
            .conditions = conditions,
        };
    }

    const parameters = try allocator.alloc(AnimationGraphParameterRecord, graph.parameters.items.len);
    for (graph.parameters.items, 0..) |parameter, index| {
        parameters[index] = .{
            .name = parameter.name,
            .type = parameter.type,
            .float_value = switch (parameter.default_value) {
                .float => |value| value,
                else => 0.0,
            },
            .bool_value = switch (parameter.default_value) {
                .bool => |value| value,
                else => false,
            },
            .int_value = switch (parameter.default_value) {
                .int => |value| value,
                else => 0,
            },
        };
    }

    return .{
        .name = graph.name,
        .default_state = graph.default_state,
        .states = states,
        .blend_spaces_1d = blend_spaces_1d,
        .blend_spaces_2d = blend_spaces_2d,
        .transitions = transitions,
        .parameters = parameters,
    };
}

fn buildAnimationGraphFromRecord(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    graph_record: AnimationGraphRecord,
    animation_clip_bindings: []const AnimationClipBinding,
) !@import("../animation/animation_graph.zig").AnimationGraph {
    const animation_graph_mod = @import("../animation/animation_graph.zig");
    var graph = try animation_graph_mod.AnimationGraph.init(allocator, graph_record.name);
    errdefer graph.deinit();

    for (graph_record.states) |state_record| {
        const clip_handle = if (state_record.clip_asset_id) |asset_id|
            findAnimationClipHandle(animation_clip_bindings, asset_id) orelse world.resources.animationClipHandleByAssetId(asset_id) orelse return error.AnimationClipAssetNotFound
        else
            null;
        const state_index = try graph.addState(state_record.name, clip_handle);
        graph.states.items[state_index].speed = state_record.speed;
        graph.states.items[state_index].loop = state_record.loop;
        graph.states.items[state_index].duration_seconds = state_record.duration_seconds;
    }
    graph.default_state = graph_record.default_state;

    for (graph_record.blend_spaces_1d) |blend_space_record| {
        const points = try allocator.alloc(animation_graph_mod.BlendSpacePoint1D, blend_space_record.points.len);
        defer allocator.free(points);
        for (blend_space_record.points, 0..) |point_record, index| {
            points[index] = .{
                .position = point_record.position,
                .clip_handle = findAnimationClipHandle(animation_clip_bindings, point_record.clip_asset_id) orelse world.resources.animationClipHandleByAssetId(point_record.clip_asset_id) orelse return error.AnimationClipAssetNotFound,
            };
        }
        _ = try graph.addBlendSpace1D(blend_space_record.name, points);
    }

    for (graph_record.blend_spaces_2d) |blend_space_record| {
        const points = try allocator.alloc(animation_graph_mod.BlendSpacePoint2D, blend_space_record.points.len);
        defer allocator.free(points);
        for (blend_space_record.points, 0..) |point_record, index| {
            points[index] = .{
                .position = point_record.position,
                .clip_handle = findAnimationClipHandle(animation_clip_bindings, point_record.clip_asset_id) orelse world.resources.animationClipHandleByAssetId(point_record.clip_asset_id) orelse return error.AnimationClipAssetNotFound,
            };
        }
        _ = try graph.addBlendSpace2D(blend_space_record.name, points);
    }

    for (graph_record.parameters) |parameter_record| {
        try graph.addParameter(parameter_record.name, parameter_record.type, switch (parameter_record.type) {
            .float => .{ .float = parameter_record.float_value },
            .bool => .{ .bool = parameter_record.bool_value },
            .trigger => .{ .bool = parameter_record.bool_value },
            .int => .{ .int = parameter_record.int_value },
        });
    }

    for (graph_record.transitions) |transition_record| {
        const conditions = try allocator.alloc(animation_graph_mod.TransitionCondition, transition_record.conditions.len);
        defer {
            for (conditions) |*condition| {
                condition.deinit(allocator);
            }
            allocator.free(conditions);
        }

        for (transition_record.conditions, 0..) |condition_record, index| {
            conditions[index] = switch (condition_record.kind) {
                .time_remaining => .{ .time_remaining = condition_record.threshold },
                .time_elapsed => .{ .time_elapsed = condition_record.threshold },
                .parameter => .{
                    .parameter = .{
                        .name = try allocator.dupe(u8, condition_record.parameter_name orelse return error.AnimationGraphParameterMissing),
                        .value = condition_record.threshold,
                        .comparison = switch (condition_record.comparison) {
                            .less => .less,
                            .greater => .greater,
                            .equal => .equal,
                        },
                    },
                },
            };
        }

        try graph.addTransition(
            transition_record.from_state,
            transition_record.to_state,
            transition_record.duration,
            conditions,
        );
    }

    return graph;
}

fn mapEntityIdsToIndices(
    allocator: std.mem.Allocator,
    entity_indices: *const std.AutoHashMap(world_mod.EntityId, u32),
    target_entities: []const world_mod.EntityId,
) ![]u32 {
    const indices = try allocator.alloc(u32, target_entities.len);
    for (target_entities, 0..) |entity_id, index| {
        indices[index] = entity_indices.get(entity_id) orelse return error.BindingTargetMissing;
    }
    return indices;
}

fn mapEntityIndicesToIds(
    allocator: std.mem.Allocator,
    entity_ids: []const world_mod.EntityId,
    target_indices: []const u32,
) ![]world_mod.EntityId {
    const target_ids = try allocator.alloc(world_mod.EntityId, target_indices.len);
    for (target_indices, 0..) |target_index, index| {
        if (target_index >= entity_ids.len) {
            return error.BindingTargetIndexOutOfBounds;
        }
        target_ids[index] = entity_ids[target_index];
    }
    return target_ids;
}

fn hashSkeletonAlloc(
    allocator: std.mem.Allocator,
    skeleton: *const @import("../assets/skeleton_resource.zig").SkeletonResource,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(skeleton.name);
    for (skeleton.joints) |joint| {
        hasher.update(joint.name);
        hasher.update(std.mem.asBytes(&joint.node_entity_index));
        if (joint.parent_joint_index) |parent_index| {
            hasher.update(&.{1});
            hasher.update(std.mem.asBytes(&parent_index));
        } else {
            hasher.update(&.{0});
        }
        hasher.update(std.mem.asBytes(&joint.rest_local_transform.translation));
        hasher.update(std.mem.asBytes(&joint.rest_local_transform.rotation));
        hasher.update(std.mem.asBytes(&joint.rest_local_transform.scale));
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

fn hashSkinAlloc(
    allocator: std.mem.Allocator,
    skin: *const @import("../assets/skin_resource.zig").SkinResource,
    skeleton_asset_id: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(skin.name);
    hasher.update(skeleton_asset_id);
    hasher.update(std.mem.sliceAsBytes(skin.joint_entity_indices));
    hasher.update(std.mem.sliceAsBytes(skin.inverse_bind_matrices));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

fn hashAnimationClipAlloc(
    allocator: std.mem.Allocator,
    clip: *const @import("../assets/animation_clip_resource.zig").AnimationClipResource,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(clip.name);
    hasher.update(std.mem.asBytes(&clip.duration));
    for (clip.translation_tracks) |track| {
        hasher.update(std.mem.asBytes(&track.target_entity_index));
        hasher.update(@tagName(track.interpolation));
        hasher.update(std.mem.sliceAsBytes(track.times));
        hasher.update(std.mem.sliceAsBytes(track.values));
    }
    for (clip.rotation_tracks) |track| {
        hasher.update(std.mem.asBytes(&track.target_entity_index));
        hasher.update(@tagName(track.interpolation));
        hasher.update(std.mem.sliceAsBytes(track.times));
        hasher.update(std.mem.sliceAsBytes(track.values));
    }
    for (clip.scale_tracks) |track| {
        hasher.update(std.mem.asBytes(&track.target_entity_index));
        hasher.update(@tagName(track.interpolation));
        hasher.update(std.mem.sliceAsBytes(track.times));
        hasher.update(std.mem.sliceAsBytes(track.values));
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

fn scriptSourceExtension(script: *const @import("../assets/script_resource.zig").ScriptResource) []const u8 {
    if (script.source_path.len != 0) {
        const ext = std.fs.path.extension(script.source_path);
        if (ext.len != 0) {
            return ext;
        }
    }
    return switch (script.language) {
        .zig => ".zig",
        .csharp => ".cs",
    };
}

fn scriptResourceLanguage(language: components.ScriptLanguage) script_types.ScriptLanguage {
    return @enumFromInt(@intFromEnum(language));
}

fn scriptComponentLanguage(language: script_types.ScriptLanguage) components.ScriptLanguage {
    return @enumFromInt(@intFromEnum(language));
}

fn bindTextureAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.TextureHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .texture, fallback_name);
    _ = try world.resources.bindTextureAssetRecord(handle, record);
}

fn bindMaterialAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.MaterialHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .material, fallback_name);
    _ = try world.resources.bindMaterialAssetRecord(handle, record);
}

fn bindMeshAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.MeshHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .mesh, fallback_name);
    _ = try world.resources.bindMeshAssetRecord(handle, record);
}

fn bindSkeletonAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.SkeletonHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .skeleton, fallback_name);
    _ = try world.resources.bindSkeletonAssetRecord(handle, record);
}

fn bindSkinAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.SkinHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .skin, fallback_name);
    _ = try world.resources.bindSkinAssetRecord(handle, record);
}

fn bindAnimationClipAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.AnimationClipHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .animation_clip, fallback_name);
    _ = try world.resources.bindAnimationClipAssetRecord(handle, record);
}

fn bindScriptAssetFromScene(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    scene: *const SceneFile,
    asset_id: []const u8,
    fallback_name: []const u8,
    handle: assets_handles.ScriptHandle,
) !void {
    const record = if (findAssetRecord(scene.asset_records, asset_id)) |asset_record|
        try asset_record.clone(allocator)
    else
        try fallbackSceneAssetRecord(allocator, asset_id, .script, fallback_name);
    _ = try world.resources.bindScriptAssetRecord(handle, record);
}

fn fallbackSceneAssetRecord(
    allocator: std.mem.Allocator,
    asset_id: []const u8,
    asset_type: asset_registry.AssetType,
    display_name: []const u8,
) !asset_registry.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, asset_id),
        .type = asset_type,
        .source_path = try std.fmt.allocPrint(allocator, "scene://recovered/{s}/{s}", .{ @tagName(asset_type), display_name }),
        .source_hash = try asset_registry.hashStringAlloc(allocator, asset_id),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, asset_type),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ""),
        },
    };
}

fn findAssetRecord(records: []const asset_registry.AssetRecord, asset_id: []const u8) ?*const asset_registry.AssetRecord {
    for (records) |*record| {
        if (std.mem.eql(u8, record.id, asset_id)) {
            return record;
        }
    }
    return null;
}

fn findTextureHandle(bindings: []const TextureBinding, asset_id: []const u8) ?assets_handles.TextureHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findMaterialHandle(bindings: []const MaterialBinding, asset_id: []const u8) ?assets_handles.MaterialHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findMeshHandle(bindings: []const MeshBinding, asset_id: []const u8) ?assets_handles.MeshHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findSkeletonHandle(bindings: []const SkeletonBinding, asset_id: []const u8) ?assets_handles.SkeletonHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findSkinHandle(bindings: []const SkinBinding, asset_id: []const u8) ?assets_handles.SkinHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findAnimationClipHandle(bindings: []const AnimationClipBinding, asset_id: []const u8) ?assets_handles.AnimationClipHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn findScriptHandle(bindings: []const ScriptBinding, asset_id: []const u8) ?assets_handles.ScriptHandle {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.asset_id, asset_id)) {
            return binding.handle;
        }
    }
    return null;
}

fn makeSceneIdAlloc(
    allocator: std.mem.Allocator,
    entities: []const EntityRecord,
    meshes: []const MeshRecord,
    materials: []const MaterialRecord,
    textures: []const TextureRecord,
    skeletons: []const SkeletonRecord,
    skins: []const SkinRecord,
    animation_clips: []const AnimationClipRecord,
    scripts: []const ScriptRecord,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entities) |entity| {
        hasher.update(entity.name);
        if (entity.mesh) |mesh| {
            hasher.update(mesh.asset_id orelse "none");
        }
        if (entity.skinned_mesh) |skinned_mesh| {
            hasher.update(skinned_mesh.mesh_asset_id orelse "none");
            hasher.update(skinned_mesh.skeleton_asset_id orelse "none");
            hasher.update(skinned_mesh.skin_asset_id orelse "none");
        }
        if (entity.animator) |animator| {
            hasher.update(animator.skeleton_asset_id orelse "none");
            hasher.update(animator.default_clip_asset_id orelse "none");
        }
        if (entity.material) |material| {
            hasher.update(material.asset_id orelse "none");
        }
        if (entity.animation_graph) |graph| {
            hasher.update(graph.name);
        }
        if (entity.script) |script| {
            hasher.update(script.asset_id orelse "none");
            hasher.update(@tagName(script.language));
            hasher.update(if (script.enabled) "1" else "0");
            hasher.update(script.parameters);
        }
    }
    for (meshes) |mesh| hasher.update(mesh.asset_id);
    for (materials) |material| hasher.update(material.asset_id);
    for (textures) |texture| hasher.update(texture.asset_id);
    for (skeletons) |skeleton| hasher.update(skeleton.asset_id);
    for (skins) |skin| hasher.update(skin.asset_id);
    for (animation_clips) |clip| hasher.update(clip.asset_id);
    for (scripts) |script| hasher.update(script.asset_id);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexLowerAlloc(allocator, digest[0..16]);
}

fn encodeHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        const high = byte >> 4;
        const low = byte & 0x0F;
        encoded[index * 2] = nibbleToHex(high);
        encoded[index * 2 + 1] = nibbleToHex(low);
    }
    return encoded;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) {
        return error.InvalidHexEncoding;
    }

    const decoded = try allocator.alloc(u8, encoded.len / 2);
    errdefer allocator.free(decoded);
    _ = try std.fmt.hexToBytes(decoded, encoded);
    return decoded;
}

fn nibbleToHex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn cloneStringList(allocator: std.mem.Allocator, values: []const []const u8) ![][]u8 {
    const cloned = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(cloned);

    var index: usize = 0;
    errdefer {
        while (index > 0) {
            index -= 1;
            allocator.free(cloned[index]);
        }
    }
    while (index < values.len) : (index += 1) {
        cloned[index] = try allocator.dupe(u8, values[index]);
    }
    return cloned;
}

fn applyBuiltinMeshHandle(resources: anytype, name: []const u8, handle: assets_handles.MeshHandle) void {
    if (std.mem.eql(u8, name, "BuiltinCube")) {
        resources.cube_mesh = handle;
    } else if (std.mem.eql(u8, name, "BuiltinSphere")) {
        resources.sphere_mesh = handle;
    } else if (std.mem.eql(u8, name, "BuiltinPlane")) {
        resources.plane_mesh = handle;
    }
}

fn applyBuiltinTextureHandle(resources: anytype, name: []const u8, handle: assets_handles.TextureHandle) void {
    if (std.mem.eql(u8, name, "White1x1")) {
        resources.white_texture = handle;
    }
}

fn applyBuiltinMaterialHandle(resources: anytype, name: []const u8, handle: assets_handles.MaterialHandle) void {
    if (std.mem.eql(u8, name, "DefaultMaterial")) {
        resources.default_material = handle;
    }
}

fn hexLowerAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        encoded[index * 2] = nibbleToHex(byte >> 4);
        encoded[index * 2 + 1] = nibbleToHex(byte & 0x0F);
    }
    return encoded;
}

test "scene serialization round-trips meshes, lights, textures, and asset ids" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    _ = try world.importGltfStaticModel(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ -1.0, 0.0, 0.0 },
        },
    );
    _ = try world.createLightEntity(.point, .{ .translation = .{ 1.0, 1.5, 2.0 } }, 16.0);

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const summary = loaded.summary();
    try std.testing.expectEqual(@as(usize, 7), summary.entity_count);
    try std.testing.expectEqual(@as(usize, 5), summary.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), summary.light_count);
    try std.testing.expect(loaded.findEntityByName("PointLight") != null);
    try std.testing.expect(loaded.findEntityByName("guava_showcase_GuavaShowcase") != null);

    const imported = loaded.findEntityByName("guava_showcase_GuavaShowcase").?;
    const mesh_handle = imported.mesh.?.handle.?;
    const material_handle = imported.material.?.handle.?;
    const mesh = loaded.resources.mesh(mesh_handle).?;
    const material = loaded.resources.material(material_handle).?;
    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expect(material.base_color_texture != null);
    try std.testing.expect(loaded.resources.meshAssetId(mesh_handle) != null);
    try std.testing.expect(loaded.resources.materialAssetId(material_handle) != null);
}

test "scene serialization is byte deterministic for identical world state" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    const first = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(first);
    const second = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "scene save-load-resave is byte stable" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const cwd = std.fs.cwd();
    var original = try cwd.openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    const script_handle = try world.resources.createScript(.{
        .source =
        \\pub var speed: f32 = 2.0;
        \\pub fn onUpdate(dt: f32) void {
        \\    _ = dt;
        \\}
        \\
        ,
        .language = .zig,
        .entry_fn = "main",
        .description = "Scene Patrol",
        .source_path = "assets/scripts/scene_patrol.zig",
        .last_modified = 123456789,
        .bytecode = &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 },
        .user_data = "{\"version\":1,\"parameters\":[]}\n",
    });
    const root = try world.createEntity(.{
        .name = "SceneRoot",
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } },
        .script = .{
            .script_handle = script_handle,
            .language = .zig,
            .enabled = true,
            .parameters = "{\"speed\":6.5}\n",
        },
    });
    _ = try world.createEntity(.{
        .name = "SceneChild",
        .parent = root,
        .visible = false,
        .local_transform = .{ .translation = .{ 0.5, 0.0, -1.0 } },
    });

    try saveWorldToPath(std.testing.allocator, &world, "assets/scenes/test.guava_scene");

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try loadWorldFromPath(std.testing.allocator, &loaded, "assets/scenes/test.guava_scene");
    try saveWorldToPath(std.testing.allocator, &loaded, "assets/scenes/test_resaved.guava_scene");

    const loaded_root = loaded.findEntityByName("SceneRoot").?;
    try std.testing.expect(loaded_root.script != null);
    try std.testing.expectEqualStrings("{\"speed\":6.5}\n", loaded_root.script.?.parameters);
    try std.testing.expect(loaded_root.script.?.script_handle != null);
    const loaded_script = loaded.resources.script(loaded_root.script.?.script_handle.?).?;
    try std.testing.expectEqual(script_types.ScriptLanguage.zig, loaded_script.language);
    try std.testing.expectEqualStrings("Scene Patrol", loaded_script.description);
    try std.testing.expectEqualStrings("assets/scripts/scene_patrol.zig", loaded_script.source_path);
    try std.testing.expectEqual(@as(i128, 123456789), loaded_script.last_modified);
    try std.testing.expectEqualStrings("{\"version\":1,\"parameters\":[]}\n", loaded_script.user_data);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 }, loaded_script.bytecode);
    try std.testing.expect(loaded.resources.scriptAssetId(loaded_root.script.?.script_handle.?) != null);

    const first = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/scenes/test.guava_scene", 4 * 1024 * 1024);
    defer std.testing.allocator.free(first);
    const second = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/scenes/test_resaved.guava_scene", 4 * 1024 * 1024);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "scene runtime snapshot round-trips application state" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity = try world.createEntity(.{
        .name = "Runtime State Entity",
    });
    _ = entity;

    const runtime_state = SceneRuntimeState{
        .global_time = 42.5,
        .time_scale = 0.5,
        .physics_accumulator_seconds = 0.125,
        .game_state = .paused,
    };

    const encoded = try serializeWorldWithRuntimeStateAlloc(std.testing.allocator, &world, runtime_state);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();

    var loaded_runtime_state: SceneRuntimeState = .{};
    try deserializeWorldWithRuntimeStateFromSlice(std.testing.allocator, &loaded, encoded, &loaded_runtime_state);

    try std.testing.expectEqual(runtime_state.game_state, loaded_runtime_state.game_state);
    try std.testing.expectApproxEqAbs(runtime_state.global_time, loaded_runtime_state.global_time, 0.0001);
    try std.testing.expectApproxEqAbs(runtime_state.time_scale, loaded_runtime_state.time_scale, 0.0001);
    try std.testing.expectApproxEqAbs(runtime_state.physics_accumulator_seconds, loaded_runtime_state.physics_accumulator_seconds, 0.0001);
    try std.testing.expectEqualStrings("Runtime State Entity", loaded.findEntityByName("Runtime State Entity").?.name);
}

test "scene runtime snapshot round-trips audio components" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "AudioEmitter",
        .local_transform = .{ .translation = .{ 3.0, 1.0, -2.0 } },
        .audio_source = .{
            .clip_asset_path = "assets/audio/test.wav",
            .bus = .music,
            .volume = 0.35,
            .spatial = true,
            .looping = true,
            .play_on_awake = true,
            .min_distance = 2.0,
            .max_distance = 40.0,
            .doppler_factor = 0.5,
        },
    });
    _ = try world.createEntity(.{
        .name = "AudioListener",
        .audio_listener = .{ .enabled = true },
    });

    const encoded = try serializeWorldWithRuntimeStateAlloc(std.testing.allocator, &world, .{
        .global_time = 1.0,
        .time_scale = 1.0,
        .playback_state = .playing,
        .game_state = .playing,
    });
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const emitter = loaded.findEntityByName("AudioEmitter").?;
    const audio_source = emitter.audio_source.?;
    try std.testing.expectEqualStrings("assets/audio/test.wav", audio_source.clip_asset_path.?);
    try std.testing.expectEqual(components.AudioBus.music, audio_source.bus);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), audio_source.volume, 0.0001);
    try std.testing.expect(audio_source.spatial);
    try std.testing.expect(audio_source.looping);
    try std.testing.expect(audio_source.play_on_awake);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), audio_source.min_distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40.0), audio_source.max_distance, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), audio_source.doppler_factor, 0.0001);
    try std.testing.expect(loaded.findEntityByName("AudioListener").?.audio_listener != null);
}

test "scene serialization round-trips parent relationships" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "Parent",
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = root,
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 0.0 },
        },
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_child = loaded.findEntityByName("Child").?;
    const loaded_root = loaded.findEntityByName("Parent").?;
    try std.testing.expectEqual(loaded_root.id, loaded_child.parent.?);
    const world_transform = loaded.worldTransform(loaded_child.id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), world_transform.translation[1], 0.0001);
    _ = child;
}

test "scene serialization round-trips folder entities" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const folder = try world.createFolderEntity(.{
        .translation = .{ 4.0, 0.0, 0.0 },
    });
    _ = try world.createEntity(.{
        .name = "Child",
        .parent = folder,
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_folder = loaded.findEntityByName("Folder").?;
    try std.testing.expect(loaded_folder.is_folder);
    try std.testing.expectEqual(loaded_folder.id, loaded.findEntityByName("Child").?.parent.?);
}

test "scene serialization round-trips vfx entities" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createVfxEntity(.orbit, .{
        .translation = .{ 2.0, 0.5, -1.0 },
    });

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_vfx = loaded.findEntityByName("OrbitVfx").?;
    try std.testing.expect(loaded_vfx.vfx != null);
    try std.testing.expectEqual(components.VfxKind.orbit, loaded_vfx.vfx.?.kind);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), loaded_vfx.local_transform.translation[0], 0.0001);
}

test "scene serialization round-trips animation bindings and graphs" {
    const animation_graph_mod = @import("../animation/animation_graph.zig");
    const mesh_resource_mod = @import("../assets/mesh_resource.zig");

    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const mesh_handle = try world.resources.createMesh(.{
        .name = "AnimatedMesh",
        .vertices = &.{
            mesh_resource_mod.Vertex{
                .position = .{ 0.0, 0.0, 0.0 },
                .normal = .{ 0.0, 1.0, 0.0 },
                .tangent = .{ 1.0, 0.0, 0.0, 1.0 },
                .color = .{ 1.0, 1.0, 1.0, 1.0 },
                .uv = .{ 0.0, 0.0 },
            },
        },
        .indices = &.{0},
    });

    const skeleton_handle = try world.resources.createSkeleton(.{
        .name = "Rig",
        .joints = &.{
            .{
                .name = "Root",
                .node_entity_index = 0,
            },
        },
    });

    const skin_handle = try world.resources.createSkin(.{
        .name = "RigSkin",
        .skeleton = skeleton_handle,
        .joint_entity_indices = &.{0},
        .inverse_bind_matrices = &.{
            .{ 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 },
        },
    });

    const clip_idle = try world.resources.createAnimationClip(.{
        .name = "Idle",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.1, 0.0 } },
            },
        },
    });

    const clip_run = try world.resources.createAnimationClip(.{
        .name = "Run",
        .duration = 0.5,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 0.5 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.2, 0.0, 0.0 } },
            },
        },
    });

    const joint_id = try world.createEntity(.{
        .name = "JointRoot",
    });

    const skinned_id = try world.createEntity(.{
        .name = "SkinnedActor",
        .skinned_mesh = .{
            .mesh_handle = mesh_handle,
            .primitive = .custom,
            .skeleton_handle = skeleton_handle,
            .skin_handle = skin_handle,
        },
    });
    try world.bindSkinnedMeshTargets(skinned_id, &.{joint_id});

    const animator_id = try world.createEntity(.{
        .name = "AnimatorActor",
        .animator = .{
            .skeleton_handle = skeleton_handle,
            .default_clip_handle = clip_idle,
            .speed = 1.25,
            .looping = false,
        },
    });
    try world.bindAnimatorTargets(animator_id, &.{joint_id});

    var graph = try animation_graph_mod.AnimationGraph.init(std.testing.allocator, "CharacterGraph");
    defer graph.deinit();

    const idle_state = try graph.addState("Idle", clip_idle);
    const run_state = try graph.addState("Run", clip_run);
    graph.default_state = idle_state;
    graph.states.items[run_state].speed = 1.5;
    try graph.addParameter("Speed", .float, .{ .float = 0.0 });

    const parameter_name = try std.testing.allocator.dupe(u8, "Speed");
    defer std.testing.allocator.free(parameter_name);
    const transition_conditions = [_]animation_graph_mod.TransitionCondition{
        .{
            .parameter = .{
                .name = parameter_name,
                .value = 0.5,
                .comparison = .greater,
            },
        },
    };
    try graph.addTransition(idle_state, run_state, 0.2, &transition_conditions);
    try world.bindAnimatorGraph(animator_id, &graph);

    const encoded = try serializeWorldAlloc(std.testing.allocator, &world);
    defer std.testing.allocator.free(encoded);

    var loaded = world_mod.World.init(std.testing.allocator, null);
    defer loaded.deinit();
    try deserializeWorldFromSlice(std.testing.allocator, &loaded, encoded);

    const loaded_joint = loaded.findEntityByName("JointRoot").?;
    const loaded_skinned = loaded.findEntityByName("SkinnedActor").?;
    const loaded_animator = loaded.findEntityByName("AnimatorActor").?;

    try std.testing.expect(loaded_skinned.skinned_mesh != null);
    try std.testing.expect(loaded_animator.animator != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.skinnedMeshTargets(loaded_skinned.id).?.len);
    try std.testing.expectEqual(loaded_joint.id, loaded.skinnedMeshTargets(loaded_skinned.id).?[0]);
    try std.testing.expectEqual(@as(usize, 1), loaded.animatorTargets(loaded_animator.id).?.len);
    try std.testing.expectEqual(loaded_joint.id, loaded.animatorTargets(loaded_animator.id).?[0]);

    try std.testing.expect(loaded.resources.skeleton(loaded_animator.animator.?.skeleton_handle.?) != null);
    try std.testing.expect(loaded.resources.skin(loaded_skinned.skinned_mesh.?.skin_handle.?) != null);
    try std.testing.expect(loaded.resources.animationClip(loaded_animator.animator.?.default_clip_handle.?) != null);

    const loaded_graph = loaded.animatorGraph(loaded_animator.id).?;
    try std.testing.expectEqualStrings("CharacterGraph", loaded_graph.name);
    try std.testing.expectEqual(@as(?u32, idle_state), loaded_graph.default_state);
    try std.testing.expectEqual(@as(usize, 2), loaded_graph.states.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded_graph.transitions.items.len);
    try std.testing.expectEqual(@as(usize, 1), loaded_graph.parameters.items.len);
    try std.testing.expectEqualStrings("Speed", loaded_graph.parameters.items[0].name);
    try std.testing.expect(loaded_graph.states.items[0].clip_handle != null);
    try std.testing.expect(loaded_graph.states.items[1].clip_handle != null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), loaded_graph.states.items[1].speed, 0.0001);
}
