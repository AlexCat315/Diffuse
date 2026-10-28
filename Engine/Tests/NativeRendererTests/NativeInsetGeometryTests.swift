import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeInsetGeometryTests: XCTestCase {
    func testRecessedPanelRendersAndCancellationRestoresPixelsAndWireframe() throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-inset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = AssetRegistry(), document = GeometryDocument(name: "panel",source: .box(size: SIMD3(repeating: 2)))
        try document.save(to: root.appendingPathComponent("panel.dmesh"))
        let slot = try XCTUnwrap(assets.loadProject(at: root.path).first?.meshIndex)
        let device = try RendererTestDevice.make(DeviceConfig(preferredBackends: [api],enableValidation: true))
        let renderer = try NativeRenderer(device: device,assets: assets)
        defer { try? device.waitUntilIdle() }
        var packet = MeshProbeScene.packet(size: .init(width: 128,height: 128))
        packet.renderSettings.shading.debugViewMode = .worldNormal
        packet.scene.camera = RenderCamera(eye: SIMD3(3,2,6),target: .zero,near: 0.1,far: 100)
        packet.scene.instances = [RenderInstance(meshIndex: slot,transform: matrix_identity_float4x4)]
        try renderer.renderChecked(packet: packet)
        let before = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        var mesh = try document.source.evaluate()
        try mesh.inset(faces: [1],by: 0.25)
        try mesh.extrude(faces: [1],by: SIMD3(0,0,-0.5))
        let preview = try mesh.bake(name: "recess")
        assets.registerTransientMesh(preview.mesh,at: slot,assetID: "recess",topologySlices: [preview.topologySlice],polygonMesh: mesh)
        packet.frameIndex = 1
        try renderer.renderChecked(packet: packet)
        let inset = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertGreaterThan(try GridImage.difference(before,inset).pixelsOverThree,100)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,28)
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: slot)?.count,28)
        assets.unregisterTransientMesh(at: slot)
        packet.frameIndex = 2
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: slot)?.count,12)
        XCTAssertEqual(before,try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize))
    }
}
