import Foundation

/// Opaque handle to a single playing voice owned by an `AudioBackend`.
///
/// The high bits encode the backend's voice slot and the low bits a generation
/// counter, so a handle held after its slot was recycled is rejected rather than
/// silently controlling whatever now occupies the slot.
public struct AudioVoiceID: Hashable, Sendable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// The platform-specific sound-output sink behind `AudioEngine`.
///
/// `AudioEngine` owns every piece of gameplay policy — entity tracking,
/// spatial attenuation, play-on-awake, clip search paths. A backend only has to
/// load clips and turn playback requests into audible sound. Splitting the two
/// keeps the engine's audio *logic* identical on every platform; only the final
/// output path is swapped (`AVFoundation` on Apple, `SDL3` elsewhere, or a
/// silent stub). It also makes the logic unit-testable against a recording mock.
public protocol AudioBackend: AnyObject {
    /// Load and cache the clip at `url` under `name`. Returns `true` once the
    /// clip is available for playback (including when it was already loaded).
    func loadClip(name: String, url: URL) -> Bool

    /// Whether a clip with `name` is loaded and ready.
    func isClipLoaded(_ name: String) -> Bool

    /// Start a tracked voice for an already-loaded clip. Returns `nil` if the
    /// clip is missing or no voice could be allocated.
    func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID?

    /// Stop and release a voice. A stale or already-stopped handle is ignored.
    func stop(_ voice: AudioVoiceID)

    /// Whether the voice is still producing sound. A stale handle returns `false`.
    func isActive(_ voice: AudioVoiceID) -> Bool

    /// Update the gain of a live voice (used for per-tick distance attenuation).
    func setVolume(_ voice: AudioVoiceID, volume: Float)

    /// Dedicated single background-music channel (independent of the voice pool).
    func playBGM(clip: String, volume: Float, loop: Bool)
    func stopBGM()

    /// Stop every voice and the background-music channel (play-mode reset).
    func stopAll()

    /// Advance backend bookkeeping once per frame: refeed looping voices and
    /// reclaim voices that have finished. No-op for fully event-driven backends.
    func pump()
}

public extension AudioBackend {
    func pump() {}
}
