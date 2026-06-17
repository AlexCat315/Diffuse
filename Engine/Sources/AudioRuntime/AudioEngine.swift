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

    private struct ResolvedListener {
        var position: SIMD3<Float>
        var masterVolume: Float
        var linearVelocity: SIMD3<Float>
    }

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
                playEntity(id: id, source: source, scene: scene, listener: resolvedListener)
            } else if let voice = entityVoices[id], backend.isActive(voice) {
                // Re-mix live voices so moving sources fade and pan with position.
                let mix = spatialMix(source: source, entityID: id, scene: scene,
                                     listener: resolvedListener)
                backend.setVolume(voice, volume: mix.volume)
                backend.setPan(voice, pan: mix.pan)
                backend.setPitch(voice, pitch: mix.pitch)
            }
        }

        // Drop voices whose entity or component went away.
        let stale = entityVoices.keys.filter { !activeIDs.contains($0) }
        for id in stale { stopEntity(id: id) }
    }

    public func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                           listenerPosition: SIMD3<Float> = .zero) {
        playEntity(id: id, source: source, scene: scene,
                   listener: ResolvedListener(position: listenerPosition, masterVolume: 1,
                                              linearVelocity: .zero))
    }

    private func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                            listener: ResolvedListener) {
        guard preload(source.clipName) else { return }
        if let existing = entityVoices[id] { backend.stop(existing) }
        let mix = spatialMix(source: source, entityID: id, scene: scene, listener: listener)
        guard let voice = backend.play(clip: source.clipName, volume: mix.volume,
                                       pitch: mix.pitch, loop: source.loop) else {
            entityVoices.removeValue(forKey: id)
            return
        }
        entityVoices[id] = voice
        backend.setPan(voice, pan: mix.pan)
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

    private func resolveListener(scene: SceneRuntime, fallback: SIMD3<Float>) -> ResolvedListener {
        for id in scene.entities(with: AudioListener.self) {
            guard let listener = scene.component(AudioListener.self, for: id) else { continue }
            let position = scene.component(WorldTransform.self, for: id)?.translation ?? fallback
            let velocity = scene.component(RigidBody.self, for: id)?.linearVelocity ?? .zero
            return ResolvedListener(position: position, masterVolume: listener.masterVolume,
                                    linearVelocity: velocity)
        }
        return ResolvedListener(position: fallback, masterVolume: 1, linearVelocity: .zero)
    }

    private func spatialMix(source: AudioSource, entityID: EntityID,
                            scene: SceneRuntime,
                            listener: ResolvedListener) -> (volume: Float, pan: Float, pitch: Float) {
        let spatialBlend = simd_clamp(source.spatialBlend, 0, 1)
        guard spatialBlend > 0,
              let wt = scene.component(WorldTransform.self, for: entityID) else {
            return (source.volume * listener.masterVolume, 0, max(0.01, source.pitch))
        }

        let offset = wt.translation - listener.position
        let dist = simd_length(offset)
        let falloff = max(0, 1 - dist / 50)
        let spatial = source.volume * falloff
        let flat = source.volume * (1 - spatialBlend)
        let volume = (flat + spatial * spatialBlend) * listener.masterVolume

        let pitch = dopplerPitch(sourcePitch: source.pitch, sourceVelocity:
            scene.component(RigidBody.self, for: entityID)?.linearVelocity ?? .zero,
            listenerVelocity: listener.linearVelocity, offset: offset, spatialBlend: spatialBlend)

        let horizontalDistance = sqrt(offset.x * offset.x + offset.z * offset.z)
        guard horizontalDistance > 0.0001 else { return (volume, 0, pitch) }
        let pan = simd_clamp(offset.x / horizontalDistance, -1, 1) * spatialBlend
        return (volume, pan, pitch)
    }

    private func dopplerPitch(sourcePitch: Float, sourceVelocity: SIMD3<Float>,
                              listenerVelocity: SIMD3<Float>, offset: SIMD3<Float>,
                              spatialBlend: Float) -> Float {
        let distance = simd_length(offset)
        guard distance > 0.0001 else { return max(0.01, sourcePitch) }
        let direction = offset / distance
        let speedOfSound: Float = 343
        let maxRadial = speedOfSound * 0.9
        let sourceRadial = simd_clamp(simd_dot(sourceVelocity, direction), -maxRadial, maxRadial)
        let listenerRadial = simd_clamp(simd_dot(listenerVelocity, direction), -maxRadial, maxRadial)
        let doppler = simd_clamp((speedOfSound + listenerRadial) / (speedOfSound + sourceRadial),
                                 0.5, 2)
        let blended = 1 + (doppler - 1) * spatialBlend
        return max(0.01, sourcePitch * blended)
    }
}
