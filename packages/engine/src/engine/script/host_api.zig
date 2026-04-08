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

    // ─── 新增字段追加在此处 ───────────────────────────────────────
};
