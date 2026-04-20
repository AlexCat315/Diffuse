//! SoLoud C API 绑定包装
//!
//! 该模块提供对 SoLoud 音频引擎 C API 的 Zig 友好包装。
//! SoLoud 提供完整的 3D 空间音效、混音器和多种音频格式支持。

const std = @import("std");
const c = @import("c_soloud");

pub const Soloud = c.Soloud;
pub const AudioSource = c.AudioSource;
pub const Wav = c.Wav;
pub const Bus = c.Bus;

/// SoLoud 后端选项
const builtin = @import("builtin");

pub const Backend = enum(c_uint) {
    auto = c.SOLOUD_AUTO,
    sdl2 = c.SOLOUD_SDL2,
    miniaudio = c.SOLOUD_MINIAUDIO,
    openal = c.SOLOUD_OPENAL,
    coreaudio = c.SOLOUD_COREAUDIO,
    nosound = c.SOLOUD_NOSOUND,
};

const default_backend: Backend = if (builtin.os.tag == .macos) .coreaudio else .miniaudio;

/// SoLoud 初始化标记
pub const InitFlags = struct {
    pub const clip_roundoff: c_uint = c.SOLOUD_CLIP_ROUNDOFF;
    pub const enable_visualization: c_uint = c.SOLOUD_ENABLE_VISUALIZATION;
    pub const left_handed_3d: c_uint = c.SOLOUD_LEFT_HANDED_3D;
};

/// 错误代码
pub const Error = error{
    SoloudError,
    BackendNotFound,
    InvalidAudioFile,
};

/// 创建新的 SoLoud 引擎实例
pub fn create() !*Soloud {
    const soloud = c.Soloud_create() orelse return Error.SoloudError;
    return soloud;
}

/// 销毁 SoLoud 引擎实例
pub fn destroy(soloud: *Soloud) void {
    c.Soloud_destroy(soloud);
}

/// 初始化 SoLoud 引擎
/// 使用 MiniAudio 后端作为默认（跨平台支持）
pub fn init(soloud: *Soloud) !void {
    const result = c.Soloud_initEx(
        soloud,
        InitFlags.clip_roundoff,
        @intFromEnum(default_backend),
        0, // AUTO samplerate
        0, // AUTO buffer size
        2, // 2 channels (stereo)
    );
    if (result != 0) {
        // 输出 SoLoud 内部错误描述以便排查后端初始化失败原因
        const err_str = getErrorString(soloud, result);
        std.log.warn("SoLoud init failed (code {d}): {s}", .{ result, err_str });
        return Error.SoloudError;
    }
}

/// 反初始化 SoLoud 引擎
pub fn deinit(soloud: *Soloud) void {
    c.Soloud_deinit(soloud);
}

/// 获取错误字符串
pub fn getErrorString(soloud: *Soloud, error_code: c_int) [:0]const u8 {
    return std.mem.sliceTo(c.Soloud_getErrorString(soloud, error_code), 0);
}

/// 播放音频源
/// 返回语音句柄（用于后续控制）
pub fn play(soloud: *Soloud, audio_source: *AudioSource) u32 {
    return c.Soloud_play(soloud, audio_source);
}

/// 播放音频源（带音量和平移）
pub fn playEx(
    soloud: *Soloud,
    audio_source: *AudioSource,
    volume: f32,
    pan: f32,
    paused: bool,
    bus: u32,
) u32 {
    return c.Soloud_playEx(soloud, audio_source, volume, pan, @intFromBool(paused), bus);
}

/// 以 3D 位置播放音频源
pub fn play3d(
    soloud: *Soloud,
    audio_source: *AudioSource,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
) u32 {
    return c.Soloud_play3d(soloud, audio_source, pos_x, pos_y, pos_z);
}

/// 以 3D 位置播放音频源（带速度和音量）
pub fn play3dEx(
    soloud: *Soloud,
    audio_source: *AudioSource,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
    vel_x: f32,
    vel_y: f32,
    vel_z: f32,
    volume: f32,
    paused: bool,
    bus: u32,
) u32 {
    return c.Soloud_play3dEx(
        soloud,
        audio_source,
        pos_x,
        pos_y,
        pos_z,
        vel_x,
        vel_y,
        vel_z,
        volume,
        @intFromBool(paused),
        bus,
    );
}

/// 停止播放指定的语音
pub fn stop(soloud: *Soloud, voice_handle: u32) void {
    c.Soloud_stop(soloud, voice_handle);
}

/// 停止所有播放
pub fn stopAll(soloud: *Soloud) void {
    c.Soloud_stopAll(soloud);
}

/// 设置全局音量
pub fn setGlobalVolume(soloud: *Soloud, volume: f32) void {
    c.Soloud_setGlobalVolume(soloud, volume);
}

/// 获取全局音量
pub fn getGlobalVolume(soloud: *Soloud) f32 {
    return c.Soloud_getGlobalVolume(soloud);
}

/// 设置语音音量
pub fn setVolume(soloud: *Soloud, voice_handle: u32, volume: f32) void {
    c.Soloud_setVolume(soloud, voice_handle, volume);
}

/// 获取语音音量
pub fn getVolume(soloud: *Soloud, voice_handle: u32) f32 {
    return c.Soloud_getVolume(soloud, voice_handle);
}

/// 暂停语音
pub fn setPause(soloud: *Soloud, voice_handle: u32, paused: bool) void {
    c.Soloud_setPause(soloud, voice_handle, @intFromBool(paused));
}

/// 获取语音暂停状态
pub fn getPause(soloud: *Soloud, voice_handle: u32) bool {
    return c.Soloud_getPause(soloud, voice_handle) != 0;
}

/// 暂停所有语音
pub fn setPauseAll(soloud: *Soloud, paused: bool) void {
    c.Soloud_setPauseAll(soloud, @intFromBool(paused));
}

/// 设置 3D 监听器位置、方向和速度
pub fn set3dListenerParameters(
    soloud: *Soloud,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
    at_x: f32,
    at_y: f32,
    at_z: f32,
    up_x: f32,
    up_y: f32,
    up_z: f32,
) void {
    c.Soloud_set3dListenerParameters(
        soloud,
        pos_x,
        pos_y,
        pos_z,
        at_x,
        at_y,
        at_z,
        up_x,
        up_y,
        up_z,
    );
}

/// 设置 3D 监听器位置
pub fn set3dListenerPosition(soloud: *Soloud, pos_x: f32, pos_y: f32, pos_z: f32) void {
    c.Soloud_set3dListenerPosition(soloud, pos_x, pos_y, pos_z);
}

/// 设置 3D 监听器速度
pub fn set3dListenerVelocity(
    soloud: *Soloud,
    vel_x: f32,
    vel_y: f32,
    vel_z: f32,
) void {
    c.Soloud_set3dListenerVelocity(soloud, vel_x, vel_y, vel_z);
}

/// 设置 3D 音源参数
pub fn set3dSourceParameters(
    soloud: *Soloud,
    voice_handle: u32,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
) void {
    c.Soloud_set3dSourceParameters(soloud, voice_handle, pos_x, pos_y, pos_z);
}

/// 设置 3D 音源位置
pub fn set3dSourcePosition(
    soloud: *Soloud,
    voice_handle: u32,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
) void {
    c.Soloud_set3dSourcePosition(soloud, voice_handle, pos_x, pos_y, pos_z);
}

/// 设置 3D 音源速度（用于多普勒效应）
pub fn set3dSourceVelocity(
    soloud: *Soloud,
    voice_handle: u32,
    vel_x: f32,
    vel_y: f32,
    vel_z: f32,
) void {
    c.Soloud_set3dSourceVelocity(soloud, voice_handle, vel_x, vel_y, vel_z);
}

/// 设置 3D 音源最小和最大距离
pub fn set3dSourceMinMaxDistance(
    soloud: *Soloud,
    voice_handle: u32,
    min_distance: f32,
    max_distance: f32,
) void {
    c.Soloud_set3dSourceMinMaxDistance(soloud, voice_handle, min_distance, max_distance);
}

/// 设置 3D 音源衰减（距离衰减模型）
pub fn set3dSourceAttenuation(
    soloud: *Soloud,
    voice_handle: u32,
    attenuation_model: u32,
    attenuation_rolloff_factor: f32,
) void {
    c.Soloud_set3dSourceAttenuation(
        soloud,
        voice_handle,
        attenuation_model,
        attenuation_rolloff_factor,
    );
}

/// 设置 3D 音源多普勒因子
pub fn set3dSourceDopplerFactor(
    soloud: *Soloud,
    voice_handle: u32,
    doppler_factor: f32,
) void {
    c.Soloud_set3dSourceDopplerFactor(soloud, voice_handle, doppler_factor);
}

/// 更新 3D 音频（必须在每帧调用以更新监听器和音源位置）
pub fn update3dAudio(soloud: *Soloud) void {
    c.Soloud_update3dAudio(soloud);
}

/// 获取活跃语音数量
pub fn getActiveVoiceCount(soloud: *Soloud) u32 {
    return c.Soloud_getActiveVoiceCount(soloud);
}

/// 检查语音句柄是否有效
pub fn isValidVoiceHandle(soloud: *Soloud, voice_handle: u32) bool {
    return c.Soloud_isValidVoiceHandle(soloud, voice_handle) != 0;
}

// ============ WAV 音频源 ============

/// 创建新的 WAV 音频源
pub fn wavCreate() !*Wav {
    const wav = c.Wav_create() orelse return Error.SoloudError;
    return wav;
}

/// 销毁 WAV 音频源
pub fn wavDestroy(wav: *Wav) void {
    c.Wav_destroy(wav);
}

/// 从文件路径加载 WAV 音频
pub fn wavLoad(wav: *Wav, filename: [:0]const u8) !void {
    const result = c.Wav_load(wav, filename.ptr);
    if (result != 0) {
        return Error.InvalidAudioFile;
    }
}

/// 设置 WAV 音频循环
pub fn wavSetLooping(wav: *Wav, looping: bool) void {
    c.Wav_setLooping(wav, @intFromBool(looping));
}

/// 设置 WAV 音频自动停止
pub fn wavSetAutoStop(wav: *Wav, auto_stop: bool) void {
    c.Wav_setAutoStop(wav, @intFromBool(auto_stop));
}

/// 停止 WAV 音频
pub fn wavStop(wav: *Wav) void {
    c.Wav_stop(wav);
}

// ============ Bus（混音器） ============

/// 创建新的混音器总线
pub fn busCreate() !*Bus {
    const bus = c.Bus_create() orelse return Error.SoloudError;
    return bus;
}

/// 销毁混音器总线
pub fn busDestroy(bus: *Bus) void {
    c.Bus_destroy(bus);
}

/// 通过总线播放音频源
pub fn busPlay(bus: *Bus, audio_source: *AudioSource) u32 {
    return c.Bus_play(bus, audio_source);
}

/// 通过总线播放音频源（带音量和平移）
pub fn busPlayEx(
    bus: *Bus,
    audio_source: *AudioSource,
    volume: f32,
    pan: f32,
    paused: bool,
) u32 {
    return c.Bus_playEx(bus, audio_source, volume, pan, @intFromBool(paused));
}

/// 设置总线音量
pub fn busSetVolume(bus: *Bus, volume: f32) void {
    c.Bus_setVolume(bus, volume);
}

/// 设置总线循环
pub fn busSetLooping(bus: *Bus, looping: bool) void {
    c.Bus_setLooping(bus, @intFromBool(looping));
}

/// 获取总线活跃语音数量
pub fn busGetActiveVoiceCount(bus: *Bus) u32 {
    return c.Bus_getActiveVoiceCount(bus);
}
