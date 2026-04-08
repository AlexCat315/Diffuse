// ---------------------------------------------------------------------------
// GuavaHostApi — 引擎↔脚本 C ABI 契约
//
// ⚠️  此文件零引擎内部依赖，可独立分发给脚本/插件开发者。
// ⚠️  只追加字段，永不删除/重排已有字段，保证 ABI 向前兼容。
// ---------------------------------------------------------------------------

/// 当前 API 版本。布局不兼容时递增。
pub const API_VERSION: u32 = 1;

/// Guava 引擎 Host API — 所有脚本语言通过此结构访问引擎功能。
///
/// 引擎在每次回调前通过 `guava_bind()` 将此表 + context 指针传给脚本。
/// 脚本通过函数指针调用引擎功能，无需链接引擎符号。
///
/// 版本兼容规则：
///   - `api_version` = API_VERSION，主版本不匹配时引擎拒绝加载脚本
///   - `api_size` = @sizeOf(GuavaHostApi)，脚本可检测新版本是否追加了字段
///   - 新增字段只追加到 struct 末尾
///   - 永不删除、永不重排已有字段
pub const GuavaHostApi = extern struct {
    // ─── 头部（版本协商）───────────────────────────────────────────
    api_version: u32,
    api_size: u32,

    // ─── Logging ──────────────────────────────────────────────────
    log_fn: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    // ─── Entity ───────────────────────────────────────────────────
    get_entity_id: *const fn (?*anyopaque) callconv(.c) u64,
    find_entity_by_name: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u64,
    spawn_entity: *const fn (?*anyopaque) callconv(.c) u64,
    destroy_entity: *const fn (?*anyopaque, u64) callconv(.c) void,

    // ─── Transform ────────────────────────────────────────────────
    get_position: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_position: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,
    get_rotation: *const fn (?*anyopaque, *f32, *f32, *f32, *f32) callconv(.c) void,
    set_rotation: *const fn (?*anyopaque, f32, f32, f32, f32) callconv(.c) void,
    get_scale: *const fn (?*anyopaque, *f32, *f32, *f32) callconv(.c) void,
    set_scale: *const fn (?*anyopaque, f32, f32, f32) callconv(.c) void,

    // ─── Input (Keyboard / Mouse) ─────────────────────────────────
    is_key_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_key_released: *const fn (?*anyopaque, u32) callconv(.c) u32,
    is_mouse_button_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_mouse_position: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    get_mouse_delta: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,
    get_mouse_wheel: *const fn (?*anyopaque, *f32, *f32) callconv(.c) void,

    // ─── Time ─────────────────────────────────────────────────────
    get_delta_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_time: *const fn (?*anyopaque) callconv(.c) f32,

    // ─── Physics ──────────────────────────────────────────────────
    raycast: *const fn (?*anyopaque, f32, f32, f32, f32, f32, f32, f32, *f32, *f32, *f32, *f32, *u64) callconv(.c) u32,
    set_linear_velocity: *const fn (?*anyopaque, u64, f32, f32, f32) callconv(.c) void,
    get_linear_velocity: *const fn (?*anyopaque, u64, *f32, *f32, *f32) callconv(.c) void,
    add_impulse: *const fn (?*anyopaque, u64, f32, f32, f32) callconv(.c) void,

    // ─── Scene ────────────────────────────────────────────────────
    load_scene: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    // ─── Gamepad ──────────────────────────────────────────────────
    is_gamepad_connected: *const fn (?*anyopaque) callconv(.c) u32,
    is_gamepad_button_down: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_gamepad_button_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    get_gamepad_axis: *const fn (?*anyopaque, u32) callconv(.c) f32,

    // ─── Audio ────────────────────────────────────────────────────
    audio_load_clip: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u32,
    audio_play_2d: *const fn (?*anyopaque, u32, f32, u32) callconv(.c) u32,
    audio_play_3d: *const fn (?*anyopaque, u32, f32, f32, f32, f32, u32) callconv(.c) u32,
    audio_stop: *const fn (?*anyopaque, u32) callconv(.c) void,
    audio_set_volume: *const fn (?*anyopaque, u32, f32) callconv(.c) void,
    audio_pause: *const fn (?*anyopaque, u32, u32) callconv(.c) void,
    audio_is_playing: *const fn (?*anyopaque, u32) callconv(.c) u32,

    // ─── Animation ────────────────────────────────────────────────
    anim_play: *const fn (?*anyopaque, u64, [*]const u8, usize, f32) callconv(.c) void,
    anim_stop: *const fn (?*anyopaque, u64) callconv(.c) void,
    anim_set_speed: *const fn (?*anyopaque, u64, f32) callconv(.c) void,
    anim_is_playing: *const fn (?*anyopaque, u64) callconv(.c) u32,

    // ─── Canvas / UI ──────────────────────────────────────────────
    canvas_clear: *const fn (?*anyopaque) callconv(.c) void,
    canvas_add_text: *const fn (?*anyopaque, f32, f32, f32, f32, [*]const u8, usize, u8, u8, u8, u8) callconv(.c) u32,
    canvas_add_panel: *const fn (?*anyopaque, f32, f32, f32, f32, u8, u8, u8, u8) callconv(.c) u32,
    canvas_add_button: *const fn (?*anyopaque, f32, f32, f32, f32, [*]const u8, usize) callconv(.c) u32,
    canvas_add_progress_bar: *const fn (?*anyopaque, f32, f32, f32, f32, f32) callconv(.c) u32,
    canvas_set_text: *const fn (?*anyopaque, u32, [*]const u8, usize) callconv(.c) void,
    canvas_set_progress: *const fn (?*anyopaque, u32, f32) callconv(.c) void,
    canvas_set_visible: *const fn (?*anyopaque, u32, u32) callconv(.c) void,
    canvas_remove_widget: *const fn (?*anyopaque, u32) callconv(.c) void,
    canvas_was_button_clicked: *const fn (?*anyopaque, u32) callconv(.c) u32,

    // ─── Script Parameters ────────────────────────────────────────
    get_parameter_float: *const fn (?*anyopaque, [*]const u8, usize, f32) callconv(.c) f32,
    get_parameter_int: *const fn (?*anyopaque, [*]const u8, usize, i32) callconv(.c) i32,
    get_parameter_bool: *const fn (?*anyopaque, [*]const u8, usize, u32) callconv(.c) u32,

    // ═══════════════════════════════════════════════════════════════
    // Phase 1: 新增功能（API_VERSION = 1 追加字段）
    // ═══════════════════════════════════════════════════════════════

    // ─── Entity Hierarchy ─────────────────────────────────────────
    get_child_count: *const fn (?*anyopaque) callconv(.c) u32,
    get_child_entity: *const fn (?*anyopaque, u32) callconv(.c) u64,
    get_parent_entity: *const fn (?*anyopaque) callconv(.c) u64,

    // ─── Scene Management ─────────────────────────────────────────
    unload_scene: *const fn (?*anyopaque) callconv(.c) void,
    is_scene_loading: *const fn (?*anyopaque) callconv(.c) u32,
    set_dont_destroy_on_load: *const fn (?*anyopaque, u32) callconv(.c) void,
    set_entity_dont_destroy_on_load: *const fn (?*anyopaque, u64, u32) callconv(.c) void,

    // ─── Time (extended) ──────────────────────────────────────────
    get_time_scale: *const fn (?*anyopaque) callconv(.c) f32,
    set_time_scale: *const fn (?*anyopaque, f32) callconv(.c) void,
    get_scaled_delta_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_scaled_time: *const fn (?*anyopaque) callconv(.c) f32,
    get_fps: *const fn (?*anyopaque) callconv(.c) f32,

    // ─── Input: Mouse (extended) ──────────────────────────────────
    was_mouse_button_pressed: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_mouse_button_released: *const fn (?*anyopaque, u32) callconv(.c) u32,
    was_mouse_double_clicked: *const fn (?*anyopaque, u32) callconv(.c) u32,

    // ─── Input: Action Map ────────────────────────────────────────
    is_action_pressed: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u32,
    was_action_just_pressed: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u32,
    was_action_just_released: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) u32,
    get_action_axis: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) f32,

    // ─── Physics (extended) ───────────────────────────────────────
    /// overlap_box: 返回命中数量，将 entity_id 写入 out_entities (最多 max_results 个)
    overlap_box: *const fn (?*anyopaque, f32, f32, f32, f32, f32, f32, u64, u32, [*]u64, u32) callconv(.c) u32,
    /// sweep_box: 返回 1=命中 0=未命中，通过 out 参数输出命中详情
    sweep_box: *const fn (?*anyopaque, f32, f32, f32, f32, f32, f32, f32, f32, f32, u64, u32, *u64, *f32, *f32, *f32, *f32) callconv(.c) u32,

    // ═══════════════════════════════════════════════════════════════
    // Phase 2: 新增能力
    // ═══════════════════════════════════════════════════════════════

    // ─── Entity Tag Query ─────────────────────────────────────────
    /// 按标签查找实体，返回命中数量，将 entity_id 写入 out_entities
    find_entities_by_tag: *const fn (?*anyopaque, [*]const u8, usize, [*]u64, u32) callconv(.c) u32,
    /// 获取当前实体标签（ptr+len 输出）
    get_tag: *const fn (?*anyopaque, *[*]const u8, *usize) callconv(.c) void,
    /// 设置当前实体标签
    set_tag: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    // ─── Prefab ───────────────────────────────────────────────────
    /// 实例化预制体，返回根实体 ID（0 = 失败）
    instantiate_prefab: *const fn (?*anyopaque, [*]const u8, usize, f32, f32, f32) callconv(.c) u64,

    // ─── Persistence ──────────────────────────────────────────────
    /// 写入持久化键值（saves/{key}.dat）
    save_data: *const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) u32,
    /// 读取持久化键值，返回值指针+长度（0 = 不存在）
    load_data: *const fn (?*anyopaque, [*]const u8, usize, *[*]const u8, *usize) callconv(.c) u32,

    // ─── Blackboard ───────────────────────────────────────────────
    /// 设置全局黑板键值
    blackboard_set: *const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize) callconv(.c) void,
    /// 获取全局黑板键值，通过 out 参数输出
    blackboard_get: *const fn (?*anyopaque, [*]const u8, usize, *[*]const u8, *usize) callconv(.c) u32,
    /// 删除全局黑板键
    blackboard_remove: *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,

    // ─── 新增字段追加在此处 ───────────────────────────────────────
};
