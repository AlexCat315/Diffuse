@testable import EditorCore
import GuavaUIRuntime
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Generated rendering and playback forms", .serialized)
struct GeneratedComponentFormTests {
    private func section(_ adapter: EditorSceneAdapter, _ id: UInt64, _ typeID: String) throws -> EditorInspectorSection {
        #expect(adapter.inspectorRenderers[typeID] == nil)
        return try #require(adapter.inspectorSections(for: id).first { $0.componentTypeID == typeID })
    }

    private func field(_ section: EditorInspectorSection, _ id: String) throws -> EditorInspectorFieldValue {
        try #require(section.fields.first { $0.id == id }?.value)
    }

    @Test("mesh form retains asset and LOD data, clamps RGB and coalesces component edits")
    func meshForm() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        let original = RenderMeshComponent(meshIndex: 7, colorTint: SIMD3(0.2, 0.4, 0.6), assetID: "mesh.tree",
                                           levelsOfDetail: [RenderMeshLOD(meshIndex: 9, minimumDistance: 20)])
        _ = adapter.scene.setComponent(original, for: entity)
        adapter.resetEditHistory()
        let form = try section(adapter, entity.rawValue, "renderMesh")
        #expect(form.id == "render-mesh")
        #expect(form.fields.filter { if case .standard = $0.presentation { return true }; return false }
            .map(\.id) == ["mesh-visible", "mesh-color-tint"])
        guard case let .bool(visible) = try field(form, "mesh-visible"),
              case let .color(tint) = try field(form, "mesh-color-tint"),
              case .readOnly = try field(form, "meshIndex") else {
            Issue.record("Expected generated mesh controls"); return
        }
        adapter.beginInteractiveEditHistoryGroup()
        tint.wrappedValue = Color(r: -1, g: 0.5, b: 2, a: 1)
        visible.wrappedValue = false
        adapter.endInteractiveEditHistoryGroup()
        var expected = original
        expected.colorTint = SIMD3(0, 0.5, 1)
        expected.isVisible = false
        #expect(adapter.scene.component(RenderMeshComponent.self, for: entity) == expected)
        let revision = adapter.revision
        tint.wrappedValue = Color(r: .nan, g: 0, b: 0, a: 1)
        #expect(adapter.revision == revision)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(RenderMeshComponent.self, for: entity) == original)
        #expect(!adapter.canUndoEdit)
        #expect(adapter.redoEdit())
        #expect(adapter.scene.component(RenderMeshComponent.self, for: entity) == expected)
    }

    @Test("material form retains HDR RGB and coverage overrides while normalizing bounded channels")
    func materialForm() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        let original = RenderMaterialComponent(baseColorFactor: SIMD4(0.2, 0.4, 0.6, 0.5), baseColorTextureIndex: 3,
            normalTextureIndex: 4, metallicFactor: 0.2, roughnessFactor: 0.8, emissiveFactor: SIMD3(2, 4, 8),
            alphaMode: .mask, alphaCutoff: 0.25, doubleSided: true)
        _ = adapter.scene.setComponent(original, for: entity)
        adapter.resetEditHistory()
        let form = try section(adapter, entity.rawValue, "renderMaterial")
        #expect(form.id == "render-material")
        guard case let .color(base) = try field(form, "mat-base-color"),
              case let .color(emissive) = try field(form, "mat-emissive"),
              case let .constrainedNumber(metallic, _, _, _, _) = try field(form, "mat-metallic"),
              case let .constrainedNumber(roughness, _, _, _, _) = try field(form, "mat-roughness") else {
            Issue.record("Expected generated material controls"); return
        }
        #expect(emissive.wrappedValue.g == 4)
        adapter.beginInteractiveEditHistoryGroup()
        // A color picker edits a single channel through a read-modify-write.
        emissive.wrappedValue.r = 0.5
        #expect(adapter.scene.component(RenderMaterialComponent.self, for: entity)?.emissiveFactor == SIMD3(0.5, 4, 8))
        emissive.wrappedValue = Color(r: 4, g: -1, b: 8, a: 0.5)
        base.wrappedValue = Color(r: -1, g: 0.3, b: 2, a: 5)
        metallic.wrappedValue = 12
        roughness.wrappedValue = -2
        adapter.endInteractiveEditHistoryGroup()
        var expected = original
        expected.emissiveFactor = SIMD3(4, 0, 8)
        expected.baseColorFactor = SIMD4(0, 0.3, 1, 1)
        expected.metallicFactor = 1
        expected.roughnessFactor = 0
        #expect(adapter.scene.component(RenderMaterialComponent.self, for: entity) == expected)
        let revision = adapter.revision
        emissive.wrappedValue = Color(r: .infinity, g: 0, b: 0, a: 1)
        #expect(adapter.revision == revision)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(RenderMaterialComponent.self, for: entity) == original)
        #expect(!adapter.canUndoEdit)
    }

    @Test("a missing clip is editable, clearing restores nil, and unrelated controls preserve playback")
    func playbackForm() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let entity = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(AnimationPlayer(time: 4.25), for: entity)
        adapter.resetEditHistory()
        let form = try section(adapter, entity.rawValue, "animationPlayer")
        #expect(form.id == "animation-player")
        guard case let .text(clip) = try field(form, "anim-clip"),
              case let .constrainedNumber(speed, _, _, _, _) = try field(form, "anim-speed"),
              case let .bool(loop) = try field(form, "anim-loop"),
              case let .bool(playing) = try field(form, "anim-playing"),
              case .readOnly = try field(form, "time") else {
            Issue.record("Expected generated playback controls"); return
        }
        #expect(clip.wrappedValue.isEmpty)
        speed.wrappedValue = 2
        loop.wrappedValue = false
        playing.wrappedValue = false
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity) ==
            AnimationPlayer(speed: 2, loop: false, isPlaying: false, time: 4.25))
        clip.wrappedValue = "Run"
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity)?.time == 0)
        _ = adapter.scene.updateComponent(AnimationPlayer.self, for: entity) { $0.time = 3.5 }
        adapter.resetEditHistory()
        clip.wrappedValue = ""
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity)?.clipName == nil)
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity)?.time == 0)
        #expect(adapter.scene.componentData("animationPlayer", for: entity)?.value(at: ["clipName"]) == nil)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity)?.clipName == "Run")
        #expect(adapter.scene.component(AnimationPlayer.self, for: entity)?.time == 3.5)
        #expect(adapter.redoEdit())
        #expect(clip.wrappedValue.isEmpty)
        adapter.setAuthoringEnabled(false)
        let revision = adapter.revision
        clip.wrappedValue = "Locked"
        #expect(adapter.revision == revision)
    }

    @Test("clearing a mixed optional clip changes only non-empty members and undoes as one group")
    func mixedOptionalClips() throws {
        let adapter = EditorSceneAdapter(seedPreviewScene: false)
        let a = adapter.scene.createEntity(), b = adapter.scene.createEntity()
        _ = adapter.scene.setComponent(AnimationPlayer(time: 2), for: a)
        _ = adapter.scene.setComponent(AnimationPlayer(clipName: "Walk", time: 5), for: b)
        adapter.resetEditHistory()
        let form = try #require(adapter.inspectorSections(for: [a.rawValue, b.rawValue], primaryID: a.rawValue)
            .first { $0.componentTypeID == "animationPlayer" })
        let field = try #require(form.fields.first { $0.id == "anim-clip" })
        #expect(field.isMixed)
        guard case let .text(clip) = field.value else { Issue.record("Expected optional clip"); return }
        clip.wrappedValue = ""
        #expect(adapter.scene.component(AnimationPlayer.self, for: a)?.time == 2)
        #expect(adapter.scene.component(AnimationPlayer.self, for: b)?.time == 0)
        #expect(adapter.scene.component(AnimationPlayer.self, for: b)?.clipName == nil)
        #expect(adapter.undoEdit())
        #expect(adapter.scene.component(AnimationPlayer.self, for: b)?.clipName == "Walk")
        #expect(adapter.scene.component(AnimationPlayer.self, for: b)?.time == 5)
        #expect(!adapter.canUndoEdit)
    }
}
