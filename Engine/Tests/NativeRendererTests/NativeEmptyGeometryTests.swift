import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeEmptyGeometryTests: XCTestCase {
    func testDeletingEveryFaceClearsPixelsAndRestoringTheAssetRestoresTheImage() throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("surface.dmesh"), assets = AssetRegistry()
        let original = GeometryDocument(name: "surface",source: .box(size: SIMD3(repeating: 2)))
        try original.save(to: url)
        let slot = try XCTUnwrap(assets.loadProject(at: root.path).first?.meshIndex)
        let device = try RendererTestDevice.make(DeviceConfig(preferredBackends: [api],enableValidation: true))
        let renderer = try NativeRenderer(device: device,assets: assets)
        defer { try? device.waitUntilIdle() }
        var packet = MeshProbeScene.packet(size: .init(width: 128,height: 128))
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,6),target: .zero,near: 0.1,far: 100)
        packet.scene.instances = []
        try renderer.renderChecked(packet: packet)
        let background = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        packet.scene.instances = [RenderInstance(meshIndex: slot,transform: matrix_identity_float4x4)]
        packet.frameIndex = 1
        try renderer.renderChecked(packet: packet)
        let filled = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertGreaterThan(try GridImage.difference(background,filled).pixelsOverThree,100)
        var empty = original, mesh = try original.source.evaluate()
        try mesh.delete(faces: Set(mesh.faces.indices))
        empty.source = .polygon(mesh: mesh)
        try empty.save(to: url)
        XCTAssertEqual(try assets.loadProject(at: root.path).first?.meshIndex,slot)
        packet.frameIndex = 2
        try renderer.renderChecked(packet: packet)
        let cleared = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertEqual(cleared,background)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,0)
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: slot)?.count,0)
        XCTAssertNil(MeshPickingRegistry.shared.surface(for: slot)?.hitDistance(origin: SIMD3(0,0,6),direction: SIMD3(0,0,-1)))
        try original.save(to: url)
        XCTAssertEqual(try assets.loadProject(at: root.path).first?.meshIndex,slot)
        packet.frameIndex = 3
        try renderer.renderChecked(packet: packet)
        let restored = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertEqual(restored,filled)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,12)
    }
}
