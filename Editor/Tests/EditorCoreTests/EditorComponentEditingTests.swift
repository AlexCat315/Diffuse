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

    @Test("adding an animation graph creates a default graph player")
    func addAnimationGraphPlayer() {
        let adapter = EditorSceneAdapter()
        let id = makeEntity(in: adapter)
        let entity = EntityID(rawValue: id)!

        #expect(adapter.addComponent(.animationGraphPlayer, to: id) == true)
        let player = adapter.scene.component(AnimationGraphPlayer.self, for: entity)
        #expect(player != nil)
        #expect(player?.graph.stateMachine.initialState == "Default")
        #expect(player?.graph.stateMachine.states.count == 1)
        #expect(adapter.componentKinds(on: id).contains(.animationGraphPlayer))

        #expect(adapter.removeComponent(.animationGraphPlayer, from: id) == true)
        #expect(adapter.scene.component(AnimationGraphPlayer.self, for: entity) == nil)
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

    @Test("multi-selection component add is atomic and one undo step")
    func multiSelectionAddIsAtomicAndUndoable() throws {
        let adapter = EditorSceneAdapter()
        let first = try #require(adapter.spawnEntity(template: .empty))
        let second = try #require(adapter.spawnEntity(template: .empty))
        let selection: Set<UInt64> = [first, second]

        #expect(adapter.addableComponentKinds(on: selection).contains(.audioSource))
        #expect(adapter.addComponent(.audioSource, to: selection))
        #expect(selection.allSatisfy { adapter.hasComponent(.audioSource, on: $0) })

        #expect(adapter.undoEdit())
        #expect(selection.allSatisfy { !adapter.hasComponent(.audioSource, on: $0) })
        #expect(adapter.redoEdit())
        #expect(selection.allSatisfy { adapter.hasComponent(.audioSource, on: $0) })
    }

    @Test("multi-selection add fills missing members without resetting existing data")
    func multiSelectionAddFillsMissingMembers() throws {
        let adapter = EditorSceneAdapter()
        let first = try #require(adapter.spawnEntity(template: .empty))
        let second = try #require(adapter.spawnEntity(template: .empty))
        #expect(adapter.addComponent(.light, to: first))
        let firstEntity = try #require(EntityID(rawValue: first))
        adapter.scene.updateComponent(LightComponent.self, for: firstEntity) {
            $0.intensity = 42
        }
        adapter.notifyRevisionChanged()
        let selection: Set<UInt64> = [first, second]

        #expect(adapter.addableComponentKinds(on: selection).contains(.light))
        #expect(adapter.addComponent(.light, to: selection))
        #expect(adapter.scene.component(LightComponent.self, for: firstEntity)?.intensity == 42)
        #expect(adapter.hasComponent(.light, on: second))

        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(LightComponent.self, for: firstEntity)?.intensity == 42)
        #expect(!adapter.hasComponent(.light, on: second))
    }

    @Test("multi-selection add rejects a locked member without partial mutation")
    func multiSelectionAddRejectsLockedMember() throws {
        let adapter = EditorSceneAdapter()
        let first = try #require(adapter.spawnEntity(template: .empty))
        let second = try #require(adapter.spawnEntity(template: .empty))
        let selection: Set<UInt64> = [first, second]
        adapter.setEntityLocked(true, entityIDs: [second])
        var revisionCount = 0
        adapter.onRevisionChanged = { _ in revisionCount += 1 }

        #expect(!adapter.addComponent(.light, to: selection))
        #expect(selection.allSatisfy { !adapter.hasComponent(.light, on: $0) })
        #expect(revisionCount == 0)
    }

    @Test("multi-selection remove and reset are atomic undoable operations")
    func multiSelectionRemoveAndResetAreUndoable() throws {
        let adapter = EditorSceneAdapter()
        let first = try #require(adapter.spawnEntity(template: .empty))
        let second = try #require(adapter.spawnEntity(template: .empty))
        let selection: Set<UInt64> = [first, second]
        #expect(adapter.addComponent(.light, to: selection))

        for rawID in selection {
            let entity = try #require(EntityID(rawValue: rawID))
            adapter.scene.updateComponent(LightComponent.self, for: entity) {
                $0.intensity = 42
            }
        }
        adapter.notifyRevisionChanged()

        #expect(adapter.resetComponent(.light, on: selection))
        #expect(selection.allSatisfy { rawID in
            guard let entity = EntityID(rawValue: rawID) else { return false }
            return adapter.scene.component(LightComponent.self, for: entity)?.intensity
                == LightComponent().intensity
        })
        #expect(adapter.undoEdit())
        #expect(selection.allSatisfy { rawID in
            guard let entity = EntityID(rawValue: rawID) else { return false }
            return adapter.scene.component(LightComponent.self, for: entity)?.intensity == 42
        })

        #expect(adapter.removeComponent(.light, from: selection))
        #expect(selection.allSatisfy { !adapter.hasComponent(.light, on: $0) })
        #expect(adapter.undoEdit())
        #expect(selection.allSatisfy { adapter.hasComponent(.light, on: $0) })
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF), generation: UInt32(rawValue >> 32))
    }
}
