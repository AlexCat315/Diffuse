import SceneRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("GameSave")
struct GameSaveTests {

    struct PlayerProgress: Codable, Equatable {
        var score: Int
        var health: Float
        var inventory: [String]
        var checkpoint: String
    }

    private func makeScene() -> SceneRuntime {
        var scene = SceneRuntime()
        let player = scene.createEntity()
        _ = scene.setComponent(SceneNameComponent(value: "Player"), for: player)
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 9)), for: player)
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 70), for: player)
        return scene
    }

    @Test("scene + game state round-trips through a single document")
    func fullRoundTrip() throws {
        let scene = makeScene()
        let progress = PlayerProgress(score: 4200, health: 75.5,
                                      inventory: ["sword", "key"], checkpoint: "level-2")

        let save = try GameSave.capture(scene: scene, state: progress,
                                        metadata: ["savedAt": "2026-05-29", "slot": "1"])
        let document = try save.serialized()
        #expect(!document.isEmpty)

        let loaded = try GameSave.load(document)
        #expect(loaded.metadata["slot"] == "1")

        var restored = SceneRuntime()
        try loaded.restoreScene(into: &restored)
        let player = restored.findEntity(named: "Player")
        #expect(player != nil)
        let t = restored.localTransform(for: player!)
        #expect(abs(t!.translation.x - 4) < 0.01)
        #expect(abs(t!.translation.z - 9) < 0.01)
        #expect(restored.component(RigidBody.self, for: player!)?.mass == 70)

        let decoded = try loaded.decodeState(PlayerProgress.self)
        #expect(decoded == progress)
    }

    @Test("scene-only save carries no state payload")
    func sceneOnly() throws {
        let save = try GameSave.capture(scene: makeScene())
        let loaded = try GameSave.load(save.serialized())
        #expect(loaded.state == nil)
        #expect(try loaded.decodeState(PlayerProgress.self) == nil)

        var restored = SceneRuntime()
        try loaded.restoreScene(into: &restored)
        #expect(restored.snapshot.entityCount == 1)
    }

    @Test("captures live runtime transforms, not just the authored layout")
    func capturesRuntimeState() throws {
        var scene = makeScene()
        let player = scene.findEntity(named: "Player")!
        // Simulate the player moving during play.
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(100, 0, -50)), for: player)

        let save = try GameSave.capture(scene: scene)
        var restored = SceneRuntime()
        try GameSave.load(save.serialized()).restoreScene(into: &restored)

        let t = restored.localTransform(for: restored.findEntity(named: "Player")!)
        #expect(abs(t!.translation.x - 100) < 0.01)
        #expect(abs(t!.translation.z + 50) < 0.01)
    }

    @Test("rejects an unsupported version")
    func unsupportedVersion() throws {
        let bad = try JSONSerialization.data(withJSONObject: ["version": 999, "scene": ["entities": []]])
        #expect(throws: GameSaveError.unsupportedVersion(999)) {
            _ = try GameSave.load(bad)
        }
    }

    @Test("rejects a malformed document")
    func malformed() {
        let junk = Data("not a save".utf8)
        #expect(throws: (any Error).self) { _ = try GameSave.load(junk) }
    }

    @Test("AnimationPlayer playback time survives serialization")
    func animationTimePersists() throws {
        var scene = SceneRuntime()
        let e = scene.createEntity()
        _ = scene.setComponent(AnimationPlayer(clipName: "run", time: 1.75), for: e)

        let data = try SceneSerializer.serialize(scene)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let player = restored.component(AnimationPlayer.self, for: restored.entities()[0])
        #expect(player != nil)
        #expect(abs(player!.time - 1.75) < 1e-6)
    }
}
