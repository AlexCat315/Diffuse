import Testing
import Foundation
import SIMDCompat
import SceneRuntime
@testable import AudioRuntime

/// Records every request the facade makes so the platform-neutral audio logic
/// (entity tracking, play-on-awake, spatial attenuation, reset) can be asserted
/// without any real sound device.
private final class MockAudioBackend: AudioBackend, @unchecked Sendable {
    struct PlayCall { let clip: String; var volume: Float; let pitch: Float; let loop: Bool }

    private(set) var loaded: Set<String> = []
    private(set) var plays: [AudioVoiceID: PlayCall] = [:]
    private(set) var playOrder: [AudioVoiceID] = []
    private(set) var stopped: [AudioVoiceID] = []
    private(set) var bgmPlays: [String] = []
    private(set) var stopAllCount = 0
    private(set) var pumpCount = 0

    private var nextRaw: UInt64 = 1
    private var active: Set<AudioVoiceID> = []

    func loadClip(name: String, url: URL) -> Bool { loaded.insert(name); return true }
    func isClipLoaded(_ name: String) -> Bool { loaded.contains(name) }

    func play(clip: String, volume: Float, pitch: Float, loop: Bool) -> AudioVoiceID? {
        let id = AudioVoiceID(raw: nextRaw); nextRaw &+= 1
        plays[id] = PlayCall(clip: clip, volume: volume, pitch: pitch, loop: loop)
        playOrder.append(id)
        active.insert(id)
        return id
    }
    func stop(_ voice: AudioVoiceID) { stopped.append(voice); active.remove(voice) }
    func isActive(_ voice: AudioVoiceID) -> Bool { active.contains(voice) }
    func setVolume(_ voice: AudioVoiceID, volume: Float) { plays[voice]?.volume = volume }
    func playBGM(clip: String, volume: Float, loop: Bool) { bgmPlays.append(clip) }
    func stopBGM() {}
    func stopAll() { stopAllCount += 1; active.removeAll() }
    func pump() { pumpCount += 1 }

    var lastPlay: PlayCall? { playOrder.last.flatMap { plays[$0] } }
}

@Suite("AudioEngine")
struct AudioEngineTests {

    /// Create real (empty) clip files so the facade's on-disk search succeeds;
    /// the mock backend then "loads" them without touching a decoder.
    private func makeClipDir(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-audio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(name).wav").path,
                                           contents: Data())
        }
        return dir
    }

    private func worldTransform(_ p: SIMD3<Float>) -> WorldTransform {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return WorldTransform(matrix: m)
    }

    @Test("playOnAwake triggers exactly one voice and not again next tick")
    func playOnAwakeOnce() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let e = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", playOnAwake: true, spatialBlend: 0), for: e)

        engine.tick(scene: scene)
        #expect(mock.plays.count == 1)
        #expect(mock.lastPlay?.clip == "beep")
        #expect(mock.pumpCount == 1)

        engine.tick(scene: scene)
        #expect(mock.plays.count == 1, "an awakened source must not retrigger")
        #expect(mock.pumpCount == 2)
    }

    @Test("a source that disappears stops its voice")
    func staleVoiceStopped() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let e = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", playOnAwake: true, spatialBlend: 0), for: e)
        engine.tick(scene: scene)
        #expect(mock.stopped.isEmpty)

        // Clear the clip name: the entity is no longer an active source.
        _ = scene.setComponent(AudioSource(clipName: "", playOnAwake: true), for: e)
        engine.tick(scene: scene)
        #expect(mock.stopped.count == 1)
    }

    @Test("spatial sources attenuate with listener distance")
    func spatialAttenuation() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let listener = scene.createEntity()
        _ = scene.setComponent(AudioListener(), for: listener)
        _ = scene.setComponent(worldTransform(.zero), for: listener)

        let source = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", volume: 1, playOnAwake: true, spatialBlend: 1), for: source)
        _ = scene.setComponent(worldTransform(SIMD3<Float>(25, 0, 0)), for: source)  // half the 50u falloff range

        engine.tick(scene: scene)
        let v = try #require(mock.lastPlay?.volume)
        #expect(abs(v - 0.5) < 0.01, "expected ~0.5 at half falloff range, got \(v)")
    }

    @Test("2D sources ignore distance")
    func flatSourceNotAttenuated() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let source = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", volume: 0.8, playOnAwake: true, spatialBlend: 0), for: source)
        _ = scene.setComponent(worldTransform(SIMD3<Float>(1000, 0, 0)), for: source)

        engine.tick(scene: scene)
        #expect(mock.lastPlay?.volume == 0.8)
    }

    @Test("resetPlaybackState stops everything and re-arms play-on-awake")
    func resetReArms() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let e = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", playOnAwake: true, spatialBlend: 0), for: e)

        engine.tick(scene: scene)
        #expect(mock.plays.count == 1)

        engine.resetPlaybackState()
        #expect(mock.stopAllCount == 1)

        engine.tick(scene: scene)
        #expect(mock.plays.count == 2, "after reset the source should awaken again")
    }

    @Test("missing clip files never reach the backend")
    func missingClipNotLoaded() {
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-audio-nonexistent-\(UUID().uuidString)"))

        var scene = SceneRuntime()
        let e = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "ghost", playOnAwake: true), for: e)

        engine.tick(scene: scene)
        #expect(mock.plays.isEmpty)
        #expect(mock.loaded.isEmpty)
    }
}
