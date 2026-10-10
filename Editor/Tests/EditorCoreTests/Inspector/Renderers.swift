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

    @Test("built-in registrations declare the property-grid layout their fields are shaped for")
    func builtInLayouts() {
        let renderers = EditorInspectorRendererRegistry.builtIn
        #expect(renderers.layout(forComponentTypeID: "script") == .scriptBindings)
        #expect(renderers.layout(forComponentTypeID: "particleEmitter") == .particleModules)
        #expect(renderers.layout(forComponentTypeID: "collider") == .standard)
        #expect(renderers.layout(forComponentTypeID: "rigidbody") == .standard)
    }

    @Test("a registration value installs layout, presentation and renderer together")
    func registrationValue() throws {
        var registry = EditorInspectorRendererRegistry()
        var section = EditorInspectorSection(id: "terrain", title: "Terrain", fields: [])
        section.componentTypeID = "module.terrain"
        section.fields = [EditorInspectorField(id: "height", label: "Height", value: .readOnly("0"))]
        let registration = EditorInspectorRendererRegistration(
            componentTypeID: "module.terrain", layout: .particleModules,
            presentation: { presented in
                var result = presented
                result.fields = presented.fields.filter { $0.id != "height" }
                return result
            },
            render: { _, _ in section })
        try registry.register(registration)
        #expect(registry.componentTypeIDs == ["module.terrain"])
        #expect(registry.layout(forComponentTypeID: "module.terrain") == .particleModules)
        #expect(registry.presentedSection(section).fields.isEmpty)
        var untyped = section
        untyped.componentTypeID = nil
        #expect(registry.presentedSection(untyped).fields.count == 1)
        #expect(throws: EditorInspectorRendererRegistrationError.duplicateRenderer("module.terrain")) {
            try registry.register(registration)
        }
    }

    @Test("presentations apply to their own component only")
    func presentationScope() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("collider", to: entity.rawValue))
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "collider"
        })
        #expect(section.fields.contains { $0.id == "shape-kind" })
        let presented = adapter.inspectorRenderers.presentedSection(section)
        #expect(!presented.fields.contains { $0.id == "shape-kind" })
        #expect(presented.fields.contains { $0.id == "shape-instances" })
        #expect(adapter.inspectorRenderers.remove(componentTypeID: "collider") != nil)
        #expect(adapter.inspectorRenderers.presentedSection(section).fields.count == section.fields.count)
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
