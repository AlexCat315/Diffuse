const std = @import("std");
const io_globals = @import("io_globals");
const collaboration_mod = @import("../collaboration.zig");
const protocol = @import("../protocol.zig");
const editor_utility_runtime_mod = @import("../../script/editor_utility_runtime.zig");
const script_runtime_mod = @import("../../script/runtime.zig");
const scene_mod = @import("../../scene/scene.zig");
const components = @import("../../scene/components.zig");
const render_mod = @import("../../render/renderer.zig");
const audio_mod = @import("../../audio/mod.zig");

pub const resource_templates = [_]protocol.ResourceTemplateDescriptor{
    .{
        .uriTemplate = "entity://{id}",
        .name = "Entity Detail",
        .description = "Read-only snapshot for a specific entity id discovered from scene://hierarchy or selection://current.",
        .mimeType = "application/json",
    },
};

const schema_components_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://components",
    .name = "Component Schema",
    .title = "Component Schema",
    .description = "Stable JSON contract for entity fields, vector conventions, enums, and component payloads accepted by Guava Engine.",
    .mimeType = "application/json",
    .size = null,
};

const schema_scene_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://scene-json-v6",
    .name = "Scene JSON v6 Schema",
    .title = "Scene JSON v6 Schema",
    .description = "Stable JSON contract for scene_io.zig scene files, including top-level arrays and entity record payloads.",
    .mimeType = "application/json",
    .size = null,
};

const schema_prefab_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://prefab",
    .name = "Prefab Schema",
    .title = "Prefab Schema",
    .description = "Stable JSON contract for prefab files, prefab entity records, and instance override masks.",
    .mimeType = "application/json",
    .size = null,
};

const schema_material_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://material",
    .name = "Material Schema",
    .title = "Material Schema",
    .description = "Stable JSON contract for MaterialResource and MaterialResourceDesc payloads used by the engine.",
    .mimeType = "application/json",
    .size = null,
};

const schema_tools_descriptor = protocol.ResourceDescriptor{
    .uri = "schema://tools",
    .name = "Tool Schema",
    .title = "Tool Schema",
    .description = "JSON contract for MCP tool arguments, including required fields, paging defaults, and staged transaction inputs.",
    .mimeType = "application/json",
    .size = null,
};

pub const SnapshotStore = struct {
    allocator: std.mem.Allocator,
    collaboration: ?*const collaboration_mod.Store = null,
    script_runtime: ?*const script_runtime_mod.ScriptRuntime = null,
    editor_utility_runtime: ?*const editor_utility_runtime_mod.EditorUtilityRuntime = null,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    ready: bool = false,
    entries: std.ArrayList(ResourceEntry) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        collaboration: ?*const collaboration_mod.Store,
        script_runtime: ?*const script_runtime_mod.ScriptRuntime,
        editor_utility_runtime: ?*const editor_utility_runtime_mod.EditorUtilityRuntime,
    ) SnapshotStore {
        return .{
            .allocator = allocator,
            .collaboration = collaboration,
            .script_runtime = script_runtime,
            .editor_utility_runtime = editor_utility_runtime,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *SnapshotStore) void {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);
        freeEntriesOwned(self.allocator, self.entries.items);
        self.entries.deinit(self.allocator);
    }

    pub fn isReady(self: *const SnapshotStore) bool {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lockUncancelable(io_globals.global_io);
        defer mutable.mutex.unlock(io_globals.global_io);
        return mutable.ready;
    }

    pub fn replaceFromRenderer(self: *SnapshotStore, world: *const scene_mod.World, renderer: *const render_mod.Renderer) !void {
        try self.replaceFromSelection(world, renderer.selectedEntity(), renderer.selectedEntities());
    }

    pub fn replaceFromSelection(
        self: *SnapshotStore,
        world: *const scene_mod.World,
        primary_selection: ?scene_mod.EntityId,
        selected_entities: []const scene_mod.EntityId,
    ) !void {
        const next_entries = try buildResourceEntriesAlloc(self.allocator, world, primary_selection, selected_entities);
        errdefer {
            freeEntriesOwned(self.allocator, next_entries);
            self.allocator.free(next_entries);
        }

        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);

        freeEntriesOwned(self.allocator, self.entries.items);
        self.entries.deinit(self.allocator);
        self.entries = .empty;
        try self.entries.appendSlice(self.allocator, next_entries);
        self.ready = true;

        self.allocator.free(next_entries);
    }

    pub fn listAlloc(self: *const SnapshotStore, allocator: std.mem.Allocator) ![]protocol.ResourceDescriptor {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lockUncancelable(io_globals.global_io);
        defer mutable.mutex.unlock(io_globals.global_io);

        var resources = std.ArrayList(protocol.ResourceDescriptor).empty;
        errdefer {
            for (resources.items) |resource| {
                allocator.free(resource.uri);
                allocator.free(resource.name);
                if (resource.title) |title| {
                    allocator.free(title);
                }
                if (resource.description) |description| {
                    allocator.free(description);
                }
                if (resource.mimeType) |mime_type| {
                    allocator.free(mime_type);
                }
            }
            resources.deinit(allocator);
        }

        const listed_count = countListedResources(mutable.entries.items) +
            5 +
            @as(usize, if (mutable.collaboration != null) 4 else 0) +
            @as(usize, if (mutable.script_runtime != null) 1 else 0) +
            @as(usize, if (mutable.editor_utility_runtime != null) 1 else 0);
        try resources.ensureTotalCapacity(allocator, listed_count);
        for (mutable.entries.items) |entry| {
            if (!shouldListEntry(entry.uri)) {
                continue;
            }
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, entry.uri),
                .name = try allocator.dupe(u8, entry.name),
                .title = if (entry.title) |title| try allocator.dupe(u8, title) else null,
                .description = if (entry.description) |description| try allocator.dupe(u8, description) else null,
                .mimeType = if (entry.mime_type) |mime_type| try allocator.dupe(u8, mime_type) else null,
                .size = entry.text.len,
            });
        }

        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_components_descriptor));
        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_scene_descriptor));
        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_prefab_descriptor));
        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_material_descriptor));
        try resources.append(allocator, try copyResourceDescriptorAlloc(allocator, schema_tools_descriptor));

        if (mutable.collaboration) |_| {
            try collaboration_mod.Store.appendResourceDescriptorsAlloc(allocator, &resources);
        }
        if (mutable.script_runtime != null) {
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, "script://runtime-status"),
                .name = try allocator.dupe(u8, "Script Runtime Status"),
                .title = try allocator.dupe(u8, "Script Runtime Status"),
                .description = try allocator.dupe(u8, "Recent compile, load, and runtime errors reported by the script system."),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .size = null,
            });
        }
        if (mutable.editor_utility_runtime != null) {
            try resources.append(allocator, .{
                .uri = try allocator.dupe(u8, "editor://utilities"),
                .name = try allocator.dupe(u8, "Editor Utilities"),
                .title = try allocator.dupe(u8, "Editor Utilities"),
                .description = try allocator.dupe(u8, "Loaded editor utility panels, open state, and last runtime error."),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .size = null,
            });
        }

        try resources.append(allocator, .{
            .uri = try allocator.dupe(u8, "audio://mixer-status"),
            .name = try allocator.dupe(u8, "Audio Mixer Status"),
            .title = try allocator.dupe(u8, "Audio Mixer Status"),
            .description = try allocator.dupe(u8, "Current audio mixer state: master/music/sfx volumes, active voice count."),
            .mimeType = try allocator.dupe(u8, "application/json"),
            .size = null,
        });

        return try resources.toOwnedSlice(allocator);
    }

    pub fn readAlloc(self: *const SnapshotStore, allocator: std.mem.Allocator, uri: []const u8) !?protocol.TextResourceContents {
        const mutable: *SnapshotStore = @constCast(self);
        mutable.mutex.lockUncancelable(io_globals.global_io);
        defer mutable.mutex.unlock(io_globals.global_io);

        for (mutable.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.uri, uri)) {
                continue;
            }

            return .{
                .uri = try allocator.dupe(u8, entry.uri),
                .mimeType = if (entry.mime_type) |mime_type| try allocator.dupe(u8, mime_type) else null,
                .text = try allocator.dupe(u8, entry.text),
            };
        }

        if (std.mem.eql(u8, uri, "schema://components")) {
            return .{
                .uri = try allocator.dupe(u8, schema_components_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildComponentsSchemaJsonAlloc(allocator),
            };
        }
        if (std.mem.eql(u8, uri, "schema://scene-json-v6")) {
            return .{
                .uri = try allocator.dupe(u8, schema_scene_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildSceneSchemaJsonAlloc(allocator),
            };
        }
        if (std.mem.eql(u8, uri, "schema://prefab")) {
            return .{
                .uri = try allocator.dupe(u8, schema_prefab_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildPrefabSchemaJsonAlloc(allocator),
            };
        }
        if (std.mem.eql(u8, uri, "schema://material")) {
            return .{
                .uri = try allocator.dupe(u8, schema_material_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildMaterialSchemaJsonAlloc(allocator),
            };
        }
        if (std.mem.eql(u8, uri, "schema://tools")) {
            return .{
                .uri = try allocator.dupe(u8, schema_tools_descriptor.uri),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try buildToolsSchemaJsonAlloc(allocator),
            };
        }

        if (mutable.collaboration) |collaboration| {
            return try collaboration.readResourceAlloc(allocator, uri);
        }

        if (mutable.script_runtime != null and std.mem.eql(u8, uri, "script://runtime-status")) {
            return .{
                .uri = try allocator.dupe(u8, "script://runtime-status"),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try mutable.script_runtime.?.buildStatusJsonAlloc(allocator),
            };
        }
        if (mutable.editor_utility_runtime != null and std.mem.eql(u8, uri, "editor://utilities")) {
            return .{
                .uri = try allocator.dupe(u8, "editor://utilities"),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try mutable.editor_utility_runtime.?.buildStatusJsonAlloc(allocator),
            };
        }

        if (std.mem.eql(u8, uri, "audio://mixer-status")) {
            const status = if (audio_mod.get() catch null) |runtime| runtime.getMixerStatus() else audio_mod.MixerStatus{
                .master_volume = 0,
                .music_volume = 0,
                .sfx_volume = 0,
                .active_voices = 0,
                .music_playing = 0,
                .sfx_playing = 0,
            };
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try std.json.Stringify.value(status, .{}, &out.writer);
            return .{
                .uri = try allocator.dupe(u8, "audio://mixer-status"),
                .mimeType = try allocator.dupe(u8, "application/json"),
                .text = try out.toOwnedSlice(),
            };
        }

        return null;
    }
};

pub fn freeResourceDescriptors(allocator: std.mem.Allocator, resources: []protocol.ResourceDescriptor) void {
    for (resources) |resource| {
        allocator.free(resource.uri);
        allocator.free(resource.name);
        if (resource.title) |title| {
            allocator.free(title);
        }
        if (resource.description) |description| {
            allocator.free(description);
        }
        if (resource.mimeType) |mime_type| {
            allocator.free(mime_type);
        }
    }
    allocator.free(resources);
}

fn expectResourceListContains(resources: []const protocol.ResourceDescriptor, uri: []const u8) !void {
    for (resources) |resource| {
        if (std.mem.eql(u8, resource.uri, uri)) {
            return;
        }
    }
    std.debug.print("missing resource uri: {s}\n", .{uri});
    return error.TestExpectedEqual;
}

pub fn freeTextResourceContents(allocator: std.mem.Allocator, content: protocol.TextResourceContents) void {
    allocator.free(content.uri);
    if (content.mimeType) |mime_type| {
        allocator.free(mime_type);
    }
    allocator.free(content.text);
}

const ResourceEntry = struct {
    uri: []u8,
    name: []u8,
    title: ?[]u8 = null,
    description: ?[]u8 = null,
    mime_type: ?[]u8 = null,
    text: []u8,
};

fn shouldListEntry(uri: []const u8) bool {
    return !std.mem.startsWith(u8, uri, "entity://");
}

fn countListedResources(entries: []const ResourceEntry) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (shouldListEntry(entry.uri)) {
            count += 1;
        }
    }
    return count;
}

fn freeEntriesOwned(allocator: std.mem.Allocator, entries: []ResourceEntry) void {
    for (entries) |entry| {
        allocator.free(entry.uri);
        allocator.free(entry.name);
        if (entry.title) |title| {
            allocator.free(title);
        }
        if (entry.description) |description| {
            allocator.free(description);
        }
        if (entry.mime_type) |mime_type| {
            allocator.free(mime_type);
        }
        allocator.free(entry.text);
    }
}

fn copyResourceDescriptorAlloc(
    allocator: std.mem.Allocator,
    descriptor: protocol.ResourceDescriptor,
) !protocol.ResourceDescriptor {
    return .{
        .uri = try allocator.dupe(u8, descriptor.uri),
        .name = try allocator.dupe(u8, descriptor.name),
        .title = if (descriptor.title) |title| try allocator.dupe(u8, title) else null,
        .description = if (descriptor.description) |description| try allocator.dupe(u8, description) else null,
        .mimeType = if (descriptor.mimeType) |mime_type| try allocator.dupe(u8, mime_type) else null,
        .size = descriptor.size,
    };
}

fn buildResourceEntriesAlloc(
    allocator: std.mem.Allocator,
    world: *const scene_mod.World,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) ![]ResourceEntry {
    var entries = std.ArrayList(ResourceEntry).empty;
    errdefer {
        freeEntriesOwned(allocator, entries.items);
        entries.deinit(allocator);
    }

    try entries.append(allocator, try buildSceneHierarchyEntry(allocator, world));
    try entries.append(allocator, try buildSelectionEntry(allocator, primary_selection, selected_entities));

    for (world.entities.items) |entity| {
        try entries.append(allocator, try buildEntityEntry(allocator, world, entity.id));
    }

    return try entries.toOwnedSlice(allocator);
}

fn buildSceneHierarchyEntry(allocator: std.mem.Allocator, world: *const scene_mod.World) !ResourceEntry {
    const text = try buildHierarchyJsonAlloc(allocator, world);
    errdefer allocator.free(text);

    return .{
        .uri = try allocator.dupe(u8, "scene://hierarchy"),
        .name = try allocator.dupe(u8, "Scene Hierarchy"),
        .description = try allocator.dupe(u8, "Current entity tree and scene summary."),
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildSelectionEntry(
    allocator: std.mem.Allocator,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) !ResourceEntry {
    const text = try buildSelectionJsonAlloc(allocator, primary_selection, selected_entities);
    errdefer allocator.free(text);

    return .{
        .uri = try allocator.dupe(u8, "selection://current"),
        .name = try allocator.dupe(u8, "Current Selection"),
        .description = try allocator.dupe(u8, "Primary selection and ordered selected entities."),
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildEntityEntry(allocator: std.mem.Allocator, world: *const scene_mod.World, entity_id: scene_mod.EntityId) !ResourceEntry {
    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    const text = try buildEntityDetailJsonAlloc(allocator, world, entity_id);
    errdefer allocator.free(text);

    const uri = try std.fmt.allocPrint(allocator, "entity://{d}", .{entity_id});
    errdefer allocator.free(uri);

    const description = try std.fmt.allocPrint(allocator, "Snapshot of entity '{s}' ({d}).", .{ entity.name, entity_id });
    errdefer allocator.free(description);

    return .{
        .uri = uri,
        .name = try allocator.dupe(u8, entity.name),
        .description = description,
        .mime_type = try allocator.dupe(u8, "application/json"),
        .text = text,
    };
}

fn buildHierarchyJsonAlloc(allocator: std.mem.Allocator, world: *const scene_mod.World) ![]u8 {
    const HierarchyEntity = struct {
        id: scene_mod.EntityId,
        name: []const u8,
        parent: ?scene_mod.EntityId = null,
        children: []const scene_mod.EntityId,
        visible: bool,
        editor_only: bool,
        is_folder: bool,
    };
    const HierarchySnapshot = struct {
        world_revision: u64,
        roots: []const scene_mod.EntityId,
        entities: []const HierarchyEntity,
        summary: scene_mod.Summary,
    };

    var roots = std.ArrayList(scene_mod.EntityId).empty;
    defer roots.deinit(allocator);
    var entities = std.ArrayList(HierarchyEntity).empty;
    defer entities.deinit(allocator);

    for (world.entities.items) |entity| {
        if (entity.parent == null) {
            try roots.append(allocator, entity.id);
        }
        try entities.append(allocator, .{
            .id = entity.id,
            .name = entity.name,
            .parent = entity.parent,
            .children = entity.children.items,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
        });
    }

    return stringifyAlloc(allocator, HierarchySnapshot{
        .world_revision = world.sceneRevision(),
        .roots = roots.items,
        .entities = entities.items,
        .summary = world.summary(),
    });
}

fn buildSelectionJsonAlloc(
    allocator: std.mem.Allocator,
    primary_selection: ?scene_mod.EntityId,
    selected_entities: []const scene_mod.EntityId,
) ![]u8 {
    const SelectionSnapshot = struct {
        primary: ?scene_mod.EntityId = null,
        entities: []const scene_mod.EntityId,
    };

    return stringifyAlloc(allocator, SelectionSnapshot{
        .primary = primary_selection,
        .entities = selected_entities,
    });
}

fn buildEntityDetailJsonAlloc(allocator: std.mem.Allocator, world: *const scene_mod.World, entity_id: scene_mod.EntityId) ![]u8 {
    const MeshView = struct {
        handle: ?u32 = null,
        primitive: components.Primitive = .custom,
    };
    const SkinnedMeshView = struct {
        mesh_handle: ?u32 = null,
        primitive: components.Primitive = .custom,
        skeleton_handle: ?u32 = null,
        skin_handle: ?u32 = null,
    };
    const AnimatorView = struct {
        skeleton_handle: ?u32 = null,
        default_clip_handle: ?u32 = null,
        time_seconds: f32 = 0.0,
        next_clip_handle: ?u32 = null,
        next_time_seconds: f32 = 0.0,
        blend_duration_seconds: f32 = 0.0,
        blend_time_seconds: f32 = 0.0,
        speed: f32 = 1.0,
        playing: bool = true,
        looping: bool = true,
    };
    const MaterialView = struct {
        handle: ?u32 = null,
        shading: components.ShadingModel = .pbr_metallic_roughness,
        base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
        metallic_factor: f32 = 1.0,
        roughness_factor: f32 = 1.0,
        alpha_cutoff: f32 = 0.5,
        double_sided: bool = false,
    };
    const ScriptView = struct {
        script_handle: ?u32 = null,
        language: components.ScriptLanguage = .zig,
        instance_id: ?u64 = null,
        enabled: bool = true,
        parameters: []const u8 = "",
    };
    const BoundsView = struct {
        min: [3]f32,
        max: [3]f32,
    };
    const ComponentsView = struct {
        camera: ?components.Camera = null,
        mesh: ?MeshView = null,
        skinned_mesh: ?SkinnedMeshView = null,
        animator: ?AnimatorView = null,
        rigidbody: ?components.Rigidbody = null,
        box_collider: ?components.BoxCollider = null,
        sphere_collider: ?components.SphereCollider = null,
        mesh_collider: ?components.MeshCollider = null,
        constraint: ?components.Constraint = null,
        material: ?MaterialView = null,
        light: ?components.Light = null,
        vfx: ?components.Vfx = null,
        script: ?ScriptView = null,
    };
    const EntityDetail = struct {
        id: scene_mod.EntityId,
        name: []const u8,
        parent: ?scene_mod.EntityId = null,
        children: []const scene_mod.EntityId,
        visible: bool,
        editor_only: bool,
        is_folder: bool,
        dirty: bool,
        local_transform: components.Transform,
        world_transform: components.Transform,
        world_matrix: [16]f32,
        world_bounds: ?BoundsView = null,
        components: ComponentsView,
    };

    const entity = world.getEntityConst(entity_id) orelse return error.EntityNotFound;
    const world_transform = world.worldTransformConst(entity_id) orelse entity.local_transform;
    const world_bounds = if (world.worldBoundsConst(entity_id)) |bounds| BoundsView{
        .min = bounds.min,
        .max = bounds.max,
    } else null;

    return stringifyAlloc(allocator, EntityDetail{
        .id = entity.id,
        .name = entity.name,
        .parent = entity.parent,
        .children = entity.children.items,
        .visible = entity.visible,
        .editor_only = entity.editor_only,
        .is_folder = entity.is_folder,
        .dirty = entity.dirty,
        .local_transform = entity.local_transform,
        .world_transform = world_transform,
        .world_matrix = entity.world_matrix_cache,
        .world_bounds = world_bounds,
        .components = .{
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh| .{
                .handle = optionalHandleValue(mesh.handle),
                .primitive = mesh.primitive,
            } else null,
            .skinned_mesh = if (entity.skinned_mesh) |skinned_mesh| .{
                .mesh_handle = optionalHandleValue(skinned_mesh.mesh_handle),
                .primitive = skinned_mesh.primitive,
                .skeleton_handle = optionalHandleValue(skinned_mesh.skeleton_handle),
                .skin_handle = optionalHandleValue(skinned_mesh.skin_handle),
            } else null,
            .animator = if (entity.animator) |animator| .{
                .skeleton_handle = optionalHandleValue(animator.skeleton_handle),
                .default_clip_handle = optionalHandleValue(animator.default_clip_handle),
                .time_seconds = animator.time_seconds,
                .next_clip_handle = optionalHandleValue(animator.next_clip_handle),
                .next_time_seconds = animator.next_time_seconds,
                .blend_duration_seconds = animator.blend_duration_seconds,
                .blend_time_seconds = animator.blend_time_seconds,
                .speed = animator.speed,
                .playing = animator.playing,
                .looping = animator.looping,
            } else null,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .constraint = entity.constraint,
            .material = if (entity.material) |material| .{
                .handle = optionalHandleValue(material.handle),
                .shading = material.shading,
                .base_color_factor = material.base_color_factor,
                .emissive_factor = material.emissive_factor,
                .metallic_factor = material.metallic_factor,
                .roughness_factor = material.roughness_factor,
                .alpha_cutoff = material.alpha_cutoff,
                .double_sided = material.double_sided,
            } else null,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = if (entity.script) |script| .{
                .script_handle = optionalHandleValue(script.script_handle),
                .language = script.language,
                .instance_id = script.instance_id,
                .enabled = script.enabled,
                .parameters = script.parameters,
            } else null,
        },
    });
}

fn buildComponentsSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const TypeSchema = struct {
        name: []const u8,
        encoding: []const u8,
        example: ?[]const f32 = null,
    };
    const EnumSchema = struct {
        name: []const u8,
        values: []const []const u8,
    };
    const FieldSchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const SectionSchema = struct {
        name: []const u8,
        description: []const u8,
        fields: []const FieldSchema,
    };
    const ContractSchema = struct {
        version: []const u8,
        conventions: struct {
            vectors_are_arrays: bool,
            arrays_not_objects: bool,
            notes: []const []const u8,
        },
        shared_types: []const TypeSchema,
        enums: []const EnumSchema,
        entity_fields: []const FieldSchema,
        components: []const SectionSchema,
    };

    const vec2_example = [_]f32{ 0.0, 0.0 };
    const vec3_example = [_]f32{ 0.0, 0.0, 0.0 };
    const quat_example = [_]f32{ 0.0, 0.0, 0.0, 1.0 };
    const color4_example = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const primitive_values = [_][]const u8{ "cube", "sphere", "plane", "custom" };
    const shading_values = [_][]const u8{ "unlit", "lambert", "pbr_metallic_roughness" };
    const light_values = [_][]const u8{ "directional", "point", "spot" };
    const vfx_values = [_][]const u8{ "fountain", "orbit" };
    const script_language_values = [_][]const u8{ "zig", "csharp" };
    const rigidbody_motion_values = [_][]const u8{ "static", "dynamic", "kinematic" };
    const constraint_values = [_][]const u8{ "point_to_point", "hinge", "slider", "distance" };
    const entity_fields = [_]FieldSchema{
        .{ .name = "name", .type = "string", .description = "Entity display name.", .required = true },
        .{ .name = "parent", .type = "entity_id|null", .description = "Parent entity id or null for a root." },
        .{ .name = "local_transform", .type = "Transform", .description = "Local transform, always encoded with array vectors." },
        .{ .name = "visible", .type = "bool", .description = "Entity visibility flag." },
        .{ .name = "editor_only", .type = "bool", .description = "Whether the entity is editor-only." },
        .{ .name = "is_folder", .type = "bool", .description = "Hierarchy organization flag." },
    };
    const camera_fields = [_]FieldSchema{
        .{ .name = "is_primary", .type = "bool", .description = "Marks the primary scene camera." },
        .{ .name = "projection", .type = "CameraProjection", .description = "Either { perspective = ... } or { orthographic = ... }." },
    };
    const mesh_fields = [_]FieldSchema{
        .{ .name = "handle", .type = "asset_handle|null", .description = "Optional mesh asset handle." },
        .{ .name = "primitive", .type = "Primitive", .description = "Fallback primitive when no mesh handle is bound." },
    };
    const skinned_mesh_fields = [_]FieldSchema{
        .{ .name = "mesh_handle", .type = "asset_handle|null", .description = "Optional mesh asset handle." },
        .{ .name = "primitive", .type = "Primitive", .description = "Fallback primitive when no mesh handle is bound." },
        .{ .name = "skeleton_handle", .type = "asset_handle|null", .description = "Skeleton asset handle." },
        .{ .name = "skin_handle", .type = "asset_handle|null", .description = "Skin asset handle." },
    };
    const animator_fields = [_]FieldSchema{
        .{ .name = "skeleton_handle", .type = "asset_handle|null", .description = "Skeleton asset handle." },
        .{ .name = "default_clip_handle", .type = "asset_handle|null", .description = "Default animation clip handle." },
        .{ .name = "time_seconds", .type = "f32", .description = "Current animation time." },
        .{ .name = "next_clip_handle", .type = "asset_handle|null", .description = "Pending next clip handle." },
        .{ .name = "next_time_seconds", .type = "f32", .description = "Time in the pending next clip." },
        .{ .name = "blend_duration_seconds", .type = "f32", .description = "Blend duration in seconds." },
        .{ .name = "blend_time_seconds", .type = "f32", .description = "Current blend progress." },
        .{ .name = "speed", .type = "f32", .description = "Playback speed multiplier." },
        .{ .name = "playing", .type = "bool", .description = "Animation playing flag." },
        .{ .name = "looping", .type = "bool", .description = "Animation looping flag." },
    };
    const rigidbody_fields = [_]FieldSchema{
        .{ .name = "motion_type", .type = "RigidbodyMotionType", .description = "Motion mode for physics integration." },
        .{ .name = "mass", .type = "f32", .description = "Mass in kilograms." },
        .{ .name = "linear_velocity", .type = "Vec3", .description = "Linear velocity vector." },
        .{ .name = "angular_velocity", .type = "Vec3", .description = "Angular velocity vector." },
        .{ .name = "gravity_scale", .type = "f32", .description = "Gravity multiplier." },
        .{ .name = "linear_damping", .type = "f32", .description = "Linear damping coefficient." },
        .{ .name = "angular_damping", .type = "f32", .description = "Angular damping coefficient." },
        .{ .name = "allow_sleep", .type = "bool", .description = "Whether the rigidbody may sleep." },
    };
    const box_collider_fields = [_]FieldSchema{
        .{ .name = "half_extents", .type = "Vec3", .description = "Half extents of the box." },
        .{ .name = "center", .type = "Vec3", .description = "Local center offset." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const sphere_collider_fields = [_]FieldSchema{
        .{ .name = "radius", .type = "f32", .description = "Sphere radius." },
        .{ .name = "center", .type = "Vec3", .description = "Local center offset." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const mesh_collider_fields = [_]FieldSchema{
        .{ .name = "use_attached_mesh", .type = "bool", .description = "Use the attached mesh as the collision source." },
        .{ .name = "is_trigger", .type = "bool", .description = "Trigger-only collider flag." },
        .{ .name = "layer_id", .type = "u16", .description = "Collision layer id." },
        .{ .name = "layer_group", .type = "u16", .description = "Collision layer mask." },
    };
    const constraint_fields = [_]FieldSchema{
        .{ .name = "constraint_type", .type = "ConstraintType", .description = "Constraint kind." },
        .{ .name = "entity_a", .type = "entity_id", .description = "First constrained entity.", .required = true },
        .{ .name = "entity_b", .type = "entity_id", .description = "Second constrained entity.", .required = true },
        .{ .name = "pivot_a", .type = "Vec3", .description = "Constraint pivot on entity A." },
        .{ .name = "pivot_b", .type = "Vec3", .description = "Constraint pivot on entity B." },
        .{ .name = "axis_a", .type = "Vec3", .description = "Constraint axis on entity A." },
        .{ .name = "axis_b", .type = "Vec3", .description = "Constraint axis on entity B." },
        .{ .name = "min_limit", .type = "f32", .description = "Minimum distance or angle limit." },
        .{ .name = "max_limit", .type = "f32", .description = "Maximum distance or angle limit." },
        .{ .name = "is_enabled", .type = "bool", .description = "Constraint enabled flag." },
    };
    const material_fields = [_]FieldSchema{
        .{ .name = "handle", .type = "asset_handle|null", .description = "Optional material asset handle." },
        .{ .name = "shading", .type = "ShadingModel", .description = "Shading model enum." },
        .{ .name = "base_color_factor", .type = "Vec4", .description = "RGBA base color multiplier." },
        .{ .name = "emissive_factor", .type = "Vec3", .description = "RGB emissive multiplier." },
        .{ .name = "metallic_factor", .type = "f32", .description = "Metalness factor." },
        .{ .name = "roughness_factor", .type = "f32", .description = "Roughness factor." },
        .{ .name = "alpha_cutoff", .type = "f32", .description = "Alpha cutoff threshold." },
        .{ .name = "double_sided", .type = "bool", .description = "Double-sided rendering flag." },
    };
    const light_fields = [_]FieldSchema{
        .{ .name = "kind", .type = "LightKind", .description = "Light type enum." },
        .{ .name = "color", .type = "Vec3", .description = "RGB light color." },
        .{ .name = "intensity", .type = "f32", .description = "Light intensity multiplier." },
        .{ .name = "range", .type = "f32", .description = "Point/spot light range." },
    };
    const vfx_fields = [_]FieldSchema{
        .{ .name = "kind", .type = "VfxKind", .description = "Built-in VFX preset enum." },
        .{ .name = "looping", .type = "bool", .description = "Loop playback flag." },
        .{ .name = "emission_rate", .type = "f32", .description = "Particles per second." },
        .{ .name = "particle_lifetime", .type = "f32", .description = "Lifetime in seconds." },
        .{ .name = "speed", .type = "f32", .description = "Initial particle speed." },
        .{ .name = "max_particles", .type = "u16", .description = "Maximum living particles." },
        .{ .name = "radius", .type = "f32", .description = "Spawn radius." },
        .{ .name = "spread", .type = "f32", .description = "Emission spread." },
        .{ .name = "size", .type = "f32", .description = "Particle size." },
        .{ .name = "color", .type = "Vec3", .description = "RGB particle color." },
    };
    const script_fields = [_]FieldSchema{
        .{ .name = "script_handle", .type = "asset_handle|null", .description = "Script resource handle." },
        .{ .name = "language", .type = "ScriptLanguage", .description = "Script language enum." },
        .{ .name = "instance_id", .type = "u64|null", .description = "Runtime script instance id." },
        .{ .name = "enabled", .type = "bool", .description = "Script enabled flag." },
        .{ .name = "parameters", .type = "string", .description = "Serialized script parameter payload." },
    };

    return stringifyAlloc(allocator, ContractSchema{
        .version = "1",
        .conventions = .{
            .vectors_are_arrays = true,
            .arrays_not_objects = true,
            .notes = &.{
                "Vec2, Vec3, Quat, and Vec4 values must be JSON arrays, not keyed objects.",
                "Optional handles and parent ids use null when absent.",
                "Enum fields must use the exact lowercase strings declared in this schema.",
            },
        },
        .shared_types = &.{
            .{ .name = "Vec2", .encoding = "array<f32,2>", .example = &vec2_example },
            .{ .name = "Vec3", .encoding = "array<f32,3>", .example = &vec3_example },
            .{ .name = "Quat", .encoding = "array<f32,4>", .example = &quat_example },
            .{ .name = "Vec4", .encoding = "array<f32,4>", .example = &color4_example },
            .{ .name = "Transform", .encoding = "{ translation: Vec3, rotation: Quat, scale: Vec3 }" },
            .{ .name = "CameraProjection", .encoding = "{ perspective: {...} } | { orthographic: {...} }" },
        },
        .enums = &.{
            .{ .name = "Primitive", .values = &primitive_values },
            .{ .name = "ShadingModel", .values = &shading_values },
            .{ .name = "LightKind", .values = &light_values },
            .{ .name = "VfxKind", .values = &vfx_values },
            .{ .name = "ScriptLanguage", .values = &script_language_values },
            .{ .name = "RigidbodyMotionType", .values = &rigidbody_motion_values },
            .{ .name = "ConstraintType", .values = &constraint_values },
        },
        .entity_fields = &entity_fields,
        .components = &.{
            .{ .name = "camera", .description = "Camera component payload.", .fields = &camera_fields },
            .{ .name = "mesh", .description = "Mesh component payload.", .fields = &mesh_fields },
            .{ .name = "skinned_mesh", .description = "Skinned mesh component payload.", .fields = &skinned_mesh_fields },
            .{ .name = "animator", .description = "Animator component payload.", .fields = &animator_fields },
            .{ .name = "rigidbody", .description = "Rigidbody component payload.", .fields = &rigidbody_fields },
            .{ .name = "box_collider", .description = "Box collider component payload.", .fields = &box_collider_fields },
            .{ .name = "sphere_collider", .description = "Sphere collider component payload.", .fields = &sphere_collider_fields },
            .{ .name = "mesh_collider", .description = "Mesh collider component payload.", .fields = &mesh_collider_fields },
            .{ .name = "constraint", .description = "Constraint component payload.", .fields = &constraint_fields },
            .{ .name = "material", .description = "Material component payload.", .fields = &material_fields },
            .{ .name = "light", .description = "Light component payload.", .fields = &light_fields },
            .{ .name = "vfx", .description = "VFX component payload.", .fields = &vfx_fields },
            .{ .name = "script", .description = "Script component payload.", .fields = &script_fields },
        },
    });
}

fn buildSceneSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const FieldSchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const SectionSchema = struct {
        name: []const u8,
        description: []const u8,
        fields: []const FieldSchema,
    };
    const SchemaDocument = struct {
        version: []const u8,
        source: []const u8,
        notes: []const []const u8,
        root: []const FieldSchema,
        sections: []const SectionSchema,
    };

    const scene_fields = [_]FieldSchema{
        .{ .name = "version", .type = "u32", .description = "Scene schema version. Current stable value is 6.", .required = true },
        .{ .name = "scene_id", .type = "string", .description = "Stable scene asset identifier.", .required = true },
        .{ .name = "asset_records", .type = "AssetRecord[]", .description = "Asset registry rows referenced by the scene.", .required = true },
        .{ .name = "meshes", .type = "MeshRecord[]", .description = "Embedded or referenced mesh resources.", .required = true },
        .{ .name = "textures", .type = "TextureRecord[]", .description = "Texture resources used by the scene.", .required = true },
        .{ .name = "materials", .type = "MaterialRecord[]", .description = "Material resources used by the scene.", .required = true },
        .{ .name = "skeletons", .type = "SkeletonRecord[]", .description = "Optional skeleton resources." },
        .{ .name = "skins", .type = "SkinRecord[]", .description = "Optional skin resources." },
        .{ .name = "animation_clips", .type = "AnimationClipRecord[]", .description = "Optional animation clips." },
        .{ .name = "scripts", .type = "ScriptRecord[]", .description = "Embedded script resources referenced by the scene." },
        .{ .name = "entities", .type = "EntityRecord[]", .description = "Flat entity array with parent indices.", .required = true },
    };
    const material_record_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string", .description = "Stable material asset id.", .required = true },
        .{ .name = "name", .type = "string", .description = "Display name.", .required = true },
        .{ .name = "shading", .type = "ShadingModel", .description = "Material shading model.", .required = true },
        .{ .name = "base_color_factor", .type = "Vec4", .description = "RGBA multiplier encoded as an array.", .required = true },
        .{ .name = "base_color_texture_asset_id", .type = "string|null", .description = "Optional base color texture asset id." },
    };
    const mesh_component_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string|null", .description = "Optional mesh asset id." },
        .{ .name = "primitive", .type = "Primitive", .description = "Fallback primitive enum." },
    };
    const material_component_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string|null", .description = "Optional material asset id." },
        .{ .name = "shading", .type = "ShadingModel", .description = "Material shading model override." },
        .{ .name = "base_color_factor", .type = "Vec4", .description = "RGBA multiplier encoded as an array." },
    };
    const script_record_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string", .description = "Stable script asset id.", .required = true },
        .{ .name = "language", .type = "ScriptLanguage", .description = "Script language enum.", .required = true },
        .{ .name = "entry_fn", .type = "string", .description = "Script entry function name.", .required = true },
        .{ .name = "description", .type = "string", .description = "Human readable script description." },
        .{ .name = "source_path", .type = "string", .description = "Original source path when available." },
        .{ .name = "last_modified", .type = "i128", .description = "Last observed source mtime." },
        .{ .name = "source", .type = "string", .description = "Script source text.", .required = true },
        .{ .name = "bytecode_hex", .type = "string", .description = "Compiled bytecode encoded as lowercase hex." },
        .{ .name = "user_data", .type = "string", .description = "Script metadata payload, currently used for reflected parameter schema." },
    };
    const script_component_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string|null", .description = "Optional referenced script asset id." },
        .{ .name = "language", .type = "ScriptLanguage", .description = "Script language enum.", .required = true },
        .{ .name = "enabled", .type = "bool", .description = "Whether the script starts enabled." },
        .{ .name = "parameters", .type = "string", .description = "Serialized script parameter payload string." },
    };
    const entity_record_fields = [_]FieldSchema{
        .{ .name = "name", .type = "string", .description = "Entity display name.", .required = true },
        .{ .name = "parent", .type = "u32|null", .description = "Parent entity index or null for a root." },
        .{ .name = "local_transform", .type = "Transform", .description = "Local transform with array vectors." },
        .{ .name = "camera", .type = "Camera|null", .description = "Optional camera payload." },
        .{ .name = "mesh", .type = "MeshComponentRecord|null", .description = "Optional mesh component record." },
        .{ .name = "skinned_mesh", .type = "SkinnedMeshComponentRecord|null", .description = "Optional skinned mesh component record." },
        .{ .name = "animator", .type = "AnimatorComponentRecord|null", .description = "Optional animator component record." },
        .{ .name = "material", .type = "MaterialComponentRecord|null", .description = "Optional material component record." },
        .{ .name = "light", .type = "Light|null", .description = "Optional light payload." },
        .{ .name = "vfx", .type = "Vfx|null", .description = "Optional VFX payload." },
        .{ .name = "script", .type = "ScriptComponentRecord|null", .description = "Optional script component payload." },
        .{ .name = "visible", .type = "bool", .description = "Entity visibility flag." },
        .{ .name = "editor_only", .type = "bool", .description = "Editor-only flag." },
        .{ .name = "is_folder", .type = "bool", .description = "Hierarchy folder flag." },
    };

    return stringifyAlloc(allocator, SchemaDocument{
        .version = "6",
        .source = "src/engine/scene/scene_io.zig",
        .notes = &.{
            "This resource documents the stable JSON surface, not every private helper struct in scene_io.zig.",
            "Vec2, Vec3, Vec4, and Quat values remain JSON arrays, matching schema://components.",
            "EntityRecord uses flat storage with parent indices instead of recursive children arrays.",
            "Script bytecode is persisted as lowercase hex so scenes can reload resources without recompilation.",
        },
        .root = &scene_fields,
        .sections = &.{
            .{ .name = "SceneFile", .description = "Top-level scene document.", .fields = &scene_fields },
            .{ .name = "MaterialRecord", .description = "Serialized material asset record.", .fields = &material_record_fields },
            .{ .name = "ScriptRecord", .description = "Serialized script resource row.", .fields = &script_record_fields },
            .{ .name = "MeshComponentRecord", .description = "Serialized mesh component payload inside EntityRecord.", .fields = &mesh_component_fields },
            .{ .name = "MaterialComponentRecord", .description = "Serialized material component payload inside EntityRecord.", .fields = &material_component_fields },
            .{ .name = "ScriptComponentRecord", .description = "Serialized script component payload inside EntityRecord.", .fields = &script_component_fields },
            .{ .name = "EntityRecord", .description = "Flat entity row in the scene file.", .fields = &entity_record_fields },
        },
    });
}

fn buildPrefabSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const FieldSchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const SectionSchema = struct {
        name: []const u8,
        description: []const u8,
        fields: []const FieldSchema,
    };
    const SchemaDocument = struct {
        version: []const u8,
        source: []const u8,
        notes: []const []const u8,
        root: []const FieldSchema,
        sections: []const SectionSchema,
    };

    const prefab_fields = [_]FieldSchema{
        .{ .name = "version", .type = "u32", .description = "Prefab schema version. Current stable value is 1.", .required = true },
        .{ .name = "prefab_id", .type = "string", .description = "Stable prefab identifier.", .required = true },
        .{ .name = "root_entity_name", .type = "string", .description = "Root entity display name.", .required = true },
        .{ .name = "asset_records", .type = "AssetRecord[]", .description = "Asset registry rows referenced by the prefab.", .required = true },
        .{ .name = "meshes", .type = "MeshRecord[]", .description = "Embedded or referenced mesh resources.", .required = true },
        .{ .name = "textures", .type = "TextureRecord[]", .description = "Texture resources used by the prefab.", .required = true },
        .{ .name = "materials", .type = "MaterialRecord[]", .description = "Material resources used by the prefab.", .required = true },
        .{ .name = "entities", .type = "PrefabEntityRecord[]", .description = "Flat prefab entity array keyed by prefab_entity_id.", .required = true },
    };
    const prefab_entity_fields = [_]FieldSchema{
        .{ .name = "prefab_entity_id", .type = "u32", .description = "Stable id used inside the prefab.", .required = true },
        .{ .name = "name", .type = "string", .description = "Entity display name.", .required = true },
        .{ .name = "parent", .type = "u32|null", .description = "Parent prefab_entity_id or null for a root." },
        .{ .name = "local_transform", .type = "Transform", .description = "Local transform with array vectors." },
        .{ .name = "mesh", .type = "MeshComponentRecord|null", .description = "Optional mesh component payload." },
        .{ .name = "material", .type = "MaterialComponentRecord|null", .description = "Optional material component payload." },
        .{ .name = "script", .type = "ScriptComponentRecord|null", .description = "Optional script component payload." },
        .{ .name = "visible", .type = "bool", .description = "Visibility flag." },
        .{ .name = "editor_only", .type = "bool", .description = "Editor-only flag." },
        .{ .name = "is_folder", .type = "bool", .description = "Hierarchy folder flag." },
        .{ .name = "nested_prefab_id", .type = "string|null", .description = "Optional nested prefab reference." },
    };
    const script_component_fields = [_]FieldSchema{
        .{ .name = "asset_id", .type = "string|null", .description = "Optional referenced script asset id." },
        .{ .name = "language", .type = "ScriptLanguage", .description = "Script language enum.", .required = true },
        .{ .name = "enabled", .type = "bool", .description = "Whether the script starts enabled." },
        .{ .name = "parameters", .type = "string", .description = "Serialized script parameter payload string." },
    };
    const override_mask_fields = [_]FieldSchema{
        .{ .name = "local_transform", .type = "bool", .description = "Whether local transform override is active." },
        .{ .name = "name", .type = "bool", .description = "Whether name override is active." },
        .{ .name = "visible", .type = "bool", .description = "Whether visibility override is active." },
        .{ .name = "mesh", .type = "bool", .description = "Whether mesh override is active." },
        .{ .name = "material", .type = "bool", .description = "Whether material override is active." },
        .{ .name = "light", .type = "bool", .description = "Whether light override is active." },
        .{ .name = "camera", .type = "bool", .description = "Whether camera override is active." },
        .{ .name = "rigidbody", .type = "bool", .description = "Whether rigidbody override is active." },
        .{ .name = "collider", .type = "bool", .description = "Whether collider override is active." },
        .{ .name = "vfx", .type = "bool", .description = "Whether VFX override is active." },
        .{ .name = "script", .type = "bool", .description = "Whether script override is active." },
    };

    return stringifyAlloc(allocator, SchemaDocument{
        .version = "1",
        .source = "src/engine/scene/prefab.zig",
        .notes = &.{
            "Prefab files use flat entity storage keyed by prefab_entity_id.",
            "OverrideMask is a runtime-facing contract for instance overrides and should stay aligned with prefab instance editing.",
            "Vector fields remain array encoded, matching schema://components.",
            "Prefab script payloads preserve asset ids and parameter strings, but script resources themselves are still resolved through the target world asset library.",
        },
        .root = &prefab_fields,
        .sections = &.{
            .{ .name = "PrefabFile", .description = "Top-level prefab document.", .fields = &prefab_fields },
            .{ .name = "ScriptComponentRecord", .description = "Serialized script component payload inside a prefab entity row.", .fields = &script_component_fields },
            .{ .name = "PrefabEntityRecord", .description = "Serialized entity row inside a prefab file.", .fields = &prefab_entity_fields },
            .{ .name = "OverrideMask", .description = "Prefab instance override flags.", .fields = &override_mask_fields },
        },
    });
}

fn buildMaterialSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const FieldSchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const SchemaDocument = struct {
        version: []const u8,
        source: []const u8,
        notes: []const []const u8,
        resource: []const FieldSchema,
        resource_desc: []const FieldSchema,
    };

    const resource_fields = [_]FieldSchema{
        .{ .name = "name", .type = "string", .description = "Material display name.", .required = true },
        .{ .name = "shading", .type = "ShadingModel", .description = "Material shading model." },
        .{ .name = "base_color_factor", .type = "Vec4", .description = "RGBA multiplier encoded as an array." },
        .{ .name = "base_color_texture", .type = "texture_handle|null", .description = "Optional base color texture handle." },
        .{ .name = "metallic_roughness_texture", .type = "texture_handle|null", .description = "Optional metallic-roughness texture handle." },
        .{ .name = "normal_texture", .type = "texture_handle|null", .description = "Optional normal map handle." },
        .{ .name = "occlusion_texture", .type = "texture_handle|null", .description = "Optional occlusion texture handle." },
        .{ .name = "emissive_texture", .type = "texture_handle|null", .description = "Optional emissive texture handle." },
        .{ .name = "emissive_factor", .type = "Vec3", .description = "RGB emissive multiplier encoded as an array." },
        .{ .name = "metallic_factor", .type = "f32", .description = "Metalness factor." },
        .{ .name = "roughness_factor", .type = "f32", .description = "Roughness factor." },
        .{ .name = "alpha_cutoff", .type = "f32", .description = "Alpha cutoff threshold." },
        .{ .name = "double_sided", .type = "bool", .description = "Double-sided rendering flag." },
        .{ .name = "use_ibl", .type = "bool", .description = "Enable image based lighting." },
        .{ .name = "ibl_intensity", .type = "f32", .description = "IBL intensity multiplier." },
    };

    return stringifyAlloc(allocator, SchemaDocument{
        .version = "1",
        .source = "src/engine/assets/material_resource.zig",
        .notes = &.{
            "MaterialResource and MaterialResourceDesc intentionally share the same field surface.",
            "Texture references are runtime handles; text assets should map ids to handles before instantiation.",
            "Color and vector values remain JSON arrays, not keyed objects.",
        },
        .resource = &resource_fields,
        .resource_desc = &resource_fields,
    });
}

fn buildToolsSchemaJsonAlloc(allocator: std.mem.Allocator) ![]u8 {
    const PropertySchema = struct {
        name: []const u8,
        type: []const u8,
        description: []const u8,
        required: bool = false,
    };
    const ToolSchema = struct {
        name: []const u8,
        description: []const u8,
        properties: []const PropertySchema,
    };
    const ToolsDocument = struct {
        version: []const u8,
        notes: []const []const u8,
        tools: []const ToolSchema,
    };

    const create_entity_properties = [_]PropertySchema{
        .{ .name = "name", .type = "string", .description = "Entity display name.", .required = true },
        .{ .name = "parent", .type = "entity_id|null", .description = "Optional parent entity id." },
        .{ .name = "visible", .type = "bool", .description = "Initial visibility flag." },
        .{ .name = "editor_only", .type = "bool", .description = "Initial editor-only flag." },
        .{ .name = "is_folder", .type = "bool", .description = "Create a hierarchy folder instead of a renderable entity." },
        .{ .name = "local_transform", .type = "Transform", .description = "Optional initial local transform." },
        .{ .name = "components", .type = "object", .description = "Optional component payloads using schema://components." },
    };
    const delete_entity_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Target entity id.", .required = true },
    };
    const rename_entity_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Target entity id.", .required = true },
        .{ .name = "name", .type = "string", .description = "New entity display name.", .required = true },
    };
    const set_parent_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Target entity id.", .required = true },
        .{ .name = "parent_id", .type = "entity_id|null", .description = "Parent entity id or null to re-root.", .required = true },
    };
    const transform_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Target entity id.", .required = true },
        .{ .name = "translation", .type = "Vec3", .description = "Translation array [x, y, z]." },
        .{ .name = "rotation", .type = "Quat", .description = "Quaternion array [x, y, z, w]." },
        .{ .name = "scale", .type = "Vec3", .description = "Scale array [x, y, z]." },
    };
    const set_visible_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Target entity id.", .required = true },
        .{ .name = "visible", .type = "bool", .description = "New visibility flag.", .required = true },
    };
    const query_entities_properties = [_]PropertySchema{
        .{ .name = "id", .type = "entity_id", .description = "Filter to one entity id." },
        .{ .name = "name_contains", .type = "string", .description = "Case-insensitive substring filter." },
        .{ .name = "has_component", .type = "string", .description = "Component name from schema://components." },
        .{ .name = "parent_id", .type = "entity_id", .description = "Filter by parent entity id." },
        .{ .name = "visible", .type = "bool", .description = "Filter by visibility flag." },
        .{ .name = "origin", .type = "Vec3", .description = "Center of radius query." },
        .{ .name = "radius", .type = "f32", .description = "Radius in world units." },
        .{ .name = "aabb_min", .type = "Vec3", .description = "Inclusive minimum corner for AABB point query." },
        .{ .name = "aabb_max", .type = "Vec3", .description = "Inclusive maximum corner for AABB point query." },
        .{ .name = "limit", .type = "usize", .description = "Maximum rows to return. Default 50." },
        .{ .name = "offset", .type = "usize", .description = "Row offset for paging. Default 0." },
        .{ .name = "count_only", .type = "bool", .description = "Return only totals without item payloads." },
    };
    const compile_script_properties = [_]PropertySchema{
        .{ .name = "entity_id", .type = "entity_id", .description = "Attach or replace the script on this entity." },
        .{ .name = "script_handle", .type = "script_handle", .description = "Optional existing script handle to replace." },
        .{ .name = "source", .type = "string", .description = "Zig source for the script.", .required = true },
        .{ .name = "source_path", .type = "string", .description = "Optional source path label shown in diagnostics." },
        .{ .name = "description", .type = "string", .description = "Optional human label for the compile request." },
        .{ .name = "enabled", .type = "bool", .description = "Whether the resulting script starts enabled." },
    };
    const compile_editor_utility_properties = [_]PropertySchema{
        .{ .name = "script_handle", .type = "script_handle", .description = "Optional existing utility script handle to replace." },
        .{ .name = "source", .type = "string", .description = "Zig source to compile into an editor utility panel.", .required = true },
        .{ .name = "source_path", .type = "string", .description = "Optional source path label shown in diagnostics." },
        .{ .name = "description", .type = "string", .description = "Optional human label stored on the script resource." },
        .{ .name = "utility_name", .type = "string", .description = "Panel title shown in the editor window tab." },
        .{ .name = "open", .type = "bool", .description = "Whether the utility window should start open." },
    };
    const stage_transaction_properties = [_]PropertySchema{
        .{ .name = "commands", .type = "Command[]", .description = "Ordered staged commands to preview before apply.", .required = true },
        .{ .name = "label", .type = "string", .description = "Human-readable preview label." },
        .{ .name = "meta", .type = "object", .description = "Command metadata object (actor/client/session/request/trace/approval/base_revision)." },
        .{ .name = "actor", .type = "string", .description = "Actor id (legacy top-level shorthand)." },
        .{ .name = "client", .type = "string", .description = "Client id (legacy top-level shorthand)." },
        .{ .name = "session", .type = "string", .description = "Session id (legacy top-level shorthand)." },
        .{ .name = "request", .type = "string", .description = "Request id (legacy top-level shorthand)." },
        .{ .name = "trace", .type = "string", .description = "Trace id (legacy top-level shorthand)." },
        .{ .name = "approval", .type = "string", .description = "Approval state: auto/previewed/user_approved/rejected." },
        .{ .name = "base_revision", .type = "u64", .description = "Expected scene revision before applying queued command." },
    };
    const apply_preview_properties = [_]PropertySchema{
        .{ .name = "meta", .type = "object", .description = "Command metadata object (actor/client/session/request/trace/approval/base_revision)." },
        .{ .name = "actor", .type = "string", .description = "Actor id (legacy top-level shorthand)." },
        .{ .name = "client", .type = "string", .description = "Client id (legacy top-level shorthand)." },
        .{ .name = "session", .type = "string", .description = "Session id (legacy top-level shorthand)." },
        .{ .name = "request", .type = "string", .description = "Request id (legacy top-level shorthand)." },
        .{ .name = "trace", .type = "string", .description = "Trace id (legacy top-level shorthand)." },
        .{ .name = "approval", .type = "string", .description = "Approval state: auto/previewed/user_approved/rejected." },
        .{ .name = "base_revision", .type = "u64", .description = "Expected scene revision before applying queued command." },
    };
    const discard_preview_properties = apply_preview_properties;

    return stringifyAlloc(allocator, ToolsDocument{
        .version = "1",
        .notes = &.{
            "All vector and quaternion arguments inherit the array encoding rules from schema://components.",
            "query_entities should default to paged access: limit=50, offset=0, count_only=false.",
            "AABB filtering requires both aabb_min and aabb_max (Vec3 arrays).",
            "Staged transaction commands share the same command payload shapes as the write tools they wrap.",
        },
        .tools = &.{
            .{ .name = "create_entity", .description = "Create a new entity and optional initial component payloads.", .properties = &create_entity_properties },
            .{ .name = "delete_entity", .description = "Delete an entity by id.", .properties = &delete_entity_properties },
            .{ .name = "rename_entity", .description = "Rename an entity.", .properties = &rename_entity_properties },
            .{ .name = "set_parent", .description = "Re-parent an entity or move it to the root.", .properties = &set_parent_properties },
            .{ .name = "set_local_transform", .description = "Write local transform channels on an entity.", .properties = &transform_properties },
            .{ .name = "set_world_transform", .description = "Write world transform channels on an entity.", .properties = &transform_properties },
            .{ .name = "set_visible", .description = "Update entity visibility.", .properties = &set_visible_properties },
            .{ .name = "query_entities", .description = "Run a paged entity query with optional radius and AABB spatial filtering.", .properties = &query_entities_properties },
            .{ .name = "compile_script", .description = "Register Zig source as a script and optionally attach it to an entity.", .properties = &compile_script_properties },
            .{ .name = "compile_editor_utility", .description = "Register Zig source as an editor utility panel.", .properties = &compile_editor_utility_properties },
            .{ .name = "stage_transaction", .description = "Preview a staged command batch without committing it to the main world.", .properties = &stage_transaction_properties },
            .{ .name = "apply_staged_transaction", .description = "Commit the current staged transaction into the main world.", .properties = &apply_preview_properties },
            .{ .name = "discard_staged_transaction", .description = "Discard the current staged transaction preview.", .properties = &discard_preview_properties },
        },
    });
}

fn optionalHandleValue(handle: anytype) ?u32 {
    if (handle) |resolved| {
        const raw = @intFromEnum(resolved);
        if (raw == 0) {
            return null;
        }
        return @intCast(raw);
    }
    return null;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

test "SnapshotStore publishes read-only hierarchy, selection, and entity snapshots" {
    var store = SnapshotStore.init(std.testing.allocator, null, null, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "Root",
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = root,
        .visible = false,
    });
    world.updateHierarchy();

    try store.replaceFromSelection(&world, root, &.{ root, child });
    try std.testing.expect(store.isReady());

    const listed = try store.listAlloc(std.testing.allocator);
    defer freeResourceDescriptors(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 8), listed.len);
    try expectResourceListContains(listed, "scene://hierarchy");
    try expectResourceListContains(listed, "selection://current");
    try expectResourceListContains(listed, "schema://components");
    try expectResourceListContains(listed, "schema://scene-json-v6");
    try expectResourceListContains(listed, "schema://prefab");
    try expectResourceListContains(listed, "schema://material");
    try expectResourceListContains(listed, "schema://tools");

    const selection = (try store.readAlloc(std.testing.allocator, "selection://current")).?;
    defer freeTextResourceContents(std.testing.allocator, selection);
    try std.testing.expect(std.mem.indexOf(u8, selection.text, "\"primary\": 1") != null);

    const entity = (try store.readAlloc(std.testing.allocator, "entity://2")).?;
    defer freeTextResourceContents(std.testing.allocator, entity);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"name\": \"Child\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, entity.text, "\"visible\": false") != null);
}

test "SnapshotStore exposes collaboration context and preview resources" {
    var collaboration = collaboration_mod.Store.init(std.testing.allocator);
    defer collaboration.deinit();

    var store = SnapshotStore.init(std.testing.allocator, &collaboration, null, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try store.replaceFromSelection(&world, null, &.{});
    try collaboration.updateContext(.{
        .selected_entities = &.{},
        .viewport_size = .{ 1920, 1080 },
        .camera_transform = .{},
        .camera_projection = .{},
    });

    const listed = try store.listAlloc(std.testing.allocator);
    defer freeResourceDescriptors(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 12), listed.len);
    try expectResourceListContains(listed, "scene://hierarchy");
    try expectResourceListContains(listed, "selection://current");
    try expectResourceListContains(listed, "schema://components");
    try expectResourceListContains(listed, "schema://scene-json-v6");
    try expectResourceListContains(listed, "schema://prefab");
    try expectResourceListContains(listed, "schema://material");
    try expectResourceListContains(listed, "schema://tools");
    try expectResourceListContains(listed, "editor://context");
    try expectResourceListContains(listed, "editor://intent-log");
    try expectResourceListContains(listed, "editor://command-timeline");
    try expectResourceListContains(listed, "preview://staged");

    const context = (try store.readAlloc(std.testing.allocator, "editor://context")).?;
    defer freeTextResourceContents(std.testing.allocator, context);
    try std.testing.expect(std.mem.indexOf(u8, context.text, "\"viewport\"") != null);

    const preview = (try store.readAlloc(std.testing.allocator, "preview://staged")).?;
    defer freeTextResourceContents(std.testing.allocator, preview);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "\"active\": false") != null);
}

test "resource templates advertise dynamic entity snapshots" {
    try std.testing.expectEqual(@as(usize, 1), resource_templates.len);
    try std.testing.expectEqualStrings("entity://{id}", resource_templates[0].uriTemplate);
    try std.testing.expectEqualStrings("application/json", resource_templates[0].mimeType.?);
}

test "SnapshotStore exposes schema resource for AI-facing component contracts" {
    var store = SnapshotStore.init(std.testing.allocator, null, null, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try store.replaceFromSelection(&world, null, &.{});

    const schema = (try store.readAlloc(std.testing.allocator, "schema://components")).?;
    defer freeTextResourceContents(std.testing.allocator, schema);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"vectors_are_arrays\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"name\": \"material\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema.text, "\"name\": \"ScriptLanguage\"") != null);
}

test "SnapshotStore exposes scene, prefab, material, and tool schemas" {
    var store = SnapshotStore.init(std.testing.allocator, null, null, null);
    defer store.deinit();

    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try store.replaceFromSelection(&world, null, &.{});

    const scene_schema = (try store.readAlloc(std.testing.allocator, "schema://scene-json-v6")).?;
    defer freeTextResourceContents(std.testing.allocator, scene_schema);
    try std.testing.expect(std.mem.indexOf(u8, scene_schema.text, "\"name\": \"SceneFile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scene_schema.text, "\"name\": \"EntityRecord\"") != null);

    const prefab_schema = (try store.readAlloc(std.testing.allocator, "schema://prefab")).?;
    defer freeTextResourceContents(std.testing.allocator, prefab_schema);
    try std.testing.expect(std.mem.indexOf(u8, prefab_schema.text, "\"name\": \"PrefabFile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prefab_schema.text, "\"name\": \"OverrideMask\"") != null);

    const material_schema = (try store.readAlloc(std.testing.allocator, "schema://material")).?;
    defer freeTextResourceContents(std.testing.allocator, material_schema);
    try std.testing.expect(std.mem.indexOf(u8, material_schema.text, "\"name\": \"base_color_texture\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, material_schema.text, "\"name\": \"ibl_intensity\"") != null);

    const tools_schema = (try store.readAlloc(std.testing.allocator, "schema://tools")).?;
    defer freeTextResourceContents(std.testing.allocator, tools_schema);
    try std.testing.expect(std.mem.indexOf(u8, tools_schema.text, "\"name\": \"query_entities\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_schema.text, "\"name\": \"compile_script\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_schema.text, "\"name\": \"stage_transaction\"") != null);
}
