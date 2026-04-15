const std = @import("std");
const io_globals = @import("io_globals");
const asset_registry = @import("../assets/registry.zig");
const assets_handles = @import("../assets/handles.zig");
const mesh_mod = @import("../assets/mesh_resource.zig");
const rhi_types = @import("../rhi/types.zig");
const components = @import("components.zig");
const world_mod = @import("world.zig");

const current_prefab_version: u32 = 1;

/// Prefab 库 - 管理所有 Prefab 资源
pub const PrefabLibrary = struct {
    allocator: std.mem.Allocator,
    /// Prefab ID -> PrefabResource
    prefabs: std.StringHashMap(*PrefabResource),

    pub fn init(allocator: std.mem.Allocator) PrefabLibrary {
        return .{
            .allocator = allocator,
            .prefabs = std.StringHashMap(*PrefabResource).init(allocator),
        };
    }

    pub fn deinit(self: *PrefabLibrary) void {
        var it = self.prefabs.valueIterator();
        while (it.next()) |prefab_ptr| {
            prefab_ptr.*.deinit();
            self.allocator.destroy(prefab_ptr.*);
        }
        self.prefabs.deinit();
    }

    /// 注册 Prefab
    pub fn registerPrefab(self: *PrefabLibrary, prefab: *PrefabResource) !void {
        if (try self.prefabs.fetchPut(prefab.id, prefab)) |existing| {
            existing.value.deinit();
            self.allocator.destroy(existing.value);
        }
    }

    /// 获取 Prefab
    pub fn getPrefab(self: *const PrefabLibrary, id: []const u8) ?*PrefabResource {
        return self.prefabs.get(id);
    }

    /// 移除 Prefab
    pub fn removePrefab(self: *PrefabLibrary, id: []const u8) bool {
        if (self.prefabs.fetchRemove(id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
            return true;
        }
        return false;
    }
};

/// Prefab ID 格式: prefab://assets/prefabs/hero/v1
pub const PrefabId = []const u8;

/// Prefab 文件结构 (版本 1)
const PrefabFile = struct {
    version: u32 = current_prefab_version,
    prefab_id: []const u8,
    root_entity_name: []const u8,
    asset_records: []asset_registry.AssetRecord,
    meshes: []MeshRecord,
    textures: []TextureRecord,
    materials: []MaterialRecord,
    /// 扁平化存储的实体数组，通过 parent 字段建立关系
    entities: []PrefabEntityRecord,
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
};

const MeshComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    primitive: components.Primitive = .custom,
};

const MaterialComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

const ScriptComponentRecord = struct {
    asset_id: ?[]const u8 = null,
    language: components.ScriptLanguage = .zig,
    enabled: bool = true,
    parameters: []const u8 = "",
};

/// Prefab 中的实体记录
const PrefabEntityRecord = struct {
    /// 实体在原始 Prefab 中的唯一标识 (用于实例化时映射)
    prefab_entity_id: u32,
    name: []const u8,
    parent: ?u32 = null, // 指向父实体的 prefab_entity_id
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?MeshComponentRecord = null,
    rigidbody: ?components.Rigidbody = null,
    box_collider: ?components.BoxCollider = null,
    sphere_collider: ?components.SphereCollider = null,
    mesh_collider: ?components.MeshCollider = null,
    capsule_collider: ?components.CapsuleCollider = null,
    character_controller: ?components.CharacterController = null,
    tag: ?components.Tag = null,
    sky: ?components.Sky = null,
    material: ?MaterialComponentRecord = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?ScriptComponentRecord = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    /// 引用的嵌套 Prefab ID
    nested_prefab_id: ?[]const u8 = null,
};

/// Prefab 资源
pub const PrefabResource = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    name: []u8,
    source_path: ?[]u8 = null,
    version: u32 = 1,
    /// 扁平化存储的实体数据
    entities: []PrefabEntityData,
    /// 资源引用映射 (asset_id -> handle)
    mesh_asset_bindings: std.AutoHashMap([]const u8, assets_handles.MeshHandle),
    texture_asset_bindings: std.AutoHashMap([]const u8, assets_handles.TextureHandle),
    material_asset_bindings: std.AutoHashMap([]const u8, assets_handles.MaterialHandle),
    /// 嵌套 Prefab 引用
    nested_prefab_ids: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) PrefabResource {
        return .{
            .allocator = allocator,
            .id = allocator.dupe(u8, id) catch unreachable,
            .name = allocator.dupe(u8, name) catch unreachable,
            .entities = &.{},
            .mesh_asset_bindings = std.AutoHashMap([]const u8, assets_handles.MeshHandle).init(allocator),
            .texture_asset_bindings = std.AutoHashMap([]const u8, assets_handles.TextureHandle).init(allocator),
            .material_asset_bindings = std.AutoHashMap([]const u8, assets_handles.MaterialHandle).init(allocator),
            .nested_prefab_ids = .empty,
        };
    }

    pub fn deinit(self: *PrefabResource) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        if (self.source_path) |path| self.allocator.free(path);
        for (self.entities) |*entity| {
            entity.deinit(self.allocator);
        }
        self.allocator.free(self.entities);
        self.mesh_asset_bindings.deinit();
        self.texture_asset_bindings.deinit();
        self.material_asset_bindings.deinit();
        for (self.nested_prefab_ids.items) |prefab_id| {
            self.allocator.free(prefab_id);
        }
        self.nested_prefab_ids.deinit(self.allocator);
    }
};

/// Prefab 中的实体数据 (运行时使用)
pub const PrefabEntityData = struct {
    /// 在原始 Prefab 中的唯一标识
    prefab_entity_id: u32,
    name: []u8,
    parent: ?u32 = null,
    mesh_asset_id: ?[]u8 = null,
    material_asset_id: ?[]u8 = null,
    script_asset_id: ?[]u8 = null,
    local_transform: components.Transform = .{},
    camera: ?components.Camera = null,
    mesh: ?components.Mesh = null,
    skinned_mesh: ?components.SkinnedMesh = null,
    animator: ?components.Animator = null,
    rigidbody: ?components.Rigidbody = null,
    box_collider: ?components.BoxCollider = null,
    sphere_collider: ?components.SphereCollider = null,
    mesh_collider: ?components.MeshCollider = null,
    capsule_collider: ?components.CapsuleCollider = null,
    character_controller: ?components.CharacterController = null,
    tag: ?components.Tag = null,
    sky: ?components.Sky = null,
    material: ?components.Material = null,
    light: ?components.Light = null,
    vfx: ?components.Vfx = null,
    script: ?components.Script = null,
    visible: bool = true,
    editor_only: bool = false,
    is_folder: bool = false,
    /// 引用的嵌套 Prefab ID
    nested_prefab_id: ?[]u8 = null,

    pub fn deinit(self: *PrefabEntityData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.mesh_asset_id) |asset_id| allocator.free(asset_id);
        if (self.material_asset_id) |asset_id| allocator.free(asset_id);
        if (self.script_asset_id) |asset_id| allocator.free(asset_id);
        if (self.script) |script| {
            freeScriptParameters(allocator, script.parameters);
        }
        if (self.nested_prefab_id) |id| allocator.free(id);
    }
};

fn cloneScriptComponent(allocator: std.mem.Allocator, script: ?components.Script) !?components.Script {
    const value = script orelse return null;
    var cloned = value;
    cloned.parameters = if (value.parameters.len != 0) try allocator.dupe(u8, value.parameters) else &.{};
    return cloned;
}

fn freeScriptParameters(allocator: std.mem.Allocator, parameters: []const u8) void {
    if (parameters.len != 0) {
        allocator.free(parameters);
    }
}

/// Prefab 实例覆盖数据 - 存储在实体上
pub const PrefabInstanceOverride = struct {
    /// 实例所属的 Prefab ID
    prefab_id: []u8,
    /// Prefab 版本号
    prefab_version: u32,
    /// 根实体在 Prefab 中的 entity_id
    root_prefab_entity_id: u32,
    /// 覆盖的字段掩码
    override_mask: OverrideMask = .{},
    /// 覆盖的变换
    local_transform_override: ?components.Transform = null,
    /// 覆盖的名称
    name_override: ?[]u8 = null,
    /// 覆盖的可见性
    visible_override: ?bool = null,

    pub fn deinit(self: *PrefabInstanceOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.prefab_id);
        if (self.name_override) |name| allocator.free(name);
    }
};

/// 覆盖字段掩码
pub const OverrideMask = struct {
    local_transform: bool = false,
    name: bool = false,
    visible: bool = false,
    mesh: bool = false,
    material: bool = false,
    light: bool = false,
    camera: bool = false,
    rigidbody: bool = false,
    collider: bool = false,
    vfx: bool = false,
    script: bool = false,
};

/// Prefab 实例化选项
pub const InstantiateOptions = struct {
    /// 实例名称前缀
    name_prefix: ?[]const u8 = null,
    /// 实例化后的根变换
    transform: components.Transform = .{},
    /// 是否立即初始化资源
    load_resources: bool = true,
};

/// 从 Prefab 序列化
pub fn serializePrefabAlloc(
    allocator: std.mem.Allocator,
    prefab: *const PrefabResource,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 构建 PrefabFile
    const prefab_file = try buildPrefabFile(arena, prefab);

    return try std.json.Stringify.valueAlloc(allocator, prefab_file, .{ .whitespace = .indent_2 });
}

/// 从 JSON 反序列化
pub fn deserializePrefabFromSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
) !PrefabResource {
    var header_parse = try std.json.parseFromSlice(PrefabHeader, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer header_parse.deinit();

    switch (header_parse.value.version) {
        1 => return try deserializePrefabV1FromSlice(allocator, source),
        else => return error.UnsupportedPrefabVersion,
    }
}

/// 保存 Prefab 到文件
pub fn savePrefabToPath(
    allocator: std.mem.Allocator,
    prefab: *const PrefabResource,
    path: []const u8,
) !void {
    const encoded = try serializePrefabAlloc(allocator, prefab);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io_globals.global_io, directory);
    }
    try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
        .sub_path = path,
        .data = encoded,
    });
}

/// 从文件加载 Prefab
pub fn loadPrefabFromPath(
    allocator: std.mem.Allocator,
    path: []const u8,
) !PrefabResource {
    const source = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(source);
    var prefab = try deserializePrefabFromSlice(allocator, source);
    prefab.source_path = try allocator.dupe(u8, path);
    return prefab;
}

/// 创建 Prefab (从 World 中的实体树)
pub fn createPrefabFromEntities(
    allocator: std.mem.Allocator,
    world: *const world_mod.World,
    root_entity_id: world_mod.EntityId,
    prefab_id: []const u8,
) !PrefabResource {
    const root_entity = world.getEntityConst(root_entity_id) orelse return error.EntityNotFound;
    var prefab = PrefabResource.init(allocator, prefab_id, root_entity.name);

    // 构建实体列表 (扁平化)
    var entity_list = std.ArrayList(world_mod.EntityId).empty;
    defer entity_list.deinit(allocator);

    try collectEntitiesRecursive(root_entity_id, world, &entity_list, allocator);

    // 转换实体数据
    var entity_data_list = std.ArrayList(PrefabEntityData).empty;
    defer {
        for (entity_data_list.items) |*ed| {
            ed.deinit(allocator);
        }
        entity_data_list.deinit(allocator);
    }

    // 创建 prefab_entity_id 到数组索引的映射
    var entity_id_map = std.AutoHashMap(world_mod.EntityId, u32).init(allocator);
    defer entity_id_map.deinit();

    for (entity_list.items, 0..) |entity_id, index| {
        try entity_id_map.put(entity_id, @intCast(index));
    }

    for (entity_list.items) |entity_id| {
        const entity = world.getEntityConst(entity_id).?;

        // 处理嵌套 Prefab 引用
        var nested_prefab_id: ?[]u8 = null;
        if (entity.prefab_instance_override) |override| {
            nested_prefab_id = try allocator.dupe(u8, override.prefab_id);
            errdefer if (nested_prefab_id) |id| allocator.free(id);
        }

        try entity_data_list.append(allocator, .{
            .prefab_entity_id = entity_id_map.get(entity_id).?,
            .name = try allocator.dupe(u8, entity.name),
            .parent = if (entity.parent) |parent_id| entity_id_map.get(parent_id) else null,
            .mesh_asset_id = if (entity.mesh) |mesh|
                if (mesh.handle) |handle|
                    if (world.resources.meshAssetId(handle)) |asset_id|
                        try allocator.dupe(u8, asset_id)
                    else
                        null
                else
                    null
            else
                null,
            .material_asset_id = if (entity.material) |material|
                if (material.handle) |handle|
                    if (world.resources.materialAssetId(handle)) |asset_id|
                        try allocator.dupe(u8, asset_id)
                    else
                        null
                else
                    null
            else
                null,
            .script_asset_id = if (entity.script) |script|
                if (script.script_handle) |handle|
                    if (world.resources.scriptAssetId(handle)) |asset_id|
                        try allocator.dupe(u8, asset_id)
                    else
                        null
                else
                    null
            else
                null,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = entity.mesh,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .capsule_collider = entity.capsule_collider,
            .character_controller = entity.character_controller,
            .tag = entity.tag,
            .sky = entity.sky,
            .material = entity.material,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = try cloneScriptComponent(allocator, entity.script),
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
            .nested_prefab_id = nested_prefab_id,
        });

        // 收集嵌套 Prefab ID
        if (nested_prefab_id != null) {
            try prefab.nested_prefab_ids.append(allocator, try allocator.dupe(u8, nested_prefab_id.?));
        }
    }

    prefab.entities = try entity_data_list.toOwnedSlice(allocator);

    return prefab;
}

/// 实例化 Prefab 到 World
pub fn instantiatePrefab(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    prefab: *const PrefabResource,
    options: InstantiateOptions,
) !world_mod.EntityId {
    if (prefab.entities.len == 0) {
        return error.EmptyPrefab;
    }

    // 创建 prefab_entity_id 到新实体 ID 的映射
    var entity_id_map = std.AutoHashMap(u32, world_mod.EntityId).init(allocator);
    defer entity_id_map.deinit();

    // 创建实体
    for (prefab.entities) |*prefab_entity| {
        // 构建 EntityDesc
        var desc = world_mod.EntityDesc{
            .name = if (options.name_prefix) |prefix|
                try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, prefab_entity.name })
            else
                try allocator.dupe(u8, prefab_entity.name),
        };
        defer allocator.free(desc.name);

        desc.local_transform = prefab_entity.local_transform;
        desc.camera = prefab_entity.camera;
        desc.mesh = prefab_entity.mesh;
        desc.rigidbody = prefab_entity.rigidbody;
        desc.box_collider = prefab_entity.box_collider;
        desc.sphere_collider = prefab_entity.sphere_collider;
        desc.mesh_collider = prefab_entity.mesh_collider;
        desc.capsule_collider = prefab_entity.capsule_collider;
        desc.character_controller = prefab_entity.character_controller;
        desc.tag = prefab_entity.tag;
        desc.sky = prefab_entity.sky;
        desc.material = prefab_entity.material;
        desc.light = prefab_entity.light;
        desc.vfx = prefab_entity.vfx;
        desc.script = resolvePrefabScript(world, prefab_entity);
        desc.visible = prefab_entity.visible;
        desc.editor_only = prefab_entity.editor_only;
        desc.is_folder = prefab_entity.is_folder;

        // 处理父关系
        if (prefab_entity.parent) |parent_prefab_id| {
            if (entity_id_map.get(parent_prefab_id)) |parent_entity_id| {
                desc.parent = parent_entity_id;
            }
        }

        const entity_id = try world.createEntity(desc);
        try entity_id_map.put(prefab_entity.prefab_entity_id, entity_id);

        // 应用初始变换偏移 (如果是根实体)
        if (prefab_entity.parent == null) {
            const entity = world.getEntity(entity_id).?;
            entity.local_transform = .{
                .translation = .{
                    entity.local_transform.translation[0] + options.transform.translation[0],
                    entity.local_transform.translation[1] + options.transform.translation[1],
                    entity.local_transform.translation[2] + options.transform.translation[2],
                },
                .rotation = options.transform.rotation,
                .scale = .{
                    entity.local_transform.scale[0] * options.transform.scale[0],
                    entity.local_transform.scale[1] * options.transform.scale[1],
                    entity.local_transform.scale[2] * options.transform.scale[2],
                },
            };
        }
    }

    // 第一个创建的实体作为根实体返回
    if (prefab.entities.len > 0) {
        return entity_id_map.get(0).?;
    }

    return error.InvalidPrefab;
}

/// 生成 Prefab ID
pub fn makePrefabIdAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    version: u32,
) ![]u8 {
    return try std.fmt.allocPrint(allocator, "prefab://{s}/v{d}", .{ path, version });
}

// ============================================================================
// 内部函数
// ============================================================================

const PrefabHeader = struct {
    version: u32 = 1,
};

fn collectEntitiesRecursive(
    entity_id: world_mod.EntityId,
    world: *const world_mod.World,
    list: *std.ArrayList(world_mod.EntityId),
    allocator: std.mem.Allocator,
) !void {
    try list.append(allocator, entity_id);
    const entity = world.getEntityConst(entity_id) orelse return;
    for (entity.children.items) |child_id| {
        try collectEntitiesRecursive(child_id, world, list, allocator);
    }
}

fn buildPrefabFile(allocator: std.mem.Allocator, prefab: *const PrefabResource) !PrefabFile {
    var asset_records = std.ArrayList(asset_registry.AssetRecord).empty;
    defer asset_records.deinit(allocator);

    var entity_records = std.ArrayList(PrefabEntityRecord).empty;
    defer entity_records.deinit(allocator);

    // 转换实体数据到记录
    for (prefab.entities) |entity| {
        try entity_records.append(allocator, .{
            .prefab_entity_id = entity.prefab_entity_id,
            .name = entity.name,
            .parent = entity.parent,
            .local_transform = entity.local_transform,
            .camera = entity.camera,
            .mesh = if (entity.mesh) |mesh| .{
                .asset_id = entity.mesh_asset_id,
                .primitive = mesh.primitive,
            } else null,
            .rigidbody = entity.rigidbody,
            .box_collider = entity.box_collider,
            .sphere_collider = entity.sphere_collider,
            .mesh_collider = entity.mesh_collider,
            .capsule_collider = entity.capsule_collider,
            .character_controller = entity.character_controller,
            .tag = entity.tag,
            .sky = entity.sky,
            .material = if (entity.material) |mat| .{
                .asset_id = entity.material_asset_id,
                .shading = mat.shading,
                .base_color_factor = mat.base_color_factor,
            } else null,
            .light = entity.light,
            .vfx = entity.vfx,
            .script = if (entity.script) |script| .{
                .asset_id = entity.script_asset_id,
                .language = script.language,
                .enabled = script.enabled,
                .parameters = script.parameters,
            } else null,
            .visible = entity.visible,
            .editor_only = entity.editor_only,
            .is_folder = entity.is_folder,
            .nested_prefab_id = entity.nested_prefab_id,
        });
    }

    return .{
        .prefab_id = prefab.id,
        .root_entity_name = if (prefab.entities.len > 0) prefab.entities[0].name else "",
        .asset_records = try asset_records.toOwnedSlice(allocator),
        .meshes = &.{},
        .textures = &.{},
        .materials = &.{},
        .entities = try entity_records.toOwnedSlice(allocator),
    };
}

fn deserializePrefabV1FromSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
) !PrefabResource {
    var parsed = try std.json.parseFromSlice(PrefabFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const prefab_file = parsed.value;
    if (prefab_file.version != 1) {
        return error.UnsupportedPrefabVersion;
    }

    var prefab = PrefabResource.init(allocator, prefab_file.prefab_id, prefab_file.root_entity_name);
    prefab.version = prefab_file.version;

    // 转换记录到实体数据
    var entity_data_list = std.ArrayList(PrefabEntityData).empty;
    defer {
        for (entity_data_list.items) |*ed| {
            ed.deinit(allocator);
        }
        entity_data_list.deinit(allocator);
    }

    for (prefab_file.entities) |record| {
        try entity_data_list.append(allocator, .{
            .prefab_entity_id = record.prefab_entity_id,
            .name = try allocator.dupe(u8, record.name),
            .parent = record.parent,
            .mesh_asset_id = if (record.mesh) |mesh|
                if (mesh.asset_id) |asset_id|
                    try allocator.dupe(u8, asset_id)
                else
                    null
            else
                null,
            .material_asset_id = if (record.material) |material|
                if (material.asset_id) |asset_id|
                    try allocator.dupe(u8, asset_id)
                else
                    null
            else
                null,
            .script_asset_id = if (record.script) |script|
                if (script.asset_id) |asset_id|
                    try allocator.dupe(u8, asset_id)
                else
                    null
            else
                null,
            .local_transform = record.local_transform,
            .camera = record.camera,
            .mesh = if (record.mesh) |mesh| .{
                .handle = null,
                .primitive = mesh.primitive,
            } else null,
            .rigidbody = record.rigidbody,
            .box_collider = record.box_collider,
            .sphere_collider = record.sphere_collider,
            .mesh_collider = record.mesh_collider,
            .capsule_collider = record.capsule_collider,
            .character_controller = record.character_controller,
            .tag = record.tag,
            .sky = record.sky,
            .material = if (record.material) |mat| .{
                .handle = null,
                .shading = mat.shading,
                .base_color_factor = mat.base_color_factor,
            } else null,
            .light = record.light,
            .vfx = record.vfx,
            .script = if (record.script) |script| .{
                .script_handle = null,
                .language = script.language,
                .enabled = script.enabled,
                .parameters = if (script.parameters.len != 0) try allocator.dupe(u8, script.parameters) else &.{},
            } else null,
            .visible = record.visible,
            .editor_only = record.editor_only,
            .is_folder = record.is_folder,
            .nested_prefab_id = if (record.nested_prefab_id) |id|
                try allocator.dupe(u8, id)
            else
                null,
        });

        // 收集嵌套 Prefab ID
        if (record.nested_prefab_id) |id| {
            try prefab.nested_prefab_ids.append(allocator, try allocator.dupe(u8, id));
        }
    }

    prefab.entities = try entity_data_list.toOwnedSlice(allocator);

    return prefab;
}

/// Diff 检测 - 比较两个 Prefab 版本
pub fn detectDiffs(
    allocator: std.mem.Allocator,
    old_prefab: *const PrefabResource,
    new_prefab: *const PrefabResource,
) !PrefabDiff {
    var diff = PrefabDiff{
        .allocator = allocator,
        .added_entities = .empty,
        .removed_entities = .empty,
        .modified_entities = .empty,
    };

    // 构建旧实体的 ID 集合
    var old_ids = std.AutoHashMap(u32, void).init(allocator);
    defer old_ids.deinit();
    for (old_prefab.entities) |entity| {
        try old_ids.put(entity.prefab_entity_id, {});
    }

    // 检测新增和修改的实体
    for (new_prefab.entities) |new_entity| {
        if (!old_ids.contains(new_entity.prefab_entity_id)) {
            // 新增实体
            try diff.added_entities.append(allocator, new_entity.prefab_entity_id);
        } else {
            // 检测修改 - 查找旧实体
            for (old_prefab.entities) |old_entity| {
                if (old_entity.prefab_entity_id == new_entity.prefab_entity_id) {
                    const entity_diff = detectEntityDiff(&old_entity, &new_entity);
                    if (entity_diff.has_changes) {
                        try diff.modified_entities.append(allocator, entity_diff);
                    }
                    break;
                }
            }
        }
    }

    // 检测删除的实体
    var new_ids = std.AutoHashMap(u32, void).init(allocator);
    defer new_ids.deinit();
    for (new_prefab.entities) |entity| {
        try new_ids.put(entity.prefab_entity_id, {});
    }
    for (old_prefab.entities) |old_entity| {
        if (!new_ids.contains(old_entity.prefab_entity_id)) {
            try diff.removed_entities.append(allocator, old_entity.prefab_entity_id);
        }
    }

    return diff;
}

/// 单个实体的 Diff
pub const EntityDiff = struct {
    prefab_entity_id: u32,
    has_changes: bool,
    transform_changed: bool,
    name_changed: bool,
    component_changes: ComponentChangeList,
};

const ComponentChangeList = struct {
    mesh_changed: bool = false,
    material_changed: bool = false,
    light_changed: bool = false,
    camera_changed: bool = false,
    rigidbody_changed: bool = false,
    collider_changed: bool = false,
    vfx_changed: bool = false,
    script_changed: bool = false,
};

fn detectEntityDiff(
    old_entity: *const PrefabEntityData,
    new_entity: *const PrefabEntityData,
) EntityDiff {
    var diff = EntityDiff{
        .prefab_entity_id = old_entity.prefab_entity_id,
        .has_changes = false,
        .transform_changed = false,
        .name_changed = false,
        .component_changes = .{},
    };

    // 检测名称变化
    if (!std.mem.eql(u8, old_entity.name, new_entity.name)) {
        diff.name_changed = true;
        diff.has_changes = true;
    }

    // 检测变换变化
    const old_t = &old_entity.local_transform;
    const new_t = &new_entity.local_transform;
    if (!std.mem.eql(f32, old_t.translation[0..3], new_t.translation[0..3]) or
        !std.mem.eql(f32, old_t.rotation[0..4], new_t.rotation[0..4]) or
        !std.mem.eql(f32, old_t.scale[0..3], new_t.scale[0..3]))
    {
        diff.transform_changed = true;
        diff.has_changes = true;
    }

    // 检测组件变化
    if (!equalOrNull(old_entity.mesh, new_entity.mesh)) {
        diff.component_changes.mesh_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.material, new_entity.material)) {
        diff.component_changes.material_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.light, new_entity.light)) {
        diff.component_changes.light_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.camera, new_entity.camera)) {
        diff.component_changes.camera_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.rigidbody, new_entity.rigidbody)) {
        diff.component_changes.rigidbody_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.box_collider, new_entity.box_collider) or
        !equalOrNull(old_entity.sphere_collider, new_entity.sphere_collider) or
        !equalOrNull(old_entity.mesh_collider, new_entity.mesh_collider) or
        !equalOrNull(old_entity.capsule_collider, new_entity.capsule_collider) or
        !equalOrNull(old_entity.character_controller, new_entity.character_controller))
    {
        diff.component_changes.collider_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.vfx, new_entity.vfx)) {
        diff.component_changes.vfx_changed = true;
        diff.has_changes = true;
    }
    if (!equalOrNull(old_entity.script, new_entity.script) or
        !equalStringOrNull(old_entity.script_asset_id, new_entity.script_asset_id))
    {
        diff.component_changes.script_changed = true;
        diff.has_changes = true;
    }

    return diff;
}

fn equalOrNull(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.meta.eql(a.?, b.?);
}

fn equalStringOrNull(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

// ============================================================================
// 单元测试
// ============================================================================

test "PrefabResource 创建和销毁" {
    const allocator = std.testing.allocator;

    var prefab = PrefabResource.init(allocator, "prefab://test/hero/v1", "Hero");
    defer prefab.deinit();

    try std.testing.expectEqualStrings("prefab://test/hero/v1", prefab.id);
    try std.testing.expectEqualStrings("Hero", prefab.name);
    try std.testing.expectEqual(@as(usize, 0), prefab.entities.len);
    try std.testing.expectEqual(@as(usize, 0), prefab.nested_prefab_ids.items.len);
}

test "PrefabInstanceOverride 创建和销毁" {
    const allocator = std.testing.allocator;

    var override = PrefabInstanceOverride{
        .prefab_id = try allocator.dupe(u8, "prefab://test/hero/v1"),
        .prefab_version = 1,
        .root_prefab_entity_id = 0,
        .override_mask = .{},
        .local_transform_override = null,
        .name_override = null,
        .visible_override = null,
    };
    defer override.deinit(allocator);

    try std.testing.expectEqualStrings("prefab://test/hero/v1", override.prefab_id);
    try std.testing.expectEqual(@as(u32, 1), override.prefab_version);
}

test "创建 Prefab 从简单实体" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();

    // 创建一个简单的实体树
    const root = try world.createEntity(.{
        .name = "Hero",
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } },
    });

    _ = try world.createEntity(.{
        .name = "Sword",
        .parent = root,
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
    });

    // 创建 Prefab
    var prefab = try createPrefabFromEntities(
        std.testing.allocator,
        &world,
        root,
        "prefab://test/hero/v1",
    );
    defer prefab.deinit();

    try std.testing.expectEqual(@as(usize, 2), prefab.entities.len);
    try std.testing.expectEqualStrings("Hero", prefab.entities[0].name);
    try std.testing.expectEqualStrings("Sword", prefab.entities[1].name);

    // 验证 prefab_entity_id 分配
    try std.testing.expectEqual(@as(u32, 0), prefab.entities[0].prefab_entity_id);
    try std.testing.expectEqual(@as(u32, 1), prefab.entities[1].prefab_entity_id);

    // 验证父关系
    try std.testing.expectEqual(@as(?u32, null), prefab.entities[0].parent);
    try std.testing.expectEqual(@as(?u32, 0), prefab.entities[1].parent);
}

test "Prefab 序列化和反序列化" {
    const allocator = std.testing.allocator;

    // 创建 Prefab
    var prefab = PrefabResource.init(allocator, "prefab://test/hero/v1", "Hero");
    defer prefab.deinit();

    // 添加一些实体数据
    var entity_data = try allocator.alloc(PrefabEntityData, 1);
    entity_data[0] = .{
        .prefab_entity_id = 0,
        .name = try allocator.dupe(u8, "Hero"),
        .parent = null,
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } },
        .mesh = null,
        .rigidbody = null,
        .light = null,
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    prefab.entities = entity_data;

    // 序列化
    const serialized = try serializePrefabAlloc(allocator, &prefab);
    defer allocator.free(serialized);

    // 反序列化
    var deserialized = try deserializePrefabFromSlice(allocator, serialized);
    defer deserialized.deinit();

    try std.testing.expectEqualStrings(prefab.id, deserialized.id);
    try std.testing.expectEqualStrings(prefab.name, deserialized.name);
    try std.testing.expectEqual(prefab.entities.len, deserialized.entities.len);
    try std.testing.expectEqualStrings(prefab.entities[0].name, deserialized.entities[0].name);
}

test "Prefab save-load-resave is byte stable" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const cwd = std.Io.Dir.cwd();
    var original = try cwd.openDir(io_globals.global_io, ".", .{});
    defer original.close(io_globals.global_io);
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    const allocator = std.testing.allocator;
    var prefab = PrefabResource.init(allocator, "prefab://test/robot/v1", "Robot");
    defer prefab.deinit();

    var entity_data = try allocator.alloc(PrefabEntityData, 2);
    entity_data[0] = .{
        .prefab_entity_id = 0,
        .name = try allocator.dupe(u8, "Robot"),
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
        .mesh = .{ .handle = null, .primitive = .cube },
        .script_asset_id = try allocator.dupe(u8, "script://robot/patrol"),
        .script = .{
            .script_handle = null,
            .language = .zig,
            .enabled = true,
            .parameters = try allocator.dupe(u8, "{\"speed\":3.0}\n"),
        },
        .visible = true,
    };
    entity_data[1] = .{
        .prefab_entity_id = 1,
        .name = try allocator.dupe(u8, "Sensor"),
        .parent = 0,
        .local_transform = .{ .translation = .{ 0.25, 0.5, 0.0 } },
        .light = .{ .kind = .point, .intensity = 12.0, .range = 5.0 },
        .visible = false,
    };
    prefab.entities = entity_data;

    try savePrefabToPath(allocator, &prefab, "assets/prefabs/test.prefab");
    var loaded = try loadPrefabFromPath(allocator, "assets/prefabs/test.prefab");
    defer loaded.deinit();
    try savePrefabToPath(allocator, &loaded, "assets/prefabs/test_resaved.prefab");

    const first = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, "assets/prefabs/test.prefab", allocator, .limited(1024 * 1024));
    defer allocator.free(first);
    const second = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, "assets/prefabs/test_resaved.prefab", allocator, .limited(1024 * 1024));
    defer allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}

test "instantiatePrefab resolves script asset ids into live handles" {
    const allocator = std.testing.allocator;

    var world = world_mod.World.init(allocator, null);
    defer world.deinit();

    const script_handle = try world.resources.createScript(.{
        .source = "pub fn onUpdate(dt: f32) void { _ = dt; }\n",
        .language = .zig,
        .description = "Prefab Logic",
        .source_path = "assets/scripts/prefab_logic.zig",
        .bytecode = &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 },
        .user_data = "{\"version\":1,\"parameters\":[]}\n",
    });
    _ = try world.resources.bindScriptAssetRecord(script_handle, .{
        .id = try allocator.dupe(u8, "script://prefab/logic"),
        .type = .script,
        .source_path = try allocator.dupe(u8, "assets/scripts/prefab_logic.zig"),
        .source_hash = try asset_registry.hashStringAlloc(allocator, "prefab-logic"),
        .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(allocator, .script),
        .import_version = asset_registry.AssetType.script.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(asset_registry.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, "Prefab Logic"),
            .importer = try allocator.dupe(u8, asset_registry.AssetType.script.importerName()),
            .source_extension = try allocator.dupe(u8, ".zig"),
        },
    });

    var prefab = PrefabResource.init(allocator, "prefab://test/logic/v1", "LogicActor");
    defer prefab.deinit();

    var entity_data = try allocator.alloc(PrefabEntityData, 1);
    entity_data[0] = .{
        .prefab_entity_id = 0,
        .name = try allocator.dupe(u8, "LogicActor"),
        .script_asset_id = try allocator.dupe(u8, "script://prefab/logic"),
        .script = .{
            .script_handle = null,
            .language = .zig,
            .enabled = true,
            .parameters = try allocator.dupe(u8, "{\"speed\":5.0}\n"),
        },
        .visible = true,
    };
    prefab.entities = entity_data;

    const root_id = try instantiatePrefab(allocator, &world, &prefab, .{});
    const root = world.getEntityConst(root_id).?;
    try std.testing.expect(root.script != null);
    try std.testing.expectEqual(script_handle, root.script.?.script_handle.?);
    try std.testing.expectEqual(components.ScriptLanguage.zig, root.script.?.language);
    try std.testing.expectEqualStrings("{\"speed\":5.0}\n", root.script.?.parameters);
}

test "Prefab 实例化" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    // 创建 Prefab
    var prefab = PrefabResource.init(world.allocator, "prefab://test/hero/v1", "Hero");

    // 添加实体数据
    var entity_data = try world.allocator.alloc(PrefabEntityData, 2);
    entity_data[0] = .{
        .prefab_entity_id = 0,
        .name = try world.allocator.dupe(u8, "Hero"),
        .parent = null,
        .local_transform = .{ .translation = .{ 0.0, 0.0, 0.0 } },
        .mesh = .{ .handle = null, .primitive = .cube },
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    entity_data[1] = .{
        .prefab_entity_id = 1,
        .name = try world.allocator.dupe(u8, "Sword"),
        .parent = 0,
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
        .mesh = .{ .handle = null, .primitive = .cube },
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    prefab.entities = entity_data;

    defer prefab.deinit();

    // 实例化
    const root_id = try instantiatePrefab(
        world.allocator,
        &world,
        &prefab,
        .{ .name_prefix = "Instance1", .transform = .{ .translation = .{ 10.0, 0.0, 0.0 } } },
    );

    // 验证实例化结果
    const root = world.getEntityConst(root_id).?;
    try std.testing.expect(std.mem.startsWith(u8, root.name, "Instance1_Hero"));

    // 验证变换应用
    const world_transform = world.worldTransform(root_id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), world_transform.translation[0], 0.0001);
}

test "Prefab Diff 检测" {
    const allocator = std.testing.allocator;

    // 创建旧 Prefab
    var old_prefab = PrefabResource.init(allocator, "prefab://test/hero/v1", "Hero");
    var old_entities = try allocator.alloc(PrefabEntityData, 1);
    old_entities[0] = .{
        .prefab_entity_id = 0,
        .name = try allocator.dupe(u8, "Hero"),
        .parent = null,
        .local_transform = .{ .translation = .{ 0.0, 0.0, 0.0 } },
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    old_prefab.entities = old_entities;
    defer old_prefab.deinit();

    // 创建新 Prefab (修改了名称和位置)
    var new_prefab = PrefabResource.init(allocator, "prefab://test/hero/v2", "Hero");
    var new_entities = try allocator.alloc(PrefabEntityData, 2); // 多了一个实体
    new_entities[0] = .{
        .prefab_entity_id = 0,
        .name = try allocator.dupe(u8, "HeroModified"), // 名称修改
        .parent = null,
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } }, // 位置修改
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    new_entities[1] = .{
        .prefab_entity_id = 1,
        .name = try allocator.dupe(u8, "Shield"), // 新增实体
        .parent = 0,
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
        .visible = true,
        .editor_only = false,
        .is_folder = false,
        .nested_prefab_id = null,
    };
    new_prefab.entities = new_entities;
    defer new_prefab.deinit();

    // 检测 Diff
    var diff = try detectDiffs(allocator, &old_prefab, &new_prefab);
    defer diff.deinit();

    // 验证结果
    try std.testing.expectEqual(@as(usize, 1), diff.added_entities.items.len); // 新增 1 个实体
    try std.testing.expectEqual(@as(usize, 0), diff.removed_entities.items.len); // 没有删除
    try std.testing.expectEqual(@as(usize, 1), diff.modified_entities.items.len); // 修改 1 个实体

    try std.testing.expectEqual(@as(u32, 1), diff.added_entities.items[0]);
    try std.testing.expectEqual(@as(u32, 0), diff.modified_entities.items[0].prefab_entity_id);
    try std.testing.expect(diff.modified_entities.items[0].name_changed);
    try std.testing.expect(diff.modified_entities.items[0].transform_changed);
}

test "生成 Prefab ID" {
    const allocator = std.testing.allocator;

    const id = try makePrefabIdAlloc(allocator, "assets/prefabs/hero", 1);
    defer allocator.free(id);

    try std.testing.expectEqualStrings("prefab://assets/prefabs/hero/v1", id);
}

/// Prefab Diff 结果
pub const PrefabDiff = struct {
    allocator: std.mem.Allocator,
    added_entities: std.ArrayList(u32),
    removed_entities: std.ArrayList(u32),
    modified_entities: std.ArrayList(EntityDiff),

    pub fn deinit(self: *PrefabDiff) void {
        self.added_entities.deinit(self.allocator);
        self.removed_entities.deinit(self.allocator);
        for (self.modified_entities.items) |*diff| {
            _ = diff;
        }
        self.modified_entities.deinit(self.allocator);
    }
};

/// 更新 Prefab 实例
pub fn updatePrefabInstance(
    world: *world_mod.World,
    root_entity_id: world_mod.EntityId,
    diff: *const PrefabDiff,
    prefab: *const PrefabResource,
) !void {
    // 1. 应用修改的实体
    for (diff.modified_entities.items) |entity_diff| {
        // 查找对应的实体
        const entity = findEntityByPrefabId(world, root_entity_id, entity_diff.prefab_entity_id) orelse continue;
        const prefab_entity = findPrefabEntity(prefab, entity_diff.prefab_entity_id) orelse continue;
        const overrides = if (entity.prefab_instance_override) |*override| override else null;

        // 应用修改
        if (entity_diff.name_changed and !(overrides != null and overrides.?.override_mask.name)) {
            world.allocator.free(entity.name);
            entity.name = try world.allocator.dupe(u8, prefab_entity.name);
        }

        if (entity_diff.transform_changed and !(overrides != null and overrides.?.override_mask.local_transform)) {
            entity.local_transform = prefab_entity.local_transform;
            world.markDirty(entity.id);
        }
        if (entity_diff.component_changes.mesh_changed and !(overrides != null and overrides.?.override_mask.mesh)) {
            entity.mesh = resolvePrefabMesh(world, prefab_entity);
        }
        if (entity_diff.component_changes.material_changed and !(overrides != null and overrides.?.override_mask.material)) {
            entity.material = resolvePrefabMaterial(world, prefab_entity);
        }
        if (entity_diff.component_changes.light_changed and !(overrides != null and overrides.?.override_mask.light)) {
            entity.light = prefab_entity.light;
        }
        if (entity_diff.component_changes.camera_changed and !(overrides != null and overrides.?.override_mask.camera)) {
            entity.camera = prefab_entity.camera;
        }
        if (entity_diff.component_changes.rigidbody_changed and !(overrides != null and overrides.?.override_mask.rigidbody)) {
            entity.rigidbody = prefab_entity.rigidbody;
        }
        if (entity_diff.component_changes.collider_changed and !(overrides != null and overrides.?.override_mask.collider)) {
            entity.box_collider = prefab_entity.box_collider;
            entity.sphere_collider = prefab_entity.sphere_collider;
            entity.mesh_collider = prefab_entity.mesh_collider;
            entity.capsule_collider = prefab_entity.capsule_collider;
            entity.character_controller = prefab_entity.character_controller;
            entity.tag = prefab_entity.tag;
            entity.sky = prefab_entity.sky;
        }
        if (entity_diff.component_changes.vfx_changed and !(overrides != null and overrides.?.override_mask.vfx)) {
            entity.vfx = prefab_entity.vfx;
        }
        if (entity_diff.component_changes.script_changed and !(overrides != null and overrides.?.override_mask.script)) {
            if (entity.script) |script| {
                freeScriptParameters(world.allocator, script.parameters);
            }
            entity.script = try cloneScriptComponent(world.allocator, resolvePrefabScript(world, prefab_entity));
        }
    }

    // 2. 添加新实体
    for (diff.added_entities.items) |prefab_entity_id| {
        // 查找父实体
        const prefab_entity = findPrefabEntity(prefab, prefab_entity_id) orelse continue;

        // 创建新实体
        var desc = world_mod.EntityDesc{
            .name = prefab_entity.name,
            .local_transform = prefab_entity.local_transform,
            .parent = if (prefab_entity.parent) |parent_id|
                if (findEntityByPrefabId(world, root_entity_id, parent_id)) |parent_entity|
                    parent_entity.id
                else
                    null
            else
                null,
        };

        // 复制其他组件
        desc.camera = prefab_entity.camera;
        desc.mesh = resolvePrefabMesh(world, prefab_entity);
        desc.material = resolvePrefabMaterial(world, prefab_entity);
        desc.light = prefab_entity.light;
        desc.rigidbody = prefab_entity.rigidbody;
        desc.box_collider = prefab_entity.box_collider;
        desc.sphere_collider = prefab_entity.sphere_collider;
        desc.mesh_collider = prefab_entity.mesh_collider;
        desc.capsule_collider = prefab_entity.capsule_collider;
        desc.character_controller = prefab_entity.character_controller;
        desc.tag = prefab_entity.tag;
        desc.sky = prefab_entity.sky;
        desc.vfx = prefab_entity.vfx;
        desc.script = resolvePrefabScript(world, prefab_entity);
        desc.visible = prefab_entity.visible;

        const new_entity_id = try world.createEntity(desc);

        // 设置 Prefab 实体 ID
        const new_entity = world.getEntity(new_entity_id).?;
        new_entity.prefab_entity_id = prefab_entity_id;
    }

    // 3. 删除实体
    for (diff.removed_entities.items) |prefab_entity_id| {
        if (findEntityByPrefabId(world, root_entity_id, prefab_entity_id)) |entity| {
            // 检查是否是根实体
            if (entity.id == root_entity_id) {
                // 不能删除根实体，只删除子实体
                continue;
            }
            _ = world.destroyEntity(entity.id);
        }
    }
}

fn resolvePrefabMesh(world: *world_mod.World, prefab_entity: *const PrefabEntityData) ?components.Mesh {
    var mesh = prefab_entity.mesh orelse return null;
    if (mesh.handle == null) {
        if (prefab_entity.mesh_asset_id) |asset_id| {
            mesh.handle = world.resources.meshHandleByAssetId(asset_id);
        }
    }
    return mesh;
}

fn resolvePrefabMaterial(world: *world_mod.World, prefab_entity: *const PrefabEntityData) ?components.Material {
    var material = prefab_entity.material orelse return null;
    if (material.handle == null) {
        if (prefab_entity.material_asset_id) |asset_id| {
            material.handle = world.resources.materialHandleByAssetId(asset_id);
        }
    }
    return material;
}

fn resolvePrefabScript(world: *world_mod.World, prefab_entity: *const PrefabEntityData) ?components.Script {
    var script = prefab_entity.script orelse return null;
    if (script.script_handle == null) {
        if (prefab_entity.script_asset_id) |asset_id| {
            script.script_handle = world.resources.scriptHandleByAssetId(asset_id);
        }
    }
    script.instance_id = null;
    return script;
}

/// 根据 prefab_entity_id 查找实体
fn findEntityByPrefabId(
    world: *world_mod.World,
    root_entity_id: world_mod.EntityId,
    prefab_entity_id: u32,
) ?*world_mod.Entity {
    // 获取根实体
    const root = world.getEntity(root_entity_id) orelse return null;

    // 检查根实体
    if (root.prefab_entity_id == prefab_entity_id) {
        return root;
    }

    // 递归搜索子实体
    return findEntityInChildren(world, root, prefab_entity_id);
}

/// 递归查找子实体
fn findEntityInChildren(
    world: *world_mod.World,
    parent: *world_mod.Entity,
    prefab_entity_id: u32,
) ?*world_mod.Entity {
    for (parent.children.items) |child_id| {
        const child = world.getEntity(child_id) orelse continue;

        if (child.prefab_entity_id == prefab_entity_id) {
            return child;
        }

        if (findEntityInChildren(world, child, prefab_entity_id)) |entity| {
            return entity;
        }
    }
    return null;
}

/// 在 Prefab 中查找实体
fn findPrefabEntity(prefab: *const PrefabResource, prefab_entity_id: u32) ?*const PrefabEntityData {
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == prefab_entity_id) {
            return entity;
        }
    }
    return null;
}
