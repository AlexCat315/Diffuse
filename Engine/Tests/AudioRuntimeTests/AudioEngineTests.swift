import Testing
import Foundation
import SIMDCompat
import SceneRuntime
@testable import AudioRuntime

/// Records every request the facade makes so the platform-neutral audio logic
/// (entity tracking, play-on-awake, spatial attenuation, reset) can be asserted
/// without any real sound device.
private final class MockAudioBackend: AudioBackend, @unchecked Sendable {
    struct PlayCall { let clip: String; var volume: Float; var pitch: Float; let loop: Bool }

    private(set) var loaded: Set<String> = []
    private(set) var loadedURLs: [String: URL] = [:]
    private(set) var unloadAllClipsCount = 0
    private(set) var plays: [AudioVoiceID: PlayCall] = [:]
    private(set) var playOrder: [AudioVoiceID] = []
    private(set) var pans: [AudioVoiceID: Float] = [:]
    private(set) var stopped: [AudioVoiceID] = []
    private(set) var bgmPlays: [String] = []
    private(set) var stopAllCount = 0
    private(set) var pumpCount = 0

    private var nextRaw: UInt64 = 1
    private var active: Set<AudioVoiceID> = []

    func loadClip(name: String, url: URL) -> Bool {
        guard !loaded.contains(name) else { return true }
        loaded.insert(name)
        loadedURLs[name] = url
        return true
    }
    func isClipLoaded(_ name: String) -> Bool { loaded.contains(name) }
    func unloadAllClips() {
        stopAll()
        unloadAllClipsCount += 1
        loaded.removeAll(keepingCapacity: true)
        loadedURLs.removeAll(keepingCapacity: true)
    }

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
    func setPan(_ voice: AudioVoiceID, pan: Float) { pans[voice] = pan }
    func setPitch(_ voice: AudioVoiceID, pitch: Float) { plays[voice]?.pitch = pitch }
    func playBGM(clip: String, volume: Float, loop: Bool) { bgmPlays.append(clip) }
    func stopBGM() {}
    func stopAll() { stopAllCount += 1; active.removeAll() }
    func pump() { pumpCount += 1 }

    var lastPlay: PlayCall? { playOrder.last.flatMap { plays[$0] } }
    var lastVoice: AudioVoiceID? { playOrder.last }
    func finish(_ voice: AudioVoiceID) { active.remove(voice) }
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
        let voice = try #require(mock.lastVoice)
        #expect(mock.pans[voice] == 0)
    }

    @Test("spatial sources pan from listener-relative position and update while moving")
    func spatialPanningUpdates() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let listener = scene.createEntity()
        _ = scene.setComponent(AudioListener(), for: listener)
        _ = scene.setComponent(worldTransform(.zero), for: listener)

        let source = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", playOnAwake: true, spatialBlend: 1), for: source)
        _ = scene.setComponent(worldTransform(SIMD3<Float>(10, 0, 0)), for: source)

        engine.tick(scene: scene)
        let voice = try #require(mock.lastVoice)
        #expect(abs((mock.pans[voice] ?? 0) - 1) < 0.001)

        _ = scene.setComponent(worldTransform(SIMD3<Float>(-10, 0, 0)), for: source)
        engine.tick(scene: scene)
        #expect(abs((mock.pans[voice] ?? 0) + 1) < 0.001)
    }

    @Test("spatial sources apply Doppler pitch from rigid body velocity")
    func spatialDopplerPitchUpdates() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let listener = scene.createEntity()
        _ = scene.setComponent(AudioListener(), for: listener)
        _ = scene.setComponent(worldTransform(.zero), for: listener)

        let source = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", pitch: 1, playOnAwake: true, spatialBlend: 1), for: source)
        _ = scene.setComponent(worldTransform(SIMD3<Float>(10, 0, 0)), for: source)
        _ = scene.setComponent(RigidBody(linearVelocity: SIMD3<Float>(-100, 0, 0)), for: source)

        engine.tick(scene: scene)
        let voice = try #require(mock.lastVoice)
        let approachingPitch = try #require(mock.plays[voice]?.pitch)
        #expect(approachingPitch > 1.3)

        _ = scene.setComponent(RigidBody(linearVelocity: SIMD3<Float>(100, 0, 0)), for: source)
        engine.tick(scene: scene)
        let recedingPitch = try #require(mock.plays[voice]?.pitch)
        #expect(recedingPitch < 0.8)
    }

    @Test("listener master volume scales scene playback")
    func listenerMasterVolumeScalesPlayback() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let listener = scene.createEntity()
        _ = scene.setComponent(AudioListener(masterVolume: 0.25), for: listener)
        _ = scene.setComponent(worldTransform(.zero), for: listener)

        let source = scene.createEntity()
        _ = scene.setComponent(AudioSource(clipName: "beep", volume: 0.8, playOnAwake: true, spatialBlend: 0), for: source)

        engine.tick(scene: scene)
        let volume = try #require(mock.lastPlay?.volume)
        #expect(abs(volume - 0.2) < 0.001)
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

    @Test("play-on-awake retries when a missing clip becomes available")
    func playOnAwakeRetriesAfterMissingClipAppears() throws {
        let dir = try makeClipDir([])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            AudioSource(clipName: "late", playOnAwake: true, spatialBlend: 0),
            for: entity
        )

        engine.tick(scene: scene)
        #expect(mock.plays.isEmpty)

        let clipURL = dir.appendingPathComponent("late.wav")
        #expect(FileManager.default.createFile(atPath: clipURL.path, contents: Data()))
        engine.tick(scene: scene)

        #expect(mock.lastPlay?.clip == "late")
        #expect(mock.plays.count == 1)
    }

    @Test("changing an audio source clip replaces its live voice")
    func changingClipReplacesLiveVoice() throws {
        let dir = try makeClipDir(["first", "second"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            AudioSource(clipName: "first", playOnAwake: true, spatialBlend: 0),
            for: entity
        )
        engine.tick(scene: scene)
        let firstVoice = try #require(mock.lastVoice)

        _ = scene.setComponent(
            AudioSource(clipName: "second", playOnAwake: true, spatialBlend: 0),
            for: entity
        )
        engine.tick(scene: scene)

        #expect(mock.stopped == [firstVoice])
        #expect(mock.playOrder.count == 2)
        #expect(mock.lastPlay?.clip == "second")
    }

    @Test("removing a finished source re-arms play-on-awake")
    func removingFinishedSourceRearmsPlayOnAwake() throws {
        let dir = try makeClipDir(["beep"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)
        engine.addSearchURL(dir)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let source = AudioSource(clipName: "beep", playOnAwake: true, spatialBlend: 0)
        _ = scene.setComponent(source, for: entity)
        engine.tick(scene: scene)

        let firstVoice = try #require(mock.lastVoice)
        mock.finish(firstVoice)
        engine.tick(scene: scene)

        _ = scene.setComponent(AudioSource(clipName: "", playOnAwake: true), for: entity)
        engine.tick(scene: scene)
        _ = scene.setComponent(source, for: entity)
        engine.tick(scene: scene)

        #expect(mock.playOrder.count == 2)
        #expect(mock.lastPlay?.clip == "beep")
    }

    @Test("changing project search roots reloads same-named clips")
    func changingSearchRootsReloadsSameNamedClips() throws {
        let firstProject = try makeClipDir(["shared"])
        let secondProject = try makeClipDir(["shared"])
        let mock = MockAudioBackend()
        let engine = AudioEngine(backend: mock)

        engine.setSearchURLs([firstProject])
        #expect(engine.preload("shared"))
        #expect(mock.loadedURLs["shared"] == firstProject.appendingPathComponent("shared.wav"))
        let unloadCount = mock.unloadAllClipsCount

        engine.setSearchURLs([secondProject])
        #expect(mock.unloadAllClipsCount == unloadCount + 1)
        #expect(!mock.isClipLoaded("shared"))
        #expect(engine.preload("shared"))
        #expect(mock.loadedURLs["shared"] == secondProject.appendingPathComponent("shared.wav"))
    }
}
