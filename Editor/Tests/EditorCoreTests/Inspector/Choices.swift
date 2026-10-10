@testable import EditorCore
import SceneRuntime
import Testing

@Suite("Inspector enum choices")
struct InspectorEnumChoiceTests {
    @Test("typed enum fields present through the shared choices control")
    func enumFieldUsesSharedChoices() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("particleEmitter", to: entity.rawValue))
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "particleEmitter"
        })
        let field = try #require(section.fields.first { $0.id == "particle-blend-mode" })
        guard case let .stringOptions(binding, options) = field.value else {
            Issue.record("expected the blend mode to use the shared choices control")
            return
        }
        #expect(options.map(\.value) == ParticleBlendMode.allCases.map(\.inspectorOptionID))
        #expect(options.map(\.label) == ParticleBlendMode.allCases.map(\.inspectorOptionLabel))
        binding.wrappedValue = ParticleBlendMode.additive.inspectorOptionID
        #expect(adapter.scene.component(ParticleEmitter.self, for: entity)?.settings.appearance.blendMode == .additive)
    }

    @Test("collider shape kind edits through choices and keeps the compound editor registered")
    func colliderShapeKindChoices() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        #expect(adapter.addComponent("collider", to: entity.rawValue))
        let section = try #require(adapter.inspectorSections(for: entity.rawValue).first {
            $0.componentTypeID == "collider"
        })
        let field = try #require(section.fields.first { $0.id == "shape-kind" })
        guard case let .stringOptions(binding, options) = field.value else {
            Issue.record("expected the shape kind to use the shared choices control")
            return
        }
        #expect(options.count == ColliderShapeKind.allCases.count)
        binding.wrappedValue = ColliderShapeKind.sphere.inspectorOptionID
        #expect(adapter.scene.component(Collider.self, for: entity)?.shape.kind == .sphere)
        #expect(section.fields.contains { if case .colliderShapeInstances = $0.value { return true }; return false })
    }
}
