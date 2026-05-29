@testable import EditorCore
import SceneRuntime
import Testing

@Suite("EditorComponentEditing", .serialized)
struct EditorComponentEditingTests {

    private func makeEntity(in adapter: EditorSceneAdapter) -> UInt64 {
        adapter.scene.createEntity().rawValue
    }

    @Test("adding a component reports presence and updates the addable set")
    func addComponent() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)

        #expect(!adapter.hasComponent(.particleEmitter, on: id))
        #expect(adapter.addableComponentKinds(on: id).contains(.particleEmitter))

        #expect(adapter.addComponent(.particleEmitter, to: id) == true)
        #expect(adapter.hasComponent(.particleEmitter, on: id))
        #expect(adapter.componentKinds(on: id).contains(.particleEmitter))
        #expect(!adapter.addableComponentKinds(on: id).contains(.particleEmitter))
    }

    @Test("adding an existing component does not overwrite and returns false")
    func addExistingIsNoOp() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = adapter.scene.createEntity() // unused, keeps ids distinct from preview
        _ = entity

        #expect(adapter.addComponent(.light, to: id) == true)
        // Mutate it, then a second add must not reset it.
        adapter.scene.updateComponent(LightComponent.self, for: EntityID(rawValue: id)!) { $0.intensity = 42 }
        #expect(adapter.addComponent(.light, to: id) == false)
        #expect(adapter.scene.component(LightComponent.self, for: EntityID(rawValue: id)!)?.intensity == 42)
    }

    @Test("removing a component clears it")
    func removeComponent() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        _ = adapter.addComponent(.audioSource, to: id)

        #expect(adapter.removeComponent(.audioSource, from: id) == true)
        #expect(!adapter.hasComponent(.audioSource, on: id))
        // Removing again is a no-op.
        #expect(adapter.removeComponent(.audioSource, from: id) == false)
    }

    @Test("add and remove bump the scene revision")
    func mutationsBumpRevision() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        var revisions: [UInt64] = []
        adapter.onRevisionChanged = { revisions.append($0) }

        _ = adapter.addComponent(.camera, to: id)
        _ = adapter.removeComponent(.camera, from: id)
        #expect(revisions.count == 2)
    }

    @Test("operations on an unknown entity fail safely")
    func unknownEntity() {
        let adapter = EditorSceneAdapter()
        let bogus: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        #expect(adapter.addComponent(.light, to: bogus) == false)
        #expect(adapter.removeComponent(.light, from: bogus) == false)
        #expect(adapter.hasComponent(.light, on: bogus) == false)
        #expect(adapter.componentKinds(on: bogus).isEmpty)
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
