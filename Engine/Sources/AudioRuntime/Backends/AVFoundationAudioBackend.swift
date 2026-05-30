#if canImport(AVFoundation)
import Foundation
import AVFoundation

/// Apple-platform audio sink backed by `AVAudioEngine`.
///
/// One `AVAudioPlayerNode` per pooled voice plus a dedicated background-music
/// node, all mixed through the engine's main mixer — the same topology the
/// runtime used before the backend split, now behind `AudioBackend`.
public final class AVFoundationAudioBackend: AudioBackend, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let bgmNode = AVAudioPlayerNode()

    private struct Slot {
        let node: AVAudioPlayerNode
        /// Bumped every (re)allocation so a stale `AudioVoiceID` is rejected.
        var generation: UInt32 = 0
    }

    private let voiceCount = 16
    private var voices: [Slot] = []
    private var clips: [String: AVAudioPCMBuffer] = [:]

    public init() {
        engine.attach(bgmNode)
        engine.connect(bgmNode, to: engine.mainMixerNode, format: nil)
        for _ in 0..<voiceCount {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: nil)
            voices.append(Slot(node: node))
        }
        do { try engine.start() } catch {}
    }

    // MARK: - Clips

    public func loadClip(name: String, url: URL) -> Bool {
        if clips[name] != nil { return true }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              (try? file.read(into: buffer)) != nil else { return false }
        buffer.frameLength = frameCount
        clips[name] = buffer
        return true
    }

    public func isClipLoaded(_ name: String) -> Bool { clips[name] != nil }

    // MARK: - Voices

    public func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID? {
        guard let buffer = clips[clip], let index = freeVoiceIndex() else { return nil }
        let node = voices[index].node
        node.volume = volume
        node.rate = pitch
        let opts: AVAudioPlayerNodeBufferOptions = loop ? .loops : []
        node.scheduleBuffer(buffer, at: nil, options: opts, completionHandler: nil)
        node.play()
        return makeVoiceID(index)
    }

    public func stop(_ voice: AudioVoiceID) {
        guard let index = matchingIndex(voice) else { return }
        voices[index].node.stop()
        voices[index].generation &+= 1   // invalidate the handle
    }

    public func isActive(_ voice: AudioVoiceID) -> Bool {
        guard let index = matchingIndex(voice) else { return false }
        return voices[index].node.isPlaying
    }

    public func setVolume(_ voice: AudioVoiceID, volume: Float) {
        guard let index = matchingIndex(voice) else { return }
        voices[index].node.volume = volume
    }

    // MARK: - Background music

    public func playBGM(clip: String, volume: Float, loop: Bool) {
        guard let buffer = clips[clip] else { return }
        bgmNode.stop()
        bgmNode.volume = volume
        let opts: AVAudioPlayerNodeBufferOptions = loop ? .loops : []
        bgmNode.scheduleBuffer(buffer, at: nil, options: opts, completionHandler: nil)
        bgmNode.play()
    }

    public func stopBGM() { bgmNode.stop() }

    public func stopAll() {
        for i in voices.indices {
            voices[i].node.stop()
            voices[i].generation &+= 1
        }
        bgmNode.stop()
    }

    // MARK: - Voice-id helpers

    private func freeVoiceIndex() -> Int? {
        for i in voices.indices where !voices[i].node.isPlaying { return i }
        return nil
    }

    private func makeVoiceID(_ index: Int) -> AudioVoiceID {
        var gen = voices[index].generation &+ 1
        if gen == 0 { gen = 1 }
        voices[index].generation = gen
        return AudioVoiceID(raw: (UInt64(index) << 32) | UInt64(gen))
    }

    private func matchingIndex(_ voice: AudioVoiceID) -> Int? {
        let index = Int(voice.raw >> 32)
        let gen = UInt32(truncatingIfNeeded: voice.raw)
        guard voices.indices.contains(index), voices[index].generation == gen, gen != 0 else { return nil }
        return index
    }
}
#endif
