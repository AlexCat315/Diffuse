import AssetPipeline
@testable import EditorCore
import Foundation
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Mesh topology workflow",.serialized)
@MainActor
struct MeshTopologyEditingTests {
    @Test("component modes delete the matching structure and retain the scene object",arguments: [EditorMeshSelectionMode.vertex,.edge,.face])
    func deleteComponents(mode: EditorMeshSelectionMode) throws { try withApp { app,id,_ in
        #expect(app.meshEditing.setMode(mode)); app.meshEditing.select([0])
        let expected = mode == .vertex ? 3 : mode == .edge ? 4 : 5
        #expect(app.meshEditing.deleteSelection())
        #expect(app.meshEditing.controlMesh()?.faces.count == expected)
        #expect(app.meshEditing.selection.isEmpty && app.store.selectedEntityID == id)
        #expect(app.scene.entitySummary(id: id) != nil)
        let asset = try #require(app.scene.referencedAsset(for: id))
        #expect(try GeometryDocument.load(from: URL(fileURLWithPath: asset.absolutePath)).source.evaluate().faces.count == expected)
        app.undo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh()?.faces.count == 6)
        app.redo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh()?.faces.count == expected)
    } }

    @Test("deleting the last face preserves modifiers, empty collision data and scene reopening")
    func emptyAndRestore() throws { try withApp { app,id,root in
        #expect(app.meshEditing.setMode(.face))
        #expect(app.geometryAuthoring.addModifier(.subdivision(levels: 1),to: id))
        #expect(app.geometryAuthoring.addModifier(.array(count: 2,offset: SIMD3(2,0,0)),to: id))
        let original = try #require(try app.geometryAuthoring.document(for: id))
        let asset = try #require(app.scene.referencedAsset(for: id)), resourceID = "meshIndex:\(asset.meshIndex)"
        app.meshEditing.selectAll()
        #expect(app.meshEditing.deleteSelection())
        #expect(app.meshEditing.isEditing && app.meshEditing.controlMesh()?.positions.isEmpty == true)
        #expect(app.meshEditing.picker()?.pick(x: 100,y: 100,mode: .face,
            projection: try #require(EditorViewportProjection(camera: app.scene.currentRenderCamera(),frame: .init(x: 0,y: 0,width: 400,height: 400)))) == nil)
        #expect(try app.geometryAuthoring.document(for: id)?.modifiers == original.modifiers)
        #expect(app.scene.scene.resource(MeshColliderGeometryResource.self)?.geometryByResourceID[resourceID]?.triangleCount == 0)
        #expect(app.scene.scene.resource(MeshColliderBoundsResource.self)?.boundsByResourceID[resourceID]?.max == .zero)
        _ = try #require(app.saveSceneManifest())
        do {
            let restored = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
            defer { restored.shutdown() }
            _ = try #require(restored.openSceneManifest())
            #expect(restored.scene.entitySummary(id: id) != nil)
            #expect(try restored.geometryAuthoring.document(for: id)?.source.evaluate().faces.isEmpty == true)
        }
        app.undo(); app.meshEditing.synchronize()
        #expect(try app.geometryAuthoring.document(for: id) == original)
        #expect((app.scene.scene.resource(MeshColliderGeometryResource.self)?.geometryByResourceID[resourceID]?.triangleCount ?? 0) > 0)
        app.redo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh()?.faces.isEmpty == true)
        #expect(app.scene.scene.resource(MeshColliderGeometryResource.self)?.geometryByResourceID[resourceID]?.triangleCount == 0)
    } }

    @Test("dissolve joins triangulated faces without losing UVs and shares chronological history")
    func dissolveAndUndo() throws { try withApp { app,id,_ in
        #expect(app.geometryAuthoring.edit(entityID: id) { $0.source = .grid(size: SIMD2(2,2),segments: SIMD2(1,1)) })
        #expect(app.meshEditing.setMode(.face))
        let original = try #require(app.meshEditing.controlMesh())
        app.meshEditing.selectAll(); #expect(app.meshEditing.triangulateSelection())
        #expect(app.meshEditing.setMode(.edge))
        let mesh = try #require(app.meshEditing.controlMesh()), edgeIndex = try #require(mesh.edges.firstIndex { edge in
            mesh.faces.filter { $0.vertices.contains(edge.a) && $0.vertices.contains(edge.b) }.count == 2
        })
        app.meshEditing.select([edgeIndex])
        #expect(app.meshEditing.dissolveSelection())
        #expect(app.meshEditing.controlMesh() == original && app.meshEditing.selection.isEmpty)
        app.undo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh()?.faces.count == 2)
        app.redo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh() == original)
    } }

    @Test("failed dissolve preserves the file and history; active transforms reject topology edits")
    func failureAndTransform() throws { try withApp { app,id,_ in
        #expect(app.meshEditing.setMode(.edge))
        #expect(app.geometryAuthoring.edit(entityID: id) { document in
            var mesh = try GeometryPrimitives.grid(size: SIMD2(2,1),segments: SIMD2(2,1))
            mesh.faces[1].materialIndex = 1
            document.materials.append(.init())
            document.source = .polygon(mesh: mesh)
        })
        app.meshEditing.synchronize()
        let mesh = try #require(app.meshEditing.controlMesh()), index = try #require(mesh.edges.firstIndex(of: .init(1,4)))
        app.meshEditing.select([index])
        let asset = try #require(app.scene.referencedAsset(for: id)), url = URL(fileURLWithPath: asset.absolutePath)
        let data = try Data(contentsOf: url)
        #expect(!app.meshEditing.dissolveSelection())
        #expect(try Data(contentsOf: url) == data)
        #expect(app.meshEditing.beginTransform())
        #expect(!app.meshEditing.deleteSelection() && !app.meshEditing.dissolveSelection())
        #expect(app.meshEditing.cancelTransform())
        app.undo(); app.meshEditing.synchronize()
        #expect(app.meshEditing.controlMesh()?.faces.count == 6)
    } }

    private func withApp(_ body: (EditorApplication,UInt64,URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topology-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path,seedPreviewScene: false)
        defer { app.shutdown() }
        let id = try #require(app.geometryAuthoring.create(.box))
        try body(app,id,root)
    }
}
