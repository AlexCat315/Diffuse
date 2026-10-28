import AssetPipeline
@testable import EditorCore
import Foundation
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Mesh edit workflow", .serialized)
@MainActor
struct MeshEditingTests {
    @Test("saving during an interactive transform commits one edit and persists the scene")
    func saveDuringTransform() throws { try withApp { app,id in
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let before = try #require(try app.geometryAuthoring.document(for: id))
        #expect(app.meshEditing.beginTransform())
        var delta = matrix_identity_float4x4; delta.columns.3.x = 1
        #expect(app.meshEditing.previewTransform(delta))
        let saved = try #require(app.saveSceneManifest())
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(!app.meshEditing.isTransforming && !app.geometryAuthoring.hasInteractiveEdit)
        let asset = try #require(app.scene.referencedAsset(for: id))
        let document = try GeometryDocument.load(from: URL(fileURLWithPath: asset.absolutePath))
        #expect(try document.evaluate().mesh.localBounds.max.x == 1.5)
        app.undo()
        #expect(try app.geometryAuthoring.document(for: id) == before)
    } }

    @Test("a complete closed selection can extrude along an explicitly chosen axis")
    func extrusionAxis() throws { try withApp { app,_ in
        #expect(app.meshEditing.setMode(.face)); app.meshEditing.selectAll()
        app.meshEditing.extrusionDirection = .y; app.meshEditing.extrusionDistance = 1
        #expect(app.meshEditing.extrudeRegion())
        let mesh = try #require(app.meshEditing.controlMesh())
        #expect(try mesh.bake(name: "translated region").mesh.localBounds.max.y == 1.5)
        #expect(mesh.faces.count == 6)
    } }

    @Test("selection modes resolve editable control vertices and clear stale topology selection")
    func selection() throws { try withApp { app,id in
        #expect(app.meshEditing.setMode(.vertex))
        app.meshEditing.select([0,1,99])
        #expect(app.meshEditing.selection == [0,1])
        #expect(app.meshEditing.selectedVertices == [0,1])
        #expect(app.meshEditing.setMode(.edge))
        app.meshEditing.select([0])
        let edge = try #require(app.meshEditing.picker()?.edges.first)
        #expect(app.meshEditing.selectedVertices == [edge.a,edge.b])
        #expect(app.meshEditing.setMode(.face))
        app.meshEditing.select([3])
        #expect(app.meshEditing.selectedVertices.count == 4)
        let before = try #require(app.meshEditing.controlMesh())
        #expect(app.meshEditing.extrudeRegion())
        #expect(app.meshEditing.controlMesh()?.faces.count == before.faces.count+4)
        #expect(app.meshEditing.selection == [3])
        app.undo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh() == before)
        #expect(app.meshEditing.selection.isEmpty)
        #expect(app.scene.inspectorSections(for: id).contains { $0.id == "mesh-edit-selection" })
    } }

    @Test("drag previews do not write the file or history and Escape/undo cancels them")
    func previewCancel() throws { try withApp { app,id in
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let asset = try #require(app.scene.referencedAsset(for: id)), url = URL(fileURLWithPath: asset.absolutePath)
        let original = try Data(contentsOf: url)
        let source = try #require(app.meshEditing.controlMesh())
        #expect(app.meshEditing.beginTransform())
        var delta = matrix_identity_float4x4; delta.columns.3.x = 0.2
        #expect(app.meshEditing.previewTransform(delta))
        delta.columns.3.x = 0.4
        #expect(app.meshEditing.previewTransform(delta))
        #expect(app.meshEditing.controlMesh()?.positions[0] == source.positions[0]+SIMD3(0.4,0,0))
        #expect(try Data(contentsOf: url) == original)
        #expect(abs((AssetRegistry.shared.meshAsset(for: asset.meshIndex)?.localBounds.max.x ?? 0)-0.9) < 1e-6)
        app.undo()
        #expect(!app.meshEditing.isTransforming && !app.geometryAuthoring.hasInteractiveEdit)
        #expect(app.meshEditing.controlMesh() == source)
        #expect(AssetRegistry.shared.meshAsset(for: asset.meshIndex)?.localBounds.max.x == 0.5)
        #expect(try Data(contentsOf: url) == original)
        app.undo(); app.meshEditing.synchronize()
        #expect(!app.meshEditing.isEditing) // Undo now reaches the original source conversion.
    } }

    @Test("one drag commits as one reversible asset edit while retaining modifiers")
    func previewCommit() throws { try withApp { app,id in
        #expect(app.geometryAuthoring.addModifier(.array(count: 2,offset: SIMD3(2,0,0)),to: id))
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let original = try #require(try app.geometryAuthoring.document(for: id))
        #expect(app.meshEditing.beginTransform())
        var delta = matrix_identity_float4x4; delta.columns.3.y = 0.2
        #expect(app.meshEditing.previewTransform(delta))
        delta.columns.3.y = 0.5
        #expect(app.meshEditing.previewTransform(delta))
        #expect(app.meshEditing.finishTransform())
        let final = try #require(try app.geometryAuthoring.document(for: id))
        #expect(final.modifiers == original.modifiers)
        #expect(try final.evaluate().mesh.localBounds.max.y == 1)
        app.undo()
        #expect(try app.geometryAuthoring.document(for: id) == original)
        app.redo()
        #expect(try app.geometryAuthoring.document(for: id) == final)
    } }

    @Test("external source changes during a drag cannot be overwritten")
    func conflict() throws { try withApp { app,id in
        #expect(app.meshEditing.setMode(.vertex)); app.meshEditing.selectAll()
        let asset = try #require(app.scene.referencedAsset(for: id)), url = URL(fileURLWithPath: asset.absolutePath)
        #expect(app.meshEditing.beginTransform())
        var delta = matrix_identity_float4x4; delta.columns.3.y = 1
        #expect(app.meshEditing.previewTransform(delta))
        var external = try GeometryDocument.load(from: url); external.name = "External"
        try external.save(to: url)
        #expect(!app.meshEditing.finishTransform())
        #expect(try GeometryDocument.load(from: url) == external)
        #expect(AssetRegistry.shared.meshAsset(for: asset.meshIndex)?.name == "External")
        #expect(!app.geometryAuthoring.hasInteractiveEdit)
    } }

    @Test("picking observes other scene meshes, including movement after the picker was cached")
    func sceneOcclusion() throws { try withApp { app,id in
        #expect(app.meshEditing.setMode(.face))
        MeshPickingRegistry.shared.register(meshIndex: 0,mesh: BuiltinMesh.cube())
        let blocker = try #require(app.scene.spawnEntity(template: .cube))
        var matrix = matrix_identity_float4x4; matrix.columns.0.x = 3; matrix.columns.1.y = 3; matrix.columns.3.z = 2
        app.scene.setEntityLocalMatrix(blocker,to: matrix)
        app.scene.setEditorViewportCameraEnabled(true)
        app.scene.lookAlongAxis(SIMD3(0,0,-1),orthographic: true)
        app.scene.tickScene()
        let picker = try #require(app.meshEditing.picker())
        let projection = try #require(EditorViewportProjection(camera: app.scene.currentRenderCamera(),
            frame: .init(x: 0,y: 0,width: 800,height: 600)))
        let screen = try #require(projection.project(.zero))
        #expect(picker.pick(x: screen.x,y: screen.y,mode: .face,projection: projection) == nil)
        #expect(picker.pick(x: screen.x,y: screen.y,mode: .face,projection: projection,xray: true)?.index == 1)
        app.scene.setEntityLocalTranslation(blocker,to: SIMD3(20,0,2)); app.scene.tickScene()
        #expect(picker.pick(x: screen.x,y: screen.y,mode: .face,projection: projection)?.index == 1)
        #expect(app.meshEditing.entityID == id)
    } }

    private func withApp(_ work: (EditorApplication,UInt64) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        try work(app,id)
    }
}
