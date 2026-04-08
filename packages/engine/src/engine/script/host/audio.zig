// host/audio.zig — 音频系统桥接
const audio_mod = @import("../../audio/mod.zig");

pub fn guavaHostAudioLoadClip(_: ?*anyopaque, path_ptr: [*]const u8, path_len: usize) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    const path = path_ptr[0..path_len];
    const handle = runtime.loadClipBySlice(path) catch return 0;
    return handle;
}

pub fn guavaHostAudioPlay2d(_: ?*anyopaque, clip_id: u32, volume: f32, loop_flag: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return runtime.playClip2d(clip_id, volume, loop_flag != 0) catch return 0;
}

pub fn guavaHostAudioPlay3d(_: ?*anyopaque, clip_id: u32, x: f32, y: f32, z: f32, volume: f32, loop_flag: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return runtime.playClip3d(clip_id, .{ x, y, z }, volume, loop_flag != 0) catch return 0;
}

pub fn guavaHostAudioStop(_: ?*anyopaque, voice_handle: u32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.stopVoice(voice_handle);
}

pub fn guavaHostAudioSetVolume(_: ?*anyopaque, voice_handle: u32, volume: f32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.setVoiceVolume(voice_handle, volume);
}

pub fn guavaHostAudioPause(_: ?*anyopaque, voice_handle: u32, paused: u32) callconv(.c) void {
    const runtime = audio_mod.get() catch return;
    runtime.pauseVoice(voice_handle, paused != 0);
}

pub fn guavaHostAudioIsPlaying(_: ?*anyopaque, voice_handle: u32) callconv(.c) u32 {
    const runtime = audio_mod.get() catch return 0;
    return if (runtime.isVoiceHandleActive(voice_handle)) @as(u32, 1) else @as(u32, 0);
}
