import Foundation
import SIMDCompat
import SceneRuntime

/// High-level audio runtime: turns the scene's `AudioSource` / `AudioListener`
/// components into playback requests and drives spatial attenuation.
///
/// All of this logic is platform-neutral. The actual sound output is delegated
/// to an injected `AudioBackend` (`AVFoundation` on Apple, `SDL3` elsewhere, or
/// a silent stub), so the same gameplay behaviour runs on every platform and can
/// be unit-tested with a mock backend.
public final class AudioEngine: @unchecked Sendable {

    /// Process-wide instance used by the simulation thread. Created with the
    /// best backend available on the current platform.
    public static let shared = AudioEngine()

    private let backend: AudioBackend
    private let searchExtensions = ["wav", "mp3", "m4a", "aiff", "caf", "ogg"]

    private var searchURLs: [URL] = []
    private var loadedClips: Set<String> = []
    private var awakened: Set<EntityID> = []
    /// Tracked voices keyed by the entity that owns them.
    private var entityVoices: [EntityID: AudioVoiceID] = [:]

    /// Inject a specific backend (used by tests and embedders).
    public init(backend: AudioBackend) {
        self.backend = backend
    }

    private convenience init() {
        self.init(backend: AudioEngine.makeDefaultBackend())
    }

    /// SDL3 is the audio backend on every platform — it is already a core engine
    /// dependency (windowing / input), so there is no need for an Apple-only
    /// path. Falls back to silence only if no audio device can be opened.
    static func makeDefaultBackend() -> AudioBackend {
        #if canImport(CSDL3)
        if let sdl = SDL3AudioBackend() { return sdl }
        #endif
        return SilentAudioBackend()
    }

    // MARK: - Clip loading

    public func addSearchURL(_ url: URL) { searchURLs.append(url) }

    /// Ensure `name` is decoded and cached by the backend. Returns whether the
    /// clip is now available.
    @discardableResult
    public func preload(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if loadedClips.contains(name) { return true }
        for dir in searchURLs {
            for ext in searchExtensions {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path),
                   backend.loadClip(name: name, url: url) {
                    loadedClips.insert(name)
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Fire-and-forget playback

    public func playSFX(_ clipName: String, volume: Float = 1, pitch: Float = 1) {
        guard preload(clipName) else { return }
        _ = backend.play(clip: clipName, volume: volume, pitch: pitch, loop: false)
    }

    public func playBGM(_ clipName: String, volume: Float = 1, loop: Bool = true) {
        guard preload(clipName) else { return }
        backend.playBGM(clip: clipName, volume: volume, loop: loop)
    }

    public func stopBGM() { backend.stopBGM() }

    // MARK: - Scene-driven playback

    public func tick(scene: SceneRuntime, listenerPosition: SIMD3<Float> = .zero) {
        backend.pump()

        let resolvedListener = resolveListener(scene: scene, fallback: listenerPosition)

        let entities = scene.entities(with: AudioSource.self)
        var activeIDs: Set<EntityID> = []
        for id in entities {
            guard let source = scene.component(AudioSource.self, for: id),
                  !source.clipName.isEmpty else { continue }
            activeIDs.insert(id)

            if source.playOnAwake && !awakened.contains(id) {
                awakened.insert(id)
                playEntity(id: id, source: source, scene: scene, listenerPosition: resolvedListener)
            } else if let voice = entityVoices[id], backend.isActive(voice) {
                // Re-attenuate live voices so moving sources fade with distance.
                backend.setVolume(voice, volume: attenuatedVolume(
                    source: source, entityID: id, scene: scene, listenerPosition: resolvedListener))
            }
        }

        // Drop voices whose entity or component went away.
        let stale = entityVoices.keys.filter { !activeIDs.contains($0) }
        for id in stale { stopEntity(id: id) }
    }

    public func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                           listenerPosition: SIMD3<Float> = .zero) {
        guard preload(source.clipName) else { return }
        if let existing = entityVoices[id] { backend.stop(existing) }
        let volume = attenuatedVolume(source: source, entityID: id, scene: scene,
                                      listenerPosition: listenerPosition)
        guard let voice = backend.play(clip: source.clipName, volume: volume,
                                       pitch: source.pitch, loop: source.loop) else {
            entityVoices.removeValue(forKey: id)
            return
        }
        entityVoices[id] = voice
    }

    public func stopEntity(id: EntityID) {
        if let voice = entityVoices.removeValue(forKey: id) { backend.stop(voice) }
        awakened.remove(id)
    }

    /// Stop everything and forget which entities have awakened. Called when play
    /// mode stops so the next run restarts cleanly.
    public func resetPlaybackState() {
        backend.stopAll()
        awakened.removeAll()
        entityVoices.removeAll()
    }

    // MARK: - Attenuation (platform-neutral)

    private func resolveListener(scene: SceneRuntime, fallback: SIMD3<Float>) -> SIMD3<Float> {
        for id in scene.entities(with: AudioListener.self) {
            if let wt = scene.component(WorldTransform.self, for: id) {
                return wt.translation
            }
        }
        return fallback
    }

    private func attenuatedVolume(source: AudioSource, entityID: EntityID,
                                  scene: SceneRuntime, listenerPosition: SIMD3<Float>) -> Float {
        guard source.spatialBlend > 0,
              let wt = scene.component(WorldTransform.self, for: entityID) else {
            return source.volume
        }
        let dist = simd_length(wt.translation - listenerPosition)
        let falloff = max(0, 1 - dist / 50)
        let spatial = source.volume * falloff
        let flat = source.volume * (1 - source.spatialBlend)
        return flat + spatial * source.spatialBlend
    }
}
