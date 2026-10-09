import Foundation
import AssetPipeline
import GuavaUIRuntime
import GuavaUICompose
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing
@testable import EditorCore

@Suite("Editor surface picking", .serialized)
@MainActor
struct EditorViewportSurfacePickingTests {
    @Test("material coverage and authored LOD survive scene save and load, including missing optional fields")
    func scenePersistence() throws {
        let adapter = EditorSceneAdapter()
        let id = try #require(adapter.spawnEntity(template: .cube))
        let entity = EntityID(index: UInt32(id & 0xFFFF_FFFF), generation: UInt32(id >> 32))
        let material = RenderMaterialComponent(baseColorFactor: SIMD4(1, 1, 1, 0.4),
            alphaMode: .blend, alphaCutoff: 0.35, doubleSided: true)
        _ = adapter.scene.setComponent(material, for: entity)
        var mesh = try #require(adapter.scene.component(RenderMeshComponent.self, for: entity))
        mesh.levelsOfDetail = [RenderMeshLOD(meshIndex: 3, minimumDistance: 20)]
        _ = adapter.scene.setComponent(mesh, for: entity)
        let data = try JSONEncoder().encode(adapter.manifest())
        let saved = try JSONDecoder().decode(EditorSceneManifest.self, from: data)
        let restored = EditorSceneAdapter(); _ = restored.load(manifest: saved)
        #expect(restored.scene.component(RenderMaterialComponent.self, for: entity) == material)
        #expect(restored.scene.component(RenderMeshComponent.self, for: entity)?.levelsOfDetail == mesh.levelsOfDetail)
        let emptyNode = try JSONDecoder().decode(EditorSceneManifestNode.self,
            from: Data(#"{"id":0,"name":"Empty","kind":"empty"}"#.utf8))
        #expect(emptyNode.components.isEmpty && emptyNode.children.isEmpty)
    }

    @Test("a triangle's blank bounding-box corner stays unselected despite its collider",
          arguments: [RenderCamera.Projection.perspective, .orthographic])
    func triangleAndCollider(projection: RenderCamera.Projection) throws {
        let slot = 402_001
        var vertices: [Float] = []
        for p in [SIMD3<Float>(-1, -1, 0), SIMD3<Float>(1, -1, 0), SIMD3<Float>(-1, 1, 0)] {
            MeshAsset.appendVertex(to: &vertices, position: p, normal: SIMD3(0, 0, 1))
        }
        let mesh = MeshAsset(name: "triangle", vertices: vertices, indices: [0, 1, 2])
        MeshPickingRegistry.shared.register(meshIndex: slot, mesh: mesh)
        MeshBoundsRegistry.shared.register(meshIndex: slot, min: mesh.localBounds.min, max: mesh.localBounds.max)
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        adapter.lookAlongAxis(SIMD3(0, 0, -1), orthographic: projection == .orthographic)
        let asset = EditorAsset(id: "triangle", name: "triangle", relativePath: "triangle.obj",
            absolutePath: "/tmp/triangle.obj", kind: .obj, meshIndex: slot)
        let rawID = try #require(adapter.spawnEntity(from: asset, at: .zero))
        adapter.tickScene()
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        let projection = try #require(EditorViewportProjection(camera: adapter.currentRenderCamera(), frame: frame))
        let empty = try #require(projection.project(SIMD3(0.8, 0.8, 0)))
        #expect(adapter.pickEntity(cursorX: empty.x, cursorY: empty.y, in: frame) == nil)
        let solid = try #require(projection.project(SIMD3(-0.6, -0.6, 0)))
        #expect(adapter.pickEntity(cursorX: solid.x, cursorY: solid.y, in: frame) == rawID)
    }

    @Test("rotated, negatively scaled meshes retain world-distance ordering")
    func rotatedAndScaled() throws {
        let adapter = EditorSceneAdapter()
        adapter.setEditorViewportCameraEnabled(true)
        adapter.lookAlongAxis(SIMD3(0, 0, -1), orthographic: true)
        let front = try #require(adapter.spawnEntity(template: .cube))
        let rear = try #require(adapter.spawnEntity(template: .cube))
        let entity = EntityID(index: UInt32(front & 0xFFFF_FFFF), generation: UInt32(front >> 32))
        var matrix = simd_float4x4(simd_quatf(angle: .pi / 4, axis: SIMD3(0, 1, 0)))
        matrix.columns.0 *= -0.5; matrix.columns.1 *= 2; matrix.columns.2 *= 0.5
        _ = adapter.scene.setLocalTransform(LocalTransform(matrix: matrix), for: entity)
        adapter.setEntityLocalTranslation(rear, to: SIMD3(0, 0, -3))
        adapter.tickScene()
        let frame = ViewportScreenFrame(x: 0, y: 0, width: 800, height: 600)
        let center = try #require(EditorViewportProjection(camera: adapter.currentRenderCamera(), frame: frame)?.project(.zero))
        #expect(adapter.pickEntity(cursorX: center.x, cursorY: center.y, in: frame) == front)
    }
}
