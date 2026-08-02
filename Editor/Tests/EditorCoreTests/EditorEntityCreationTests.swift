@testable import EditorCore
import SceneRuntime
import Testing

@Suite("Editor entity creation", .serialized)
struct EditorEntityCreationTests {
    @Test("built-in templates create usable SceneRuntime entities",
          arguments: EditorEntityTemplate.allCases)
    func createsBuiltInTemplate(_ template: EditorEntityTemplate) {
        let adapter = EditorSceneAdapter()
        guard let rawID = adapter.spawnEntity(template: template) else {
            Issue.record("Expected \(template.rawValue) to create an entity")
            return
        }
        let entity = EntityID(rawValue: rawID)!

        #expect(adapter.scene.contains(entity))
        #expect(adapter.scene.component(SceneNameComponent.self, for: entity) != nil)
        #expect(adapter.scene.localTransform(for: entity) != nil)

        switch template {
        case .empty:
            #expect(adapter.scene.component(RenderMeshComponent.self, for: entity) == nil)
        case .cube:
            #expect(adapter.scene.component(RenderMeshComponent.self, for: entity)?.meshIndex == 0)
        case .directionalLight:
            #expect(adapter.scene.component(LightComponent.self, for: entity)?.type == .directional)
        case .pointLight:
            #expect(adapter.scene.component(LightComponent.self, for: entity)?.type == .point)
        case .spotLight:
            #expect(adapter.scene.component(LightComponent.self, for: entity)?.type == .spot)
        case .camera:
            #expect(adapter.scene.component(CameraComponent.self, for: entity) != nil)
        }
    }

    @Test("repeated templates receive unique names and can be undone")
    func uniqueNamesAndUndo() {
        let adapter = EditorSceneAdapter()
        let first = adapter.spawnEntity(template: .cube)
        let second = adapter.spawnEntity(template: .cube)

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
        #expect(adapter.entitySummary(id: first)?.name == "Cube")
        #expect(adapter.entitySummary(id: second)?.name == "Cube 2")
        #expect(adapter.canUndoEdit)
        #expect(adapter.undoEdit())
        #expect(adapter.entitySummary(id: second) == nil)
        #expect(adapter.entitySummary(id: first)?.name == "Cube")
    }
}

private extension EntityID {
    init?(rawValue: UInt64) {
        self.init(index: UInt32(rawValue & 0xFFFF_FFFF),
                  generation: UInt32(rawValue >> 32))
    }
}
