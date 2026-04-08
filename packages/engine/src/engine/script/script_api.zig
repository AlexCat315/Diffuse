//! Guava Engine 脚本 API
//!
//! 用户脚本通过 @import("guava") 获取此模块。
//! 提供实体操作、输入查询、物理、日志等引擎 API。
//!
//! 用法示例：
//!   const guava = @import("guava");
//!
//!   export fn guava_on_update(dt: f32) callconv(.c) void {
//!       var pos = guava.getPosition();
//!       if (guava.isKeyDown(.w)) pos[2] -= 5.0 * dt;
//!       guava.setPosition(pos);
//!   }

const std = @import("std");
const host_api = @import("host_api.zig");

// ---------------------------------------------------------------------------
// Host API 函数表（C ABI，由 host_api.zig 统一定义）
// ---------------------------------------------------------------------------

pub const HostApi = host_api.GuavaHostApi;
pub const API_VERSION = host_api.API_VERSION;

// ---------------------------------------------------------------------------
// 模块级别状态（每次回调前由引擎通过 guava_bind 设置）
// ---------------------------------------------------------------------------

var api: *const HostApi = undefined;
var ctx: ?*anyopaque = null;
var bound_entity: u64 = 0;

/// 引擎在每次回调前调用此函数注入 API 与上下文
export fn guava_bind(host: *const HostApi, host_ctx: ?*anyopaque, entity_id: u64) callconv(.c) void {
    api = host;
    ctx = host_ctx;
    bound_entity = entity_id;
}

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

pub const Vec3 = [3]f32;
pub const Quat = [4]f32;

pub const Key = enum(u32) {
    w = 0,
    a = 1,
    s = 2,
    d = 3,
    b = 4,
    i = 5,
    m = 6,
    q = 7,
    e = 8,
    f = 9,
    g = 10,
    r = 11,
    t = 12,
    n = 13,
    tab = 14,
    delete = 15,
    backspace = 16,
    one = 17,
    two = 18,
    three = 19,
    l = 20,
    o = 21,
    p = 22,
    x = 23,
    y = 24,
    z = 25,
    period = 26,
    shift = 27,
    ctrl = 28,
    alt = 29,
    space = 30,
    escape = 31,
    up = 32,
    down = 33,
    left = 34,
    right = 35,
    f1 = 36,
    f2 = 37,
    f3 = 38,
    f4 = 39,
    f5 = 40,
    f6 = 41,
    f7 = 42,
    f8 = 43,
    f9 = 44,
    f10 = 45,
    f11 = 46,
    f12 = 47,
};

pub const MouseButton = enum(u32) {
    left = 0,
    right = 1,
    middle = 2,
};

// ---------------------------------------------------------------------------
// 公开 API
// ---------------------------------------------------------------------------

/// 当前脚本绑定的实体 ID
pub fn entityId() u64 {
    return bound_entity;
}

/// 打印日志
pub fn log(msg: []const u8) void {
    api.log_fn(ctx, msg.ptr, msg.len);
}

/// 通过名称查找实体，未找到返回 0
pub fn findEntityByName(name: []const u8) u64 {
    return api.find_entity_by_name(ctx, name.ptr, name.len);
}

/// 创建新实体，返回实体 ID
pub fn spawnEntity() u64 {
    return api.spawn_entity(ctx);
}

/// 销毁实体
pub fn destroyEntity(id: u64) void {
    api.destroy_entity(ctx, id);
}

/// 获取当前实体（或指定实体）的本地位置
pub fn getPosition() Vec3 {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api.get_position(ctx, &x, &y, &z);
    return .{ x, y, z };
}

/// 获取任意实体的本地位置
pub fn getPositionOf(entity_id: u64) Vec3 {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api.get_position_of_entity(ctx, entity_id, &x, &y, &z);
    return .{ x, y, z };
}

/// 设置当前实体的本地位置
pub fn setPosition(pos: Vec3) void {
    api.set_position(ctx, pos[0], pos[1], pos[2]);
}

/// 获取当前实体的旋转（四元数 xyzw）
pub fn getRotation() Quat {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    var w: f32 = 1;
    api.get_rotation(ctx, &x, &y, &z, &w);
    return .{ x, y, z, w };
}

/// 设置当前实体的旋转（四元数 xyzw）
pub fn setRotation(rot: Quat) void {
    api.set_rotation(ctx, rot[0], rot[1], rot[2], rot[3]);
}

/// 获取当前实体的缩放
pub fn getScale() Vec3 {
    var x: f32 = 1;
    var y: f32 = 1;
    var z: f32 = 1;
    api.get_scale(ctx, &x, &y, &z);
    return .{ x, y, z };
}

/// 设置当前实体的缩放
pub fn setScale(scale: Vec3) void {
    api.set_scale(ctx, scale[0], scale[1], scale[2]);
}

/// 查询按键是否当前按下
pub fn isKeyDown(key: Key) bool {
    return api.is_key_down(ctx, @intFromEnum(key)) != 0;
}

/// 查询按键是否刚按下（本帧边沿）
pub fn wasKeyPressed(key: Key) bool {
    return api.was_key_pressed(ctx, @intFromEnum(key)) != 0;
}

/// 查询按键是否刚释放（本帧边沿）
pub fn wasKeyReleased(key: Key) bool {
    return api.was_key_released(ctx, @intFromEnum(key)) != 0;
}

/// 查询鼠标按钮是否按下
pub fn isMouseButtonDown(button: MouseButton) bool {
    return api.is_mouse_button_down(ctx, @intFromEnum(button)) != 0;
}

/// 获取鼠标位置
pub fn getMousePosition() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    api.get_mouse_position(ctx, &x, &y);
    return .{ x, y };
}

/// 获取鼠标本帧移动量
pub fn getMouseDelta() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    api.get_mouse_delta(ctx, &x, &y);
    return .{ x, y };
}

/// 获取鼠标滚轮值
pub fn getMouseWheel() [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    api.get_mouse_wheel(ctx, &x, &y);
    return .{ x, y };
}

/// 获取帧间隔时间（秒）
pub fn deltaTime() f32 {
    return api.get_delta_time(ctx);
}

/// 获取游戏运行总时间（秒）
pub fn time() f32 {
    return api.get_time(ctx);
}

// ---------------------------------------------------------------------------
// 物理查询 API
// ---------------------------------------------------------------------------

pub const RaycastHit = struct {
    position: Vec3,
    distance: f32,
    entity_id: u64,
};

/// 射线检测，返回最近的碰撞点
pub fn raycast(origin: Vec3, direction: Vec3, max_distance: f32) ?RaycastHit {
    var hx: f32 = 0;
    var hy: f32 = 0;
    var hz: f32 = 0;
    var dist: f32 = 0;
    var eid: u64 = 0;
    const hit = api.raycast(ctx, origin[0], origin[1], origin[2], direction[0], direction[1], direction[2], max_distance, &hx, &hy, &hz, &dist, &eid);
    if (hit == 0) return null;
    return .{ .position = .{ hx, hy, hz }, .distance = dist, .entity_id = eid };
}

/// 设置刚体线速度
pub fn setLinearVelocity(entity_id: u64, velocity: Vec3) void {
    api.set_linear_velocity(ctx, entity_id, velocity[0], velocity[1], velocity[2]);
}

/// 获取刚体线速度
pub fn getLinearVelocity(entity_id: u64) Vec3 {
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api.get_linear_velocity(ctx, entity_id, &x, &y, &z);
    return .{ x, y, z };
}

/// 对刚体施加冲量
pub fn addImpulse(entity_id: u64, impulse: Vec3) void {
    api.add_impulse(ctx, entity_id, impulse[0], impulse[1], impulse[2]);
}

/// 加载场景
pub fn loadScene(path: []const u8) void {
    api.load_scene(ctx, path.ptr, path.len);
}

// ---------------------------------------------------------------------------
// Gamepad API
// ---------------------------------------------------------------------------

pub const GamepadButton = enum(u32) {
    south = 0,
    east = 1,
    west = 2,
    north = 3,
    back = 4,
    guide = 5,
    start = 6,
    left_stick = 7,
    right_stick = 8,
    left_shoulder = 9,
    right_shoulder = 10,
    dpad_up = 11,
    dpad_down = 12,
    dpad_left = 13,
    dpad_right = 14,
};

pub const GamepadAxis = enum(u32) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

/// 检查是否有手柄连接
pub fn isGamepadConnected() bool {
    return api.is_gamepad_connected(ctx) != 0;
}

/// 查询手柄按钮是否按下
pub fn isGamepadButtonDown(button: GamepadButton) bool {
    return api.is_gamepad_button_down(ctx, @intFromEnum(button)) != 0;
}

/// 查询手柄按钮是否刚按下（本帧边沿）
pub fn wasGamepadButtonPressed(button: GamepadButton) bool {
    return api.was_gamepad_button_pressed(ctx, @intFromEnum(button)) != 0;
}

/// 获取手柄轴值（-1.0 ~ 1.0，trigger 为 0.0 ~ 1.0）
pub fn getGamepadAxis(axis: GamepadAxis) f32 {
    return api.get_gamepad_axis(ctx, @intFromEnum(axis));
}

// ---------------------------------------------------------------------------
// Audio API
// ---------------------------------------------------------------------------

pub const AudioClipHandle = u32;
pub const VoiceHandle = u32;

/// 从文件路径加载音频片段，返回 clip handle（0 = 加载失败）
pub fn audioLoadClip(path: []const u8) AudioClipHandle {
    return api.audio_load_clip(ctx, path.ptr, path.len);
}

/// 播放 2D 音频（无空间化），返回 voice handle（0 = 播放失败）
pub fn audioPlay2d(clip: AudioClipHandle, volume: f32, loop: bool) VoiceHandle {
    return api.audio_play_2d(ctx, clip, volume, if (loop) @as(u32, 1) else @as(u32, 0));
}

/// 播放 3D 空间音频，返回 voice handle（0 = 播放失败）
pub fn audioPlay3d(clip: AudioClipHandle, pos: Vec3, volume: f32, loop: bool) VoiceHandle {
    return api.audio_play_3d(ctx, clip, pos[0], pos[1], pos[2], volume, if (loop) @as(u32, 1) else @as(u32, 0));
}

/// 停止播放指定 voice
pub fn audioStop(voice: VoiceHandle) void {
    api.audio_stop(ctx, voice);
}

/// 设置指定 voice 音量
pub fn audioSetVolume(voice: VoiceHandle, volume: f32) void {
    api.audio_set_volume(ctx, voice, volume);
}

/// 暂停/恢复指定 voice
pub fn audioPause(voice: VoiceHandle, paused: bool) void {
    api.audio_pause(ctx, voice, if (paused) @as(u32, 1) else @as(u32, 0));
}

/// 查询指定 voice 是否正在播放
pub fn audioIsPlaying(voice: VoiceHandle) bool {
    return api.audio_is_playing(ctx, voice) != 0;
}

// ---------------------------------------------------------------------------
// Animation API
// ---------------------------------------------------------------------------

/// 播放动画片段（通过 asset ID），可指定混合过渡时间
pub fn animPlay(entity_id: u64, clip_asset_id: []const u8, blend_duration: f32) void {
    api.anim_play(ctx, entity_id, clip_asset_id.ptr, clip_asset_id.len, blend_duration);
}

/// 停止实体的动画播放
pub fn animStop(entity_id: u64) void {
    api.anim_stop(ctx, entity_id);
}

/// 设置动画播放速度
pub fn animSetSpeed(entity_id: u64, speed: f32) void {
    api.anim_set_speed(ctx, entity_id, speed);
}

/// 查询实体是否正在播放动画
pub fn animIsPlaying(entity_id: u64) bool {
    return api.anim_is_playing(ctx, entity_id) != 0;
}

// ---------------------------------------------------------------------------
// Canvas / UI
// ---------------------------------------------------------------------------

pub const WidgetId = u32;

/// 清空画布上所有控件
pub fn canvasClear() void {
    api.canvas_clear(ctx);
}

/// 添加文本控件，返回 WidgetId（0 = 失败）
pub fn canvasAddText(x: f32, y: f32, w: f32, h: f32, text: []const u8, r: u8, g: u8, b: u8, a: u8) WidgetId {
    return api.canvas_add_text(ctx, x, y, w, h, text.ptr, text.len, r, g, b, a);
}

/// 添加面板控件
pub fn canvasAddPanel(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) WidgetId {
    return api.canvas_add_panel(ctx, x, y, w, h, r, g, b, a);
}

/// 添加按钮控件
pub fn canvasAddButton(x: f32, y: f32, w: f32, h: f32, label: []const u8) WidgetId {
    return api.canvas_add_button(ctx, x, y, w, h, label.ptr, label.len);
}

/// 添加进度条控件
pub fn canvasAddProgressBar(x: f32, y: f32, w: f32, h: f32, value: f32) WidgetId {
    return api.canvas_add_progress_bar(ctx, x, y, w, h, value);
}

/// 更新文本内容
pub fn canvasSetText(id: WidgetId, text: []const u8) void {
    api.canvas_set_text(ctx, id, text.ptr, text.len);
}

/// 更新进度条值
pub fn canvasSetProgress(id: WidgetId, value: f32) void {
    api.canvas_set_progress(ctx, id, value);
}

/// 设置控件可见性
pub fn canvasSetVisible(id: WidgetId, visible: bool) void {
    api.canvas_set_visible(ctx, id, if (visible) 1 else 0);
}

/// 移除控件
pub fn canvasRemoveWidget(id: WidgetId) void {
    api.canvas_remove_widget(ctx, id);
}

/// 查询按钮本帧是否被点击
pub fn canvasWasButtonClicked(id: WidgetId) bool {
    return api.canvas_was_button_clicked(ctx, id) != 0;
}

// ---------------------------------------------------------------------------
// Script Parameters API
// ---------------------------------------------------------------------------

/// 获取 float 类型参数值，参数由编辑器 Inspector 设置
pub fn getParameterFloat(name: []const u8, default: f32) f32 {
    return api.get_parameter_float(ctx, name.ptr, name.len, default);
}

/// 获取 int 类型参数值
pub fn getParameterInt(name: []const u8, default: i32) i32 {
    return api.get_parameter_int(ctx, name.ptr, name.len, default);
}

/// 获取 bool 类型参数值
pub fn getParameterBool(name: []const u8, default: bool) bool {
    return api.get_parameter_bool(ctx, name.ptr, name.len, if (default) @as(u32, 1) else @as(u32, 0)) != 0;
}

// ---------------------------------------------------------------------------
// Entity Hierarchy API
// ---------------------------------------------------------------------------

/// 获取当前实体的直接子实体数量
pub fn getChildCount() u32 {
    return api.get_child_count(ctx);
}

/// 按索引获取子实体 ID（0 = 无效/越界）
pub fn getChildEntity(index: u32) u64 {
    return api.get_child_entity(ctx, index);
}

/// 获取当前实体的父实体 ID（0 = 根实体/无父）
pub fn getParentEntity() u64 {
    return api.get_parent_entity(ctx);
}

// ---------------------------------------------------------------------------
// Scene Management (extended)
// ---------------------------------------------------------------------------

/// 卸载当前场景
pub fn unloadScene() void {
    api.unload_scene(ctx);
}

/// 查询场景是否正在加载中
pub fn isSceneLoading() bool {
    return api.is_scene_loading(ctx) != 0;
}

/// 标记当前实体为"跨场景不销毁"
pub fn setDontDestroyOnLoad(enabled: bool) void {
    api.set_dont_destroy_on_load(ctx, if (enabled) 1 else 0);
}

/// 标记指定实体为"跨场景不销毁"
pub fn setEntityDontDestroyOnLoad(entity_id: u64, enabled: bool) void {
    api.set_entity_dont_destroy_on_load(ctx, entity_id, if (enabled) 1 else 0);
}

// ---------------------------------------------------------------------------
// Time (extended)
// ---------------------------------------------------------------------------

/// 获取时间缩放系数
pub fn getTimeScale() f32 {
    return api.get_time_scale(ctx);
}

/// 设置时间缩放系数
pub fn setTimeScale(scale: f32) void {
    api.set_time_scale(ctx, scale);
}

/// 获取缩放后的帧间隔（deltaTime * timeScale）
pub fn scaledDeltaTime() f32 {
    return api.get_scaled_delta_time(ctx);
}

/// 获取缩放后的总时间
pub fn scaledTime() f32 {
    return api.get_scaled_time(ctx);
}

/// 获取当前帧率（FPS）
pub fn fps() f32 {
    return api.get_fps(ctx);
}

// ---------------------------------------------------------------------------
// Mouse Input (extended)
// ---------------------------------------------------------------------------

/// 查询鼠标按钮是否在本帧刚按下
pub fn wasMouseButtonPressed(button: MouseButton) bool {
    return api.was_mouse_button_pressed(ctx, @intFromEnum(button)) != 0;
}

/// 查询鼠标按钮是否在本帧刚释放
pub fn wasMouseButtonReleased(button: MouseButton) bool {
    return api.was_mouse_button_released(ctx, @intFromEnum(button)) != 0;
}

/// 查询鼠标是否双击
pub fn wasMouseDoubleClicked(button: MouseButton) bool {
    return api.was_mouse_double_clicked(ctx, @intFromEnum(button)) != 0;
}

// ---------------------------------------------------------------------------
// Action Map API
// ---------------------------------------------------------------------------

/// 查询动作是否当前按住（持续状态）
pub fn isActionPressed(action: []const u8) bool {
    return api.is_action_pressed(ctx, action.ptr, action.len) != 0;
}

/// 查询动作是否刚按下（本帧上升沿）
pub fn wasActionJustPressed(action: []const u8) bool {
    return api.was_action_just_pressed(ctx, action.ptr, action.len) != 0;
}

/// 查询动作是否刚释放（本帧下降沿）
pub fn wasActionJustReleased(action: []const u8) bool {
    return api.was_action_just_released(ctx, action.ptr, action.len) != 0;
}

/// 获取合成轴值（-1.0 ~ 1.0）
pub fn getActionAxis(action: []const u8) f32 {
    return api.get_action_axis(ctx, action.ptr, action.len);
}

// ---------------------------------------------------------------------------
// Physics (extended)
// ---------------------------------------------------------------------------

pub const OverlapResult = struct {
    count: u32,
    entities: []const u64,
};

/// 盒体重叠检测，返回命中实体数量。entity_buf 需由调用者分配。
pub fn overlapBox(center: Vec3, half_extents: Vec3, exclude_entity: u64, include_triggers: bool, entity_buf: []u64) u32 {
    return api.overlap_box(
        ctx,
        center[0],
        center[1],
        center[2],
        half_extents[0],
        half_extents[1],
        half_extents[2],
        exclude_entity,
        if (include_triggers) 1 else 0,
        entity_buf.ptr,
        @intCast(entity_buf.len),
    );
}

pub const SweepHit = struct {
    entity_id: u64,
    fraction: f32,
    normal: Vec3,
};

/// 盒体扫掠检测（shape cast），返回最近命中
pub fn sweepBox(center: Vec3, half_extents: Vec3, direction: Vec3, exclude_entity: u64, include_triggers: bool) ?SweepHit {
    var eid: u64 = 0;
    var frac: f32 = 0;
    var nx: f32 = 0;
    var ny: f32 = 0;
    var nz: f32 = 0;
    const hit = api.sweep_box(
        ctx,
        center[0],
        center[1],
        center[2],
        half_extents[0],
        half_extents[1],
        half_extents[2],
        direction[0],
        direction[1],
        direction[2],
        exclude_entity,
        if (include_triggers) 1 else 0,
        &eid,
        &frac,
        &nx,
        &ny,
        &nz,
    );
    if (hit == 0) return null;
    return .{ .entity_id = eid, .fraction = frac, .normal = .{ nx, ny, nz } };
}

// ---------------------------------------------------------------------------
// Entity Tag API (Phase 2a)
// ---------------------------------------------------------------------------

/// 按标签查找实体，返回命中数量。entity_buf 需由调用者分配。
pub fn findEntitiesByTag(tag: []const u8, entity_buf: []u64) u32 {
    return api.find_entities_by_tag(ctx, tag.ptr, tag.len, entity_buf.ptr, @intCast(entity_buf.len));
}

/// 获取当前实体的标签
pub fn getTag() []const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    api.get_tag(ctx, &ptr, &len);
    if (len == 0) return "";
    return ptr[0..len];
}

/// 设置当前实体的标签
pub fn setTag(tag: []const u8) void {
    api.set_tag(ctx, tag.ptr, tag.len);
}

// ---------------------------------------------------------------------------
// Prefab API (Phase 2b)
// ---------------------------------------------------------------------------

/// 实例化预制体，返回根实体 ID（0 = 失败）
pub fn instantiatePrefab(prefab_id: []const u8, position: Vec3) u64 {
    return api.instantiate_prefab(ctx, prefab_id.ptr, prefab_id.len, position[0], position[1], position[2]);
}

// ---------------------------------------------------------------------------
// Persistence API (Phase 2c)
// ---------------------------------------------------------------------------

/// 将字符串值保存到持久化文件
pub fn saveData(key: []const u8, value: []const u8) bool {
    return api.save_data(ctx, key.ptr, key.len, value.ptr, value.len) != 0;
}

/// 从持久化文件读取字符串值
pub fn loadData(key: []const u8) ?[]const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    if (api.load_data(ctx, key.ptr, key.len, &ptr, &len) == 0) return null;
    return ptr[0..len];
}

// ---------------------------------------------------------------------------
// Blackboard API (Phase 2d)
// ---------------------------------------------------------------------------

/// 设置全局黑板键值对（对所有脚本实例可见）
pub fn blackboardSet(key: []const u8, value: []const u8) void {
    api.blackboard_set(ctx, key.ptr, key.len, value.ptr, value.len);
}

/// 获取全局黑板键值对
pub fn blackboardGet(key: []const u8) ?[]const u8 {
    var ptr: [*]const u8 = undefined;
    var len: usize = 0;
    if (api.blackboard_get(ctx, key.ptr, key.len, &ptr, &len) == 0) return null;
    return ptr[0..len];
}

/// 删除全局黑板键
pub fn blackboardRemove(key: []const u8) void {
    api.blackboard_remove(ctx, key.ptr, key.len);
}
