import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeGeometryOverlayTests: XCTestCase {
    func testSurfaceWiresHideGpuDiagonalsAndFaceFillRespectsOtherObjects() throws {
        try withRenderer { device,renderer,slot in
            var packet = MeshProbeScene.packet(size: .init(width: 256,height: 256))
            packet.scene.camera = .init(eye: SIMD3(0,0,6),target: .zero,projection: .orthographic,orthographicHeight: 4)
            var blocker = matrix_identity_float4x4
            blocker.columns.0.x = 0.35; blocker.columns.1.y = 1.2; blocker.columns.2.z = 0.1
            blocker.columns.3 = SIMD4(0.2,0,1.3,1)
            packet.scene.instances = [.init(meshIndex: slot,transform: matrix_identity_float4x4),.init(meshIndex: slot,transform: blocker)]
            let original = try render(packet,device,renderer), red = SIMD4<Float>(1,0.1,0,1)
            var overlay = RenderGeometryOverlay(viewportSize: SIMD2(256,256))
            overlay.triangles = [.init(SIMD3(-1,-1,1),SIMD3(1,-1,1),SIMD3(1,1,1),color: .zero,
                                      edgeWidths: SIMD3(3,0,3),edgeA: red,edgeB: red,edgeC: red),
                                 .init(SIMD3(-1,-1,1),SIMD3(1,1,1),SIMD3(-1,1,1),color: .zero,
                                      edgeWidths: SIMD3(3,3,0),edgeA: red,edgeB: red,edgeC: red)]
            packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            let wire = try render(packet,device,renderer)
            XCTAssertEqual(pixel(wire,world: SIMD3(-0.5,-0.5,1),packet: packet),pixel(original,world: SIMD3(-0.5,-0.5,1),packet: packet))
            XCTAssertTrue(isOrange(wire,world: SIMD3(-1,0,1),packet: packet))
            for i in overlay.triangles.indices { overlay.triangles[i].color = SIMD4(1,0.48,0.08,0.3) }
            packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            let filled = try render(packet,device,renderer)
            XCTAssertNotEqual(pixel(filled,world: SIMD3(-0.6,0,1),packet: packet),pixel(original,world: SIMD3(-0.6,0,1),packet: packet))
            XCTAssertEqual(pixel(filled,world: SIMD3(0.2,0,1),packet: packet),pixel(original,world: SIMD3(0.2,0,1),packet: packet))
            overlay.xray = true; packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            XCTAssertNotEqual(pixel(try render(packet,device,renderer),world: SIMD3(0.2,0,1),packet: packet),pixel(original,world: SIMD3(0.2,0,1),packet: packet))
        }
    }

    func testDepthClipsPartiallyOccludedEdgesAndXrayRevealsThem() throws {
        try withRenderer { device,renderer,slot in
            var packet = MeshProbeScene.packet(size: .init(width: 256,height: 256))
            packet.scene.camera = .init(eye: SIMD3(0,0,6),target: .zero,projection: .orthographic,orthographicHeight: 4)
            packet.scene.instances = [.init(meshIndex: slot,transform: matrix_identity_float4x4)]
            let original = try render(packet,device,renderer)
            var overlay = RenderGeometryOverlay(viewportSize: SIMD2(256,256))
            overlay.lines = [.init(SIMD3(-1.7,0,0),SIMD3(1.7,0,0),color: SIMD4(1,0.1,0,1),width: 4)]
            packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            let clipped = try render(packet,device,renderer)
            for x: Float in [-1.4,1.4] { XCTAssertTrue(isOrange(clipped,world: SIMD3(x,0,0),packet: packet)) }
            XCTAssertEqual(pixel(clipped,world: .zero,packet: packet),pixel(original,world: .zero,packet: packet))
            overlay.xray = true; packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            XCTAssertTrue(isOrange(try render(packet,device,renderer),world: .zero,packet: packet))
            packet.scene.geometryOverlays = []; packet.frameIndex += 1
            XCTAssertEqual(try render(packet,device,renderer),original)
        }
    }

    func testRecessedFaceFillAndItsEdgesFollowDepthAtFrontalObliqueAndGrazingAngles() throws {
        try withRenderer(recess: true) { device,renderer,slot in
            var mesh = try GeometryPrimitives.box(size: SIMD3(repeating: 2))
            try mesh.inset(faces: [1],by: 0.3); try mesh.extrude(faces: [1],by: SIMD3(0,0,-0.6))
            let topology = try mesh.topologySlice(), surface = MeshPickingSurface(positions: mesh.positions,indices: topology.triangleIndices)
            let face = mesh.faces[1], points = face.vertices.map { mesh.positions[$0] }
            var packet = MeshProbeScene.packet(size: .init(width: 256,height: 256))
            packet.scene.instances = [.init(meshIndex: slot,transform: matrix_identity_float4x4)]
            for eye in [SIMD3<Float>(0,0,6),SIMD3(4,2,6),SIMD3(-4,2,6),SIMD3(6,1,2)] {
                packet.scene.camera = .init(eye: eye,target: .zero,near: 0.1,far: 100)
                packet.scene.geometryOverlays = []; packet.frameIndex += 1
                let original = try render(packet,device,renderer)
                var fill = RenderGeometryOverlay(viewportSize: SIMD2(256,256))
                fill.triangles = [.init(points[0],points[1],points[2],color: SIMD4(1,0.48,0.08,0.3)),
                                  .init(points[0],points[2],points[3],color: SIMD4(1,0.48,0.08,0.3))]
                packet.scene.geometryOverlays = [fill]; packet.frameIndex += 1
                let highlighted = try render(packet,device,renderer)
                for x: Float in [-0.45,0,0.45] { for y: Float in [-0.45,0,0.45] {
                    let p = SIMD3(x,y,0.4), distance = simd_length(p-eye), direction = (p-eye)/distance
                    let nearest = surface.hitDistance(origin: eye,direction: direction,maxDistance: distance+0.01) ?? distance
                    if abs(nearest-distance) < 0.001 {
                        XCTAssertNotEqual(pixel(original,world: p,packet: packet),pixel(highlighted,world: p,packet: packet))
                    } else if nearest < distance-0.04 {
                        XCTAssertEqual(pixel(original,world: p,packet: packet),pixel(highlighted,world: p,packet: packet))
                    }
                } }
                for i in points.indices {
                    let a = points[i], b = points[(i+1)%points.count]
                    var wire = RenderGeometryOverlay(viewportSize: SIMD2(256,256))
                    let selected = PolygonMeshEdge(face.vertices[i],face.vertices[(i+1)%points.count])
                    for t in stride(from: 0,to: topology.triangleIndices.count,by: 3) {
                        let ids = (0..<3).map { Int(topology.triangleIndices[t+$0]) }
                        let edges = [PolygonMeshEdge(ids[1],ids[2]),.init(ids[2],ids[0]),.init(ids[0],ids[1])]
                        let red = SIMD4<Float>(1,0.1,0,1)
                        wire.triangles.append(.init(mesh.positions[ids[0]],mesh.positions[ids[1]],mesh.positions[ids[2]],color: .zero,
                            edgeWidths: SIMD3(edges[0] == selected ? 3 : 0,edges[1] == selected ? 3 : 0,edges[2] == selected ? 3 : 0),
                            edgeA: red,edgeB: red,edgeC: red))
                    }
                    packet.scene.geometryOverlays = [wire]; packet.frameIndex += 1
                    let image = try render(packet,device,renderer)
                    for step in 1..<10 {
                        let p = a+(b-a)*(Float(step)/10), distance = simd_length(p-eye), direction = (p-eye)/distance
                        let nearest = surface.hitDistance(origin: eye,direction: direction,maxDistance: distance+0.01) ?? distance
                        if abs(nearest-distance) < 0.001 { XCTAssertTrue(isOrange(image,world: p,packet: packet),"visible edge at \(eye) \(p)") }
                        else if nearest < distance-0.06 { XCTAssertFalse(isOrange(image,world: p,packet: packet,radius: 0),"hidden edge at \(eye) \(p)") }
                    }
                }
            }
        }
    }

    func testOverlayIsOutsideOpaqueCacheAndDoesNotLeakAfterSelectionClears() throws {
        try withRenderer { device,renderer,slot in
            var packet = MeshProbeScene.packet(size: .init(width: 128,height: 128))
            packet.renderSettings.shading.pbr = true
            packet.scene.camera = .init(eye: SIMD3(0,0,6),target: .zero)
            packet.scene.instances = [.init(meshIndex: slot,transform: matrix_identity_float4x4)]
            let original = try render(packet,device,renderer)
            var overlay = RenderGeometryOverlay(viewportSize: SIMD2(128,128))
            overlay.triangles = [.init(SIMD3(-1,-1,1),SIMD3(1,-1,1),SIMD3(1,1,1),color: SIMD4(1,0.48,0.08,0.3))]
            packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
            XCTAssertGreaterThan(try GridImage.difference(original,render(packet,device,renderer)).pixelsOverThree,100)
            packet.scene.geometryOverlays = []; packet.frameIndex += 1
            let cleared = try render(packet,device,renderer)
            XCTAssertTrue(renderer.lastFrameUsedOpaqueCache)
            XCTAssertEqual(cleared,original)
        }
    }

    private func withRenderer(recess: Bool = false,_ body: (Device,NativeRenderer,Int) throws -> Void) throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-gpu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var mesh = try GeometryPrimitives.box(size: SIMD3(repeating: 2))
        if recess { try mesh.inset(faces: [1],by: 0.3); try mesh.extrude(faces: [1],by: SIMD3(0,0,-0.6)) }
        try GeometryDocument(name: "surface",source: .polygon(mesh: mesh)).save(to: root.appendingPathComponent("surface.dmesh"))
        let assets = AssetRegistry(), slot = try XCTUnwrap(assets.loadProject(at: root.path).first?.meshIndex)
        let device = try RendererTestDevice.make(.init(preferredBackends: [api],enableValidation: true))
        let renderer = try NativeRenderer(device: device,assets: assets)
        defer { try? device.waitUntilIdle() }
        try body(device,renderer,slot)
    }
    private func render(_ packet: RenderPacket,_ device: Device,_ renderer: NativeRenderer) throws -> Data {
        try renderer.renderChecked(packet: packet)
        return try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
    }
    private func pixel(_ data: Data,world: SIMD3<Float>,packet: RenderPacket,dx: Int = 0,dy: Int = 0) -> [UInt8] {
        let p = RenderCameraMatrices.make(scene: packet.scene,drawableSize: packet.drawableSize).viewProjection*SIMD4(world,1)
        let x = max(0,min(Int(packet.drawableSize.width)-1,Int((p.x/p.w*0.5+0.5)*Float(packet.drawableSize.width))+dx))
        let y = max(0,min(Int(packet.drawableSize.height)-1,Int((0.5-p.y/p.w*0.5)*Float(packet.drawableSize.height))+dy))
        let i = (y*Int(packet.drawableSize.width)+x)*4
        return Array(data[i..<i+4])
    }
    private func isOrange(_ data: Data,world: SIMD3<Float>,packet: RenderPacket,radius: Int = 1) -> Bool {
        (-radius...radius).contains { y in (-radius...radius).contains { x in
            let p = pixel(data,world: world,packet: packet,dx: x,dy: y)
            return Int(p[2]) > Int(p[1])+70 && Int(p[1]) > Int(p[0])+10
        } }
    }
}
