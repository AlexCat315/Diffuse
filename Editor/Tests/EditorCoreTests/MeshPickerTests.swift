import AssetPipeline
import CoveUICompose
import CoveUIRuntime
import EditorCore
import Foundation
import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Control mesh picking")
struct MeshPickerTests {
    @Test("vertices and edges reject occluded cage elements",arguments: [RenderCamera.Projection.perspective,.orthographic])
    func cageVisibility(projection kind: RenderCamera.Projection) throws {
        let mesh = try GeometryPrimitives.box()
        let picker = try EditorMeshPicker(mesh: mesh,worldMatrix: matrix_identity_float4x4)
        let projection = try #require(EditorViewportProjection(camera: RenderCamera(eye: SIMD3(0,0,5),target: .zero,
            projection: kind,orthographicHeight: 4),frame: .init(x: 70,y: 90,width: 800,height: 600)))
        #expect(!picker.isVisible(picker.positions[0],projection: projection,xray: false))
        #expect(picker.isVisible(picker.positions[0],projection: projection,xray: true))
        #expect(picker.isVisible(picker.positions[4],projection: projection,xray: false))
        let vertex = try #require(projection.project(picker.positions[4]))
        #expect(picker.pick(x: vertex.x,y: vertex.y,mode: .vertex,projection: projection)?.index == 4)
        let edgeIndex = try #require(picker.edges.firstIndex(of: .init(6,7)))
        let edge = try #require(projection.project((picker.positions[6]+picker.positions[7])*0.5))
        #expect(picker.pick(x: edge.x,y: edge.y,mode: .edge,projection: projection)?.index == edgeIndex)
        #expect(picker.pick(x: 0,y: 0,mode: .vertex,projection: projection) == nil)
    }

    @Test("orthographic marquee supports through selection without changing point picking priority")
    func marquee() throws {
        let picker = try EditorMeshPicker(mesh: GeometryPrimitives.box(),worldMatrix: matrix_identity_float4x4)
        let projection = try #require(EditorViewportProjection(camera: RenderCamera(eye: SIMD3(0,0,5),target: .zero,
            projection: .orthographic,orthographicHeight: 4),frame: .init(x: 0,y: 0,width: 800,height: 600)))
        let point = try #require(projection.project(picker.positions[4]))
        let rect = UIRect(x: point.x-2,y: point.y-2,width: 4,height: 4)
        #expect(picker.pick(in: rect,mode: .vertex,projection: projection) == [4])
        #expect(picker.pick(in: rect,mode: .vertex,projection: projection,xray: true) == [0,4])
        #expect(picker.pick(x: point.x,y: point.y,mode: .vertex,projection: projection,xray: true)?.index == 4)
    }

    @Test("face hits use real concave triangles and world distances under negative scale")
    func faces() throws {
        var world = matrix_identity_float4x4
        world.columns.0.x = -2; world.columns.1.y = 1.5; world.columns.2.z = 0.5; world.columns.3 = SIMD4(1,-1,0,1)
        let picker = try EditorMeshPicker(mesh: GeometryPrimitives.box(),worldMatrix: world)
        let camera = RenderCamera(eye: SIMD3(1,-1,5),target: SIMD3(1,-1,0),projection: .orthographic,orthographicHeight: 4)
        let projection = try #require(EditorViewportProjection(camera: camera,frame: .init(x: 0,y: 0,width: 800,height: 600)))
        let center = try #require(projection.project(SIMD3(1,-1,0)))
        let hit = try #require(picker.pick(x: center.x,y: center.y,mode: .face,projection: projection))
        #expect(hit.index == 1)
        #expect(abs(hit.distance-(5-camera.near-0.25)) < 1e-5)
        let polygon = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(2,0,0),SIMD3(2,1,0),SIMD3(1,1,0),SIMD3(1,2,0),SIMD3(0,2,0)],faces: [.init([0,1,2,3,4,5])])
        let concave = try EditorMeshPicker(mesh: polygon,worldMatrix: matrix_identity_float4x4)
        let concaveProjection = try #require(EditorViewportProjection(camera: RenderCamera(eye: SIMD3(1,1,5),target: SIMD3(1,1,0),
            projection: .orthographic,orthographicHeight: 4),frame: .init(x: 0,y: 0,width: 800,height: 600)))
        let blank = try #require(concaveProjection.project(SIMD3(1.5,1.5,0)))
        let solid = try #require(concaveProjection.project(SIMD3(0.5,0.5,0)))
        #expect(concave.pick(x: blank.x,y: blank.y,mode: .face,projection: concaveProjection) == nil)
        #expect(concave.pick(x: solid.x,y: solid.y,mode: .face,projection: concaveProjection)?.index == 0)
    }
}
