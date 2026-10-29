import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeLoopCutTests: XCTestCase {
    func testTransientCutsRenderSelectableSurfaceWiresAndCancelRestoresTheOriginal() throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loop-cut-gpu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = GeometryDocument(name: "cube",source: .box(size: SIMD3(repeating: 2)))
        try source.save(to: root.appendingPathComponent("cube.dmesh"))
        let assets = AssetRegistry(), entry = try XCTUnwrap(assets.loadProject(at: root.path).first)
        let device = try RendererTestDevice.make(.init(preferredBackends: [api],enableValidation: true))
        let renderer = try NativeRenderer(device: device,assets: assets)
        defer { try? device.waitUntilIdle() }
        var packet = MeshProbeScene.packet(size: .init(width: 128,height: 128))
        packet.scene.camera = .init(eye: SIMD3(3,2,6),target: .zero)
        packet.scene.instances = [.init(meshIndex: entry.meshIndex,transform: matrix_identity_float4x4)]
        try renderer.renderChecked(packet: packet)
        let original = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        var mesh = try source.source.evaluate()
        let cuts = try mesh.loopCut(startingAt: .init(0,1),cuts: 2,slide: 0.3), baked = try mesh.bake(name: "cut")
        assets.registerTransientMesh(baked.mesh,at: entry.meshIndex,assetID: entry.id,topologySlices: [baked.topologySlice],polygonMesh: mesh)
        var overlay = RenderGeometryOverlay(viewportSize: SIMD2(128,128))
        let triangles = try mesh.topologySlice().triangleIndices, color = SIMD4<Float>(1,0.58,0.12,1)
        for i in stride(from: 0,to: triangles.count,by: 3) {
            let v = (0..<3).map { Int(triangles[i+$0]) }
            let edges = [PolygonMeshEdge(v[1],v[2]),.init(v[2],v[0]),.init(v[0],v[1])]
            overlay.triangles.append(.init(mesh.positions[v[0]],mesh.positions[v[1]],mesh.positions[v[2]],color: .zero,
                edgeWidths: SIMD3(cuts.contains(edges[0]) ? 2 : 0,cuts.contains(edges[1]) ? 2 : 0,cuts.contains(edges[2]) ? 2 : 0),
                edgeA: color,edgeB: color,edgeC: color))
        }
        packet.scene.geometryOverlays = [overlay]; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        let preview = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,28)
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: entry.meshIndex)?.count,28)
        XCTAssertGreaterThan(try GridImage.difference(original,preview).pixelsOverThree,70)
        assets.unregisterTransientMesh(at: entry.meshIndex); packet.scene.geometryOverlays = []; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,12)
        XCTAssertEqual(original,try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize))
    }
}
