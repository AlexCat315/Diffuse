@testable import EditorCore
import SceneRuntime
import Testing

@Suite("EditorMultiSelectionInspector", .serialized)
struct EditorMultiSelectionInspectorTests {
    private func field(_ adapter: EditorSceneAdapter, _ ids: Set<UInt64>,
                       section: String, field: String, primaryID: UInt64? = nil) throws -> EditorInspectorField {
        try #require(adapter.inspectorSections(for: ids, primaryID: primaryID).first { $0.id == section }?
            .fields.first { $0.id == field })
    }

    @Test("only fields of components shared by all selected entities are offered")
    func intersection() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .empty))
        let b = try #require(adapter.spawnEntity(template: .empty))
        #expect(adapter.addComponent("light", to: a))
        #expect(!adapter.inspectorSections(for: Set([a, b])).contains { $0.id == "light" })
        #expect(adapter.addComponent("light", to: b))
        #expect(adapter.inspectorSections(for: Set([a, b])).contains { $0.id == "light" })
    }

    @Test("mixed names can be unified to the first value and undone together")
    func mixedNames() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .empty))
        let b = try #require(adapter.spawnEntity(template: .empty))
        let ids: Set<UInt64> = [a, b]
        let original = ids.sorted().map { adapter.entitySummary(id: $0)?.name }
        let name = try field(adapter, ids, section: "general", field: "name")
        #expect(name.isMixed)
        guard case .text(let binding) = name.value else { Issue.record("Expected text"); return }
        let first = binding.wrappedValue
        binding.wrappedValue = first
        #expect(ids.allSatisfy { adapter.entitySummary(id: $0)?.name == first })
        let unified = try field(adapter, ids, section: "general", field: "name")
        #expect(!unified.isMixed)
        #expect(adapter.undoEdit())
        #expect(ids.sorted().map { adapter.entitySummary(id: $0)?.name } == original)
        #expect(adapter.redoEdit())
        #expect(ids.allSatisfy { adapter.entitySummary(id: $0)?.name == first })
    }

    @Test("a mixed checkbox can apply the already-selected primary value in one undo step")
    func mixedBoolean() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .cube))
        let b = try #require(adapter.spawnEntity(template: .cube))
        let single = try field(adapter, [b], section: "render-mesh", field: "mesh-visible")
        guard case .bool(let visible) = single.value else { Issue.record("Expected visibility binding"); return }
        visible.wrappedValue = false
        let shared = try field(adapter, [a, b], section: "render-mesh", field: "mesh-visible", primaryID: b)
        #expect(shared.isMixed)
        let apply = try #require(shared.applyPrimaryValue)
        apply()
        let other = try field(adapter, [a], section: "render-mesh", field: "mesh-visible")
        guard case .bool(let otherVisible) = other.value else { Issue.record("Expected visibility binding"); return }
        #expect(!otherVisible.wrappedValue)
        #expect(!visible.wrappedValue)
        #expect(adapter.undoEdit())
        #expect(otherVisible.wrappedValue)
        #expect(!visible.wrappedValue)
    }

    @Test("editing one mixed vector axis preserves each object's other axes")
    func vectorAxes() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .empty))
        let b = try #require(adapter.spawnEntity(template: .empty))
        let single = try field(adapter, [b], section: "transform", field: "local-position")
        guard case .vector3(let bx, let by, _) = single.value else { Issue.record("Expected vector"); return }
        bx.wrappedValue = 3; by.wrappedValue = 7
        let shared = try field(adapter, [a, b], section: "transform", field: "local-position")
        #expect(shared.mixedAxes == ["x", "y"])
        guard case .vector3(let x, _, _) = shared.value else { Issue.record("Expected vector"); return }
        x.wrappedValue = 12
        #expect(adapter.entityWorldPosition(a)?.x == 12)
        #expect(adapter.entityWorldPosition(b)?.x == 12)
        #expect(adapter.entityWorldPosition(a)?.y == 0)
        #expect(adapter.entityWorldPosition(b)?.y == 7)
        #expect(adapter.undoEdit())
        #expect(adapter.entityWorldPosition(a)?.x == 0)
        #expect(adapter.entityWorldPosition(b)?.x == 3)
    }

    @Test("a lock added after presenting the fields rejects the entire batch")
    func lockAtCommit() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .empty))
        let b = try #require(adapter.spawnEntity(template: .empty))
        let name = try field(adapter, [a, b], section: "general", field: "name")
        guard case .text(let binding) = name.value else { Issue.record("Expected text"); return }
        adapter.setEntityLocked(true, entityIDs: [b])
        let original = [a, b].map { adapter.entitySummary(id: $0)?.name }
        let revision = adapter.revision
        binding.wrappedValue = "Batch rename"
        #expect([a, b].map { adapter.entitySummary(id: $0)?.name } == original)
        #expect(adapter.revision == revision)
    }

    @Test("removing a common component before commit does not partially edit the remaining objects")
    func componentRemovedAtCommit() throws {
        let adapter = EditorSceneAdapter()
        let a = try #require(adapter.spawnEntity(template: .pointLight))
        let b = try #require(adapter.spawnEntity(template: .pointLight))
        let intensity = try field(adapter, [a, b], section: "light", field: "intensity")
        guard case .constrainedNumber(let binding, _, _, _, _) = intensity.value else { Issue.record("Expected intensity binding"); return }
        let original = binding.wrappedValue
        #expect(adapter.removeComponent("light", from: b))
        let revision = adapter.revision
        binding.wrappedValue = original + 10
        #expect(binding.wrappedValue == original)
        #expect(adapter.revision == revision)
    }

    @Test("scene settings are available in a scene with zero entities")
    func emptySceneSettings() {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        #expect(adapter.entityCount == 0)
        #expect(adapter.sceneSettingsSections().map(\.id) == ["physics-settings", "particle-scalability"])
    }
}
