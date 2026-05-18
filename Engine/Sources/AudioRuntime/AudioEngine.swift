import AVFoundation
import Foundation
import SceneRuntime

/// Lightweight audio engine backed by AVAudioEngine.
///
/// Owns a pool of player nodes (SFX) and a dedicated BGM node.
/// Call `tick(scene:listenerPosition:)` each frame to drive playOnAwake
/// and spatial positioning.
public final class AudioEngine: @unchecked Sendable {

    // MARK: - Public

    public static let shared = AudioEngine()

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private let bgmNode = AVAudioPlayerNode()

    private struct PlayerSlot {
        let node: AVAudioPlayerNode
        var entityID: EntityID?
        var clipName: String = ""
    }

    private let sfxPoolSize = 16
    private var sfxPool: [PlayerSlot] = []

    private var clips: [String: AudioClipResource] = [:]
    private var searchURLs: [URL] = []

    // Track which entities are already playing so playOnAwake only fires once.
    private var awakened: Set<EntityID> = []
    // Track playing state so we can stop when component is removed.
    private var playing: [EntityID: Int] = [:]   // entityID → pool index

    // MARK: - Init

    private init() {
        engine.attach(bgmNode)
        engine.connect(bgmNode, to: engine.mainMixerNode, format: nil)

        for _ in 0..<sfxPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            sfxPool.append(PlayerSlot(node: node))
        }

        do { try engine.start() } catch {
            // Audio not critical; editor continues without sound.
        }
    }

    // MARK: - Asset management

    /// Register directories to search for audio files.
    public func addSearchURL(_ url: URL) {
        searchURLs.append(url)
    }

    /// Preload a clip by name. Safe to call multiple times.
    @discardableResult
    public func preload(_ name: String) -> AudioClipResource? {
        if let existing = clips[name] { return existing }
        let extensions = ["wav", "mp3", "m4a", "aiff", "caf"]
        for dir in searchURLs {
            for ext in extensions {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if let clip = AudioClipResource.load(name: name, url: url) {
                    clips[name] = clip
                    return clip
                }
            }
        }
        return nil
    }

    // MARK: - Immediate API (non-spatial)

    /// Play a one-shot sound effect immediately, no entity binding.
    public func playSFX(_ clipName: String, volume: Float = 1, pitch: Float = 1) {
        guard let clip = preload(clipName) else { return }
        guard let idx = freeSlotIndex() else { return }
        let node = sfxPool[idx].node
        node.volume = volume
        node.rate = pitch
        node.scheduleBuffer(clip.buffer, completionHandler: nil)
        node.play()
    }

    /// Play background music (loops by default).
    public func playBGM(_ clipName: String, volume: Float = 1, loop: Bool = true) {
        guard let clip = preload(clipName) else { return }
        bgmNode.stop()
        bgmNode.volume = volume
        let opts: AVAudioPlayerNodeBufferOptions = loop ? .loops : []
        bgmNode.scheduleBuffer(clip.buffer, at: nil, options: opts, completionHandler: nil)
        bgmNode.play()
    }

    public func stopBGM() { bgmNode.stop() }

    // MARK: - Scene-driven tick

    /// Called each frame by EngineCore to drive `playOnAwake` and spatial audio.
    public func tick(scene: SceneRuntime, listenerPosition: SIMD3<Float> = .zero) {
        let entities = scene.entities(with: AudioSource.self)

        var activeIDs: Set<EntityID> = []
        for id in entities {
            guard let source = scene.component(AudioSource.self, for: id) else { continue }
            guard !source.clipName.isEmpty else { continue }
            activeIDs.insert(id)

            if source.playOnAwake && !awakened.contains(id) {
                awakened.insert(id)
                playEntity(id: id, source: source, scene: scene, listenerPosition: listenerPosition)
            }
        }

        // Stop nodes whose entity no longer has an AudioSource or left scene.
        let stale = playing.keys.filter { !activeIDs.contains($0) }
        for id in stale { stopEntity(id: id) }
    }

    // MARK: - Entity play / stop

    public func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                           listenerPosition: SIMD3<Float> = .zero) {
        guard let clip = preload(source.clipName) else { return }
        if let idx = playing[id] {
            sfxPool[idx].node.stop()
        }
        guard let idx = freeSlotIndex() else { return }
        sfxPool[idx].entityID = id
        sfxPool[idx].clipName = source.clipName

        let node = sfxPool[idx].node
        node.volume = attenuatedVolume(source: source, entityID: id, scene: scene,
                                       listenerPosition: listenerPosition)
        node.rate = source.pitch
        let opts: AVAudioPlayerNodeBufferOptions = source.loop ? .loops : []
        node.scheduleBuffer(clip.buffer, at: nil, options: opts, completionHandler: nil)
        node.play()
        playing[id] = idx
    }

    public func stopEntity(id: EntityID) {
        guard let idx = playing[id] else { return }
        sfxPool[idx].node.stop()
        sfxPool[idx].entityID = nil
        playing.removeValue(forKey: id)
        awakened.remove(id)
    }

    /// Reset awakened state (called when play mode stops so clips re-fire on next play).
    public func resetPlaybackState() {
        for i in sfxPool.indices { sfxPool[i].node.stop() }
        bgmNode.stop()
        awakened.removeAll()
        playing.removeAll()
    }

    // MARK: - Helpers

    private func freeSlotIndex() -> Int? {
        for i in sfxPool.indices {
            if sfxPool[i].entityID == nil || !sfxPool[i].node.isPlaying {
                sfxPool[i].entityID = nil
                return i
            }
        }
        return nil
    }

    private func attenuatedVolume(source: AudioSource, entityID: EntityID,
                                  scene: SceneRuntime, listenerPosition: SIMD3<Float>) -> Float {
        guard source.spatialBlend > 0,
              let wt = scene.component(WorldTransform.self, for: entityID) else {
            return source.volume
        }
        let dist = simd_length(wt.translation - listenerPosition)
        // Simple inverse-distance falloff starting at 1 m, full at 0, silent at 50 m.
        let falloff = max(0, 1 - dist / 50)
        let spatial = source.volume * falloff
        let flat = source.volume * (1 - source.spatialBlend)
        return flat + spatial * source.spatialBlend
    }
}
