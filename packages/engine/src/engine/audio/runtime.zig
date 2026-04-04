//! 音频系统运行时
//!
//! 提供高级音频管理 API，包括混音器、音效控制、3D 空间音效、
//! 以及与 ECS 系统的集成。

const std = @import("std");
const components = @import("../scene/components.zig");
const world_mod = @import("../scene/world.zig");
const soloud_bindings = @import("./soloud_bindings.zig");

// ============ 类型定义 ============

/// 音频剪辑 ID
pub const AudioClipHandle = u32;

/// 语音句柄（用于控制正在播放的声音）
pub const VoiceHandle = u32;

/// 混音器总线 ID
pub const BusId = enum(u8) {
    /// 主总线
    master = 0,
    /// 音乐总线
    music = 1,
    /// 音效总线
    sfx = 2,
};

/// 音频源播放状态
pub const PlayState = enum {
    stopped,
    playing,
    paused,
};

/// 音频剪辑信息
pub const AudioClipInfo = struct {
    name: []const u8,
    path: []const u8,
    duration_seconds: f32,
    channels: u8,
    sample_rate: u32,
};

/// 音频播放实例（运行中）
pub const PlayingInstance = struct {
    voice_handle: VoiceHandle,
    clip_id: AudioClipHandle,
    bus_id: BusId,
    pos: [3]f32 = .{ 0, 0, 0 },
    is_spatial: bool = false,
    looping: bool = false,
    entity_id: ?world_mod.EntityId = null,
    state: PlayState = .playing,
};

/// 混音器信息快照
pub const MixerStatus = struct {
    master_volume: f32,
    music_volume: f32,
    sfx_volume: f32,
    active_voices: u32,
    music_playing: u32,
    sfx_playing: u32,
};

// ============ 全局音频系统 ============

/// 全局音频运行时实例
var audio_system: ?*AudioRuntime = null;

/// 获取全局音频系统
pub fn get() !*AudioRuntime {
    if (audio_system) |sys| {
        return sys;
    }
    return error.AudioSystemNotInitialized;
}

/// 音频系统运行时
pub const AudioRuntime = struct {
    allocator: std.mem.Allocator,
    soloud: *soloud_bindings.Soloud,

    // 混音器总线
    bus_master: ?*soloud_bindings.Bus = null,
    bus_music: ?*soloud_bindings.Bus = null,
    bus_sfx: ?*soloud_bindings.Bus = null,

    // 加载的音频剪辑缓存
    clips: std.AutoHashMap(u32, AudioClip),
    next_clip_id: u32 = 1,

    // 路径 → clip ID 缓存（避免重复加载）
    clip_path_cache: std.StringHashMap(u32),

    // 正在播放的实例追踪
    playing_instances: std.ArrayList(PlayingInstance),

    // 混音器音量状态
    master_volume: f32 = 1.0,
    music_volume: f32 = 0.8,
    sfx_volume: f32 = 1.0,

    // 3D 音效参数
    listener_pos: [3]f32 = .{ 0, 0, 0 },
    listener_vel: [3]f32 = .{ 0, 0, 0 },
    sound_speed: f32 = 340.29, // 音速（米/秒）

    /// 初始化音频系统
    pub fn init(allocator: std.mem.Allocator) !*AudioRuntime {
        // 创建 SoLoud 引擎
        const soloud = try soloud_bindings.create();
        errdefer soloud_bindings.destroy(soloud);

        // 初始化 SoLoud
        soloud_bindings.init(soloud) catch |err| {
            std.log.warn("Failed to initialize SoLoud runtime: {}", .{err});
            return err;
        };

        // 创建混音器总线
        const bus_master = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_master);

        const bus_music = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_music);

        const bus_sfx = try soloud_bindings.busCreate();
        errdefer soloud_bindings.busDestroy(bus_sfx);

        // 分配运行时结构
        const runtime = try allocator.create(AudioRuntime);
        errdefer allocator.destroy(runtime);

        runtime.* = .{
            .allocator = allocator,
            .soloud = soloud,
            .bus_master = bus_master,
            .bus_music = bus_music,
            .bus_sfx = bus_sfx,
            .clips = std.AutoHashMap(u32, AudioClip).init(allocator),
            .clip_path_cache = std.StringHashMap(u32).init(allocator),
            .playing_instances = .empty,
        };

        audio_system = runtime;

        // 输出初始化成功消息
        std.debug.print("[INF] audio: Audio system initialized successfully\n", .{});

        return runtime;
    }

    /// 反初始化音频系统
    pub fn deinit(runtime: *AudioRuntime) void {
        // 停止所有播放
        soloud_bindings.stopAll(runtime.soloud);

        // 销毁所有音频剪辑
        var iter = runtime.clips.valueIterator();
        while (iter.next()) |clip| {
            clip.deinit(runtime.allocator);
        }
        runtime.clips.deinit();
        runtime.clip_path_cache.deinit();

        // 销毁混音器总线
        if (runtime.bus_sfx) |bus| soloud_bindings.busDestroy(bus);
        if (runtime.bus_music) |bus| soloud_bindings.busDestroy(bus);
        if (runtime.bus_master) |bus| soloud_bindings.busDestroy(bus);

        // 反初始化并销毁 SoLoud
        soloud_bindings.deinit(runtime.soloud);
        soloud_bindings.destroy(runtime.soloud);

        // 清理实例列表
        runtime.playing_instances.deinit(runtime.allocator);

        // 销毁运行时结构
        runtime.allocator.destroy(runtime);
        audio_system = null;

        std.debug.print("[INF] audio: Audio system deinitialized\n", .{});
    }

    /// 加载音频剪辑
    pub fn loadClip(
        runtime: *AudioRuntime,
        name: []const u8,
        path: [:0]const u8,
    ) !AudioClipHandle {
        const clip_id = runtime.next_clip_id;
        runtime.next_clip_id += 1;

        const clip = try AudioClip.load(runtime.allocator, name, path);
        try runtime.clips.put(clip_id, clip);

        std.debug.print("[INF] audio: Loaded audio clip '{s}' (id={d})\n", .{ name, clip_id });
        return clip_id;
    }

    /// 通过路径加载或获取已缓存的音频剪辑
    pub fn loadClipByPath(runtime: *AudioRuntime, path: [:0]const u8) !AudioClipHandle {
        if (runtime.clip_path_cache.get(path)) |existing_id| {
            if (runtime.clips.contains(existing_id)) {
                return existing_id;
            }
            _ = runtime.clip_path_cache.remove(path);
        }
        const clip_id = try runtime.loadClip(path, path);
        const clip = runtime.clips.get(clip_id).?;
        try runtime.clip_path_cache.put(clip.path, clip_id);
        return clip_id;
    }

    pub fn loadClipBySlice(runtime: *AudioRuntime, path: []const u8) !AudioClipHandle {
        if (path.len == 0) {
            return error.ClipNotFound;
        }
        if (runtime.clip_path_cache.get(path)) |existing_id| {
            if (runtime.clips.contains(existing_id)) {
                return existing_id;
            }
            _ = runtime.clip_path_cache.remove(path);
        }
        const path_z = try runtime.allocator.dupeZ(u8, path);
        defer runtime.allocator.free(path_z);
        return runtime.loadClipByPath(path_z);
    }

    /// 卸载音频剪辑
    pub fn unloadClip(runtime: *AudioRuntime, clip_id: AudioClipHandle) void {
        if (runtime.clips.fetchRemove(clip_id)) |kv| {
            _ = runtime.clip_path_cache.remove(kv.value.path);
            kv.value.deinit(runtime.allocator);
            std.debug.print("[INF] audio: Unloaded audio clip (id={d})\n", .{clip_id});
        }
    }

    /// 播放音效 2D（无空间音效）
    pub fn playClip2d(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        volume: f32,
        loop: bool,
    ) !VoiceHandle {
        return runtime.playClip2dForEntityOnBus(clip_id, volume, loop, null, .sfx);
    }

    pub fn playClip2dForEntity(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        volume: f32,
        loop: bool,
        entity_id: ?world_mod.EntityId,
    ) !VoiceHandle {
        return runtime.playClip2dForEntityOnBus(clip_id, volume, loop, entity_id, .sfx);
    }

    fn playClip2dForEntityOnBus(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        volume: f32,
        loop: bool,
        entity_id: ?world_mod.EntityId,
        bus_id: BusId,
    ) !VoiceHandle {
        const clip = runtime.clips.get(clip_id) orelse return error.ClipNotFound;

        const wav = clip.wav;
        soloud_bindings.wavSetLooping(wav, loop);
        soloud_bindings.wavSetAutoStop(wav, !loop);

        const voice = soloud_bindings.playEx(
            runtime.soloud,
            @ptrCast(wav),
            volume,
            0.0, // no pan
            false,
            @intFromEnum(bus_id),
        );

        const instance: PlayingInstance = .{
            .voice_handle = voice,
            .clip_id = clip_id,
            .bus_id = bus_id,
            .is_spatial = false,
            .looping = loop,
            .entity_id = entity_id,
        };
        try runtime.playing_instances.append(runtime.allocator, instance);

        return voice;
    }

    /// 播放音效 3D（带空间音效）
    pub fn playClip3d(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        pos: [3]f32,
        volume: f32,
        loop: bool,
    ) !VoiceHandle {
        return runtime.playClip3dForEntityOnBus(clip_id, pos, volume, loop, null, .sfx);
    }

    pub fn playClip3dForEntity(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        pos: [3]f32,
        volume: f32,
        loop: bool,
        entity_id: ?world_mod.EntityId,
    ) !VoiceHandle {
        return runtime.playClip3dForEntityOnBus(clip_id, pos, volume, loop, entity_id, .sfx);
    }

    fn playClip3dForEntityOnBus(
        runtime: *AudioRuntime,
        clip_id: AudioClipHandle,
        pos: [3]f32,
        volume: f32,
        loop: bool,
        entity_id: ?world_mod.EntityId,
        bus_id: BusId,
    ) !VoiceHandle {
        const clip = runtime.clips.get(clip_id) orelse return error.ClipNotFound;

        const wav = clip.wav;
        soloud_bindings.wavSetLooping(wav, loop);
        soloud_bindings.wavSetAutoStop(wav, !loop);

        const voice = soloud_bindings.play3dEx(
            runtime.soloud,
            @ptrCast(wav),
            pos[0],
            pos[1],
            pos[2],
            0,
            0,
            0, // velocity
            volume,
            false, // not paused
            @intFromEnum(bus_id),
        );

        // 配置 3D 参数
        soloud_bindings.set3dSourceMinMaxDistance(runtime.soloud, voice, 1.0, 100.0);
        soloud_bindings.set3dSourceAttenuation(runtime.soloud, voice, 0, 1.0);

        const instance: PlayingInstance = .{
            .voice_handle = voice,
            .clip_id = clip_id,
            .bus_id = bus_id,
            .pos = pos,
            .is_spatial = true,
            .looping = loop,
            .entity_id = entity_id,
        };
        try runtime.playing_instances.append(runtime.allocator, instance);

        return voice;
    }

    pub fn ensureClipHandle(runtime: *AudioRuntime, audio_src: *components.AudioSource) !AudioClipHandle {
        if (audio_src.clip_handle) |handle| {
            const clip_id = @intFromEnum(handle);
            if (runtime.clips.contains(clip_id)) {
                return clip_id;
            }
            audio_src.clip_handle = null;
        }

        const path = audio_src.clip_asset_path orelse return error.ClipNotFound;
        const clip_id = try runtime.loadClipBySlice(path);
        audio_src.clip_handle = @enumFromInt(clip_id);
        return clip_id;
    }

    pub fn isVoiceHandleActive(runtime: *AudioRuntime, voice_handle: ?VoiceHandle) bool {
        const resolved = voice_handle orelse return false;
        return soloud_bindings.isValidVoiceHandle(runtime.soloud, resolved);
    }

    pub fn playEntitySource(
        runtime: *AudioRuntime,
        entity_id: world_mod.EntityId,
        pos: [3]f32,
        audio_src: *components.AudioSource,
    ) !VoiceHandle {
        const clip_id = try runtime.ensureClipHandle(audio_src);
        const bus_id = runtimeBusId(audio_src.bus);

        if (audio_src._voice_handle) |voice_handle| {
            if (runtime.isVoiceHandleActive(voice_handle)) {
                runtime.stopVoice(voice_handle);
            }
        }

        const voice = if (audio_src.spatial)
            try runtime.playClip3dForEntityOnBus(clip_id, pos, audio_src.volume, audio_src.looping, entity_id, bus_id)
        else
            try runtime.playClip2dForEntityOnBus(clip_id, audio_src.volume, audio_src.looping, entity_id, bus_id);

        audio_src._voice_handle = voice;
        audio_src._is_playing = true;
        return voice;
    }

    /// 停止播放
    pub fn stopVoice(runtime: *AudioRuntime, voice_handle: VoiceHandle) void {
        soloud_bindings.stop(runtime.soloud, voice_handle);

        // 从实例列表中移除
        for (runtime.playing_instances.items, 0..) |instance, i| {
            if (instance.voice_handle == voice_handle) {
                _ = runtime.playing_instances.orderedRemove(i);
                break;
            }
        }
    }

    /// 停止所有播放
    pub fn stopAll(runtime: *AudioRuntime) void {
        soloud_bindings.stopAll(runtime.soloud);
        runtime.playing_instances.clearRetainingCapacity();
    }

    /// 设置语音音量
    pub fn setVoiceVolume(runtime: *AudioRuntime, voice_handle: VoiceHandle, volume: f32) void {
        soloud_bindings.setVolume(runtime.soloud, voice_handle, volume);
    }

    /// 暂停语音
    pub fn pauseVoice(runtime: *AudioRuntime, voice_handle: VoiceHandle, paused: bool) void {
        soloud_bindings.setPause(runtime.soloud, voice_handle, paused);
    }

    /// 设置混音器音量
    pub fn setMixerVolume(runtime: *AudioRuntime, bus_id: BusId, volume: f32) void {
        const bus = switch (bus_id) {
            .master => runtime.bus_master,
            .music => runtime.bus_music,
            .sfx => runtime.bus_sfx,
        };

        if (bus) |b| {
            soloud_bindings.busSetVolume(b, volume);
        }

        switch (bus_id) {
            .master => runtime.master_volume = volume,
            .music => runtime.music_volume = volume,
            .sfx => runtime.sfx_volume = volume,
        }
    }

    /// 获取混音器音量
    pub fn getMixerVolume(runtime: *AudioRuntime, bus_id: BusId) f32 {
        return switch (bus_id) {
            .master => runtime.master_volume,
            .music => runtime.music_volume,
            .sfx => runtime.sfx_volume,
        };
    }

    /// 设置 3D 监听器位置（相机位置）
    pub fn setListenerPosition(runtime: *AudioRuntime, pos: [3]f32, vel: [3]f32) void {
        runtime.listener_pos = pos;
        runtime.listener_vel = vel;

        soloud_bindings.set3dListenerParameters(
            runtime.soloud,
            pos[0],
            pos[1],
            pos[2],
            pos[0],
            pos[1],
            pos[2] - 1, // 向前看
            0,
            1,
            0, // 向上
        );
        soloud_bindings.set3dListenerVelocity(runtime.soloud, vel[0], vel[1], vel[2]);
    }

    /// 更新语音 3D 位置
    pub fn updateVoice3dPosition(
        runtime: *AudioRuntime,
        voice_handle: VoiceHandle,
        pos: [3]f32,
        vel: [3]f32,
    ) void {
        soloud_bindings.set3dSourcePosition(runtime.soloud, voice_handle, pos[0], pos[1], pos[2]);
        soloud_bindings.set3dSourceVelocity(runtime.soloud, voice_handle, vel[0], vel[1], vel[2]);
    }

    /// 从 ECS 世界更新音频（每帧调用）
    pub fn updateFromWorld(runtime: *AudioRuntime, world: *world_mod.World) void {
        runtime.stopOrphanedEntityVoices(world);
        runtime.cleanupStoppedVoices(world);

        if (findActiveListenerPosition(world)) |listener_pos| {
            runtime.setListenerPosition(listener_pos, .{ 0, 0, 0 });
        }

        for (world.entities.items) |*entity| {
            const audio_src = &(entity.audio_source orelse continue);
            const pos = entityAudioPosition(world, entity.id);

            const resolved_clip_id = runtime.ensureClipHandle(audio_src) catch null;
            const source_bus_id = runtimeBusId(audio_src.bus);

            var restart_requested = false;
            if (audio_src._voice_handle) |voice_handle| {
                if (!runtime.isVoiceHandleActive(voice_handle)) {
                    audio_src._voice_handle = null;
                    audio_src._is_playing = false;
                } else if (runtime.findPlayingInstance(voice_handle)) |instance| {
                    if (resolved_clip_id == null or
                        instance.clip_id != resolved_clip_id.? or
                        instance.bus_id != source_bus_id or
                        instance.is_spatial != audio_src.spatial or
                        instance.looping != audio_src.looping)
                    {
                        runtime.stopVoice(voice_handle);
                        audio_src._voice_handle = null;
                        audio_src._is_playing = false;
                        restart_requested = true;
                    }
                }
            }

            if (audio_src._voice_handle == null and resolved_clip_id != null) {
                if (restart_requested or shouldAutoStartSource(audio_src, true, false)) {
                    _ = runtime.playEntitySource(entity.id, pos, audio_src) catch continue;
                    if (audio_src.play_on_awake) {
                        audio_src._play_on_awake_consumed = true;
                    }
                }
            }

            if (audio_src._voice_handle) |voice_handle| {
                runtime.setVoiceVolume(voice_handle, audio_src.volume);
                runtime.ensureTrackedInstance(
                    voice_handle,
                    resolved_clip_id orelse @intFromEnum(audio_src.clip_handle orelse continue),
                    source_bus_id,
                    audio_src.spatial,
                    audio_src.looping,
                    entity.id,
                    pos,
                );
                if (audio_src.spatial) {
                    runtime.applySpatialSourceSettings(voice_handle, pos, audio_src);
                }
                audio_src._is_playing = runtime.isVoiceHandleActive(voice_handle);
            }
        }

        soloud_bindings.update3dAudio(runtime.soloud);
        runtime.cleanupStoppedVoices(world);
    }

    /// 获取混音器状态快照
    pub fn getMixerStatus(runtime: *AudioRuntime) MixerStatus {
        const active_voices = soloud_bindings.getActiveVoiceCount(runtime.soloud);

        var music_playing: u32 = 0;
        var sfx_playing: u32 = 0;
        for (runtime.playing_instances.items) |instance| {
            if (soloud_bindings.isValidVoiceHandle(runtime.soloud, instance.voice_handle)) {
                switch (instance.bus_id) {
                    .master => {},
                    .music => music_playing += 1,
                    .sfx => sfx_playing += 1,
                }
            }
        }

        return .{
            .master_volume = runtime.master_volume,
            .music_volume = runtime.music_volume,
            .sfx_volume = runtime.sfx_volume,
            .active_voices = active_voices,
            .music_playing = music_playing,
            .sfx_playing = sfx_playing,
        };
    }

    fn findPlayingInstance(runtime: *AudioRuntime, voice_handle: VoiceHandle) ?*PlayingInstance {
        for (runtime.playing_instances.items) |*instance| {
            if (instance.voice_handle == voice_handle) {
                return instance;
            }
        }
        return null;
    }

    fn ensureTrackedInstance(
        runtime: *AudioRuntime,
        voice_handle: VoiceHandle,
        clip_id: AudioClipHandle,
        bus_id: BusId,
        is_spatial: bool,
        looping: bool,
        entity_id: world_mod.EntityId,
        pos: [3]f32,
    ) void {
        if (runtime.findPlayingInstance(voice_handle)) |instance| {
            instance.clip_id = clip_id;
            instance.bus_id = bus_id;
            instance.is_spatial = is_spatial;
            instance.looping = looping;
            instance.entity_id = entity_id;
            instance.pos = pos;
            return;
        }

        runtime.playing_instances.append(runtime.allocator, .{
            .voice_handle = voice_handle,
            .clip_id = clip_id,
            .bus_id = bus_id,
            .pos = pos,
            .is_spatial = is_spatial,
            .looping = looping,
            .entity_id = entity_id,
        }) catch {};
    }

    fn applySpatialSourceSettings(
        runtime: *AudioRuntime,
        voice_handle: VoiceHandle,
        pos: [3]f32,
        audio_src: *const components.AudioSource,
    ) void {
        runtime.updateVoice3dPosition(voice_handle, pos, .{ 0, 0, 0 });
        soloud_bindings.set3dSourceMinMaxDistance(
            runtime.soloud,
            voice_handle,
            @max(0.0, audio_src.min_distance),
            @max(audio_src.min_distance, audio_src.max_distance),
        );
        soloud_bindings.set3dSourceAttenuation(runtime.soloud, voice_handle, 0, 1.0);
        soloud_bindings.set3dSourceDopplerFactor(runtime.soloud, voice_handle, @max(0.0, audio_src.doppler_factor));
    }

    fn stopOrphanedEntityVoices(runtime: *AudioRuntime, world: *world_mod.World) void {
        var index: usize = 0;
        while (index < runtime.playing_instances.items.len) {
            const instance = runtime.playing_instances.items[index];
            const entity_id = instance.entity_id orelse {
                index += 1;
                continue;
            };

            const entity = world.getEntity(entity_id);
            const keep_voice = if (entity) |resolved_entity|
                if (resolved_entity.audio_source) |audio_src|
                    audio_src._voice_handle != null and audio_src._voice_handle.? == instance.voice_handle
                else
                    false
            else
                false;

            if (!keep_voice) {
                soloud_bindings.stop(runtime.soloud, instance.voice_handle);
                _ = runtime.playing_instances.orderedRemove(index);
                continue;
            }

            index += 1;
        }
    }

    fn cleanupStoppedVoices(runtime: *AudioRuntime, world: *world_mod.World) void {
        var index: usize = 0;
        while (index < runtime.playing_instances.items.len) {
            const instance = runtime.playing_instances.items[index];
            if (!runtime.isVoiceHandleActive(instance.voice_handle)) {
                if (instance.entity_id) |entity_id| {
                    if (world.getEntity(entity_id)) |entity| {
                        if (entity.audio_source) |*audio_src| {
                            if (audio_src._voice_handle != null and audio_src._voice_handle.? == instance.voice_handle) {
                                audio_src._voice_handle = null;
                                audio_src._is_playing = false;
                            }
                        }
                    }
                }
                _ = runtime.playing_instances.orderedRemove(index);
                continue;
            }

            index += 1;
        }
    }
};

fn entityAudioPosition(world: *world_mod.World, entity_id: world_mod.EntityId) [3]f32 {
    if (world.worldTransform(entity_id)) |transform| {
        return transform.translation;
    }
    if (world.getEntityConst(entity_id)) |entity| {
        return entity.local_transform.translation;
    }
    return .{ 0, 0, 0 };
}

fn findActiveListenerPosition(world: *world_mod.World) ?[3]f32 {
    var first_enabled_listener: ?world_mod.EntityId = null;
    for (world.entities.items) |entity| {
        const listener = entity.audio_listener orelse continue;
        if (!listener.enabled) {
            continue;
        }
        if (first_enabled_listener == null) {
            first_enabled_listener = entity.id;
        }
        if (entity.camera) |camera| {
            if (camera.is_primary) {
                return entityAudioPosition(world, entity.id);
            }
        }
    }

    if (first_enabled_listener) |entity_id| {
        return entityAudioPosition(world, entity_id);
    }

    if (world.primaryCameraEntity()) |camera_id| {
        return entityAudioPosition(world, camera_id);
    }

    return null;
}

fn shouldAutoStartSource(audio_src: *const components.AudioSource, clip_ready: bool, voice_active: bool) bool {
    return clip_ready and
        audio_src.play_on_awake and
        !audio_src._play_on_awake_consumed and
        !voice_active;
}

fn runtimeBusId(bus: components.AudioBus) BusId {
    return switch (bus) {
        .master => .master,
        .music => .music,
        .sfx => .sfx,
    };
}

// ============ 音频剪辑 ============

/// 音频剪辑封装
pub const AudioClip = struct {
    name: []const u8,
    path: []const u8,
    wav: *soloud_bindings.Wav,

    /// 从文件加载音频剪辑
    pub fn load(
        allocator: std.mem.Allocator,
        name: []const u8,
        path: [:0]const u8,
    ) !AudioClip {
        const wav = try soloud_bindings.wavCreate();
        errdefer soloud_bindings.wavDestroy(wav);

        soloud_bindings.wavLoad(wav, path) catch |err| {
            std.debug.print("[ERROR] Failed to load audio file '{s}': {}\n", .{ path, err });
            return err;
        };

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        return .{
            .name = name_copy,
            .path = path_copy,
            .wav = wav,
        };
    }

    /// 销毁音频剪辑
    pub fn deinit(clip: *const AudioClip, allocator: std.mem.Allocator) void {
        soloud_bindings.wavDestroy(clip.wav);
        allocator.free(clip.name);
        allocator.free(clip.path);
    }
};

test "audio runtime prefers enabled listener over primary camera" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    _ = try world.createEntity(.{
        .name = "PrimaryCamera",
        .camera = .{ .is_primary = true },
        .local_transform = .{ .translation = .{ 1.0, 2.0, 3.0 } },
    });
    _ = try world.createEntity(.{
        .name = "AudioListener",
        .audio_listener = .{ .enabled = true },
        .local_transform = .{ .translation = .{ 4.0, 5.0, 6.0 } },
    });

    world.updateHierarchy();

    const listener_pos = findActiveListenerPosition(&world).?;
    try std.testing.expectEqualSlices(f32, &.{ 4.0, 5.0, 6.0 }, listener_pos[0..]);
}

test "audio runtime uses world transform for listener position" {
    var world = world_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const parent_id = try world.createEntity(.{
        .name = "Parent",
        .local_transform = .{ .translation = .{ 1.0, 0.0, 0.0 } },
    });
    _ = try world.createEntity(.{
        .name = "ChildListener",
        .parent = parent_id,
        .audio_listener = .{ .enabled = true },
        .local_transform = .{ .translation = .{ 0.0, 2.0, 0.0 } },
    });

    world.updateHierarchy();

    const listener_pos = findActiveListenerPosition(&world).?;
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 0.0 }, listener_pos[0..]);
}

test "audio source auto start is consumed once" {
    var audio_src = components.AudioSource{
        .play_on_awake = true,
    };

    try std.testing.expect(shouldAutoStartSource(&audio_src, true, false));

    audio_src._play_on_awake_consumed = true;
    try std.testing.expect(!shouldAutoStartSource(&audio_src, true, false));
    try std.testing.expect(!shouldAutoStartSource(&audio_src, false, false));
    try std.testing.expect(!shouldAutoStartSource(&audio_src, true, true));
}
