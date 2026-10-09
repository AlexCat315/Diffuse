@testable import EditorCore
import SceneRuntime
import Testing

@Suite("Inspector renderer registry", .serialized)
struct InspectorRendererRegistryTests {
    @Test("invalid registrations preserve the installed renderer; copies can replace it independently")
    func registrationAndIsolation() throws {
        var registry = EditorInspectorRendererRegistry()
        try registry.register(componentTypeID: "light") { _, _ in
            EditorInspectorSection(id: "original", title: "Original", fields: [])
        }
        #expect(throws: EditorInspectorRendererRegistrationError.emptyComponentTypeID) {
            try registry.register(componentTypeID: "") { _, _ in nil }
        }
        #expect(throws: EditorInspectorRendererRegistrationError.duplicateRenderer("light")) {
            try registry.register(componentTypeID: "light") { _, _ in nil }
        }
        let first = EditorSceneAdapter(seedPreviewScene: false, inspectorRenderers: registry)
        let second = EditorSceneAdapter(seedPreviewScene: false, inspectorRenderers: registry)
        #expect(first.inspectorRenderers.componentTypeIDs == ["light"])
        #expect(first.inspectorRenderers.remove(componentTypeID: "light") != nil)
        try first.inspectorRenderers.register(componentTypeID: "light") { _, _ in nil }
        let a = first.scene.createEntity(), b = second.scene.createEntity()
        #expect(first.addComponent("light", to: a.rawValue))
        #expect(second.addComponent("light", to: b.rawValue))
        #expect(first.inspectorSections(for: a.rawValue).contains { $0.id == "light" })
        #expect(second.inspectorSections(for: b.rawValue).contains { $0.id == "original" })
        #expect(registry.componentTypeIDs == ["light"])
    }

    @Test("renderer configuration survives undo, document loading and scene reset without persisting")
    func sessionLifecycle() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("light", to: entity.rawValue))
        adapter.resetEditHistory()
        let manifest = adapter.manifest(selectedEntityID: entity.rawValue)
        let revision = adapter.revision
        try adapter.inspectorRenderers.register(componentTypeID: "light") { _, _ in
            EditorInspectorSection(id: "module-light", title: "Module Light", fields: [])
        }
        #expect(adapter.revision == revision)
        #expect(adapter.manifest(selectedEntityID: entity.rawValue) == manifest)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.removeComponent("light", from: entity.rawValue))
        #expect(adapter.undoEdit())
        #expect(adapter.inspectorSections(for: entity.rawValue).contains { $0.id == "module-light" })
        let loaded = adapter.load(manifest: manifest)
        #expect(loaded.succeeded)
        let restoredID = try #require(loaded.selectedEntityID)
        #expect(adapter.inspectorSections(for: restoredID).contains { $0.id == "module-light" })
        adapter.resetToPreviewScene()
        let fresh = adapter.scene.createEntity()
        #expect(adapter.addComponent("light", to: fresh.rawValue))
        #expect(adapter.inspectorSections(for: fresh.rawValue).contains { $0.id == "module-light" })
        #expect(EditorSceneAdapter(seedPreviewScene: false).inspectorRenderers["light"] == nil)
    }

    @Test("built-in rich controls can be removed and fall back to schema fields")
    func richControlFallback() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        #expect(adapter.inspectorRenderers.componentTypeIDs.allSatisfy {
            adapter.scene.componentRegistry[$0] != nil
        })
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("collider", to: entity.rawValue))
        let rich = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "collider"
        })
        #expect(rich.fields.contains { if case .colliderShapeKind = $0.value { return true }; return false })
        #expect(adapter.inspectorRenderers.remove(componentTypeID: "collider") != nil)
        let generated = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "collider"
        })
        #expect(!generated.fields.isEmpty)
        #expect(!generated.fields.contains { if case .colliderShapeKind = $0.value { return true }; return false })
        #expect(adapter.inspectorRenderers.remove(componentTypeID: "collider") == nil)
    }
}
