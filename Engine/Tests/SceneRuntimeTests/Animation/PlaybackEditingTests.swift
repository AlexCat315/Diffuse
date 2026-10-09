import SceneRuntime
import Testing

@Suite("Animation playback component edits")
struct PlaybackEditingTests {
    @Test("control edits retain progress; clip changes restart unless the caller supplies a playhead")
    func mergePlayback() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(AnimationPlayer(clipName: "Walk", time: 7.5), for: entity)
        try scene.setComponentData(.object(["speed": .number(2), "loop": .bool(false), "isPlaying": .bool(false)]),
                                   typeID: "animationPlayer", for: entity, mode: .merge)
        #expect(scene.component(AnimationPlayer.self, for: entity) ==
            AnimationPlayer(clipName: "Walk", speed: 2, loop: false, isPlaying: false, time: 7.5))
        try scene.setComponentData(.object(["clipName": .string("Walk")]),
                                   typeID: "animationPlayer", for: entity, mode: .merge)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.time == 7.5)
        try scene.setComponentData(.object(["clipName": .string("Run")]),
                                   typeID: "animationPlayer", for: entity, mode: .merge)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.time == 0)
        try scene.setComponentData(.object(["clipName": .string("Jump"), "time": .number(3)]),
                                   typeID: "animationPlayer", for: entity, mode: .merge)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.time == 3)
        try scene.setComponentData(.object(["clipName": .null]),
                                   typeID: "animationPlayer", for: entity, mode: .merge)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.clipName == nil)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.time == 0)
        #expect(scene.componentData("animationPlayer", for: entity)?.value(at: ["clipName"]) == nil)
    }

    @Test("document replacement and serialization preserve an explicitly stored playback position")
    func storedPlayhead() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setLocalTransform(.identity, for: entity)
        _ = scene.setComponent(AnimationPlayer(clipName: "Walk", time: 7.5), for: entity)
        try scene.setComponentData(.object(["clipName": .string("Run"), "time": .number(12)]),
                                   typeID: "animationPlayer", for: entity)
        #expect(scene.component(AnimationPlayer.self, for: entity)?.time == 12)
        let data = try SceneSerializer.serialize(scene)
        var restored = SceneRuntime()
        let created = try SceneSerializer.deserialize(data, into: &restored)
        let loaded = try #require(created.first)
        #expect(restored.component(AnimationPlayer.self, for: loaded)?.clipName == "Run")
        #expect(restored.component(AnimationPlayer.self, for: loaded)?.time == 12)
        #expect(try SceneSerializer.serialize(restored) == data)
    }
}
