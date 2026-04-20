const std = @import("std");
const io_globals = @import("io_globals");
const components = @import("../scene/components.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const world_mod = @import("../scene/world.zig");
const types = @import("./types.zig");
const input_mod = @import("../core/input.zig");
const physics_mod = @import("../physics/system.zig");
const action_map_mod = @import("../core/input_action.zig");
const AABB = @import("../math/aabb.zig").AABB;

/// 实体类型别名
pub const EntityId = world_mod.EntityId;

pub const EditorSelectionApi = struct {
    context: *anyopaque,
    select_entity: *const fn (context: *anyopaque, entity_id: EntityId, additive: bool) void,
    clear_selection: *const fn (context: *anyopaque) void,
};

pub const SceneManagerApi = struct {
    context: *anyopaque,
    load_scene: *const fn (context: *anyopaque, path: []const u8) void,
    unload_scene: *const fn (context: *anyopaque) void,
    set_dont_destroy_on_load: *const fn (context: *anyopaque, entity_id: EntityId, enabled: bool) void,
    is_loading: *const fn (context: *anyopaque) bool,
};

/// 脚本执行上下文 - 脚本运行时可用的 API
pub const ScriptContext = struct {
    /// 关联的实体 ID
    entity: EntityId,
    /// 世界指针（用于查询）
    world: *world_mod.World,
    /// 脚本实例指针
    instance: *types.ScriptInstance,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 引擎级命令队列
    command_queue: ?*command_queue_mod.CommandQueue = null,
    /// 输入状态（可选）
    input: ?*const input_mod.InputState = null,
    /// 物理系统状态（用于物理查询）
    physics_state: ?*physics_mod.PhysicsState = null,
    /// 全局时间（秒）
    time: f32 = 0.0,
    /// DeltaTime（秒）
    delta_time: f32 = 0.0,
    /// 时间缩放
    time_scale: f32 = 1.0,
    /// 游戏运行时状态（GameStart/Playing/Paused/GameOver/Quit）
    game_state: u32 = 0,
    /// 可写回的 time_scale 指针（指向 Application.time_scale）
    time_scale_ptr: ?*f32 = null,
    /// 可写回的 game_state 指针（指向 Application.game_state 的 u32 表示）
    game_state_ptr: ?*u32 = null,
    /// 场景切换 API
    scene_manager_api: ?SceneManagerApi = null,
    /// 编辑器当前选择集（Editor Utility UI 使用）
    editor_selection: []const EntityId = &.{},
    /// 编辑器选择回调（Editor Utility UI 使用）
    editor_selection_api: ?EditorSelectionApi = null,
    /// 输入动作映射（GR-6；可选）
    action_map: ?*const action_map_mod.ActionMap = null,
    /// 全局黑板（所有脚本实例共享；由运行时持有）
    blackboard: ?*Blackboard = null,
    /// 持久化存储根路径（项目目录下 saves/ 子目录）
    save_root_path: ?[]const u8 = null,
    /// 运行时 UI Canvas（?*ui.Canvas 以 anyopaque 传递避免循环依赖）
    ui_canvas: ?*anyopaque = null,

    /// 获取实体的名称
    pub fn getName(self: *ScriptContext) []const u8 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].name;
        }
        return "";
    }

    /// 获取实体的 Transform
    pub fn getTransform(self: *ScriptContext) ?*components.Transform {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return &self.world.entities.items[idx].local_transform;
        }
        return null;
    }

    /// 获取实体的世界 Transform
    pub fn getWorldTransform(self: *ScriptContext) ?components.Transform {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].world_transform_cache;
        }
        return null;
    }

    /// 设置实体的位置
    pub fn setPosition(self: *ScriptContext, pos: components.Vec3) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.translation = pos;
            self.world.markDirty(self.entity);
            self.notifyPhysicsTransformChanged();
        }
    }

    /// 设置实体的旋转（四元数）
    pub fn setRotation(self: *ScriptContext, rot: components.Quat) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.rotation = rot;
            self.world.markDirty(self.entity);
            self.notifyPhysicsTransformChanged();
        }
    }

    /// 设置实体的缩放
    pub fn setScale(self: *ScriptContext, scale: components.Vec3) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].local_transform.scale = scale;
            self.world.markDirty(self.entity);
            self.notifyPhysicsTransformChanged();
        }
    }

    /// 通知物理系统当前实体的 Transform 已被脚本修改，
    /// 使 Jolt 同步新位置/旋转/缩放（而非下一帧覆盖回旧值）。
    fn notifyPhysicsTransformChanged(self: *ScriptContext) void {
        if (self.physics_state) |ps| {
            ps.enqueuePhysicsEvent(.{ .transform_changed = self.entity });
        }
    }

    /// 获取实体的位置
    pub fn getPosition(self: *ScriptContext) ?components.Vec3 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.translation;
        }
        return null;
    }

    /// 获取任意实体的位置
    pub fn getPositionOfEntity(self: *ScriptContext, entity_id: u64) ?components.Vec3 {
        if (self.world.id_to_index.get(entity_id)) |idx| {
            return self.world.entities.items[idx].local_transform.translation;
        }
        return null;
    }

    /// 获取实体的旋转
    pub fn getRotation(self: *ScriptContext) ?components.Quat {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.rotation;
        }
        return null;
    }

    /// 获取实体的缩放
    pub fn getScale(self: *ScriptContext) ?components.Vec3 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].local_transform.scale;
        }
        return null;
    }

    /// 根据名称查找实体
    pub fn findEntityByName(self: *ScriptContext, name: []const u8) ?EntityId {
        for (self.world.entities.items) |entity| {
            if (std.mem.eql(u8, entity.name, name)) {
                return entity.id;
            }
        }
        return null;
    }

    /// 获取子实体数量
    pub fn getChildCount(self: *ScriptContext) usize {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].children.items.len;
        }
        return 0;
    }

    /// 获取子实体
    pub fn getChild(self: *ScriptContext, index: usize) ?EntityId {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            const children = &self.world.entities.items[idx].children;
            if (index < children.items.len) {
                return children.items[index];
            }
        }
        return null;
    }

    /// 获取父实体
    pub fn getParent(self: *ScriptContext) ?EntityId {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].parent;
        }
        return null;
    }

    /// 检查实体是否有指定组件
    pub fn hasComponent(self: *ScriptContext, comptime T: type) bool {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            const entity = &self.world.entities.items[idx];
            return entity.hasComponent(T);
        }
        return false;
    }

    /// 获取组件指针
    pub fn getComponent(self: *ScriptContext, comptime T: type) ?*T {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            return self.world.entities.items[idx].getComponent(T);
        }
        return null;
    }

    /// 创建子实体
    pub fn createChild(self: *ScriptContext, name: []const u8) !EntityId {
        const desc = world_mod.EntityDesc{
            .name = name,
            .parent = self.entity,
        };
        return try self.world.createEntity(desc);
    }

    /// 销毁实体
    pub fn destroyEntity(self: *ScriptContext, target: EntityId) void {
        _ = self.world.destroyEntity(target);
    }

    /// 打印日志
    pub fn log(self: *ScriptContext, message: []const u8) void {
        std.log.info("[Script:{d}] {s}", .{ self.entity, message });
    }

    /// 打印警告
    pub fn warn(self: *ScriptContext, message: []const u8) void {
        std.log.warn("[Script:{d}] {s}", .{ self.entity, message });
    }

    /// 打印错误
    pub fn logError(self: *ScriptContext, message: []const u8) void {
        std.log.err("[Script:{d}] {s}", .{ self.entity, message });
    }

    pub fn selectedEntityCount(self: *const ScriptContext) usize {
        return self.editor_selection.len;
    }

    pub fn selectedEntity(self: *const ScriptContext, index: usize) ?EntityId {
        if (index >= self.editor_selection.len) {
            return null;
        }
        return self.editor_selection[index];
    }

    pub fn selectEntity(self: *ScriptContext, entity_id: EntityId, additive: bool) void {
        if (self.editor_selection_api) |api| {
            api.select_entity(api.context, entity_id, additive);
        }
    }

    pub fn clearSelection(self: *ScriptContext) void {
        if (self.editor_selection_api) |api| {
            api.clear_selection(api.context);
        }
    }

    /// 获取用户数据指针
    pub fn getUserData(self: *ScriptContext, comptime T: type) ?*T {
        return @as(?*T, @ptrCast(self.instance.user_data));
    }

    /// 设置用户数据指针
    pub fn setUserData(self: *ScriptContext, data: *anyopaque) void {
        self.instance.user_data = data;
    }

    /// ===== 输入系统 API =====
    /// 检查按键是否按下
    pub fn isKeyDown(self: *ScriptContext, key: input_mod.Key) bool {
        if (self.input) |inp| {
            return inp.isKeyDown(key);
        }
        return false;
    }

    /// 检查按键是否在本帧按下
    pub fn wasKeyPressed(self: *ScriptContext, key: input_mod.Key) bool {
        if (self.input) |inp| {
            return inp.wasKeyPressed(key);
        }
        return false;
    }

    /// 检查按键是否在本帧释放
    pub fn wasKeyReleased(self: *ScriptContext, key: input_mod.Key) bool {
        if (self.input) |inp| {
            return inp.wasKeyReleased(key);
        }
        return false;
    }

    /// 检查鼠标按键是否按下
    pub fn isMouseButtonDown(self: *ScriptContext, button: input_mod.MouseButton) bool {
        if (self.input) |inp| {
            return inp.isMouseDown(button);
        }
        return false;
    }

    /// 检查鼠标按键是否在本帧按下
    pub fn wasMouseButtonPressed(self: *ScriptContext, button: input_mod.MouseButton) bool {
        if (self.input) |inp| {
            return inp.wasMousePressed(button);
        }
        return false;
    }

    /// 检查鼠标按键是否在本帧释放
    pub fn wasMouseButtonReleased(self: *ScriptContext, button: input_mod.MouseButton) bool {
        if (self.input) |inp| {
            return inp.wasMouseReleased(button);
        }
        return false;
    }

    /// 检查鼠标是否双击
    pub fn wasMouseDoubleClicked(self: *ScriptContext, button: input_mod.MouseButton) bool {
        if (self.input) |inp| {
            return inp.wasMouseDoubleClicked(button);
        }
        return false;
    }

    /// 获取鼠标位置
    pub fn getMousePosition(self: *ScriptContext) ?[2]f32 {
        if (self.input) |inp| {
            return inp.mouse_position;
        }
        return null;
    }

    /// 获取鼠标Delta（本帧移动量）
    pub fn getMouseDelta(self: *ScriptContext) ?[2]f32 {
        if (self.input) |inp| {
            return inp.mouse_delta;
        }
        return null;
    }

    /// 获取鼠标滚轮值
    pub fn getMouseWheel(self: *ScriptContext) ?[2]f32 {
        if (self.input) |inp| {
            return inp.mouse_wheel;
        }
        return null;
    }

    /// 检查修饰键（Shift/Ctrl/Alt）
    pub fn getModifiers(self: *ScriptContext) ?input_mod.Modifiers {
        if (self.input) |inp| {
            return inp.modifiers;
        }
        return null;
    }

    /// ===== 时间系统 API =====
    /// 获取全局时间（秒）
    pub fn getTime(self: *ScriptContext) f32 {
        return self.time;
    }

    /// 获取DeltaTime（秒）
    pub fn getDeltaTime(self: *ScriptContext) f32 {
        return self.delta_time;
    }

    /// 获取帧率
    pub fn getFPS(self: *ScriptContext) f32 {
        if (self.delta_time > 0.0) {
            return 1.0 / self.delta_time;
        }
        return 0.0;
    }

    /// 获取时间缩放
    pub fn getTimeScale(self: *ScriptContext) f32 {
        return self.time_scale;
    }

    /// 设置时间缩放
    pub fn setTimeScale(self: *ScriptContext, scale: f32) void {
        self.time_scale = scale;
    }

    /// 获取已缩放的时间（time * time_scale）
    pub fn getScaledTime(self: *ScriptContext) f32 {
        return self.time * self.time_scale;
    }

    /// 获取已缩放的DeltaTime（delta_time * time_scale）
    pub fn getScaledDeltaTime(self: *ScriptContext) f32 {
        return self.delta_time * self.time_scale;
    }

    pub fn loadScene(self: *ScriptContext, path: []const u8) void {
        if (self.scene_manager_api) |api| {
            api.load_scene(api.context, path);
        }
    }

    pub fn unloadScene(self: *ScriptContext) void {
        if (self.scene_manager_api) |api| {
            api.unload_scene(api.context);
        }
    }

    pub fn setDontDestroyOnLoad(self: *ScriptContext, enabled: bool) void {
        if (self.scene_manager_api) |api| {
            api.set_dont_destroy_on_load(api.context, self.entity, enabled);
        }
    }

    pub fn setEntityDontDestroyOnLoad(self: *ScriptContext, entity_id: EntityId, enabled: bool) void {
        if (self.scene_manager_api) |api| {
            api.set_dont_destroy_on_load(api.context, entity_id, enabled);
        }
    }

    pub fn isSceneLoading(self: *ScriptContext) bool {
        if (self.scene_manager_api) |api| {
            return api.is_loading(api.context);
        }
        return false;
    }

    /// ===== 物理查询 API =====
    pub fn physicsRaycast(
        self: *ScriptContext,
        origin: components.Vec3,
        direction: components.Vec3,
        max_distance: f32,
    ) ?physics_mod.RaycastHit {
        const ps = self.physics_state orelse return null;
        return ps.raycast(self.world, .{
            .origin = origin,
            .direction = direction,
            .max_distance = max_distance,
        }, .{});
    }

    pub fn physicsOverlapAabb(
        self: *ScriptContext,
        query_bounds: AABB,
        filter: physics_mod.QueryFilter,
    ) ![]physics_mod.OverlapHit {
        const ps = self.physics_state orelse return self.allocator.alloc(physics_mod.OverlapHit, 0);
        return ps.overlapAabb(self.world, self.allocator, query_bounds, filter);
    }

    pub fn physicsOverlapBox(
        self: *ScriptContext,
        center: components.Vec3,
        half_extents: components.Vec3,
        filter: physics_mod.QueryFilter,
    ) ![]physics_mod.OverlapHit {
        return self.physicsOverlapAabb(
            physics_mod.aabbFromCenterHalfExtents(center, half_extents),
            filter,
        );
    }

    pub fn physicsSweepAabb(
        self: *ScriptContext,
        query_bounds: AABB,
        translation: components.Vec3,
        filter: physics_mod.QueryFilter,
    ) ?physics_mod.SweepHit {
        const ps = self.physics_state orelse return null;
        return ps.sweepAabb(self.world, query_bounds, translation, filter);
    }

    pub fn physicsSweepBox(
        self: *ScriptContext,
        center: components.Vec3,
        half_extents: components.Vec3,
        translation: components.Vec3,
        filter: physics_mod.QueryFilter,
    ) ?physics_mod.SweepHit {
        return self.physicsSweepAabb(
            physics_mod.aabbFromCenterHalfExtents(center, half_extents),
            translation,
            filter,
        );
    }

    // -----------------------------------------------------------------------
    // 输入动作映射查询 API (GR-6)
    // -----------------------------------------------------------------------

    /// 当前帧动作是否被持续按住
    pub fn isActionPressed(self: *ScriptContext, action: []const u8) bool {
        const am = self.action_map orelse return false;
        return am.isPressed(action);
    }

    /// 当前帧动作是否刚被按下（上升沿）
    pub fn wasActionJustPressed(self: *ScriptContext, action: []const u8) bool {
        const am = self.action_map orelse return false;
        return am.wasJustPressed(action);
    }

    /// 当前帧动作是否刚被释放（下降沿）
    pub fn wasActionJustReleased(self: *ScriptContext, action: []const u8) bool {
        const am = self.action_map orelse return false;
        return am.wasJustReleased(action);
    }

    /// 获取合成轴值，范围 [-1, 1]
    pub fn getActionAxis(self: *ScriptContext, action: []const u8) f32 {
        const am = self.action_map orelse return 0.0;
        return am.getAxis(action);
    }

    // -----------------------------------------------------------------------
    // Phase 2a: 实体标签查询
    // -----------------------------------------------------------------------

    /// 按标签查找实体，将结果写入 out_buf，返回命中数量
    pub fn findEntitiesByTag(self: *ScriptContext, tag: []const u8, out_buf: []EntityId) usize {
        var count: usize = 0;
        for (self.world.entities.items) |*entity| {
            if (entity.tag) |*t| {
                if (t.eql(tag)) {
                    if (count >= out_buf.len) break;
                    out_buf[count] = entity.id;
                    count += 1;
                }
            }
        }
        return count;
    }

    /// 获取当前实体的标签（无标签返回空切片）
    pub fn getTag(self: *ScriptContext) []const u8 {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            const entity = &self.world.entities.items[idx];
            if (entity.tag) |*t| return t.asSlice();
        }
        return "";
    }

    /// 设置当前实体的标签
    pub fn setTag(self: *ScriptContext, tag: []const u8) void {
        if (self.world.id_to_index.get(self.entity)) |idx| {
            self.world.entities.items[idx].tag = components.Tag.fromSlice(tag);
        }
    }

    // -----------------------------------------------------------------------
    // Phase 2b: Prefab 实例化
    // -----------------------------------------------------------------------

    /// 实例化预制体，返回根实体 ID
    pub fn instantiatePrefab(self: *ScriptContext, prefab_id: []const u8, px: f32, py: f32, pz: f32) ?EntityId {
        return self.world.instantiatePrefab(prefab_id, .{
            .transform = .{
                .translation = .{ px, py, pz },
            },
            .load_resources = true,
        }) catch |err| {
            std.log.err("[Script:{d}] instantiatePrefab failed: {}", .{ self.entity, err });
            return null;
        };
    }

    // -----------------------------------------------------------------------
    // Phase 2c: 持久化存储（脚本可读写的 key-value 文件）
    // -----------------------------------------------------------------------

    /// 将字符串值保存到持久化文件（saves/{key}.dat）
    pub fn saveData(self: *ScriptContext, key: []const u8, value: []const u8) bool {
        const root = self.save_root_path orelse return false;
        // 确保目录存在
        std.Io.Dir.cwd().createDirPath(io_globals.global_io, root) catch return false;

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.dat", .{ root, key }) catch return false;
        const file = std.Io.Dir.cwd().createFile(io_globals.global_io, path, .{}) catch return false;
        defer file.close(io_globals.global_io);
        file.writeStreamingAll(io_globals.global_io, value) catch return false;
        return true;
    }

    /// 从持久化文件读取字符串值，失败返回空切片
    /// 注意：返回值使用 ScriptContext.allocator 分配，调用者需要自行管理
    pub fn loadData(self: *ScriptContext, key: []const u8) ?[]const u8 {
        const root = self.save_root_path orelse return null;
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.dat", .{ root, key }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, path, self.allocator, .limited(1024 * 1024)) catch null;
    }

    // -----------------------------------------------------------------------
    // Phase 2d: 全局黑板
    // -----------------------------------------------------------------------

    /// 设置黑板键值对（值被复制到黑板分配器中）
    pub fn setBlackboard(self: *ScriptContext, key: []const u8, value: []const u8) void {
        const bb = self.blackboard orelse return;
        bb.set(key, value);
    }

    /// 获取黑板键值对
    pub fn getBlackboard(self: *ScriptContext, key: []const u8) ?[]const u8 {
        const bb = self.blackboard orelse return null;
        return bb.get(key);
    }

    /// 删除黑板键
    pub fn removeBlackboard(self: *ScriptContext, key: []const u8) void {
        const bb = self.blackboard orelse return;
        bb.remove(key);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 全局黑板 — 脚本间共享的键值存储
// ═══════════════════════════════════════════════════════════════════════════

pub const Blackboard = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) Blackboard {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Blackboard) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn set(self: *Blackboard, key: []const u8, value: []const u8) void {
        // 如果已存在，释放旧值
        if (self.map.getEntry(key)) |existing| {
            self.allocator.free(existing.value_ptr.*);
            existing.value_ptr.* = self.allocator.dupe(u8, value) catch return;
            return;
        }
        // 新增键值对
        const owned_key = self.allocator.dupe(u8, key) catch return;
        const owned_value = self.allocator.dupe(u8, value) catch {
            self.allocator.free(owned_key);
            return;
        };
        self.map.put(owned_key, owned_value) catch {
            self.allocator.free(owned_key);
            self.allocator.free(owned_value);
        };
    }

    pub fn get(self: *Blackboard, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn remove(self: *Blackboard, key: []const u8) void {
        if (self.map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
    }
};

// 扩展 Entity 添加 hasComponent 和 getComponent 方法
pub fn entityHasComponent(entity: *world_mod.Entity, comptime T: type) bool {
    const type_name = @typeName(T);
    return if (comptime std.mem.eql(u8, type_name, "components.Transform")) true else if (comptime std.mem.eql(u8, type_name, "components.Camera")) entity.camera != null else if (comptime std.mem.eql(u8, type_name, "components.Mesh")) entity.mesh != null else if (comptime std.mem.eql(u8, type_name, "components.SkinnedMesh")) entity.skinned_mesh != null else if (comptime std.mem.eql(u8, type_name, "components.Animator")) entity.animator != null else if (comptime std.mem.eql(u8, type_name, "components.Rigidbody")) entity.rigidbody != null else if (comptime std.mem.eql(u8, type_name, "components.BoxCollider")) entity.box_collider != null else if (comptime std.mem.eql(u8, type_name, "components.SphereCollider")) entity.sphere_collider != null else if (comptime std.mem.eql(u8, type_name, "components.MeshCollider")) entity.mesh_collider != null else if (comptime std.mem.eql(u8, type_name, "components.CapsuleCollider")) entity.capsule_collider != null else if (comptime std.mem.eql(u8, type_name, "components.CharacterController")) entity.character_controller != null else if (comptime std.mem.eql(u8, type_name, "components.Tag")) entity.tag != null else if (comptime std.mem.eql(u8, type_name, "components.Sky")) entity.sky != null else if (comptime std.mem.eql(u8, type_name, "components.Material")) entity.material != null else if (comptime std.mem.eql(u8, type_name, "components.Light")) entity.light != null else if (comptime std.mem.eql(u8, type_name, "components.Vfx")) entity.vfx != null else if (comptime std.mem.endsWith(u8, type_name, "AudioSource")) entity.audio_source != null else if (comptime std.mem.endsWith(u8, type_name, "AudioListener")) entity.audio_listener != null else if (comptime std.mem.eql(u8, type_name, "script.types.Script") or std.mem.eql(u8, type_name, "components.Script")) entity.script != null else false;
}

pub fn entityGetComponent(entity: *world_mod.Entity, comptime T: type) ?*T {
    const type_name = @typeName(T);
    return if (comptime std.mem.eql(u8, type_name, "components.Transform"))
        &entity.local_transform
    else if (comptime std.mem.eql(u8, type_name, "components.Camera"))
        @ptrCast(entity.camera)
    else if (comptime std.mem.eql(u8, type_name, "components.Mesh"))
        @ptrCast(entity.mesh)
    else if (comptime std.mem.eql(u8, type_name, "components.SkinnedMesh"))
        @ptrCast(entity.skinned_mesh)
    else if (comptime std.mem.eql(u8, type_name, "components.Animator"))
        @ptrCast(entity.animator)
    else if (comptime std.mem.eql(u8, type_name, "components.Rigidbody"))
        @ptrCast(entity.rigidbody)
    else if (comptime std.mem.eql(u8, type_name, "components.BoxCollider"))
        @ptrCast(entity.box_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.SphereCollider"))
        @ptrCast(entity.sphere_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.MeshCollider"))
        @ptrCast(entity.mesh_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.CapsuleCollider"))
        @ptrCast(entity.capsule_collider)
    else if (comptime std.mem.eql(u8, type_name, "components.CharacterController"))
        @ptrCast(entity.character_controller)
    else if (comptime std.mem.eql(u8, type_name, "components.Tag"))
        @ptrCast(entity.tag)
    else if (comptime std.mem.eql(u8, type_name, "components.Sky"))
        @ptrCast(entity.sky)
    else if (comptime std.mem.eql(u8, type_name, "components.Material"))
        @ptrCast(entity.material)
    else if (comptime std.mem.eql(u8, type_name, "components.Light"))
        @ptrCast(entity.light)
    else if (comptime std.mem.eql(u8, type_name, "components.Vfx"))
        @ptrCast(entity.vfx)
    else if (comptime std.mem.endsWith(u8, type_name, "AudioSource"))
        if (entity.audio_source) |*audio_source| @ptrCast(audio_source) else null
    else if (comptime std.mem.endsWith(u8, type_name, "AudioListener"))
        if (entity.audio_listener) |*audio_listener| @ptrCast(audio_listener) else null
    else if (comptime std.mem.eql(u8, type_name, "script.types.Script") or std.mem.eql(u8, type_name, "components.Script"))
        @ptrCast(entity.script)
    else
        null;
}

test "entity component access includes audio components" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const entity_id = try world.createEntity(.{
        .name = "Audio Entity",
        .audio_source = .{},
        .audio_listener = .{},
    });

    const entity = world.getEntity(entity_id).?;
    try std.testing.expect(entityHasComponent(entity, components.AudioSource));
    try std.testing.expect(entityHasComponent(entity, components.AudioListener));
    try std.testing.expect(entityGetComponent(entity, components.AudioSource) != null);
    try std.testing.expect(entityGetComponent(entity, components.AudioListener) != null);
}
