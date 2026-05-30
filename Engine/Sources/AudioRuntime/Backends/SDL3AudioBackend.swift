// SDL3 audio sink — the cross-platform backend used where AVFoundation is not
// available (Windows / Linux). Gated to non-Apple so it never participates in
// the macOS build and cannot affect that toolchain.
//
// First cut: WAV playback via `SDL_LoadWAV`. Each voice is its own
// `SDL_AudioStream` bound to the default playback device; SDL mixes the bound
// streams. Looping is driven from `pump()`. mp3/ogg decoding is a follow-up
// (needs a decoder bridge); unsupported files simply fail to load.
#if !canImport(AVFoundation) && canImport(CSDL3)
import Foundation
import CSDL3

public final class SDL3AudioBackend: AudioBackend, @unchecked Sendable {

    /// A decoded WAV resident in memory. The buffer is SDL-allocated and lives
    /// for the backend's lifetime so looping voices can re-feed it cheaply.
    private struct Clip {
        var spec: SDL_AudioSpec
        var buffer: UnsafeMutablePointer<UInt8>
        var length: UInt32
    }

    private struct Voice {
        var stream: OpaquePointer
        var clip: String
        var loop: Bool
    }

    private var clips: [String: Clip] = [:]
    private var voices: [UInt64: Voice] = [:]
    private var nextID: UInt64 = 1
    private var bgm: Voice?

    public init?() {
        guard SDL_InitSubSystem(GUAVA_SDL_INIT_AUDIO) else { return nil }
    }

    deinit {
        for (_, v) in voices { SDL_DestroyAudioStream(v.stream) }
        if let bgm { SDL_DestroyAudioStream(bgm.stream) }
        for (_, c) in clips { SDL_free(c.buffer) }
        SDL_QuitSubSystem(GUAVA_SDL_INIT_AUDIO)
    }

    // MARK: - Clips

    public func loadClip(name: String, url: URL) -> Bool {
        if clips[name] != nil { return true }
        var spec = SDL_AudioSpec()
        var buffer: UnsafeMutablePointer<UInt8>? = nil
        var length: UInt32 = 0
        guard SDL_LoadWAV(url.path, &spec, &buffer, &length), let buffer else { return false }
        clips[name] = Clip(spec: spec, buffer: buffer, length: length)
        return true
    }

    public func isClipLoaded(_ name: String) -> Bool { clips[name] != nil }

    // MARK: - Voices

    public func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID? {
        guard var clipData = clips[clip],
              let stream = openStream(spec: &clipData.spec, gain: volume, pitch: pitch) else { return nil }
        guard feed(stream, clip: clipData) else {
            SDL_DestroyAudioStream(stream)
            return nil
        }
        _ = SDL_ResumeAudioStreamDevice(stream)

        let id = nextID
        nextID &+= 1
        voices[id] = Voice(stream: stream, clip: clip, loop: loop)
        return AudioVoiceID(raw: id)
    }

    public func stop(_ voice: AudioVoiceID) {
        guard let v = voices.removeValue(forKey: voice.raw) else { return }
        SDL_DestroyAudioStream(v.stream)
    }

    public func isActive(_ voice: AudioVoiceID) -> Bool {
        guard let v = voices[voice.raw] else { return false }
        return v.loop || SDL_GetAudioStreamQueued(v.stream) > 0
    }

    public func setVolume(_ voice: AudioVoiceID, volume: Float) {
        guard let v = voices[voice.raw] else { return }
        _ = SDL_SetAudioStreamGain(v.stream, volume)
    }

    public func pump() {
        var finished: [UInt64] = []
        for (id, v) in voices where SDL_GetAudioStreamQueued(v.stream) <= 0 {
            if v.loop, let clipData = clips[v.clip] {
                _ = feed(v.stream, clip: clipData)
            } else {
                finished.append(id)
            }
        }
        for id in finished {
            if let v = voices.removeValue(forKey: id) { SDL_DestroyAudioStream(v.stream) }
        }
        refeedBGMIfNeeded()
    }

    // MARK: - Background music

    public func playBGM(clip: String, volume: Float, loop: Bool) {
        stopBGM()
        guard var clipData = clips[clip],
              let stream = openStream(spec: &clipData.spec, gain: volume, pitch: 1),
              feed(stream, clip: clipData) else { return }
        _ = SDL_ResumeAudioStreamDevice(stream)
        bgm = Voice(stream: stream, clip: clip, loop: loop)
    }

    public func stopBGM() {
        if let bgm { SDL_DestroyAudioStream(bgm.stream) }
        bgm = nil
    }

    public func stopAll() {
        for (_, v) in voices { SDL_DestroyAudioStream(v.stream) }
        voices.removeAll()
        stopBGM()
    }

    // The BGM channel loops itself; the simulation tick calls `pump()` which only
    // walks `voices`, so re-feed the music here too if it has drained.
    private func refeedBGMIfNeeded() {
        guard let music = bgm, music.loop,
              SDL_GetAudioStreamQueued(music.stream) <= 0,
              let clipData = clips[music.clip] else { return }
        _ = feed(music.stream, clip: clipData)
    }

    // MARK: - Helpers

    private func openStream(spec: inout SDL_AudioSpec, gain: Float, pitch: Float) -> OpaquePointer? {
        guard let stream = SDL_OpenAudioDeviceStream(
            GUAVA_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil) else { return nil }
        _ = SDL_SetAudioStreamGain(stream, gain)
        if pitch != 1 { _ = SDL_SetAudioStreamFrequencyRatio(stream, pitch) }
        return stream
    }

    private func feed(_ stream: OpaquePointer, clip: Clip) -> Bool {
        SDL_PutAudioStreamData(stream, clip.buffer, Int32(clip.length))
    }
}
#endif
