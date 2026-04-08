//! 场景世界管理模块
//!
//! 本模块提供 ECS（Entity-Component-System）架构的场景管理功能。
//! World 是场景的核心容器，管理所有实体及其组件。
//!
//! ## 核心功能
//!
//! - **实体管理** - 创建、销毁、查询实体
//! - **组件管理** - 添加、移除、修改组件
//! - **层级系统** - 支持父子关系，自动计算世界变换
//! - **空间索引** - BVH 加速结构，用于快速视锥剔除和射线检测
//! - **Prefab 系统** - 预制体实例化和管理
//! - **VFX 系统** - 粒子特效运行时管理
//!
//! ## 使用示例
//!
//! ```zig
//! // 创建世界
//! var world = World.init(allocator, null);
//! defer world.deinit();
//!
//! // 创建实体
//! const entity = try world.createEntity(.{
//!     .name = "Player",
//!     .local_transform = .{ .translation = .{ 0, 1, 0 } },
//! });
//!
//! // 更新层级（计算世界变换）
//! world.updateHierarchy();
//! ```

const std = @import("std");
const assets_handles = @import("../assets/handles.zig");
const animation_graph_mod = @import("../animation/animation_graph.zig");
const assets_lib = @import("../assets/library.zig");
const gltf_import = @import("../assets/gltf_import.zig");
const raycast_mod = @import("raycast.zig");
const spatial_index_mod = @import("spatial_index.zig");
const components = @import("components.zig");
const vfx_runtime_mod = @import("vfx_runtime.zig");
const vec3 = @import("../math/vec3.zig");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const job_system_mod = @import("../core/job_system.zig");
const prefab_mod = @import("prefab.zig");
const sparse_set_mod = @import("../core/sparse_set.zig");

const compose_epsilon = 0.0001;
const dynamic_reintegration_query_threshold: u8 = 3;
const spatial_log = std.log.scoped(.spatial_index);

/// 动态可渲染物状态
const DynamicRenderableState = struct {
    /// 连续查询次数（用于判断是否需要重新集成到静态树）
    steady_query_count: u8 = 0,
};

/// 空间分区快照（用于调试）
const SpatialPartitionSnapshot = struct {
    static_items: usize,
    dynamic_items: usize,
};

/// 动画器绑定（骨骼 -> 目标实体）
const AnimatorBinding = struct {
    /// 动画器实体 ID
    animator_entity_id: EntityId,
    /// 目标实体 ID 列表
    target_entities: []EntityId,
    /// 基础局部变换列表
    base_local_transforms: []components.Transform,
};

const AnimatorGraphBinding = struct {
    animator_entity_id: EntityId,
    graph: *animation_graph_mod.AnimationGraph,
    instance: animation_graph_mod.AnimationGraphInstance,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.instance.deinit();
        self.graph.deinit();
        allocator.destroy(self.graph);
        self.* = undefined;
    }
};

/// 蒙皮网格绑定
const SkinnedMeshBinding = struct {
    /// 实体 ID
    entity_id: EntityId,
    /// 目标实体 ID 列表（骨骼关节）
    target_entities: []EntityId,
};

/// 已记录的空间分区快照（用于避免重复日志）
var g_logged_spatial_partition_snapshot: ?SpatialPartitionSnapshot = null;

/// 实体 ID 类型
pub const EntityId = u64;

/// 实体结构体
///
/// 实体是 ECS 架构中的基本单位，是组件的容器。
/// 每个实体有一个唯一 ID 和一个名称，可以包含任意组合的组件。
///
/// ## 核心字段
///
/// - `id` - 唯一标识符
/// - `name` - 实体名称（用于调试和编辑器显示）
/// - `parent` - 父实体 ID（用于层级关系）
/// - `local_transform` - 局部空间变换
/// - `world_transform_cache` - 世界空间变换（缓存）
/// - `world_bounds_cache` - 世界空间包围盒（缓存）
/// - `dirty` - 是否需要更新变换
/// - `visible` - 是否可见
/// - `editor_only` - 是否仅在编辑器中显示
/// - `dont_destroy_on_load` - 场景切换时是否保留
///
/// ## 组件字段
///
/// 所有组件字段都是可选的（`?Type`），实体可以按需附加组件：
/// - `camera` - 相机组件
/// - `mesh` - 网格组件
/// - `skinned_mesh` - 蒙皮网格组件
/// - `animator` - 动画器组件
/// - `rigidbody` - 刚体组件
/// - `box_collider` / `sphere_collider` / `mesh_collider` - 碰撞器组件
/// - `constraint` - 约束组件
/// - `material` - 材质组件
/// - `light` - 光源组件
/// - `vfx` - 特效组件
/// - `script` - 脚本组件
pub const Entity = struct {
    /// 唯一标识符
    id: EntityId,
    /// 实体名称
    name: []u8,
    /// 父实体 ID（null 表示根实体）
    parent: ?EntityId = null,
    /// 局部空间变换（相对于父实体）
    local_transform: components.Transform = .{},
    /// 世界空间变换（缓存，由 updateHierarchy 更新）
    world_transform_cache: components.Transform = .{},
    /// 世界空间矩阵（缓存，由 updateHierarchy 更新）
    world_matrix_cache: [16]f32 = .{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    },
    /// 世界空间包围盒（缓存，用于视锥剔除和射线检测）
    world_bounds_cache: ?AABB = null,
    /// 是否需要更新变换
    dirty: bool = true,
    /// 相机组件
    camera: ?components.Camera = null,
    /// 网格组件
    mesh: ?components.Mesh = null,
    /// 蒙皮网格组件
    skinned_mesh: ?components.SkinnedMesh = null,
    /// 动画器组件
    animator: ?components.Animator = null,
    /// 刚体组件
    rigidbody: ?components.Rigidbody = null,
    /// 盒碰撞器组件
    box_collider: ?components.BoxCollider = null,
    /// 球碰撞器组件
    sphere_collider: ?components.SphereCollider = null,
    /// 网格碰撞器组件
    mesh_collider: ?components.MeshCollider = null,
    /// 胶囊碰撞器组件
    capsule_collider: ?components.CapsuleCollider = null,
    /// 角色控制器组件
    character_controller: ?components.CharacterController = null,
    /// 标签组件
    tag: ?components.Tag = null,
    /// 天空/环境组件
    sky: ?components.Sky = null,
    /// 约束组件
    constraint: ?components.Constraint = null,
    /// 材质组件
    material: ?components.Material = null,
    /// 光源组件
    light: ?components.Light = null,
    /// 特效组件
    vfx: ?components.Vfx = null,
    /// 脚本组件（已弃用，兼容旧场景）
    script: ?components.Script = null,
    /// 脚本组件列表（多脚本支持）
    scripts: []components.Script = &.{},
    /// 音频源组件
    audio_source: ?components.AudioSource = null,
    /// 音频监听器组件
    audio_listener: ?components.AudioListener = null,
    /// 导航代理组件
    nav_agent: ?components.NavAgent = null,
    /// 行为树组件
    behavior_tree: ?components.BehaviorTreeComponent = null,
    /// 地形组件
    terrain: ?components.TerrainComponent = null,
    /// 网络身份组件
    network_identity: ?components.NetworkIdentity = null,
    /// 网络变换同步组件
    network_transform: ?components.NetworkTransform = null,
    /// RTS 相机控制器组件
    rts_camera: ?components.RtsCamera = null,
    /// 战争迷雾视野组件
    fog_vision: ?components.FogVision = null,
    /// 战争迷雾全局配置组件
    fog_of_war_config: ?components.FogOfWarConfig = null,
    /// 是否可见
    visible: bool = true,
    /// 是否仅在编辑器中显示
    editor_only: bool = false,
    /// 是否可被鼠标拾取选择
    selectable: bool = true,
    /// 场景切换时是否保留
    dont_destroy_on_load: bool = false,
    /// 是否为文件夹（用于层级面板组织）
    is_folder: bool = false,
    /// 子实体列表
    children: std.ArrayListUnmanaged(EntityId) = .empty,

    // Prefab 相关字段
    /// 该实体在原始 Prefab 中的 ID (如果是 Prefab 实例)
    prefab_entity_id: ?u32 = null,
    /// Prefab 实例覆盖数据 (如果有覆盖)
    prefab_instance_override: ?prefab_mod.PrefabInstanceOverride = null,

    /// 释放实体占用的资源
    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        allocator.free(self.name);
        if (self.script) |script| {
            freeScriptParameters(allocator, script.parameters);
        }
        for (self.scripts) |script| {
            freeScriptParameters(allocator, script.parameters);
        }
        if (self.scripts.len > 0) allocator.free(self.scripts);
        if (self.audio_source) |audio_source| {
            if (audio_source.clip_asset_path) |path| {
                if (path.len != 0) {
                    allocator.free(path);
                }
            }
        }
        if (self.prefab_instance_override) |*override| {
            override.deinit(allocator);
        }
        if (self.behavior_tree) |*bt| {
            bt.deinit(allocator);
        }
    }
};

fn cloneScriptComponent(allocator: std.mem.Allocator, script: ?components.Script) !?components.Script {
    const value = script orelse return null;
    var cloned = value;
    cloned.parameters = if (value.parameters.len != 0) try allocator.dupe(u8, value.parameters) else &.{};
    return cloned;
}

fn cloneScriptComponents(allocator: std.mem.Allocator, scripts: []const components.Script) ![]components.Script {
    if (scripts.len == 0) return &.{};
    const cloned = try allocator.alloc(components.Script, scripts.len);
    errdefer allocator.free(cloned);
    for (scripts, 0..) |script, i| {
        cloned[i] = script;
        cloned[i].parameters = if (script.parameters.len != 0) try allocator.dupe(u8, script.parameters) else &.{};
    }
    return cloned;
}

fn cloneAudioSourceComponent(allocator: std.mem.Allocator, audio_source: ?components.AudioSource) !?components.AudioSource {
    const value = audio_source orelse return null;
    var cloned = value;
    cloned.clip_asset_path = if (value.clip_asset_path) |path|
        if (path.len != 0) try allocator.dupe(u8, path) else &.{}
    else
        null;
    cloned.clip_handle = null;
    cloned._voice_handle = null;
    cloned._is_playing = false;
    cloned._play_on_awake_consumed = false;
    return cloned;
}

fn freeScriptParameters(allocator: std.mem.Allocator, parameters: []const u8) void {
    if (parameters.len != 0) {
        allocator.free(parameters);
    }
}

fn isPrefabRootEntity(entity: *const Entity) bool {
    return entity.prefab_entity_id != null and entity.prefab_entity_id.? == 0 and entity.parent == null;
}

/// 可渲染物射线检测候选
///
/// 用于射线检测的宽阶段结果，包含实体 ID 和包围盒信息。
pub const RenderableRayCandidate = struct {
    /// 实体 ID
    id: EntityId,
    /// 世界空间包围盒
    bounds: AABB,
    /// 射线进入距离
    enter_distance: f32,
};

/// 实体描述结构体
///
/// 用于创建新实体时传递参数。所有字段都有默认值，
/// 可以按需指定需要的组件。
///
/// ## 使用示例
///
/// ```zig
/// const entity = try world.createEntity(.{
///     .name = "MyEntity",
///     .local_transform = .{
///         .translation = .{ 0, 1, 0 },
///     },
///     .mesh = .{ .primitive = .cube },
///     .material = .{},
/// });
/// ```
pub const EntityDesc = struct {
    /// 实体名称
    name: []const u8,
    /// 父实体 ID
    parent: ?EntityId = null,
    /// 局部变换
    local_transform: components.Transform = .{},
    /// 相机组件
    camera: ?components.Camera = null,
    /// 网格组件
    mesh: ?components.Mesh = null,
    /// 蒙皮网格组件
    skinned_mesh: ?components.SkinnedMesh = null,
    /// 动画器组件
    animator: ?components.Animator = null,
    /// 刚体组件
    rigidbody: ?components.Rigidbody = null,
    /// 盒碰撞器组件
    box_collider: ?components.BoxCollider = null,
    /// 球碰撞器组件
    sphere_collider: ?components.SphereCollider = null,
    /// 网格碰撞器组件
    mesh_collider: ?components.MeshCollider = null,
    /// 胶囊碰撞器组件
    capsule_collider: ?components.CapsuleCollider = null,
    /// 角色控制器组件
    character_controller: ?components.CharacterController = null,
    /// 标签组件
    tag: ?components.Tag = null,
    /// 天空/环境组件
    sky: ?components.Sky = null,
    /// 约束组件
    constraint: ?components.Constraint = null,
    /// 材质组件
    material: ?components.Material = null,
    /// 光源组件
    light: ?components.Light = null,
    /// 特效组件
    vfx: ?components.Vfx = null,
    /// 脚本组件（已弃用，使用 scripts）
    script: ?components.Script = null,
    /// 脚本组件列表（多脚本支持）
    scripts: []const components.Script = &.{},
    /// 音频源组件
    audio_source: ?components.AudioSource = null,
    /// 音频监听器组件
    audio_listener: ?components.AudioListener = null,
    /// 导航代理组件
    nav_agent: ?components.NavAgent = null,
    /// 行为树组件
    behavior_tree: ?components.BehaviorTreeComponent = null,
    /// 地形组件
    terrain: ?components.TerrainComponent = null,
    /// 网络身份组件
    network_identity: ?components.NetworkIdentity = null,
    /// 网络变换同步组件
    network_transform: ?components.NetworkTransform = null,
    /// RTS 相机控制器组件
    rts_camera: ?components.RtsCamera = null,
    /// 战争迷雾视野组件
    fog_vision: ?components.FogVision = null,
    /// 战争迷雾全局配置组件
    fog_of_war_config: ?components.FogOfWarConfig = null,
    /// 是否可见
    visible: bool = true,
    /// 是否仅在编辑器中显示
    editor_only: bool = false,
    /// 是否可被鼠标拾取选择
    selectable: bool = true,
    /// 场景切换时是否保留
    dont_destroy_on_load: bool = false,
    /// 是否为文件夹
    is_folder: bool = false,
};

/// 场景摘要
///
/// 统计场景中各类实体的数量。
pub const Summary = struct {
    /// 实体总数
    entity_count: usize = 0,
    /// 相机数量
    camera_count: usize = 0,
    /// 网格数量
    mesh_count: usize = 0,
    /// 材质数量
    material_count: usize = 0,
    /// 光源数量
    light_count: usize = 0,
    /// 特效数量
    vfx_count: usize = 0,
    /// 刚体数量
    rigidbody_count: usize = 0,
    /// 碰撞器数量
    collider_count: usize = 0,
};

/// 场景世界结构体
///
/// World 是场景的核心容器，管理所有实体、组件和资源。
/// 提供完整的 ECS（Entity-Component-System）功能。
///
/// ## 主要功能
///
/// - **实体管理** - 创建、销毁、查询实体
/// - **组件存储** - 每个实体可以拥有任意组合的组件
/// - **层级系统** - 支持父子关系，自动计算世界变换
/// - **空间索引** - BVH 加速结构，用于快速视锥剔除和射线检测
/// - **资源管理** - 通过 ResourceLibrary 管理网格、材质、纹理等资源
/// - **Prefab 系统** - 预制体库，支持实例化和覆盖
/// - **VFX 系统** - 粒子特效运行时管理
///
/// ## 使用示例
///
/// ```zig
/// // 创建世界
/// var world = World.init(allocator, null);
/// defer world.deinit();
///
/// // 创建实体
/// const entity = try world.createEntity(.{
///     .name = "Player",
///     .local_transform = .{ .translation = .{ 0, 1, 0 } },
///     .mesh = .{ .primitive = .cube },
///     .material = .{},
/// });
///
/// // 更新层级（计算世界变换）
/// world.updateHierarchy();
///
/// // 查询实体
/// if (world.getEntity(entity)) |e| {
///     // 修改组件
///     e.local_transform.translation[1] += 1.0;
///     e.dirty = true;
/// }
/// ```
pub const World = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 资源库（管理网格、材质、纹理等资源）
    resources: assets_lib.ResourceLibrary,
    /// Prefab 库
    prefab_library: prefab_mod.PrefabLibrary,
    /// 实体列表
    entities: std.ArrayList(Entity) = .empty,
    /// ID 到索引的映射（用于快速查找）
    id_to_index: std.AutoHashMap(EntityId, usize),
    /// 下一个可用的实体 ID
    next_id: EntityId = 1,
    /// 场景变更版本号（用于增量同步）
    scene_revision: u64 = 1,
    /// 作业系统（用于并行处理）
    job_system: ?*job_system_mod.JobSystem = null,
    /// VFX 运行时发射器列表
    vfx_runtime_emitters: std.ArrayList(vfx_runtime_mod.VfxRuntimeEmitter) = .empty,
    /// 静态可渲染物空间索引（BVH）
    renderable_spatial_index: spatial_index_mod.StaticBoundsBvh,
    /// 动态可渲染物空间索引（BVH）
    dynamic_renderable_spatial_index: spatial_index_mod.StaticBoundsBvh,
    /// 静态可渲染物项目列表
    static_renderable_items: std.ArrayList(spatial_index_mod.BoundsItem) = .empty,
    /// 动态可渲染物项目列表
    dynamic_renderable_items: std.ArrayList(spatial_index_mod.BoundsItem) = .empty,
    /// 静态可渲染物 ID 到索引的映射
    static_renderable_item_indices: std.AutoHashMap(EntityId, usize),
    /// 动态可渲染物 ID 到索引的映射
    dynamic_renderable_item_indices: std.AutoHashMap(EntityId, usize),
    /// 动态可渲染物状态映射
    dynamic_renderables: std.AutoHashMap(EntityId, DynamicRenderableState),
    /// 脏动态可渲染物集合
    dynamic_dirty_renderables: std.AutoHashMap(EntityId, void),
    /// 可渲染物同步候选集合
    renderable_sync_candidates: std.AutoHashMap(EntityId, void),
    /// 动画器绑定列表
    animator_bindings: std.ArrayList(AnimatorBinding) = .empty,
    /// 动画图运行时绑定列表
    animator_graph_bindings: std.ArrayList(AnimatorGraphBinding) = .empty,
    /// 蒙皮网格绑定列表
    skinned_mesh_bindings: std.ArrayList(SkinnedMeshBinding) = .empty,
    /// 是否需要完全同步可渲染物
    renderable_full_sync_required: bool = false,
    /// Transform 组件稀疏集（热路径组件，O(1) 访问）
    transform_set: sparse_set_mod.SparseSet(components.Transform),
    /// Rigidbody 组件稀疏集（热路径组件，O(1) 访问）
    rigidbody_set: sparse_set_mod.SparseSet(components.Rigidbody),
    /// BoxCollider 组件稀疏集（热路径组件，O(1) 访问）
    box_collider_set: sparse_set_mod.SparseSet(components.BoxCollider),
    /// SphereCollider 组件稀疏集（热路径组件，O(1) 访问）
    sphere_collider_set: sparse_set_mod.SparseSet(components.SphereCollider),
    /// CapsuleCollider 组件稀疏集（热路径组件，O(1) 访问）
    capsule_collider_set: sparse_set_mod.SparseSet(components.CapsuleCollider),

    /// 初始化世界
    ///
    /// ## 参数
    /// - `allocator` - 内存分配器
    /// - `job_system` - 可选的作业系统，用于并行处理
    ///
    /// ## 返回
    /// 初始化的 World 实例
    pub fn init(allocator: std.mem.Allocator, job_system: ?*job_system_mod.JobSystem) World {
        return .{
            .allocator = allocator,
            .resources = assets_lib.ResourceLibrary.init(allocator, job_system),
            .prefab_library = prefab_mod.PrefabLibrary.init(allocator),
            .id_to_index = std.AutoHashMap(EntityId, usize).init(allocator),
            .job_system = job_system,
            .renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(allocator),
            .dynamic_renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(allocator),
            .static_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(allocator),
            .dynamic_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(allocator),
            .dynamic_renderables = std.AutoHashMap(EntityId, DynamicRenderableState).init(allocator),
            .dynamic_dirty_renderables = std.AutoHashMap(EntityId, void).init(allocator),
            .renderable_sync_candidates = std.AutoHashMap(EntityId, void).init(allocator),
            .transform_set = sparse_set_mod.SparseSet(components.Transform).initNoFail(allocator, 1024),
            .rigidbody_set = sparse_set_mod.SparseSet(components.Rigidbody).initNoFail(allocator, 256),
            .box_collider_set = sparse_set_mod.SparseSet(components.BoxCollider).initNoFail(allocator, 256),
            .sphere_collider_set = sparse_set_mod.SparseSet(components.SphereCollider).initNoFail(allocator, 256),
            .capsule_collider_set = sparse_set_mod.SparseSet(components.CapsuleCollider).initNoFail(allocator, 256),
        };
    }

    /// 释放世界占用的所有资源
    pub fn deinit(self: *World) void {
        self.clearStorage(false);
    }

    /// 清空世界中的所有实体（保留资源库）
    pub fn clear(self: *World) void {
        self.clearStorage(true);
        self.bumpSceneRevision();
    }

    fn clearStorage(self: *World, reinitialize: bool) void {
        self.releaseVfxRuntime(false);
        for (self.entities.items) |*entity| {
            entity.deinit(self.allocator);
        }
        self.entities.deinit(self.allocator);
        self.id_to_index.deinit();
        self.renderable_spatial_index.deinit();
        self.dynamic_renderable_spatial_index.deinit();
        self.static_renderable_items.deinit(self.allocator);
        self.dynamic_renderable_items.deinit(self.allocator);
        self.static_renderable_item_indices.deinit();
        self.dynamic_renderable_item_indices.deinit();
        self.dynamic_renderables.deinit();
        self.dynamic_dirty_renderables.deinit();
        self.renderable_sync_candidates.deinit();
        for (self.animator_bindings.items) |binding| {
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
        }
        self.animator_bindings.deinit(self.allocator);
        for (self.animator_graph_bindings.items) |*binding| {
            binding.deinit(self.allocator);
        }
        self.animator_graph_bindings.deinit(self.allocator);
        for (self.skinned_mesh_bindings.items) |binding| {
            self.allocator.free(binding.target_entities);
        }
        self.skinned_mesh_bindings.deinit(self.allocator);
        self.resources.deinit();
        self.prefab_library.deinit();
        self.transform_set.deinit(self.allocator);
        self.rigidbody_set.deinit(self.allocator);
        self.box_collider_set.deinit(self.allocator);
        self.sphere_collider_set.deinit(self.allocator);
        self.capsule_collider_set.deinit(self.allocator);
        if (reinitialize) {
            self.entities = .empty;
            self.id_to_index = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.resources = assets_lib.ResourceLibrary.init(self.allocator, self.job_system);
            self.prefab_library = prefab_mod.PrefabLibrary.init(self.allocator);
            self.vfx_runtime_emitters = .empty;
            self.renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(self.allocator);
            self.dynamic_renderable_spatial_index = spatial_index_mod.StaticBoundsBvh.init(self.allocator);
            self.static_renderable_items = .empty;
            self.dynamic_renderable_items = .empty;
            self.static_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.dynamic_renderable_item_indices = std.AutoHashMap(EntityId, usize).init(self.allocator);
            self.dynamic_renderables = std.AutoHashMap(EntityId, DynamicRenderableState).init(self.allocator);
            self.dynamic_dirty_renderables = std.AutoHashMap(EntityId, void).init(self.allocator);
            self.renderable_sync_candidates = std.AutoHashMap(EntityId, void).init(self.allocator);
            self.animator_bindings = .empty;
            self.animator_graph_bindings = .empty;
            self.skinned_mesh_bindings = .empty;
            self.renderable_full_sync_required = false;
            self.transform_set = sparse_set_mod.SparseSet(components.Transform).initNoFail(self.allocator, 1024);
            self.rigidbody_set = sparse_set_mod.SparseSet(components.Rigidbody).initNoFail(self.allocator, 256);
            self.box_collider_set = sparse_set_mod.SparseSet(components.BoxCollider).initNoFail(self.allocator, 256);
            self.sphere_collider_set = sparse_set_mod.SparseSet(components.SphereCollider).initNoFail(self.allocator, 256);
            self.capsule_collider_set = sparse_set_mod.SparseSet(components.CapsuleCollider).initNoFail(self.allocator, 256);
        }
    }

    /// Creates a new entity with an automatically-generated unique ID.
    ///
    /// Parameters:
    /// - `desc`: EntityDesc with name, parent, transform, and component data.
    ///
    /// Returns: Unique EntityId for subsequent lookups and manipulation.
    ///
    /// Errors:
    /// - error.ParentNotFound: desc.parent is set but parent entity does not exist.
    ///
    /// Memory ownership: Caller is responsible for allocating desc.name; World assumes
    /// ownership and will free it on deinit() or when entity is deleted.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from main thread only.
    pub fn createEntity(self: *World, desc: EntityDesc) !EntityId {
        const id = self.next_id;
        self.next_id += 1;
        return self.createEntityWithId(id, desc);
    }

    /// Creates a new entity with a specific ID.
    ///
    /// Parameters:
    /// - `id`: Explicit EntityId to use. If already taken, returns error.EntityIdConflict.
    /// - `desc`: EntityDesc with name, parent, transform, and component data.
    ///
    /// Returns: The provided EntityId on success.
    ///
    /// Errors:
    /// - error.ParentNotFound: desc.parent is set but parent entity does not exist.
    /// - error.EntityIdConflict: id is already in use by another entity.
    ///
    /// Memory ownership: Caller is responsible for allocating desc.name; World assumes
    /// ownership and will free it on deinit() or when entity is deleted. All components
    /// in desc are deep-copied into the entity.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from main thread only.
    pub fn createEntityWithId(self: *World, id: EntityId, desc: EntityDesc) !EntityId {
        if (desc.parent) |parent_id| {
            if (!self.hasEntity(parent_id)) {
                return error.ParentNotFound;
            }
        }
        if (self.hasEntity(id)) {
            return error.EntityIdConflict;
        }

        const index = self.entities.items.len;
        try self.entities.append(self.allocator, .{
            .id = id,
            .name = try self.allocator.dupe(u8, desc.name),
            .parent = desc.parent,
            .local_transform = desc.local_transform,
            .camera = desc.camera,
            .mesh = desc.mesh,
            .skinned_mesh = desc.skinned_mesh,
            .animator = desc.animator,
            .rigidbody = desc.rigidbody,
            .box_collider = desc.box_collider,
            .sphere_collider = desc.sphere_collider,
            .mesh_collider = desc.mesh_collider,
            .capsule_collider = desc.capsule_collider,
            .character_controller = desc.character_controller,
            .tag = desc.tag,
            .sky = desc.sky,
            .constraint = desc.constraint,
            .material = desc.material,
            .light = desc.light,
            .vfx = desc.vfx,
            .script = try cloneScriptComponent(self.allocator, desc.script),
            .scripts = try cloneScriptComponents(self.allocator, desc.scripts),
            .audio_source = try cloneAudioSourceComponent(self.allocator, desc.audio_source),
            .audio_listener = desc.audio_listener,
            .nav_agent = desc.nav_agent,
            .visible = desc.visible,
            .editor_only = desc.editor_only,
            .selectable = desc.selectable,
            .dont_destroy_on_load = desc.dont_destroy_on_load,
            .is_folder = desc.is_folder,
            .world_transform_cache = .{},
            .world_matrix_cache = .{
                1.0, 0.0, 0.0, 0.0,
                0.0, 1.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            },
            .world_bounds_cache = null,
            .dirty = true,
            .children = .empty,
        });

        try self.id_to_index.put(id, index);
        self.transform_set.insert(id, desc.local_transform) catch |err| {
            std.log.err("failed to insert transform for entity {d}: {s}", .{ id, @errorName(err) });
        };
        if (desc.rigidbody) |rb| {
            self.rigidbody_set.insert(id, rb) catch |err| {
                std.log.err("failed to insert rigidbody for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        if (desc.box_collider) |bc| {
            self.box_collider_set.insert(id, bc) catch |err| {
                std.log.err("failed to insert box collider for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        if (desc.sphere_collider) |sc| {
            self.sphere_collider_set.insert(id, sc) catch |err| {
                std.log.err("failed to insert sphere collider for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        if (desc.capsule_collider) |cc| {
            self.capsule_collider_set.insert(id, cc) catch |err| {
                std.log.err("failed to insert capsule collider for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }

        if (desc.parent) |parent_id| {
            if (self.getEntity(parent_id)) |parent| {
                try parent.children.append(self.allocator, id);
            }
        }
        if (desc.mesh != null or desc.skinned_mesh != null or desc.vfx != null) {
            self.queueRenderableSync(id);
        }

        if (id >= self.next_id) {
            self.next_id = id + 1;
        }

        self.bumpSceneRevision();

        return id;
    }

    /// Retrieves a mutable reference to an entity by ID.
    ///
    /// Parameters:
    /// - `id`: EntityId to look up.
    ///
    /// Returns: Mutable pointer to Entity, or null if not found.
    ///
    /// Warnings:
    /// - Caller must not hold this pointer across calls to createEntity, deleteEntity, or updateHierarchy,
    ///   as internal allocations may relocate the entity array.
    /// - NOT thread-safe. Multiple threads must not modify the same entity simultaneously.
    ///   Use getEntityConst() for read-only access in other threads.
    ///
    /// Usage: Typically used to mutate entity transform, parent, or add components.
    pub fn getEntity(self: *World, id: EntityId) ?*Entity {
        const index = self.id_to_index.get(id) orelse return null;
        return &self.entities.items[index];
    }

    /// Retrieves a const reference to an entity by ID.
    ///
    /// Parameters:
    /// - `id`: EntityId to look up.
    ///
    /// Returns: Const pointer to Entity, or null if not found.
    ///
    /// Thread-safety: Thread-safe for concurrent reads from different threads.
    /// Safe to call while other threads iterate or read other entities,
    /// but not safe if World.createEntity or World.deleteEntity is called concurrently.
    ///
    /// Usage: Use this instead of getEntity() for read-only access, esp. in parallel queries.
    pub fn getEntityConst(self: *const World, id: EntityId) ?*const Entity {
        const index = self.id_to_index.get(id) orelse return null;
        return &self.entities.items[index];
    }

    pub fn hasEntity(self: *const World, id: EntityId) bool {
        return self.getEntityConst(id) != null;
    }

    pub fn sceneRevision(self: *const World) u64 {
        return self.scene_revision;
    }

    pub fn markSceneChanged(self: *World) void {
        self.bumpSceneRevision();
    }

    fn bumpSceneRevision(self: *World) void {
        const next = self.scene_revision +% 1;
        self.scene_revision = if (next == 0) 1 else next;
    }

    pub fn parentEntity(self: *const World, id: EntityId) ?EntityId {
        const entity = self.getEntityConst(id) orelse return null;
        return entity.parent;
    }

    /// Marks an entity and all descendants as dirty, triggering hierarchy recalculation.
    ///
    /// Parameters:
    /// - `id`: EntityId of entity to mark dirty.
    ///
    /// Side-effects:
    /// - Recursively marks all child entities dirty via DFS.
    /// - If entity has renderable (mesh/vfx), queues spatial index update.
    /// - If entity is cached in dynamic_renderables, flushes steady_query_count.
    /// - All dirty entities will be processed by updateHierarchy().
    ///
    /// Usage: Call after modifying local_transform, parent, or other cached properties.
    /// Note: updateHierarchy() must be called after to propagate changes to world transforms.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from main thread only.
    pub fn markDirty(self: *World, id: EntityId) void {
        const entity = self.getEntity(id) orelse return;
        if (entity.mesh != null or entity.skinned_mesh != null or entity.vfx != null) {
            self.queueRenderableSync(id);
            if (self.dynamic_renderables.getPtr(id)) |state| {
                state.steady_query_count = 0;
                _ = self.dynamic_dirty_renderables.put(id, {}) catch |err| {
                    std.log.err("failed to mark dynamic renderable dirty for entity {d}: {s}", .{ id, @errorName(err) });
                };
                // 不直接 markDirty() 整个 BVH，让 refitDirtyDynamicRenderables()
                // 先尝试增量 updateItemBounds()，只在失败时才退回全量重建。
            } else if (self.promoteRenderableToDynamic(id)) {
                _ = self.dynamic_dirty_renderables.put(id, {}) catch |err| {
                    std.log.err("failed to mark promoted dynamic renderable dirty for entity {d}: {s}", .{ id, @errorName(err) });
                };
                // 新晋升的动态实体需要全量重建以插入 BVH。
                self.dynamic_renderable_spatial_index.markDirty();
            } else {
                self.renderable_spatial_index.markDirty();
            }
        }

        const was_dirty = entity.dirty;
        entity.dirty = true;
        if (was_dirty) return;

        for (entity.children.items) |child_id| {
            self.markDirty(child_id);
        }
    }

    /// Recalculates all entity world transforms and bounds after hierarchy changes.
    ///
    /// This is a three-pass algorithm:
    /// 1. **Transform Pass**: Traverses root entities and recursively updates world transforms
    ///    by combining parent world matrix with local TRS. Only traverses entities marked dirty.
    /// 2. **Bounds Pass**: Calculates world-space AABB for each entity based on mesh geometry
    ///    or children bounds. Propagates up the hierarchy.
    /// 3. **Spatial Pass**: Syncs dirty renderables with spatial index (BVH) for culling.
    ///    Refits dynamic renderables after bounds change.
    ///
    /// Performance: O(n) where n = number of dirty entities. If no entities are dirty, early-exits.
    ///
    /// Call frequency: Typically called once per frame before rendering.
    /// Must be called if any entity's local_transform or parent relationship changed.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from main thread only.
    pub fn updateHierarchy(self: *World) void {
        const mat4 = @import("../math/mat4.zig");

        // First pass: update world transforms
        for (self.entities.items) |*entity| {
            if (entity.parent == null) {
                self.updateTransformRecursive(entity.id, mat4.identity());
            }
        }

        // Second pass: update bounds (bottom-up)
        for (self.entities.items) |*entity| {
            _ = self.updateBoundsRecursive(entity.id);
        }

        // Third pass: sync only the renderables dirtied by this hierarchy update.
        self.syncRenderableSpatialItems() catch |err| {
            std.log.err("failed to sync renderable spatial items: {s}", .{@errorName(err)});
        };
        self.refitDirtyDynamicRenderables() catch |err| {
            std.log.err("failed to refit dirty dynamic renderables: {s}", .{@errorName(err)});
        };
    }

    fn updateTransformRecursive(self: *World, id: EntityId, parent_world_matrix: [16]f32) void {
        const entity = self.getEntity(id) orelse return;
        if (entity.dirty) {
            const mat4 = @import("../math/mat4.zig");
            const quat = @import("../math/quat.zig");

            // Combine parent and local
            const local_mat = mat4.transformMatrix(entity.local_transform);
            const world_mat = mat4.mul(parent_world_matrix, local_mat);
            entity.world_matrix_cache = world_mat;

            // For now, we store it back in TRS.
            // In a real engine, we'd store the matrix and decompose only if needed.
            // But we'll follow the plan's TRS requirement.
            entity.world_transform_cache.translation = .{ world_mat[12], world_mat[13], world_mat[14] };

            // Simplified decomposition for now - assuming no skew
            const scale_x = vec3.length(.{ world_mat[0], world_mat[1], world_mat[2] });
            const scale_y = vec3.length(.{ world_mat[4], world_mat[5], world_mat[6] });
            const scale_z = vec3.length(.{ world_mat[8], world_mat[9], world_mat[10] });
            entity.world_transform_cache.scale = .{ scale_x, scale_y, scale_z };

            // Normalize the basis vectors before converting back to a quaternion.
            const safe_scale_x = if (scale_x <= compose_epsilon) 1.0 else scale_x;
            const safe_scale_y = if (scale_y <= compose_epsilon) 1.0 else scale_y;
            const safe_scale_z = if (scale_z <= compose_epsilon) 1.0 else scale_z;
            const rot_mat = [_]f32{
                world_mat[0] / safe_scale_x, world_mat[1] / safe_scale_x, world_mat[2] / safe_scale_x,  0.0,
                world_mat[4] / safe_scale_y, world_mat[5] / safe_scale_y, world_mat[6] / safe_scale_y,  0.0,
                world_mat[8] / safe_scale_z, world_mat[9] / safe_scale_z, world_mat[10] / safe_scale_z, 0.0,
                0.0,                         0.0,                         0.0,                          1.0,
            };
            entity.world_transform_cache.rotation = quat.normalize(quat.fromRotationMatrix(rot_mat));

            entity.dirty = false;
        }

        for (entity.children.items) |child_id| {
            self.updateTransformRecursive(child_id, entity.world_matrix_cache);
        }
    }

    fn updateBoundsRecursive(self: *World, id: EntityId) AABB {
        const entity = self.getEntity(id) orelse return AABB.empty();

        var bounds = AABB.empty();

        // Include own mesh bounds
        if (entity.mesh) |mesh_comp| {
            if (mesh_comp.handle) |handle| {
                if (self.resources.mesh(handle)) |mesh_res| {
                    bounds.expandAABB(mesh_res.local_bounds.transformed(entity.world_transform_cache));
                }
            }
        } else if (entity.skinned_mesh) |skinned_mesh_comp| {
            if (skinned_mesh_comp.mesh_handle) |handle| {
                if (self.resources.mesh(handle)) |mesh_res| {
                    bounds.expandAABB(mesh_res.local_bounds.transformed(entity.world_transform_cache));
                }
            }
        }

        // Include children bounds
        for (entity.children.items) |child_id| {
            const child_bounds = self.updateBoundsRecursive(child_id);
            if (child_bounds.isValid()) {
                bounds.expandAABB(child_bounds);
            }
        }

        entity.world_bounds_cache = if (bounds.isValid()) bounds else null;
        return bounds;
    }

    pub fn setEntityLocalTransform(self: *World, id: EntityId, transform: components.Transform) bool {
        const entity = self.getEntity(id) orelse return false;
        entity.local_transform = transform;
        if (self.transform_set.getPtr(id)) |t| {
            t.* = transform;
        }
        self.markDirty(id);
        self.bumpSceneRevision();
        return true;
    }

    pub fn localTransform(self: *const World, id: EntityId) components.Transform {
        if (self.transform_set.get(id)) |t| {
            return t.*;
        }
        const entity = self.getEntityConst(id) orelse return .{};
        return entity.local_transform;
    }

    pub fn worldTransform(self: *World, id: EntityId) ?components.Transform {
        const entity = self.getEntity(id) orelse return null;
        if (entity.dirty) {
            self.updateHierarchy();
        }
        return entity.world_transform_cache;
    }

    pub fn worldTransformConst(self: *const World, id: EntityId) ?components.Transform {
        const entity = self.getEntityConst(id) orelse return null;
        // In const context we can't update, so we just return the cache
        // If it's dirty, the caller should have called updateHierarchy before.
        return entity.world_transform_cache;
    }

    pub fn worldBounds(self: *World, id: EntityId) ?AABB {
        const entity = self.getEntity(id) orelse return null;
        if (entity.dirty) {
            self.updateHierarchy();
        }
        return entity.world_bounds_cache;
    }

    pub fn worldBoundsConst(self: *const World, id: EntityId) ?AABB {
        const entity = self.getEntityConst(id) orelse return null;
        return entity.world_bounds_cache;
    }

    pub fn setEntityWorldTransform(self: *World, id: EntityId, world_transform: components.Transform) bool {
        const entity = self.getEntity(id) orelse return false;
        if (entity.parent) |parent_id| {
            const parent_world = self.worldTransform(parent_id) orelse return false;
            entity.local_transform = relativeTransform(parent_world, world_transform);
        } else {
            entity.local_transform = world_transform;
        }
        if (self.transform_set.getPtr(id)) |t| {
            t.* = entity.local_transform;
        }
        self.markDirty(id);
        self.bumpSceneRevision();
        return true;
    }

    pub fn noteEntityRenderableChanged(self: *World, id: EntityId) void {
        if (!self.hasEntity(id)) {
            return;
        }
        self.markDirty(id);
        self.bumpSceneRevision();
    }

    pub fn noteMeshResourceChanged(self: *World, handle: assets_handles.MeshHandle) void {
        if (!assets_handles.isValid(handle)) {
            return;
        }

        var changed = false;
        for (self.entities.items) |entity| {
            const uses_mesh = if (entity.mesh) |mesh_component|
                if (mesh_component.handle) |mesh_handle| mesh_handle == handle else false
            else
                false;
            const uses_skinned_mesh = if (entity.skinned_mesh) |skinned_mesh_component|
                if (skinned_mesh_component.mesh_handle) |mesh_handle| mesh_handle == handle else false
            else
                false;

            if (!uses_mesh and !uses_skinned_mesh) {
                continue;
            }

            self.markDirty(entity.id);
            changed = true;
        }

        if (changed) {
            self.bumpSceneRevision();
        }
    }

    pub fn getRigidbody(self: *const World, id: EntityId) ?components.Rigidbody {
        if (self.rigidbody_set.get(id)) |rb| {
            return rb.*;
        }
        const entity = self.getEntityConst(id) orelse return null;
        return entity.rigidbody;
    }

    pub fn getRigidbodyPtr(self: *World, id: EntityId) ?*components.Rigidbody {
        if (self.rigidbody_set.getPtr(id)) |rb| {
            return rb;
        }
        const entity = self.getEntity(id) orelse return null;
        return &entity.rigidbody;
    }

    pub fn setRigidbody(self: *World, id: EntityId, rigidbody: components.Rigidbody) bool {
        const entity = self.getEntity(id) orelse return false;
        entity.rigidbody = rigidbody;
        if (self.rigidbody_set.getPtr(id)) |rb| {
            rb.* = rigidbody;
        } else {
            self.rigidbody_set.insert(id, rigidbody) catch |err| {
                std.log.err("failed to insert rigidbody for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        self.bumpSceneRevision();
        return true;
    }

    pub fn hasRigidbody(self: *const World, id: EntityId) bool {
        return self.rigidbody_set.contains(id) or (self.getEntityConst(id) != null and self.getEntityConst(id).?.rigidbody != null);
    }

    pub fn getBoxCollider(self: *const World, id: EntityId) ?components.BoxCollider {
        if (self.box_collider_set.get(id)) |bc| {
            return bc.*;
        }
        const entity = self.getEntityConst(id) orelse return null;
        return entity.box_collider;
    }

    pub fn getBoxColliderPtr(self: *World, id: EntityId) ?*components.BoxCollider {
        if (self.box_collider_set.getPtr(id)) |bc| {
            return bc;
        }
        const entity = self.getEntity(id) orelse return null;
        return &entity.box_collider;
    }

    pub fn setBoxCollider(self: *World, id: EntityId, box_collider: components.BoxCollider) bool {
        const entity = self.getEntity(id) orelse return false;
        entity.box_collider = box_collider;
        if (self.box_collider_set.getPtr(id)) |bc| {
            bc.* = box_collider;
        } else {
            self.box_collider_set.insert(id, box_collider) catch |err| {
                std.log.err("failed to insert box collider for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        self.bumpSceneRevision();
        return true;
    }

    pub fn hasBoxCollider(self: *const World, id: EntityId) bool {
        return self.box_collider_set.contains(id) or (self.getEntityConst(id) != null and self.getEntityConst(id).?.box_collider != null);
    }

    pub fn getSphereCollider(self: *const World, id: EntityId) ?components.SphereCollider {
        if (self.sphere_collider_set.get(id)) |sc| {
            return sc.*;
        }
        const entity = self.getEntityConst(id) orelse return null;
        return entity.sphere_collider;
    }

    pub fn getSphereColliderPtr(self: *World, id: EntityId) ?*components.SphereCollider {
        if (self.sphere_collider_set.getPtr(id)) |sc| {
            return sc;
        }
        const entity = self.getEntity(id) orelse return null;
        return &entity.sphere_collider;
    }

    pub fn setSphereCollider(self: *World, id: EntityId, sphere_collider: components.SphereCollider) bool {
        const entity = self.getEntity(id) orelse return false;
        entity.sphere_collider = sphere_collider;
        if (self.sphere_collider_set.getPtr(id)) |sc| {
            sc.* = sphere_collider;
        } else {
            self.sphere_collider_set.insert(id, sphere_collider) catch |err| {
                std.log.err("failed to insert sphere collider for entity {d}: {s}", .{ id, @errorName(err) });
            };
        }
        self.bumpSceneRevision();
        return true;
    }

    pub fn hasSphereCollider(self: *const World, id: EntityId) bool {
        return self.sphere_collider_set.contains(id) or (self.getEntityConst(id) != null and self.getEntityConst(id).?.sphere_collider != null);
    }

    pub fn renameEntity(self: *World, id: EntityId, new_name: []const u8) !bool {
        const entity = self.getEntity(id) orelse return false;
        if (std.mem.eql(u8, entity.name, new_name)) {
            return false;
        }

        const owned_name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(entity.name);
        entity.name = owned_name;
        self.bumpSceneRevision();
        return true;
    }

    pub fn findEntityByName(self: *const World, name: []const u8) ?*const Entity {
        for (self.entities.items) |*entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity;
            }
        }
        return null;
    }

    pub fn primaryCameraEntity(self: *const World) ?EntityId {
        var fallback: ?EntityId = null;
        for (self.entities.items) |entity| {
            const camera = entity.camera orelse continue;
            if (fallback == null) {
                fallback = entity.id;
            }
            if (camera.is_primary) {
                return entity.id;
            }
        }
        return fallback;
    }

    pub fn setPrimaryCamera(self: *World, id: EntityId) bool {
        var found = false;
        var changed = false;
        for (self.entities.items) |*entity| {
            if (entity.camera) |camera| {
                var next_camera = camera;
                next_camera.is_primary = entity.id == id;
                changed = changed or next_camera.is_primary != camera.is_primary;
                entity.camera = next_camera;
                if (entity.id == id) {
                    found = true;
                }
            }
        }
        if (changed) {
            self.bumpSceneRevision();
        }
        return found;
    }

    pub fn setParent(self: *World, child_id: EntityId, parent_id: ?EntityId) !bool {
        if (!self.hasEntity(child_id)) {
            return false;
        }

        if (parent_id) |resolved_parent_id| {
            if (!self.hasEntity(resolved_parent_id)) {
                return error.ParentNotFound;
            }
            if (resolved_parent_id == child_id or self.isDescendantOf(resolved_parent_id, child_id)) {
                return error.ParentCycleDetected;
            }
        }

        const current_world = self.worldTransform(child_id) orelse return false;
        const entity = self.getEntity(child_id) orelse return false;
        if (entity.parent == parent_id) {
            return false;
        }

        // Remove from old parent
        if (entity.parent) |old_parent_id| {
            if (self.getEntity(old_parent_id)) |old_parent| {
                for (old_parent.children.items, 0..) |cid, i| {
                    if (cid == child_id) {
                        _ = old_parent.children.swapRemove(i);
                        break;
                    }
                }
            }
        }

        entity.parent = parent_id;

        // Add to new parent
        if (parent_id) |new_parent_id| {
            if (self.getEntity(new_parent_id)) |new_parent| {
                try new_parent.children.append(self.allocator, child_id);
            }
        }

        return self.setEntityWorldTransform(child_id, current_world);
    }

    pub fn setParentLocal(self: *World, child_id: EntityId, parent_id: ?EntityId) !bool {
        if (!self.hasEntity(child_id)) {
            return false;
        }

        if (parent_id) |resolved_parent_id| {
            if (!self.hasEntity(resolved_parent_id)) {
                return error.ParentNotFound;
            }
            if (resolved_parent_id == child_id or self.isDescendantOf(resolved_parent_id, child_id)) {
                return error.ParentCycleDetected;
            }
        }

        const entity = self.getEntity(child_id) orelse return false;
        if (entity.parent == parent_id) {
            return false;
        }

        // Remove from old parent
        if (entity.parent) |old_parent_id| {
            if (self.getEntity(old_parent_id)) |old_parent| {
                for (old_parent.children.items, 0..) |cid, i| {
                    if (cid == child_id) {
                        _ = old_parent.children.swapRemove(i);
                        break;
                    }
                }
            }
        }

        entity.parent = parent_id;

        // Add to new parent
        if (parent_id) |new_parent_id| {
            if (self.getEntity(new_parent_id)) |new_parent| {
                try new_parent.children.append(self.allocator, child_id);
            }
        }

        self.markDirty(child_id);
        self.bumpSceneRevision();
        return true;
    }

    pub fn destroyEntity(self: *World, id: EntityId) bool {
        var subtree = std.ArrayList(EntityId).empty;
        defer subtree.deinit(self.allocator);
        self.collectSubtreeIds(id, &subtree) catch return false;
        if (subtree.items.len == 0) {
            return false;
        }

        self.removeVfxEmittersForEntities(subtree.items);

        var index = subtree.items.len;
        while (index > 0) {
            index -= 1;
            self.removeEntityById(subtree.items[index]);
        }
        self.bumpSceneRevision();
        return true;
    }

    pub fn setEntityVisible(self: *World, id: EntityId, visible: bool) bool {
        const entity = self.getEntity(id) orelse return false;
        if (entity.visible == visible) {
            return false;
        }
        entity.visible = visible;
        self.bumpSceneRevision();
        return true;
    }

    pub fn pruneVfxRuntimeEmitters(self: *World) void {
        var index: usize = 0;
        while (index < self.vfx_runtime_emitters.items.len) {
            const emitter_id = self.vfx_runtime_emitters.items[index].entity_id;
            const emitter_entity = self.getEntityConst(emitter_id);
            if (emitter_entity == null or emitter_entity.?.vfx == null) {
                self.clearVfxEmitterAtIndex(index, true);
                continue;
            }
            index += 1;
        }
    }

    pub fn clearVfxRuntime(self: *World) void {
        self.releaseVfxRuntime(true);
    }

    pub fn clearVfxEmitterRuntime(self: *World, entity_id: EntityId) void {
        for (self.vfx_runtime_emitters.items, 0..) |emitter, index| {
            if (emitter.entity_id == entity_id) {
                self.clearVfxEmitterAtIndex(index, true);
                return;
            }
        }
    }

    pub fn ensureVfxRuntimeEmitter(self: *World, entity_id: EntityId, vfx: components.Vfx) !*vfx_runtime_mod.VfxRuntimeEmitter {
        for (self.vfx_runtime_emitters.items) |*emitter| {
            if (emitter.entity_id == entity_id) {
                if (!vfx.looping and emitter.particles.len == 0 and emitter.elapsed <= 0.0001 and emitter.one_shot_remaining == 0) {
                    emitter.one_shot_remaining = vfx.max_particles;
                }
                return emitter;
            }
        }

        try self.vfx_runtime_emitters.append(self.allocator, .{
            .entity_id = entity_id,
            .seed = @truncate(entity_id *% 747796405 +% 2891336453),
            .one_shot_remaining = if (vfx.looping) 0 else vfx.max_particles,
        });
        return &self.vfx_runtime_emitters.items[self.vfx_runtime_emitters.items.len - 1];
    }

    pub fn duplicateEntity(self: *World, id: EntityId) !EntityId {
        const source = self.getEntityConst(id) orelse return error.EntityNotFound;
        return self.duplicateEntityRecursive(id, source.parent);
    }

    pub const createPrimitiveEntity = @import("world_factory.zig").createPrimitiveEntity;
    pub const createEmptyEntity = @import("world_factory.zig").createEmptyEntity;
    pub const createFolderEntity = @import("world_factory.zig").createFolderEntity;
    pub const createCameraEntity = @import("world_factory.zig").createCameraEntity;
    pub const createLightEntity = @import("world_factory.zig").createLightEntity;
    pub const createVfxEntity = @import("world_factory.zig").createVfxEntity;
    pub const bootstrap3D = @import("world_factory.zig").bootstrap3D;

    pub fn summary(self: *const World) Summary {
        var result = Summary{
            .entity_count = self.entities.items.len,
        };

        for (self.entities.items) |entity| {
            if (entity.camera != null) {
                result.camera_count += 1;
            }
            if (entity.mesh != null or entity.skinned_mesh != null) {
                result.mesh_count += 1;
            }
            if (entity.material != null) {
                result.material_count += 1;
            }
            if (entity.light != null) {
                result.light_count += 1;
            }
            if (entity.vfx != null) {
                result.vfx_count += 1;
            }
            if (entity.rigidbody != null) {
                result.rigidbody_count += 1;
            }
            if (entity.box_collider != null or entity.sphere_collider != null or entity.mesh_collider != null) {
                result.collider_count += 1;
            }
        }

        return result;
    }

    pub fn importGltfStaticModel(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
    ) !gltf_import.ImportReport {
        return gltf_import.importStaticModel(self, path, root_transform);
    }

    const AsyncImportContext = struct {
        world: *World,
        path: []const u8,
        root_transform: components.Transform,
        callback: ?*const fn (report: gltf_import.ImportReport) void = null,

        fn deinit(self: *AsyncImportContext) void {
            self.world.allocator.free(self.path);
            self.world.allocator.destroy(self);
        }
    };

    fn asyncImportCleanup(context: ?*anyopaque) void {
        const ctx: *AsyncImportContext = @ptrCast(@alignCast(context));
        ctx.deinit();
    }

    fn asyncImportTask(context: ?*anyopaque) void {
        const ctx: *AsyncImportContext = @ptrCast(@alignCast(context));
        defer ctx.deinit();

        const report = ctx.world.importGltfStaticModel(ctx.path, ctx.root_transform) catch |err| {
            std.log.err("Async GLTF import failed: {s}, error: {}", .{ ctx.path, err });
            return;
        };
        if (ctx.callback) |cb| {
            cb(report);
        }
    }

    pub fn importGltfAsync(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
        callback: ?*const fn (report: gltf_import.ImportReport) void,
    ) !job_system_mod.JobHandle {
        const job_system = self.job_system orelse return error.NoJobSystem;
        const ctx = try self.allocator.create(AsyncImportContext);
        ctx.* = .{
            .world = self,
            .path = try self.allocator.dupe(u8, path),
            .root_transform = root_transform,
            .callback = callback,
        };

        return job_system.enqueueWithCleanup(asyncImportTask, ctx, asyncImportCleanup, .normal);
    }

    pub fn importGltfStaticModelInstance(
        self: *World,
        path: []const u8,
        root_transform: components.Transform,
    ) !gltf_import.ImportReport {
        return gltf_import.importStaticModelInstance(self, path, root_transform);
    }

    pub fn raycastSurface(self: *World, ray: raycast_mod.Ray) ?raycast_mod.SurfaceRaycastHit {
        return raycast_mod.raycastSurface(self, ray);
    }

    pub fn queryRenderableRayCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]EntityId {
        const bounds_candidates = try self.queryRenderableRayBounds(allocator, ray_origin, ray_direction, max_distance);
        defer allocator.free(bounds_candidates);

        var candidates = std.ArrayList(EntityId).empty;
        errdefer candidates.deinit(allocator);
        try candidates.ensureTotalCapacity(allocator, @intCast(bounds_candidates.len));
        for (bounds_candidates) |candidate| {
            candidates.appendAssumeCapacity(candidate.id);
        }
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableRayBounds(
        self: *World,
        allocator: std.mem.Allocator,
        ray_origin: [3]f32,
        ray_direction: [3]f32,
        max_distance: f32,
    ) ![]RenderableRayCandidate {
        try self.ensureRenderableSpatialState();

        var candidates = std.ArrayList(RenderableRayCandidate).empty;
        errdefer candidates.deinit(allocator);

        const static_candidates = try self.renderable_spatial_index.queryRayCandidatesDetailed(
            allocator,
            ray_origin,
            ray_direction,
            max_distance,
        );
        defer allocator.free(static_candidates);
        try self.appendRenderableRayCandidates(allocator, &candidates, static_candidates);

        const dynamic_candidates = try self.dynamic_renderable_spatial_index.queryRayCandidatesDetailed(
            allocator,
            ray_origin,
            ray_direction,
            max_distance,
        );
        defer allocator.free(dynamic_candidates);
        try self.appendRenderableRayCandidates(allocator, &candidates, dynamic_candidates);

        std.sort.heap(RenderableRayCandidate, candidates.items, {}, lessThanRenderableRayCandidateDistance);
        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableFrustumCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]EntityId {
        try self.ensureRenderableSpatialState();

        var candidates = std.ArrayList(EntityId).empty;
        errdefer candidates.deinit(allocator);

        const static_candidates = try self.renderable_spatial_index.queryFrustumCandidates(allocator, frustum);
        defer allocator.free(static_candidates);
        try candidates.appendSlice(allocator, static_candidates);

        const dynamic_candidates = try self.dynamic_renderable_spatial_index.queryFrustumCandidates(allocator, frustum);
        defer allocator.free(dynamic_candidates);
        try candidates.appendSlice(allocator, dynamic_candidates);

        return try candidates.toOwnedSlice(allocator);
    }

    pub fn queryRenderableBoundsInFrustum(
        self: *World,
        allocator: std.mem.Allocator,
        frustum: frustum_mod.Frustum,
    ) ![]spatial_index_mod.BoundsItem {
        const candidate_ids = try self.queryRenderableFrustumCandidates(allocator, frustum);
        defer allocator.free(candidate_ids);

        var bounds_items = std.ArrayList(spatial_index_mod.BoundsItem).empty;
        errdefer bounds_items.deinit(allocator);
        try bounds_items.ensureTotalCapacity(allocator, @intCast(candidate_ids.len));

        // 调试可视化直接复用 BVH 候选与 world bounds cache，避免再走一遍 mesh local bounds 现场换算。
        for (candidate_ids) |entity_id| {
            const bounds = self.worldBoundsConst(entity_id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            bounds_items.appendAssumeCapacity(.{
                .id = entity_id,
                .bounds = bounds,
            });
        }

        return try bounds_items.toOwnedSlice(allocator);
    }

    pub fn assets(self: *World) *assets_lib.ResourceLibrary {
        return &self.resources;
    }

    pub fn bindAnimatorTargets(self: *World, animator_entity_id: EntityId, target_entities: []const EntityId) !void {
        if (!self.hasEntity(animator_entity_id)) {
            return error.EntityNotFound;
        }

        const owned_targets = try self.allocator.dupe(EntityId, target_entities);
        errdefer self.allocator.free(owned_targets);
        const owned_base_transforms = try self.allocator.alloc(components.Transform, target_entities.len);
        errdefer self.allocator.free(owned_base_transforms);
        for (target_entities, 0..) |target_entity_id, index| {
            owned_base_transforms[index] = if (self.getEntityConst(target_entity_id)) |entity|
                entity.local_transform
            else
                .{};
        }

        for (self.animator_bindings.items) |*binding| {
            if (binding.animator_entity_id != animator_entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
            binding.target_entities = owned_targets;
            binding.base_local_transforms = owned_base_transforms;
            return;
        }

        try self.animator_bindings.append(self.allocator, .{
            .animator_entity_id = animator_entity_id,
            .target_entities = owned_targets,
            .base_local_transforms = owned_base_transforms,
        });
    }

    pub fn animatorTargets(self: *const World, animator_entity_id: EntityId) ?[]const EntityId {
        for (self.animator_bindings.items) |binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding.target_entities;
            }
        }
        return null;
    }

    pub fn animatorBaseTransforms(self: *const World, animator_entity_id: EntityId) ?[]const components.Transform {
        for (self.animator_bindings.items) |binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding.base_local_transforms;
            }
        }
        return null;
    }

    pub const AnimatorGraphParameterError = error{
        EntityNotFound,
        GraphNotBound,
        ParameterNotFound,
    };

    pub fn bindAnimatorGraph(
        self: *World,
        animator_entity_id: EntityId,
        graph: *const animation_graph_mod.AnimationGraph,
    ) !void {
        const entity = self.getEntity(animator_entity_id) orelse return error.EntityNotFound;
        if (entity.animator == null) {
            return error.MissingAnimator;
        }

        const owned_graph = try self.allocator.create(animation_graph_mod.AnimationGraph);
        errdefer self.allocator.destroy(owned_graph);
        owned_graph.* = try graph.clone(self.allocator);
        errdefer owned_graph.deinit();

        var instance = try animation_graph_mod.AnimationGraphInstance.init(self.allocator, owned_graph);
        errdefer instance.deinit();

        if (self.findAnimatorGraphBinding(animator_entity_id)) |binding| {
            binding.deinit(self.allocator);
            binding.* = .{
                .animator_entity_id = animator_entity_id,
                .graph = owned_graph,
                .instance = instance,
            };
        } else {
            try self.animator_graph_bindings.append(self.allocator, .{
                .animator_entity_id = animator_entity_id,
                .graph = owned_graph,
                .instance = instance,
            });
        }
        entity.animator.?.playing = true;
    }

    pub fn clearAnimatorGraph(self: *World, animator_entity_id: EntityId) bool {
        return self.removeAnimatorGraphBinding(animator_entity_id);
    }

    pub fn animatorGraph(self: *const World, animator_entity_id: EntityId) ?*const animation_graph_mod.AnimationGraph {
        const binding = self.findAnimatorGraphBindingConst(animator_entity_id) orelse return null;
        return binding.graph;
    }

    pub fn animatorGraphMutable(self: *World, animator_entity_id: EntityId) ?*animation_graph_mod.AnimationGraph {
        const binding = self.findAnimatorGraphBinding(animator_entity_id) orelse return null;
        return binding.graph;
    }

    pub fn animatorGraphInstance(self: *World, animator_entity_id: EntityId) ?*animation_graph_mod.AnimationGraphInstance {
        const binding = self.findAnimatorGraphBinding(animator_entity_id) orelse return null;
        return &binding.instance;
    }

    pub fn animatorGraphInstanceConst(self: *const World, animator_entity_id: EntityId) ?*const animation_graph_mod.AnimationGraphInstance {
        const binding = self.findAnimatorGraphBindingConst(animator_entity_id) orelse return null;
        return &binding.instance;
    }

    pub fn setAnimatorGraphParameter(
        self: *World,
        animator_entity_id: EntityId,
        parameter_index: u32,
        value: animation_graph_mod.AnimationGraphInstance.ParameterValue,
    ) AnimatorGraphParameterError!void {
        _ = self.getEntityConst(animator_entity_id) orelse return error.EntityNotFound;
        const instance = self.animatorGraphInstance(animator_entity_id) orelse return error.GraphNotBound;
        if (parameter_index >= instance.parameters.items.len) {
            return error.ParameterNotFound;
        }
        instance.setParameter(parameter_index, value);
    }

    pub fn setAnimatorGraphParameterByName(
        self: *World,
        animator_entity_id: EntityId,
        name: []const u8,
        value: animation_graph_mod.AnimationGraphInstance.ParameterValue,
    ) AnimatorGraphParameterError!void {
        _ = self.getEntityConst(animator_entity_id) orelse return error.EntityNotFound;
        const graph = self.animatorGraph(animator_entity_id) orelse return error.GraphNotBound;
        const parameter_index = graph.findParameter(name) orelse return error.ParameterNotFound;
        try self.setAnimatorGraphParameter(animator_entity_id, parameter_index, value);
    }

    pub fn bindSkinnedMeshTargets(self: *World, entity_id: EntityId, target_entities: []const EntityId) !void {
        if (!self.hasEntity(entity_id)) {
            return error.EntityNotFound;
        }

        const owned_targets = try self.allocator.dupe(EntityId, target_entities);
        errdefer self.allocator.free(owned_targets);

        for (self.skinned_mesh_bindings.items) |*binding| {
            if (binding.entity_id != entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            binding.target_entities = owned_targets;
            return;
        }

        try self.skinned_mesh_bindings.append(self.allocator, .{
            .entity_id = entity_id,
            .target_entities = owned_targets,
        });
    }

    pub fn skinnedMeshTargets(self: *const World, entity_id: EntityId) ?[]const EntityId {
        for (self.skinned_mesh_bindings.items) |binding| {
            if (binding.entity_id == entity_id) {
                return binding.target_entities;
            }
        }
        return null;
    }

    fn worldTransformRecursive(self: *const World, id: EntityId, depth: usize) ?components.Transform {
        _ = depth;
        return self.worldTransformConst(id);
    }

    fn isDescendantOf(self: *const World, candidate_id: EntityId, ancestor_id: EntityId) bool {
        var current = self.getEntityConst(candidate_id) orelse return false;
        var guard: usize = 0;
        while (current.parent) |parent_id| : (guard += 1) {
            if (guard > self.entities.items.len) {
                return false;
            }
            if (parent_id == ancestor_id) {
                return true;
            }
            current = self.getEntityConst(parent_id) orelse return false;
        }
        return false;
    }

    fn collectDirectChildIds(self: *const World, parent_id: EntityId, list: *std.ArrayList(EntityId)) !void {
        for (self.entities.items) |entity| {
            if (entity.parent == parent_id) {
                try list.append(self.allocator, entity.id);
            }
        }
    }

    fn collectSubtreeIds(self: *const World, root_id: EntityId, list: *std.ArrayList(EntityId)) !void {
        if (!self.hasEntity(root_id)) {
            return;
        }

        try list.append(self.allocator, root_id);
        for (self.entities.items) |entity| {
            if (entity.parent == root_id) {
                try self.collectSubtreeIds(entity.id, list);
            }
        }
    }

    fn removeEntityById(self: *World, id: EntityId) void {
        const index = self.id_to_index.get(id) orelse return;
        const entity = &self.entities.items[index];
        self.removeBoundsItemFromPartition(
            &self.static_renderable_items,
            &self.static_renderable_item_indices,
            &self.renderable_spatial_index,
            id,
        );
        self.removeBoundsItemFromPartition(
            &self.dynamic_renderable_items,
            &self.dynamic_renderable_item_indices,
            &self.dynamic_renderable_spatial_index,
            id,
        );
        _ = self.dynamic_renderables.remove(id);
        _ = self.dynamic_dirty_renderables.remove(id);
        _ = self.renderable_sync_candidates.remove(id);
        self.removeAnimatorBinding(id);
        _ = self.removeAnimatorGraphBinding(id);
        self.removeSkinnedMeshBinding(id);

        // Remove from parent's children list
        if (entity.parent) |parent_id| {
            if (self.getEntity(parent_id)) |parent| {
                for (parent.children.items, 0..) |child_id, child_idx| {
                    if (child_id == id) {
                        _ = parent.children.swapRemove(child_idx);
                        break;
                    }
                }
            }
        }

        entity.deinit(self.allocator);
        _ = self.entities.orderedRemove(index);
        _ = self.id_to_index.remove(id);

        // Update indices in the map because orderedRemove shifts items
        for (self.entities.items[index..], index..) |shifted, i| {
            self.id_to_index.put(shifted.id, i) catch |err| {
                std.log.err("failed to update entity index for id {d}: {s}", .{ shifted.id, @errorName(err) });
            };
        }
    }

    fn duplicateEntityRecursive(self: *World, source_id: EntityId, new_parent: ?EntityId) !EntityId {
        const source = self.getEntityConst(source_id) orelse return error.EntityNotFound;
        var source_subtree_ids = std.ArrayList(EntityId).empty;
        defer source_subtree_ids.deinit(self.allocator);
        if (self.animatorTargets(source_id) != null) {
            try self.collectSubtreeIds(source_id, &source_subtree_ids);
        }

        var child_ids = std.ArrayList(EntityId).empty;
        defer child_ids.deinit(self.allocator);
        try self.collectDirectChildIds(source_id, &child_ids);

        const duplicate_name = try self.nextAvailableDerivedName(source.name, " Copy");
        defer self.allocator.free(duplicate_name);

        const duplicate_camera = if (source.camera) |camera| blk: {
            var next_camera = camera;
            next_camera.is_primary = false;
            break :blk next_camera;
        } else null;

        const duplicate_id = try self.createEntity(.{
            .name = duplicate_name,
            .parent = new_parent,
            .local_transform = source.local_transform,
            .camera = duplicate_camera,
            .mesh = source.mesh,
            .skinned_mesh = source.skinned_mesh,
            .animator = source.animator,
            .rigidbody = source.rigidbody,
            .box_collider = source.box_collider,
            .sphere_collider = source.sphere_collider,
            .mesh_collider = source.mesh_collider,
            .material = source.material,
            .light = source.light,
            .vfx = source.vfx,
            .script = try cloneScriptComponent(self.allocator, source.script),
            .scripts = try cloneScriptComponents(self.allocator, source.scripts),
            .audio_source = try cloneAudioSourceComponent(self.allocator, source.audio_source),
            .audio_listener = source.audio_listener,
            .nav_agent = source.nav_agent,
            .visible = source.visible,
            .editor_only = source.editor_only,
            .selectable = source.selectable,
            .dont_destroy_on_load = source.dont_destroy_on_load,
            .is_folder = source.is_folder,
        });

        if (self.findAnimatorGraphBindingConst(source_id)) |source_graph_binding| {
            const source_graph = source_graph_binding.graph;
            const source_instance = source_graph_binding.instance;
            try self.bindAnimatorGraph(duplicate_id, source_graph);
            if (self.findAnimatorGraphBinding(duplicate_id)) |duplicate_graph_binding| {
                copyAnimatorGraphInstanceState(&duplicate_graph_binding.instance, &source_instance);
            }
        }

        for (child_ids.items) |child_id| {
            const child = self.getEntityConst(child_id) orelse continue;
            if (child.editor_only) {
                continue;
            }
            _ = try self.duplicateEntityRecursive(child_id, duplicate_id);
        }

        if (self.animatorTargets(source_id)) |targets| {
            var duplicate_subtree_ids = std.ArrayList(EntityId).empty;
            defer duplicate_subtree_ids.deinit(self.allocator);
            try self.collectSubtreeIds(duplicate_id, &duplicate_subtree_ids);

            var remapped_targets = std.ArrayList(EntityId).empty;
            defer remapped_targets.deinit(self.allocator);
            try remapped_targets.ensureTotalCapacity(self.allocator, @intCast(targets.len));

            for (targets) |target_id| {
                const subtree_index = indexOfEntityId(source_subtree_ids.items, target_id) orelse continue;
                if (subtree_index >= duplicate_subtree_ids.items.len) {
                    continue;
                }
                remapped_targets.appendAssumeCapacity(duplicate_subtree_ids.items[subtree_index]);
            }
            if (remapped_targets.items.len == targets.len) {
                try self.bindAnimatorTargets(duplicate_id, remapped_targets.items);
            }
        }

        return duplicate_id;
    }

    pub fn nextAvailableName(self: *const World, base_name: []const u8) ![]u8 {
        return self.nextAvailableDerivedName(base_name, "");
    }

    fn ensureRenderableSpatialState(self: *World) !void {
        if (self.hasDirtyEntities()) {
            self.updateHierarchy();
        }

        const reintegrated_dynamic = try self.reintegrateStableDynamicRenderables();
        try self.syncRenderableSpatialItems();
        try self.refitDirtyDynamicRenderables();

        if (!self.renderable_spatial_index.dirty and !self.dynamic_renderable_spatial_index.dirty and !reintegrated_dynamic) {
            return;
        }

        var rebuilt_static = false;
        if (self.renderable_spatial_index.dirty) {
            // 静态树只从缓存分区条目重建，避免树 dirty 后重新线性扫完整个 World。
            try self.renderable_spatial_index.rebuild(self.static_renderable_items.items);
            rebuilt_static = true;
        }
        var rebuilt_dynamic = false;
        if (self.dynamic_renderable_spatial_index.dirty) {
            try self.dynamic_renderable_spatial_index.rebuild(self.dynamic_renderable_items.items);
            rebuilt_dynamic = true;
            self.dynamic_dirty_renderables.clearRetainingCapacity();
        }
        self.logSpatialPartitionSnapshotIfNeeded(rebuilt_static, rebuilt_dynamic);
    }

    fn promoteRenderableToDynamic(self: *World, id: EntityId) bool {
        const entity = self.getEntityConst(id) orelse return false;
        if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
            return false;
        }
        if (self.dynamic_renderables.contains(id)) {
            return false;
        }
        self.dynamic_renderables.put(id, .{}) catch {
            // OOM 时退回缓存全量同步路径，保证正确性优先。
            self.renderable_full_sync_required = true;
            return false;
        };
        return true;
    }

    fn reintegrateStableDynamicRenderables(self: *World) !bool {
        if (self.dynamic_renderables.count() == 0) {
            return false;
        }

        var reintegrate_ids = std.ArrayList(EntityId).empty;
        defer reintegrate_ids.deinit(self.allocator);

        var iter = self.dynamic_renderables.iterator();
        while (iter.next()) |entry| {
            const entity_id = entry.key_ptr.*;
            const entity = self.getEntityConst(entity_id) orelse {
                try reintegrate_ids.append(self.allocator, entity_id);
                continue;
            };
            if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
                try reintegrate_ids.append(self.allocator, entity_id);
                continue;
            }

            if (entry.value_ptr.steady_query_count < dynamic_reintegration_query_threshold) {
                entry.value_ptr.steady_query_count += 1;
            }
            if (entry.value_ptr.steady_query_count >= dynamic_reintegration_query_threshold) {
                try reintegrate_ids.append(self.allocator, entity_id);
            }
        }

        if (reintegrate_ids.items.len == 0) {
            return false;
        }

        for (reintegrate_ids.items) |entity_id| {
            _ = self.dynamic_renderables.remove(entity_id);
            _ = self.dynamic_dirty_renderables.remove(entity_id);
            self.queueRenderableSync(entity_id);
        }
        return true;
    }

    fn refitDirtyDynamicRenderables(self: *World) !void {
        if (self.dynamic_dirty_renderables.count() == 0 or self.dynamic_renderable_spatial_index.dirty) {
            return;
        }

        var iter = self.dynamic_dirty_renderables.keyIterator();
        while (iter.next()) |entity_id_ptr| {
            const entity_id = entity_id_ptr.*;
            if (!self.dynamic_renderables.contains(entity_id)) {
                continue;
            }
            const bounds = self.worldBoundsConst(entity_id) orelse {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            };
            if (!bounds.isValid()) {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            }
            if (!self.dynamic_renderable_spatial_index.updateItemBounds(entity_id, bounds)) {
                self.dynamic_renderable_spatial_index.markDirty();
                break;
            }
        }

        if (!self.dynamic_renderable_spatial_index.dirty) {
            self.dynamic_dirty_renderables.clearRetainingCapacity();
        }
    }

    fn syncRenderableSpatialItems(self: *World) !void {
        if (self.renderable_full_sync_required) {
            try self.rebuildRenderableItemCachesFromWorld();
            self.renderable_full_sync_required = false;
            self.renderable_spatial_index.markDirty();
            self.dynamic_renderable_spatial_index.markDirty();
            self.renderable_sync_candidates.clearRetainingCapacity();
            return;
        }

        if (self.renderable_sync_candidates.count() == 0) {
            return;
        }

        var iter = self.renderable_sync_candidates.keyIterator();
        while (iter.next()) |entity_id_ptr| {
            try self.syncRenderableSpatialItem(entity_id_ptr.*);
        }
        self.renderable_sync_candidates.clearRetainingCapacity();
    }

    fn syncRenderableSpatialItem(self: *World, entity_id: EntityId) !void {
        const entity = self.getEntityConst(entity_id);
        const is_renderable = entity != null and (entity.?.mesh != null or entity.?.skinned_mesh != null or entity.?.vfx != null);
        const desired_bounds = if (is_renderable) self.worldBoundsConst(entity_id) else null;
        const desired_partition: enum { none, static, dynamic } = blk: {
            if (desired_bounds == null or !desired_bounds.?.isValid()) {
                break :blk .none;
            }
            break :blk if (self.dynamic_renderables.contains(entity_id)) .dynamic else .static;
        };

        switch (desired_partition) {
            .none => {
                self.removeBoundsItemFromPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    entity_id,
                );
                self.removeBoundsItemFromPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    entity_id,
                );
                _ = self.dynamic_dirty_renderables.remove(entity_id);
            },
            .static => {
                self.removeBoundsItemFromPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    entity_id,
                );
                _ = self.dynamic_dirty_renderables.remove(entity_id);
                try self.syncBoundsItemIntoPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    .{
                        .id = entity_id,
                        .bounds = desired_bounds.?,
                    },
                );
            },
            .dynamic => {
                self.removeBoundsItemFromPartition(
                    &self.static_renderable_items,
                    &self.static_renderable_item_indices,
                    &self.renderable_spatial_index,
                    entity_id,
                );
                try self.syncBoundsItemIntoPartition(
                    &self.dynamic_renderable_items,
                    &self.dynamic_renderable_item_indices,
                    &self.dynamic_renderable_spatial_index,
                    .{
                        .id = entity_id,
                        .bounds = desired_bounds.?,
                    },
                );
            },
        }
    }

    fn rebuildRenderableItemCachesFromWorld(self: *World) !void {
        self.static_renderable_items.clearRetainingCapacity();
        self.dynamic_renderable_items.clearRetainingCapacity();
        self.static_renderable_item_indices.clearRetainingCapacity();
        self.dynamic_renderable_item_indices.clearRetainingCapacity();

        for (self.entities.items) |entity| {
            if (entity.mesh == null and entity.skinned_mesh == null and entity.vfx == null) {
                continue;
            }
            const bounds = self.worldBoundsConst(entity.id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            const item = spatial_index_mod.BoundsItem{
                .id = entity.id,
                .bounds = bounds,
            };
            if (self.dynamic_renderables.contains(entity.id)) {
                try appendBoundsItem(&self.dynamic_renderable_items, &self.dynamic_renderable_item_indices, self.allocator, item);
            } else {
                try appendBoundsItem(&self.static_renderable_items, &self.static_renderable_item_indices, self.allocator, item);
            }
        }
    }

    fn syncBoundsItemIntoPartition(
        self: *World,
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        bvh: *spatial_index_mod.StaticBoundsBvh,
        item: spatial_index_mod.BoundsItem,
    ) !void {
        const change = try upsertBoundsItem(items, indices, self.allocator, item);
        switch (change) {
            .unchanged => {},
            .inserted => {
                if (!bvh.dirty and !bvh.insertItem(item)) {
                    bvh.markDirty();
                }
            },
            .updated => {
                if (!bvh.dirty and !bvh.updateItemBounds(item.id, item.bounds)) {
                    bvh.markDirty();
                }
            },
        }
    }

    fn removeBoundsItemFromPartition(
        self: *World,
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        bvh: *spatial_index_mod.StaticBoundsBvh,
        item_id: EntityId,
    ) void {
        _ = self;
        if (!removeBoundsItem(items, indices, item_id)) {
            return;
        }
        if (!bvh.dirty and !bvh.removeItem(item_id)) {
            bvh.markDirty();
        }
    }

    fn queueRenderableSync(self: *World, entity_id: EntityId) void {
        self.renderable_sync_candidates.put(entity_id, {}) catch {
            self.renderable_full_sync_required = true;
        };
    }

    fn logSpatialPartitionSnapshotIfNeeded(self: *World, rebuilt_static: bool, rebuilt_dynamic: bool) void {
        if (!rebuilt_static and !rebuilt_dynamic) {
            return;
        }

        const snapshot = SpatialPartitionSnapshot{
            .static_items = self.static_renderable_items.items.len,
            .dynamic_items = self.dynamic_renderable_items.items.len,
        };
        if (g_logged_spatial_partition_snapshot == null or
            g_logged_spatial_partition_snapshot.?.static_items != snapshot.static_items or
            g_logged_spatial_partition_snapshot.?.dynamic_items != snapshot.dynamic_items or
            rebuilt_static or
            rebuilt_dynamic)
        {
            spatial_log.info(
                "renderable spatial partitions synced static_items={} dynamic_items={} rebuilt_static={} rebuilt_dynamic={}",
                .{ snapshot.static_items, snapshot.dynamic_items, rebuilt_static, rebuilt_dynamic },
            );
            g_logged_spatial_partition_snapshot = snapshot;
        }
    }

    fn hasDirtyEntities(self: *const World) bool {
        for (self.entities.items) |entity| {
            if (entity.dirty) {
                return true;
            }
        }
        return false;
    }

    fn appendBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        allocator: std.mem.Allocator,
        item: spatial_index_mod.BoundsItem,
    ) !void {
        const next_index = items.items.len;
        try items.append(allocator, item);
        errdefer _ = items.pop();
        try indices.put(item.id, next_index);
    }

    fn appendRenderableRayCandidates(
        self: *World,
        allocator: std.mem.Allocator,
        candidates: *std.ArrayList(RenderableRayCandidate),
        source: []const spatial_index_mod.RayCandidate,
    ) !void {
        try candidates.ensureUnusedCapacity(allocator, source.len);
        for (source) |candidate| {
            const bounds = self.worldBoundsConst(candidate.id) orelse continue;
            if (!bounds.isValid()) {
                continue;
            }
            candidates.appendAssumeCapacity(.{
                .id = candidate.id,
                .bounds = bounds,
                .enter_distance = candidate.enter_distance,
            });
        }
    }

    const BoundsItemChange = enum {
        unchanged,
        updated,
        inserted,
    };

    fn upsertBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        allocator: std.mem.Allocator,
        item: spatial_index_mod.BoundsItem,
    ) !BoundsItemChange {
        if (indices.get(item.id)) |item_index| {
            if (std.meta.eql(items.items[item_index].bounds, item.bounds)) {
                return .unchanged;
            }
            items.items[item_index] = item;
            return .updated;
        }

        try appendBoundsItem(items, indices, allocator, item);
        return .inserted;
    }

    fn removeBoundsItem(
        items: *std.ArrayList(spatial_index_mod.BoundsItem),
        indices: *std.AutoHashMap(EntityId, usize),
        item_id: EntityId,
    ) bool {
        const item_index = indices.get(item_id) orelse return false;
        const moved_item = items.items[items.items.len - 1];
        _ = items.swapRemove(item_index);
        _ = indices.remove(item_id);
        if (item_index < items.items.len) {
            indices.put(moved_item.id, item_index) catch |err| {
                std.log.err("failed to update spatial index for entity {d}: {s}", .{ moved_item.id, @errorName(err) });
            };
        }
        return true;
    }

    fn lessThanRenderableRayCandidateDistance(_: void, lhs: RenderableRayCandidate, rhs: RenderableRayCandidate) bool {
        return lhs.enter_distance < rhs.enter_distance;
    }

    fn nextAvailableDerivedName(self: *const World, base_name: []const u8, suffix: []const u8) ![]u8 {
        var candidate = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base_name, suffix });
        if (!self.entityNameExists(candidate)) {
            return candidate;
        }
        self.allocator.free(candidate);

        var index: usize = 2;
        while (true) : (index += 1) {
            candidate = try std.fmt.allocPrint(self.allocator, "{s}{s} {d}", .{ base_name, suffix, index });
            if (!self.entityNameExists(candidate)) {
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }

    fn entityNameExists(self: *const World, candidate: []const u8) bool {
        for (self.entities.items) |entity| {
            if (std.mem.eql(u8, entity.name, candidate)) {
                return true;
            }
        }
        return false;
    }

    fn releaseVfxRuntime(self: *World, destroy_particles: bool) void {
        while (self.vfx_runtime_emitters.items.len > 0) {
            self.clearVfxEmitterAtIndex(self.vfx_runtime_emitters.items.len - 1, destroy_particles);
        }
        self.vfx_runtime_emitters.deinit(self.allocator);
        self.vfx_runtime_emitters = .empty;
    }

    fn clearVfxEmitterAtIndex(self: *World, index: usize, destroy_particles: bool) void {
        var emitter = self.vfx_runtime_emitters.orderedRemove(index);
        if (destroy_particles) {
            const particle_ids = emitter.particles.items(.entity_id);
            for (particle_ids) |particle_id| {
                _ = self.destroyEntity(particle_id);
            }
        }
        emitter.deinit(self.allocator);
    }

    fn removeVfxEmittersForEntities(self: *World, entity_ids: []const EntityId) void {
        var index: usize = 0;
        while (index < self.vfx_runtime_emitters.items.len) {
            if (sliceContainsEntityId(entity_ids, self.vfx_runtime_emitters.items[index].entity_id)) {
                self.clearVfxEmitterAtIndex(index, false);
                continue;
            }
            index += 1;
        }
    }

    fn removeAnimatorBinding(self: *World, animator_entity_id: EntityId) void {
        for (self.animator_bindings.items, 0..) |binding, index| {
            if (binding.animator_entity_id != animator_entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            self.allocator.free(binding.base_local_transforms);
            _ = self.animator_bindings.swapRemove(index);
            return;
        }
    }

    fn findAnimatorGraphBinding(self: *World, animator_entity_id: EntityId) ?*AnimatorGraphBinding {
        for (self.animator_graph_bindings.items) |*binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding;
            }
        }
        return null;
    }

    fn findAnimatorGraphBindingConst(self: *const World, animator_entity_id: EntityId) ?*const AnimatorGraphBinding {
        for (self.animator_graph_bindings.items) |*binding| {
            if (binding.animator_entity_id == animator_entity_id) {
                return binding;
            }
        }
        return null;
    }

    fn removeAnimatorGraphBinding(self: *World, animator_entity_id: EntityId) bool {
        for (self.animator_graph_bindings.items, 0..) |*binding, index| {
            if (binding.animator_entity_id != animator_entity_id) {
                continue;
            }
            binding.deinit(self.allocator);
            _ = self.animator_graph_bindings.swapRemove(index);
            return true;
        }
        return false;
    }

    fn copyAnimatorGraphInstanceState(
        target: *animation_graph_mod.AnimationGraphInstance,
        source: *const animation_graph_mod.AnimationGraphInstance,
    ) void {
        target.current_state = source.current_state;
        target.next_state = source.next_state;
        target.transition_time = source.transition_time;
        target.transition_duration = source.transition_duration;
        target.state_time = source.state_time;

        const parameter_count = @min(target.parameters.items.len, source.parameters.items.len);
        for (0..parameter_count) |index| {
            target.parameters.items[index] = source.parameters.items[index];
        }
    }

    fn removeSkinnedMeshBinding(self: *World, entity_id: EntityId) void {
        for (self.skinned_mesh_bindings.items, 0..) |binding, index| {
            if (binding.entity_id != entity_id) {
                continue;
            }
            self.allocator.free(binding.target_entities);
            _ = self.skinned_mesh_bindings.swapRemove(index);
            return;
        }
    }

    pub fn createPrefab(self: *World, root_entity_id: EntityId, prefab_id: []const u8) !void {
        var prefab_value = try prefab_mod.createPrefabFromEntities(
            self.allocator,
            self,
            root_entity_id,
            prefab_id,
        );
        errdefer prefab_value.deinit();

        const prefab = try self.allocator.create(prefab_mod.PrefabResource);
        errdefer self.allocator.destroy(prefab);
        prefab.* = prefab_value;
        try self.prefab_library.registerPrefab(prefab);
    }

    pub fn loadPrefab(self: *World, path: []const u8) !prefab_mod.PrefabId {
        var prefab_value = try prefab_mod.loadPrefabFromPath(self.allocator, path);
        errdefer prefab_value.deinit();

        const prefab = try self.allocator.create(prefab_mod.PrefabResource);
        errdefer self.allocator.destroy(prefab);
        prefab.* = prefab_value;

        const prefab_id = try self.allocator.dupe(u8, prefab.id);
        errdefer self.allocator.free(prefab_id);
        try self.prefab_library.registerPrefab(prefab);
        return prefab_id;
    }

    pub fn savePrefab(self: *World, id: []const u8, path: []const u8) !void {
        const prefab = self.prefab_library.getPrefab(id) orelse return error.PrefabNotFound;
        try prefab_mod.savePrefabToPath(self.allocator, prefab, path);
        if (prefab.source_path) |existing| {
            self.allocator.free(existing);
        }
        prefab.source_path = try self.allocator.dupe(u8, path);
    }

    pub fn instantiatePrefab(self: *World, prefab_id: []const u8, options: prefab_mod.InstantiateOptions) !EntityId {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;
        return try prefab_mod.instantiatePrefab(self.allocator, self, prefab, options);
    }

    pub fn getPrefab(self: *const World, id: []const u8) ?*prefab_mod.PrefabResource {
        return self.prefab_library.getPrefab(id);
    }

    pub fn removePrefab(self: *World, id: []const u8) !void {
        if (!self.prefab_library.removePrefab(id)) {
            return error.PrefabNotFound;
        }
    }

    pub fn detectPrefabDiff(self: *World, old_prefab_id: []const u8, new_prefab_id: []const u8) !prefab_mod.PrefabDiff {
        const old_prefab = self.prefab_library.getPrefab(old_prefab_id) orelse
            return error.PrefabNotFound;
        const new_prefab = self.prefab_library.getPrefab(new_prefab_id) orelse
            return error.PrefabNotFound;
        return try prefab_mod.detectDiffs(self.allocator, old_prefab, new_prefab);
    }

    pub fn updatePrefabInstance(self: *World, root_entity_id: EntityId, prefab_id: []const u8) !void {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;
        var diff = try detectEntityTreeDiff(self, root_entity_id, prefab);
        defer diff.deinit();
        try prefab_mod.updatePrefabInstance(self, root_entity_id, &diff, prefab);
    }

    pub fn updateAllPrefabInstances(self: *World, prefab_id: []const u8) !usize {
        const prefab = self.prefab_library.getPrefab(prefab_id) orelse
            return error.PrefabNotFound;

        var updated_count: usize = 0;
        for (self.entities.items) |*entity| {
            if (!isPrefabRootEntity(entity)) {
                continue;
            }
            if (entity.prefab_instance_override) |*override| {
                if (!std.mem.eql(u8, override.prefab_id, prefab_id)) {
                    continue;
                }

                var diff = try detectEntityTreeDiff(self, entity.id, prefab);
                defer diff.deinit();

                try prefab_mod.updatePrefabInstance(self, entity.id, &diff, prefab);
                override.prefab_version = prefab.version;
                updated_count += 1;
            }
        }

        return updated_count;
    }

    pub fn applyPrefabUpdate(self: *World, old_prefab_id: []const u8, new_prefab_id: []const u8) !void {
        var diff = try self.detectPrefabDiff(old_prefab_id, new_prefab_id);
        defer diff.deinit();

        const new_prefab = self.getPrefab(new_prefab_id) orelse
            return error.PrefabNotFound;

        for (self.entities.items) |*entity| {
            if (!isPrefabRootEntity(entity)) {
                continue;
            }
            if (entity.prefab_instance_override) |*override| {
                if (!std.mem.eql(u8, override.prefab_id, old_prefab_id)) {
                    continue;
                }

                try prefab_mod.updatePrefabInstance(self, entity.id, &diff, new_prefab);
                self.allocator.free(override.prefab_id);
                override.prefab_id = try self.allocator.dupe(u8, new_prefab_id);
                override.prefab_version = new_prefab.version;
            }
        }
    }

    pub fn revertPrefabOverride(self: *World, entity_id: EntityId) !void {
        const entity = self.getEntity(entity_id) orelse return error.EntityNotFound;
        var changed = false;
        if (entity.prefab_instance_override) |*override| {
            if (override.override_mask.local_transform) {
                if (override.local_transform_override) |transform| {
                    entity.local_transform = transform;
                    changed = true;
                }
            }
            if (override.override_mask.visible) {
                if (override.visible_override) |visible| {
                    entity.visible = visible;
                    changed = true;
                }
            }
            override.deinit(self.allocator);
            entity.prefab_instance_override = null;
            changed = true;
        }
        if (changed) {
            self.bumpSceneRevision();
        }
    }
};

fn sliceContainsEntityId(entity_ids: []const EntityId, entity_id: EntityId) bool {
    for (entity_ids) |candidate| {
        if (candidate == entity_id) {
            return true;
        }
    }
    return false;
}

fn indexOfEntityId(entity_ids: []const EntityId, entity_id: EntityId) ?usize {
    for (entity_ids, 0..) |candidate, index| {
        if (candidate == entity_id) {
            return index;
        }
    }
    return null;
}

fn composeTransform(parent: components.Transform, local: components.Transform) components.Transform {
    const quat = @import("../math/quat.zig");
    return .{
        .translation = vec3.add(
            parent.translation,
            quat.rotateVec3(parent.rotation, vec3.mul(parent.scale, local.translation)),
        ),
        .rotation = quat.mul(parent.rotation, local.rotation),
        .scale = vec3.mul(parent.scale, local.scale),
    };
}

fn relativeTransform(parent: components.Transform, world: components.Transform) components.Transform {
    const quat = @import("../math/quat.zig");
    const delta = vec3.sub(world.translation, parent.translation);
    const local_translation = vec3.divSafe(
        quat.rotateVec3(quat.inverse(parent.rotation), delta),
        parent.scale,
        compose_epsilon,
    );

    return .{
        .translation = local_translation,
        .rotation = quat.mul(quat.inverse(parent.rotation), world.rotation),
        .scale = vec3.divSafe(world.scale, parent.scale, compose_epsilon),
    };
}

fn rotateVec3Euler(rotation: components.Vec3, vector: components.Vec3) components.Vec3 {
    return rotateZ(rotation[2], rotateY(rotation[1], rotateX(rotation[0], vector)));
}

fn inverseRotateVec3Euler(rotation: components.Vec3, vector: components.Vec3) components.Vec3 {
    return rotateX(-rotation[0], rotateY(-rotation[1], rotateZ(-rotation[2], vector)));
}

fn rotateX(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0],
        vector[1] * c - vector[2] * s,
        vector[1] * s + vector[2] * c,
    };
}

fn rotateY(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c + vector[2] * s,
        vector[1],
        -vector[0] * s + vector[2] * c,
    };
}

fn rotateZ(radians: f32, vector: components.Vec3) components.Vec3 {
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    return .{
        vector[0] * c - vector[1] * s,
        vector[0] * s + vector[1] * c,
        vector[2],
    };
}

test "bootstrap creates a minimal 3D scene" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();

    const result = world.summary();
    try std.testing.expectEqual(@as(usize, 4), result.entity_count);
    try std.testing.expectEqual(@as(usize, 1), result.camera_count);
    try std.testing.expectEqual(@as(usize, 2), result.mesh_count);
    try std.testing.expectEqual(@as(usize, 1), result.light_count);
    try std.testing.expect(world.findEntityByName("Hero") != null);
}

test "glTF static import creates world entities, textures, normals, tangents, and multi primitive materials" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const report = try world.importGltfStaticModel(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ -2.0, 0.0, 0.0 },
        },
    );

    // 1 个 node 实体 + 1 个额外的 primitive 实体 = 2 个实体
    // (mesh 有 2 个 primitives，第一个使用 node 实体，第二个创建子实体)
    try std.testing.expectEqual(@as(usize, 2), report.entity_count);
    try std.testing.expectEqual(@as(usize, 2), report.mesh_count);
    try std.testing.expectEqual(@as(usize, 2), report.material_count);
    try std.testing.expectEqual(@as(usize, 1), report.texture_count);
    // 第一个 primitive 使用 node 实体，名称为 "guava_showcase_GuavaShowcase"
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase") != null);
    // 第二个 primitive 创建子实体，名称为 "guava_showcase_GuavaShowcase_1"
    try std.testing.expect(world.findEntityByName("guava_showcase_GuavaShowcase_1") != null);

    const imported = world.findEntityByName("guava_showcase_GuavaShowcase").?;
    const mesh = world.resources.mesh(imported.mesh.?.handle.?).?;
    const material = world.resources.material(imported.material.?.handle.?).?;

    try std.testing.expectEqual(@as(usize, 7), mesh.vertices.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].normal[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.vertices[0].tangent[0], 0.0001);
    try std.testing.expect(material.base_color_texture != null);
}

test "glTF instance import creates a movable root entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const report = try world.importGltfStaticModelInstance(
        "assets/models/guava_showcase/guava_showcase.gltf",
        .{
            .translation = .{ 3.0, 2.0, 1.0 },
        },
    );

    try std.testing.expect(report.root_entity != null);
    const root = world.getEntityConst(report.root_entity.?).?;
    try std.testing.expectEqualStrings("guava_showcase Instance", root.name);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), root.local_transform.translation[0], 0.0001);

    // 根实例实体 + node 实体 + 额外的 primitive 实体 = 3 个实体
    // 第一个 primitive 使用 node 实体，名称为 "guava_showcase_GuavaShowcase"
    const imported = world.findEntityByName("guava_showcase_GuavaShowcase").?;
    // node 实体的父实体是根实例
    try std.testing.expectEqual(report.root_entity.?, imported.parent.?);
    const imported_world = world.worldTransform(imported.id).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), imported_world.translation[0], 0.0001);
    try std.testing.expectEqual(@as(usize, 3), report.entity_count);
}

test "world supports editor duplicate and destroy operations" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    try world.bootstrap3D();
    const source = world.findEntityByName("Hero").?.id;
    const duplicate = try world.duplicateEntity(source);
    try std.testing.expect(duplicate != source);
    try std.testing.expect(world.findEntityByName("Hero Copy") != null);
    try std.testing.expect(world.destroyEntity(source));
    try std.testing.expect(world.findEntityByName("Hero") == null);
}

test "createVfxEntity adds a selectable VFX anchor entity" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createVfxEntity(.fountain, .{
        .translation = .{ 1.0, 2.0, 3.0 },
    });
    const entity = world.getEntityConst(entity_id).?;
    try std.testing.expect(entity.vfx != null);
    try std.testing.expectEqual(components.VfxKind.fountain, entity.vfx.?.kind);
    try std.testing.expect(entity.mesh != null);
    try std.testing.expect(entity.material != null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), entity.local_transform.translation[0], 0.0001);
}

test "world hierarchy composes transforms and preserves world space on reparent" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const parent_a = try world.createEntity(.{
        .name = "ParentA",
        .local_transform = .{
            .translation = .{ 2.0, 0.0, 0.0 },
        },
    });
    const parent_b = try world.createEntity(.{
        .name = "ParentB",
        .local_transform = .{
            .translation = .{ 10.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "Child",
        .parent = parent_a,
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });

    const before = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), before.translation[0], 0.0001);

    try std.testing.expect(try world.setParent(child, parent_b));
    const after = world.worldTransform(child).?;
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), after.translation[0], 0.0001);
    const local = world.getEntityConst(child).?.local_transform;
    try std.testing.expectApproxEqAbs(@as(f32, -7.0), local.translation[0], 0.0001);
}

test "hierarchy propagation keeps descendant translation exact under non-uniform parent scale" {
    const mat4 = @import("../math/mat4.zig");
    const quat = @import("../math/quat.zig");

    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const parent = try world.createEntity(.{
        .name = "ScaledParent",
        .local_transform = .{
            .scale = .{ 2.0, 1.0, 1.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "RotatedChild",
        .parent = parent,
        .local_transform = .{
            .rotation = quat.fromEuler(.{ 0.0, 0.0, std.math.pi * 0.25 }),
        },
    });
    const grandchild = try world.createEntity(.{
        .name = "Grandchild",
        .parent = child,
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });

    const grandchild_world = world.worldTransform(grandchild).?;
    const expected_world = mat4.mul(
        mat4.transformMatrix(world.getEntityConst(parent).?.local_transform),
        mat4.mul(
            mat4.transformMatrix(world.getEntityConst(child).?.local_transform),
            mat4.transformMatrix(world.getEntityConst(grandchild).?.local_transform),
        ),
    );

    try std.testing.expectApproxEqAbs(expected_world[12], grandchild_world.translation[0], 0.0001);
    try std.testing.expectApproxEqAbs(expected_world[13], grandchild_world.translation[1], 0.0001);
    try std.testing.expectApproxEqAbs(expected_world[14], grandchild_world.translation[2], 0.0001);
}

test "duplicateEntity copies subtrees and destroyEntity removes descendants" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const root = try world.createEntity(.{
        .name = "RigRoot",
        .local_transform = .{
            .translation = .{ 1.0, 0.0, 0.0 },
        },
    });
    const child = try world.createEntity(.{
        .name = "RigChild",
        .parent = root,
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 0.0 },
        },
    });

    const duplicate_root = try world.duplicateEntity(root);
    try std.testing.expect(duplicate_root != root);
    try std.testing.expect(world.findEntityByName("RigRoot Copy") != null);
    try std.testing.expect(world.findEntityByName("RigChild Copy") != null);
    const duplicate_child = world.findEntityByName("RigChild Copy").?;
    try std.testing.expectEqual(duplicate_root, duplicate_child.parent.?);

    try std.testing.expect(world.destroyEntity(root));
    try std.testing.expect(world.findEntityByName("RigRoot") == null);
    try std.testing.expect(world.findEntityByName("RigChild") == null);
    try std.testing.expect(world.findEntityByName("RigRoot Copy") != null);
    try std.testing.expect(world.findEntityByName("RigChild Copy") != null);
    _ = child;
}

test "animator graph bindings duplicate with animator entities and are removed on destroy" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const animator_id = try world.createEntity(.{
        .name = "Rig",
        .animator = .{},
    });
    const target_id = try world.createEntity(.{
        .name = "RigBone",
        .parent = animator_id,
    });
    try world.bindAnimatorTargets(animator_id, &.{target_id});

    var graph = try animation_graph_mod.AnimationGraph.init(std.testing.allocator, "RigGraph");
    defer graph.deinit();

    _ = try graph.addState("Idle", null);
    graph.default_state = 0;
    try graph.addParameter("Speed", .float, .{ .float = 0.0 });

    try world.bindAnimatorGraph(animator_id, &graph);
    try world.setAnimatorGraphParameterByName(animator_id, "Speed", .{ .float = 1.0 });

    const duplicate_id = try world.duplicateEntity(animator_id);
    try std.testing.expect(world.animatorGraph(duplicate_id) != null);
    try std.testing.expectApproxEqAbs(
        @as(f32, 1.0),
        world.animatorGraphInstanceConst(duplicate_id).?.parameters.items[0].float,
        0.0001,
    );

    try std.testing.expect(world.destroyEntity(animator_id));
    try std.testing.expect(world.animatorGraph(animator_id) == null);
    try std.testing.expect(world.animatorGraph(duplicate_id) != null);
}

test "folder entities preserve folder state through duplication" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const folder = try world.createFolderEntity(.{
        .translation = .{ 2.0, 0.0, 0.0 },
    });
    try std.testing.expect(world.getEntityConst(folder).?.is_folder);
    try std.testing.expect(!world.getEntityConst(folder).?.editor_only);

    const duplicate = try world.duplicateEntity(folder);
    try std.testing.expect(world.getEntityConst(duplicate).?.is_folder);
}

test "renderable spatial index moves dirty meshes into dynamic partition" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const a = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ -2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });
    const b = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });

    const initial = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderables.count());

    try std.testing.expect(world.setEntityLocalTransform(a, .{
        .translation = .{ -1.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));

    const after_first_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_first_move);
    try std.testing.expectEqual(@as(usize, 1), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());

    try std.testing.expect(world.setEntityLocalTransform(a, .{
        .translation = .{ 0.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));

    const after_second_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_second_move);
    try std.testing.expectEqual(@as(usize, 1), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());
    try std.testing.expect(world.dynamic_renderables.contains(a));
    try std.testing.expect(!world.dynamic_renderables.contains(b));

    var reintegration_step: u8 = 0;
    while (reintegration_step < dynamic_reintegration_query_threshold) : (reintegration_step += 1) {
        const steady_query = try world.queryRenderableRayCandidates(
            std.testing.allocator,
            .{ -5.0, 0.0, 0.0 },
            .{ 1.0, 0.0, 0.0 },
            16.0,
        );
        defer std.testing.allocator.free(steady_query);
    }

    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderables.count());
}

test "non-renderable hierarchy updates do not dirty renderable BVHs" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ -2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });
    _ = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 2.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });
    const empty = try world.createEmptyEntity(.{
        .translation = .{ 0.0, 0.0, 0.0 },
    });

    const initial_query = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial_query);

    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expect(!world.renderable_spatial_index.dirty);
    try std.testing.expect(!world.dynamic_renderable_spatial_index.dirty);

    try std.testing.expect(world.setEntityLocalTransform(empty, .{
        .translation = .{ 5.0, 1.0, 0.0 },
    }));
    world.updateHierarchy();

    try std.testing.expectEqual(@as(usize, 2), world.renderable_spatial_index.itemCount());
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expect(!world.renderable_spatial_index.dirty);
    try std.testing.expect(!world.dynamic_renderable_spatial_index.dirty);
}

test "dynamic renderable movement refits dynamic BVH without growing dynamic partition" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createPrimitiveEntity(.plane, .{
        .translation = .{ 0.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    });

    const initial_query = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial_query);

    try std.testing.expect(world.setEntityLocalTransform(entity_id, .{
        .translation = .{ 4.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));
    const after_first_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_first_move);
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    const first_dynamic_nodes = world.dynamic_renderable_spatial_index.nodeCount();

    try std.testing.expect(world.setEntityLocalTransform(entity_id, .{
        .translation = .{ 6.0, 0.0, 0.0 },
        .rotation = @import("../math/quat.zig").fromEuler(.{ -std.math.pi * 0.5, 0.0, 0.0 }),
    }));
    const after_second_move = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(after_second_move);
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderable_spatial_index.itemCount());
    try std.testing.expectEqual(first_dynamic_nodes, world.dynamic_renderable_spatial_index.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), world.dynamic_renderables.count());
}

/// 检测实体树与 Prefab 的差异
fn detectEntityTreeDiff(
    self: *World,
    root_entity_id: EntityId,
    new_prefab: *const prefab_mod.PrefabResource,
) !prefab_mod.PrefabDiff {
    var diff = prefab_mod.PrefabDiff{
        .allocator = self.allocator,
        .added_entities = .empty,
        .removed_entities = .empty,
        .modified_entities = .empty,
    };
    errdefer diff.deinit();

    // 收集当前实例中的所有实体（按 prefab_entity_id）
    var instance_entity_map = std.AutoHashMap(u32, EntityId).init(self.allocator);
    defer instance_entity_map.deinit();

    try collectPrefabEntitiesRecursive(self, root_entity_id, &instance_entity_map);

    // 收集 Prefab 中的所有实体 ID
    var prefab_entity_set = std.AutoHashMap(u32, void).init(self.allocator);
    defer prefab_entity_set.deinit();

    for (new_prefab.entities) |entity| {
        try prefab_entity_set.put(entity.prefab_entity_id, {});
    }

    // 检测新增的实体（在 Prefab 中但不在实例中）
    for (new_prefab.entities) |prefab_entity| {
        if (!instance_entity_map.contains(prefab_entity.prefab_entity_id)) {
            try diff.added_entities.append(self.allocator, prefab_entity.prefab_entity_id);
        }
    }

    // 检测删除的实体（在实例中但不在 Prefab 中）
    var instance_it = instance_entity_map.keyIterator();
    while (instance_it.next()) |prefab_entity_id| {
        if (!prefab_entity_set.contains(prefab_entity_id.*)) {
            try diff.removed_entities.append(self.allocator, prefab_entity_id.*);
        }
    }

    // 检测修改的实体
    var it = instance_entity_map.iterator();
    while (it.next()) |entry| {
        const prefab_entity_id = entry.key_ptr.*;
        const entity_id = entry.value_ptr.*;

        // 查找对应的 Prefab 实体
        const prefab_entity = findPrefabEntity(self, new_prefab, prefab_entity_id) orelse continue;

        if (self.getEntity(entity_id)) |entity| {
            // 检测差异
            const entity_diff = detectSingleEntityDiff(self, entity, prefab_entity);
            if (entity_diff.has_changes) {
                try diff.modified_entities.append(self.allocator, entity_diff);
            }
        }
    }

    return diff;
}

/// 递归收集 Prefab 实例中的所有实体
fn collectPrefabEntitiesRecursive(
    self: *World,
    entity_id: EntityId,
    out_map: *std.AutoHashMap(u32, EntityId),
) !void {
    const entity = self.getEntity(entity_id) orelse return;

    // 记录实体（如果有 prefab_entity_id）
    if (entity.prefab_entity_id) |prefab_id| {
        try out_map.put(prefab_id, entity_id);
    }

    // 递归处理子实体
    for (entity.children.items) |child_id| {
        try collectPrefabEntitiesRecursive(self, child_id, out_map);
    }
}

/// 在 Prefab 中查找实体
fn findPrefabEntity(
    self: *World,
    prefab: *const prefab_mod.PrefabResource,
    prefab_entity_id: u32,
) ?*const prefab_mod.PrefabEntityData {
    _ = self;
    for (prefab.entities) |*entity| {
        if (entity.prefab_entity_id == prefab_entity_id) {
            return entity;
        }
    }
    return null;
}

/// 检测单个实体与 Prefab 实体的差异
fn detectSingleEntityDiff(
    self: *World,
    entity: *Entity,
    prefab_entity: *const prefab_mod.PrefabEntityData,
) prefab_mod.EntityDiff {
    _ = self;
    var diff = prefab_mod.EntityDiff{
        .prefab_entity_id = prefab_entity.prefab_entity_id,
        .has_changes = false,
        .transform_changed = false,
        .name_changed = false,
        .component_changes = .{},
    };

    // 检测名称变化
    if (!std.mem.eql(u8, entity.name, prefab_entity.name)) {
        diff.name_changed = true;
        diff.has_changes = true;
    }

    // 检测变换变化
    const et = &entity.local_transform;
    const pt = &prefab_entity.local_transform;
    if (!std.mem.eql(f32, et.translation[0..3], pt.translation[0..3]) or
        !std.mem.eql(f32, et.rotation[0..4], pt.rotation[0..4]) or
        !std.mem.eql(f32, et.scale[0..3], pt.scale[0..3]))
    {
        diff.transform_changed = true;
        diff.has_changes = true;
    }

    // 检测组件变化
    if (!equalOptionalComponents(entity.mesh, prefab_entity.mesh)) {
        diff.component_changes.mesh_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.material, prefab_entity.material)) {
        diff.component_changes.material_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.light, prefab_entity.light)) {
        diff.component_changes.light_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.camera, prefab_entity.camera)) {
        diff.component_changes.camera_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.vfx, prefab_entity.vfx)) {
        diff.component_changes.vfx_changed = true;
        diff.has_changes = true;
    }
    if (!equalOptionalComponents(entity.rigidbody, prefab_entity.rigidbody)) {
        diff.component_changes.rigidbody_changed = true;
        diff.has_changes = true;
    }

    return diff;
}

/// 比较两个可选组件是否相等
fn equalOptionalComponents(a: anytype, b: @TypeOf(a)) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.meta.eql(a.?, b.?);
}

test "renderable bounds frustum query reuses cached bounds for visible BVH candidates" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const near_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });
    _ = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 8.0, 0.0, 0.0 },
    });

    const query_frustum = frustum_mod.Frustum{
        .planes = .{
            .{ .normal = .{ 1.0, 0.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ -1.0, 0.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 1.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, -1.0, 0.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 0.0, 1.0 }, .distance = -2.5 },
            .{ .normal = .{ 0.0, 0.0, -1.0 }, .distance = -2.5 },
        },
    };

    const bounds_items = try world.queryRenderableBoundsInFrustum(std.testing.allocator, query_frustum);
    defer std.testing.allocator.free(bounds_items);

    try std.testing.expectEqual(@as(usize, 1), bounds_items.len);
    try std.testing.expectEqual(near_cube, bounds_items[0].id);
    try std.testing.expectEqualDeep(world.worldBoundsConst(near_cube).?, bounds_items[0].bounds);
}

test "renderable ray bounds query returns sorted cached bounds candidates" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const near_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });
    const far_cube = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 6.0, 0.0, 0.0 },
    });

    const candidates = try world.queryRenderableRayBounds(
        std.testing.allocator,
        .{ -4.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(candidates);

    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(near_cube, candidates[0].id);
    try std.testing.expectEqual(far_cube, candidates[1].id);
    try std.testing.expect(candidates[0].enter_distance <= candidates[1].enter_distance);
    try std.testing.expectEqualDeep(world.worldBoundsConst(near_cube).?, candidates[0].bounds);
    try std.testing.expectEqualDeep(world.worldBoundsConst(far_cube).?, candidates[1].bounds);
}

test "renderable partition caches update incrementally for create and destroy" {
    var world = World.init(std.testing.allocator, null);
    defer world.deinit();

    const first = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 0.0, 0.0, 0.0 },
    });

    const initial_query = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        16.0,
    );
    defer std.testing.allocator.free(initial_query);
    try std.testing.expectEqual(@as(usize, 1), world.static_renderable_items.items.len);
    try std.testing.expectEqual(@as(usize, 0), world.dynamic_renderable_items.items.len);
    try std.testing.expect(world.static_renderable_item_indices.contains(first));

    const second = try world.createPrimitiveEntity(.cube, .{
        .translation = .{ 6.0, 0.0, 0.0 },
    });

    const after_create = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(after_create);
    try std.testing.expectEqual(@as(usize, 2), world.static_renderable_items.items.len);
    try std.testing.expect(world.static_renderable_item_indices.contains(second));

    try std.testing.expect(world.destroyEntity(first));
    const after_destroy = try world.queryRenderableRayCandidates(
        std.testing.allocator,
        .{ -5.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        20.0,
    );
    defer std.testing.allocator.free(after_destroy);
    try std.testing.expectEqual(@as(usize, 1), world.static_renderable_items.items.len);
    try std.testing.expect(!world.static_renderable_item_indices.contains(first));
    try std.testing.expect(world.static_renderable_item_indices.contains(second));
    try std.testing.expectEqual(second, world.static_renderable_items.items[0].id);
}
