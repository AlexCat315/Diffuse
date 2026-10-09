import Foundation
import SIMDCompat
import SceneRuntime
import Testing

@testable import EditorCore

@Suite("Grouped editor state")
struct GroupedStateTests {
    @Test("State persistence uses responsibility groups and keeps transient navigation out")
    func groupedStateRoundTrip() throws {
        let state = EditorState {
            $0.selection.selectedEntityID = 42
            $0.selection.selectedEntityIDs = [42, 43]
            $0.viewport.renderScalePercent = 75
            $0.window.minimized = true
            $0.navigation.commandPaletteQuery = "temporary"
            $0.presentation = EditorPresentationState(language: .system)
        }
        let data = try JSONEncoder().encode(state)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selection = try #require(object["selection"] as? [String: Any])
        let viewport = try #require(object["viewport"] as? [String: Any])
        #expect(selection["selectedEntityID"] as? Int == 42)
        #expect(viewport["renderScalePercent"] as? Int == 75)
        #expect(object["selectedEntityID"] == nil)
        #expect(object["viewportRenderScalePercent"] == nil)

        let restored = try JSONDecoder().decode(EditorState.self, from: data)
        #expect(restored.selection.selectedEntityIDs == [42, 43])
        #expect(restored.viewport.renderScalePercent == 75)
        #expect(!restored.shouldRender)
        #expect(restored.navigation.commandPaletteQuery.isEmpty)
    }

    @Test("Component documents persist particle settings without a separate flat field table")
    func groupedParticleManifestRoundTrip() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let emitter = ParticleEmitter(
            settings: .init {
                $0.emission.seed = .max
                $0.forces.gravity = SIMD3<Float>(1, -3, 2)
                $0.textureSheet.textureAssetID = "fire.png"
            })
        _ = scene.setComponent(emitter, for: entity)
        var encodeContext = ComponentEncodeContext(entityIndexMap: [entity: 0])
        let components = SceneSerializer.componentDocument(for: entity, in: scene, context: &encodeContext)
        let data = try JSONEncoder().encode(components)
        let restored = try JSONDecoder().decode([ManifestComponent].self, from: data)
        #expect(restored == components)
        let particle = try #require(restored.value(for: "particleEmitter")?.objectValue)
        #expect(particle["settings"] is [String: Any])
        #expect(particle["gravity"] == nil)
        var restoredScene = SceneRuntime()
        let restoredEntity = restoredScene.createEntity()
        var decodeContext = ComponentDecodeContext(entityMap: [0: restoredEntity])
        SceneSerializer.applyComponentDocument(restored, to: restoredEntity, in: &restoredScene, context: &decodeContext)
        #expect(restoredScene.component(ParticleEmitter.self, for: restoredEntity)?.settings == emitter.settings)
    }
}
