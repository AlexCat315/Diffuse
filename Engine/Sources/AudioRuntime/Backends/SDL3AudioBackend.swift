#if canImport(CSDL3)
import Foundation
import MediaRuntime
import GuavaLogging

// SDL3 is an implementation detail of this backend. The access level is load
// bearing: it confines SDL declarations to this file, so any other file in
// AudioRuntime that writes `import CSDL3` — or uses an SDL symbol without
// importing — fails to compile.
private import CSDL3

/// FFmpeg supplies resident stereo PCM; SDL owns output devices and resampling.
/// A short queue permits moving-source pan changes without reloading clips.
public final class SDL3AudioBackend: AudioBackend, @unchecked Sendable {
    private struct Voice {
        let stream: OpaquePointer
        let clip: String
        let loop: Bool
        var offset = 0
        var pan: Float = 0
        var ended = false
    }
    private var clips: [String: PCMBuffer] = [:]
    private var voices: [UInt64: Voice] = [:]
    private var nextID: UInt64 = 1
    private var bgm: Voice?
    private let chunkFrames = 2048

    public init?() {
        guard SDL_InitSubSystem(GUAVA_SDL_INIT_AUDIO) else { return nil }
    }
    deinit {
        stopAll()
        SDL_QuitSubSystem(GUAVA_SDL_INIT_AUDIO)
    }

    public func loadClip(name: String, url: URL) -> Bool {
        if clips[name] != nil { return true }
        do { clips[name] = try AudioFile.decode(url); return true }
        catch {
            LogSystem.logger("com.guava.audio").error("Audio decoding failed", metadata: ["file": "\(url.lastPathComponent)", "error": "\(error)"])
            return false
        }
    }
    public func isClipLoaded(_ name: String) -> Bool { clips[name] != nil }
    public func unloadAllClips() { stopAll(); clips.removeAll(keepingCapacity: true) }

    public func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID? {
        guard let voice = makeVoice(clip: clip, volume: volume, pitch: pitch, loop: loop) else { return nil }
        let id = nextID
        nextID &+= 1
        voices[id] = voice
        return AudioVoiceID(raw: id)
    }
    public func stop(_ voice: AudioVoiceID) {
        if let value = voices.removeValue(forKey: voice.raw) { SDL_DestroyAudioStream(value.stream) }
    }
    public func isActive(_ voice: AudioVoiceID) -> Bool {
        guard let value = voices[voice.raw] else { return false }
        return !value.ended || queued(value.stream) > 0
    }
    public func setVolume(_ voice: AudioVoiceID, volume: Float) {
        if let value = voices[voice.raw] { _ = SDL_SetAudioStreamGain(value.stream, volume.isFinite ? max(0, volume) : 0) }
    }
    public func setPitch(_ voice: AudioVoiceID, pitch: Float) {
        if let value = voices[voice.raw] { _ = SDL_SetAudioStreamFrequencyRatio(value.stream, pitch.isFinite ? min(100, max(0.01, pitch)) : 1) }
    }
    public func setPan(_ voice: AudioVoiceID, pan: Float) {
        guard var value = voices[voice.raw] else { return }
        value.pan = pan.isFinite ? min(1, max(-1, pan)) : 0
        voices[voice.raw] = value
    }
    public func pump() {
        for id in Array(voices.keys) {
            guard var voice = voices[id] else { continue }
            if !feed(&voice) || (voice.ended && queued(voice.stream) <= 0) {
                SDL_DestroyAudioStream(voice.stream)
                voices.removeValue(forKey: id)
            } else { voices[id] = voice }
        }
        if var music = bgm {
            if !feed(&music) || (music.ended && queued(music.stream) <= 0) { stopBGM() }
            else { bgm = music }
        }
    }
    public func playBGM(clip: String, volume: Float, loop: Bool) {
        stopBGM()
        bgm = makeVoice(clip: clip, volume: volume, pitch: 1, loop: loop)
    }
    public func stopBGM() {
        if let bgm { SDL_DestroyAudioStream(bgm.stream) }
        bgm = nil
    }
    public func stopAll() {
        for voice in voices.values { SDL_DestroyAudioStream(voice.stream) }
        voices.removeAll()
        stopBGM()
    }

    private func makeVoice(clip: String, volume: Float, pitch: Float, loop: Bool) -> Voice? {
        guard clips[clip] != nil else { return nil }
        var spec = SDL_AudioSpec()
        spec.freq = 48000; spec.channels = 2; spec.format = SDL_AUDIO_F32
        guard let stream = SDL_OpenAudioDeviceStream(GUAVA_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil) else { return nil }
        _ = SDL_SetAudioStreamGain(stream, volume.isFinite ? max(0, volume) : 0)
        _ = SDL_SetAudioStreamFrequencyRatio(stream, pitch.isFinite ? min(100, max(0.01, pitch)) : 1)
        var voice = Voice(stream: stream, clip: clip, loop: loop)
        guard feed(&voice), SDL_ResumeAudioStreamDevice(stream) else { SDL_DestroyAudioStream(stream); return nil }
        return voice
    }
    private func queued(_ stream: OpaquePointer) -> Int32 {
        max(0, SDL_GetAudioStreamQueued(stream)) + max(0, SDL_GetAudioStreamAvailable(stream))
    }
    private func feed(_ voice: inout Voice) -> Bool {
        guard let clip = clips[voice.clip] else { return false }
        while !voice.ended && queued(voice.stream) < Int32(chunkFrames * 2 * MemoryLayout<Float>.size) {
            let count = min(chunkFrames, clip.frameCount - voice.offset)
            var samples = [Float](repeating: 0, count: count * 2)
            clip.samples.withUnsafeBytes { bytes in
                // Data's base address need not be Float-aligned.
                let start = voice.offset * 2 * MemoryLayout<Float>.size
                samples.withUnsafeMutableBytes { destination in
                    destination.copyBytes(from: bytes[start..<(start + destination.count)])
                }
            }
            let left: Float = voice.pan > 0 ? 1 - voice.pan : 1
            let right: Float = voice.pan < 0 ? 1 + voice.pan : 1
            for frame in 0..<count { samples[frame * 2] *= left; samples[frame * 2 + 1] *= right }
            let accepted = samples.withUnsafeBytes { SDL_PutAudioStreamData(voice.stream, $0.baseAddress, Int32($0.count)) }
            guard accepted else { return false }
            voice.offset += count
            if voice.offset == clip.frameCount {
                if voice.loop { voice.offset = 0 }
                else { voice.ended = true; _ = SDL_FlushAudioStream(voice.stream) }
            }
        }
        return true
    }
}
#endif
