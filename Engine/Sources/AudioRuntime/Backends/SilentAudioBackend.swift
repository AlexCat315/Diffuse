import Foundation

/// Audio sink that produces no sound. Used on platforms without a real backend.
///
/// It still reports clips as loadable (so the engine's policy code runs the same
/// path everywhere) and hands out valid, distinct voice handles that immediately
/// report inactive — the gameplay logic behaves identically, just inaudibly.
public final class SilentAudioBackend: AudioBackend, @unchecked Sendable {
    private var loaded: Set<String> = []
    private var nextVoice: UInt64 = 1

    public init() {}

    public func loadClip(name: String, url: URL) -> Bool {
        loaded.insert(name)
        return true
    }

    public func isClipLoaded(_ name: String) -> Bool { loaded.contains(name) }

    public func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID? {
        guard loaded.contains(clip) else { return nil }
        defer { nextVoice &+= 1 }
        return AudioVoiceID(raw: nextVoice)
    }

    public func stop(_ voice: AudioVoiceID) {}
    public func isActive(_ voice: AudioVoiceID) -> Bool { false }
    public func setVolume(_ voice: AudioVoiceID, volume: Float) {}
    public func playBGM(clip: String, volume: Float, loop: Bool) {}
    public func stopBGM() {}
    public func stopAll() {}
}
