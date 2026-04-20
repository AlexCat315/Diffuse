pub const ProjectTemplate = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    icon: []const u8,
};

pub const project_templates = [_]ProjectTemplate{
    .{
        .id = "empty",
        .name = "Empty Project",
        .description = "A blank project with the basic folder structure.",
        .icon = "file",
    },
    .{
        .id = "3d-basic",
        .name = "3D Basic",
        .description = "A starter scene with camera, light, ground and cube.",
        .icon = "cube",
    },
};

pub const empty_scene_json =
    \\{
    \\  "version": 7,
    \\  "scene": {
    \\    "version": 6,
    \\    "scene_id": "11111111111111111111111111111111",
    \\    "environment_asset_id": null,
    \\    "asset_records": [],
    \\    "meshes": [],
    \\    "textures": [],
    \\    "materials": [],
    \\    "skeletons": [],
    \\    "skins": [],
    \\    "animation_clips": [],
    \\    "scripts": [],
    \\    "entities": [
    \\      {
    \\        "name": "MainCamera",
    \\        "parent": null,
    \\        "local_transform": { "translation": [0, 1.5, 5], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1] },
    \\        "camera": {
    \\          "projection": {
    \\            "perspective": { "fov_y_radians": 1.0471975803375244, "near_clip": 0.1, "far_clip": 1000 }
    \\          },
    \\          "is_primary": true
    \\        },
    \\        "mesh": null,
    \\        "skinned_mesh": null,
    \\        "animator": null,
    \\        "animator_targets": null,
    \\        "skinned_mesh_targets": null,
    \\        "animation_graph": null,
    \\        "animation_graph_instance": null,
    \\        "rigidbody": null,
    \\        "box_collider": null,
    \\        "sphere_collider": null,
    \\        "mesh_collider": null,
    \\        "material": null,
    \\        "light": null,
    \\        "vfx": null,
    \\        "script": null,
    \\        "audio_source": null,
    \\        "audio_listener": null,
    \\        "nav_agent": null,
    \\        "sky": null,
    \\        "visible": true,
    \\        "editor_only": false,
    \\        "dont_destroy_on_load": false,
    \\        "is_folder": false
    \\      },
    \\      {
    \\        "name": "DirectionalLight",
    \\        "parent": null,
    \\        "local_transform": { "translation": [0, 0, 0], "rotation": [-0.4155, 0.2661, 0.1285, 0.8602], "scale": [1, 1, 1] },
    \\        "camera": null,
    \\        "mesh": null,
    \\        "skinned_mesh": null,
    \\        "animator": null,
    \\        "animator_targets": null,
    \\        "skinned_mesh_targets": null,
    \\        "animation_graph": null,
    \\        "animation_graph_instance": null,
    \\        "rigidbody": null,
    \\        "box_collider": null,
    \\        "sphere_collider": null,
    \\        "mesh_collider": null,
    \\        "material": null,
    \\        "light": { "kind": "directional", "color": [1, 0.985, 0.95], "intensity": 3.0, "range": 10 },
    \\        "vfx": null,
    \\        "script": null,
    \\        "audio_source": null,
    \\        "audio_listener": null,
    \\        "nav_agent": null,
    \\        "sky": null,
    \\        "visible": true,
    \\        "editor_only": false,
    \\        "dont_destroy_on_load": false,
    \\        "is_folder": false
    \\      }
    \\    ]
    \\  },
    \\  "runtime_state": {
    \\    "global_time": 0.0,
    \\    "time_scale": 1.0,
    \\    "physics_accumulator_seconds": 0.0,
    \\    "playback_state": "stopped",
    \\    "game_state": "game_start"
    \\  }
    \\}
;

pub const basic_scene_json =
    \\{
    \\  "version": 7,
    \\  "scene": {
    \\    "version": 6,
    \\    "scene_id": "22222222222222222222222222222222",
    \\    "environment_asset_id": null,
    \\    "asset_records": [
    \\      {
    \\        "id": "33333333333333333333333333333333",
    \\        "type": "mesh",
    \\        "source_path": "builtin://mesh/cube",
    \\        "source_hash": "8d997575e78ae4ef38fb34002a04b1d1144e90f7f05a7604267f607282cd7e90",
    \\        "import_settings_hash": "30b08ae5ad5ce2dcaf5f447ad85a72950eb91682dacfd37fdd843861d85b767d",
    \\        "import_version": 1,
    \\        "dependency_ids": [],
    \\        "outputs": [],
    \\        "metadata": { "display_name": "BuiltinCube", "importer": "embedded-mesh-v1", "source_extension": "" },
    \\        "version": 2
    \\      }
    \\    ],
    \\    "meshes": [],
    \\    "textures": [],
    \\    "materials": [],
    \\    "skeletons": [],
    \\    "skins": [],
    \\    "animation_clips": [],
    \\    "scripts": [],
    \\    "entities": [
    \\      {
    \\        "name": "MainCamera",
    \\        "parent": null,
    \\        "local_transform": { "translation": [0, 1.5, 5], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1] },
    \\        "camera": {
    \\          "projection": {
    \\            "perspective": { "fov_y_radians": 1.0471975803375244, "near_clip": 0.1, "far_clip": 1000 }
    \\          },
    \\          "is_primary": true
    \\        },
    \\        "mesh": null,
    \\        "skinned_mesh": null,
    \\        "animator": null,
    \\        "animator_targets": null,
    \\        "skinned_mesh_targets": null,
    \\        "animation_graph": null,
    \\        "animation_graph_instance": null,
    \\        "rigidbody": null,
    \\        "box_collider": null,
    \\        "sphere_collider": null,
    \\        "mesh_collider": null,
    \\        "material": null,
    \\        "light": null,
    \\        "vfx": null,
    \\        "script": null,
    \\        "audio_source": null,
    \\        "audio_listener": null,
    \\        "nav_agent": null,
    \\        "sky": null,
    \\        "visible": true,
    \\        "editor_only": false,
    \\        "dont_destroy_on_load": false,
    \\        "is_folder": false
    \\      },
    \\      {
    \\        "name": "Sun",
    \\        "parent": null,
    \\        "local_transform": { "translation": [0, 0, 0], "rotation": [-0.4155, 0.2661, 0.1285, 0.8602], "scale": [1, 1, 1] },
    \\        "camera": null,
    \\        "mesh": null,
    \\        "skinned_mesh": null,
    \\        "animator": null,
    \\        "animator_targets": null,
    \\        "skinned_mesh_targets": null,
    \\        "animation_graph": null,
    \\        "animation_graph_instance": null,
    \\        "rigidbody": null,
    \\        "box_collider": null,
    \\        "sphere_collider": null,
    \\        "mesh_collider": null,
    \\        "material": null,
    \\        "light": { "kind": "directional", "color": [1, 0.985, 0.95], "intensity": 3.25, "range": 10 },
    \\        "vfx": null,
    \\        "script": null,
    \\        "audio_source": null,
    \\        "audio_listener": null,
    \\        "nav_agent": null,
    \\        "sky": null,
    \\        "visible": true,
    \\        "editor_only": false,
    \\        "dont_destroy_on_load": false,
    \\        "is_folder": false
    \\      }
    \\    ]
    \\  },
    \\  "runtime_state": {
    \\    "global_time": 0.0,
    \\    "time_scale": 1.0,
    \\    "physics_accumulator_seconds": 0.0,
    \\    "playback_state": "stopped",
    \\    "game_state": "game_start"
    \\  }
    \\}
;

pub const starter_script =
    \\//! Guava Engine Starter Script
    \\const guava = @import("guava");
    \\
    \\var angle: f32 = 0.0;
    \\
    \\export fn guava_on_init() callconv(.c) void {
    \\    guava.log("Script initialized");
    \\}
    \\
    \\export fn guava_on_update(dt: f32) callconv(.c) void {
    \\    angle += dt;
    \\    const half = angle * 0.5;
    \\    guava.setRotation(.{ 0.0, @sin(half), 0.0, @cos(half) });
    \\}
;
