// ---------------------------------------------------------------------------
// host/mod.zig — 桥接函数公共基础 + 域模块统一入口
// ---------------------------------------------------------------------------
const std = @import("std");
const context = @import("../context.zig");
const host_api = @import("../host_api.zig");

pub const GuavaHostApi = host_api.GuavaHostApi;
pub const API_VERSION = host_api.API_VERSION;

// ═══════════════════════════════════════════════════════════════════════════
// 公共 Host Context（所有语言运行时共享）
// ═══════════════════════════════════════════════════════════════════════════

/// 存储当前活跃的 ScriptContext 指针。
/// 每个脚本实例持有一个，引擎在回调前设置 active_context。
pub const GuavaHostContext = struct {
    active_context: ?*context.ScriptContext = null,
};

/// 从 userdata 指针恢复 ScriptContext。所有桥接函数的起点。
pub fn activeContext(userdata: ?*anyopaque) ?*context.ScriptContext {
    const host_context: *GuavaHostContext = @ptrCast(@alignCast(userdata orelse return null));
    return host_context.active_context;
}

// ═══════════════════════════════════════════════════════════════════════════
// 域模块 re-export
// ═══════════════════════════════════════════════════════════════════════════

pub const log_host = @import("./log.zig");
pub const entity = @import("./entity.zig");
pub const transform = @import("./transform.zig");
pub const input = @import("./input.zig");
pub const time = @import("./time.zig");
pub const physics = @import("./physics.zig");
pub const scene = @import("./scene.zig");
pub const audio = @import("./audio.zig");
pub const animation = @import("./animation.zig");
pub const canvas = @import("./canvas.zig");
pub const parameters = @import("./parameters.zig");

// ═══════════════════════════════════════════════════════════════════════════
// GuavaHostApi 实例构造
// ═══════════════════════════════════════════════════════════════════════════

/// 全局唯一的 GuavaHostApi 实例（const，所有语言运行时共享同一张表）
pub const guava_host_api: GuavaHostApi = .{
    .api_version = API_VERSION,
    .api_size = @sizeOf(GuavaHostApi),
    // Logging
    .log_fn = log_host.guavaHostLog,
    // Entity
    .get_entity_id = entity.guavaHostGetEntityId,
    .find_entity_by_name = entity.guavaHostFindEntityByName,
    .spawn_entity = entity.guavaHostSpawnEntity,
    .destroy_entity = entity.guavaHostDestroyEntity,
    // Transform
    .get_position = transform.guavaHostGetPosition,
    .set_position = transform.guavaHostSetPosition,
    .get_rotation = transform.guavaHostGetRotation,
    .set_rotation = transform.guavaHostSetRotation,
    .get_scale = transform.guavaHostGetScale,
    .set_scale = transform.guavaHostSetScale,
    // Input
    .is_key_down = input.guavaHostIsKeyDown,
    .was_key_pressed = input.guavaHostWasKeyPressed,
    .was_key_released = input.guavaHostWasKeyReleased,
    .is_mouse_button_down = input.guavaHostIsMouseButtonDown,
    .get_mouse_position = input.guavaHostGetMousePosition,
    .get_mouse_delta = input.guavaHostGetMouseDelta,
    .get_mouse_wheel = input.guavaHostGetMouseWheel,
    // Time
    .get_delta_time = time.guavaHostGetDeltaTime,
    .get_time = time.guavaHostGetTime,
    // Physics
    .raycast = physics.guavaHostRaycast,
    .set_linear_velocity = physics.guavaHostSetLinearVelocity,
    .get_linear_velocity = physics.guavaHostGetLinearVelocity,
    .add_impulse = physics.guavaHostAddImpulse,
    // Scene
    .load_scene = scene.guavaHostLoadScene,
    // Gamepad
    .is_gamepad_connected = input.guavaHostIsGamepadConnected,
    .is_gamepad_button_down = input.guavaHostIsGamepadButtonDown,
    .was_gamepad_button_pressed = input.guavaHostWasGamepadButtonPressed,
    .get_gamepad_axis = input.guavaHostGetGamepadAxis,
    // Audio
    .audio_load_clip = audio.guavaHostAudioLoadClip,
    .audio_play_2d = audio.guavaHostAudioPlay2d,
    .audio_play_3d = audio.guavaHostAudioPlay3d,
    .audio_stop = audio.guavaHostAudioStop,
    .audio_set_volume = audio.guavaHostAudioSetVolume,
    .audio_pause = audio.guavaHostAudioPause,
    .audio_is_playing = audio.guavaHostAudioIsPlaying,
    // Animation
    .anim_play = animation.guavaHostAnimPlay,
    .anim_stop = animation.guavaHostAnimStop,
    .anim_set_speed = animation.guavaHostAnimSetSpeed,
    .anim_is_playing = animation.guavaHostAnimIsPlaying,
    // Canvas / UI
    .canvas_clear = canvas.guavaHostCanvasClear,
    .canvas_add_text = canvas.guavaHostCanvasAddText,
    .canvas_add_panel = canvas.guavaHostCanvasAddPanel,
    .canvas_add_button = canvas.guavaHostCanvasAddButton,
    .canvas_add_progress_bar = canvas.guavaHostCanvasAddProgressBar,
    .canvas_set_text = canvas.guavaHostCanvasSetText,
    .canvas_set_progress = canvas.guavaHostCanvasSetProgress,
    .canvas_set_visible = canvas.guavaHostCanvasSetVisible,
    .canvas_remove_widget = canvas.guavaHostCanvasRemoveWidget,
    .canvas_was_button_clicked = canvas.guavaHostCanvasWasButtonClicked,
    // Script Parameters
    .get_parameter_float = parameters.guavaHostGetParameterFloat,
    .get_parameter_int = parameters.guavaHostGetParameterInt,
    .get_parameter_bool = parameters.guavaHostGetParameterBool,
};
