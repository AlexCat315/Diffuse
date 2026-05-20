import Foundation
import SceneRuntime

#if canImport(AVFoundation)
import AVFoundation

/// Lightweight audio engine backed by AVAudioEngine.
public final class AudioEngine: @unchecked Sendable {

    public static let shared = AudioEngine()

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
    private var awakened: Set<EntityID> = []
    private var playing: [EntityID: Int] = [:]

    private init() {
        engine.attach(bgmNode)
        engine.connect(bgmNode, to: engine.mainMixerNode, format: nil)
        for _ in 0..<sfxPoolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            sfxPool.append(PlayerSlot(node: node))
        }
        do { try engine.start() } catch {}
    }

    public func addSearchURL(_ url: URL) { searchURLs.append(url) }

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

    public func playSFX(_ clipName: String, volume: Float = 1, pitch: Float = 1) {
        guard let clip = preload(clipName) else { return }
        guard let idx = freeSlotIndex() else { return }
        let node = sfxPool[idx].node
        node.volume = volume
        node.rate = pitch
        node.scheduleBuffer(clip.buffer, completionHandler: nil)
        node.play()
    }

    public func playBGM(_ clipName: String, volume: Float = 1, loop: Bool = true) {
        guard let clip = preload(clipName) else { return }
        bgmNode.stop()
        bgmNode.volume = volume
        let opts: AVAudioPlayerNodeBufferOptions = loop ? .loops : []
        bgmNode.scheduleBuffer(clip.buffer, at: nil, options: opts, completionHandler: nil)
        bgmNode.play()
    }

    public func stopBGM() { bgmNode.stop() }

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
        let stale = playing.keys.filter { !activeIDs.contains($0) }
        for id in stale { stopEntity(id: id) }
    }

    public func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                           listenerPosition: SIMD3<Float> = .zero) {
        guard let clip = preload(source.clipName) else { return }
        if let idx = playing[id] { sfxPool[idx].node.stop() }
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

    public func resetPlaybackState() {
        for i in sfxPool.indices { sfxPool[i].node.stop() }
        bgmNode.stop()
        awakened.removeAll()
        playing.removeAll()
    }

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
        let falloff = max(0, 1 - dist / 50)
        let spatial = source.volume * falloff
        let flat = source.volume * (1 - source.spatialBlend)
        return flat + spatial * source.spatialBlend
    }
}

#else

/// No-op audio engine stub for platforms without AVFoundation.
public final class AudioEngine: @unchecked Sendable {
    public static let shared = AudioEngine()
    private init() {}
    public func addSearchURL(_ url: URL) {}
    @discardableResult public func preload(_ name: String) -> AudioClipResource? { nil }
    public func playSFX(_ clipName: String, volume: Float = 1, pitch: Float = 1) {}
    public func playBGM(_ clipName: String, volume: Float = 1, loop: Bool = true) {}
    public func stopBGM() {}
    public func tick(scene: SceneRuntime, listenerPosition: SIMD3<Float> = .zero) {}
    public func playEntity(id: EntityID, source: AudioSource, scene: SceneRuntime,
                           listenerPosition: SIMD3<Float> = .zero) {}
    public func stopEntity(id: EntityID) {}
    public func resetPlaybackState() {}
}

#endif
