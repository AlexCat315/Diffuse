import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeGeometryTests: XCTestCase {
    func testNativeGeometryLoadsRendersAndReplacesResidentMesh() throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-geometry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rounded.dmesh")
        var document = GeometryDocument(name: "Rounded", source: .box(size: SIMD3(repeating: 2)),
            modifiers: [.init(.subdivision(levels: 2))], shading: .smooth,
            materials: [.init(baseColor: SIMD4(0.1,0.6,0.9,1))])
        try document.save(to: url)
        let assets = AssetRegistry()
        let entry = try XCTUnwrap(assets.loadProject(at: root.path).first)
        let device = try RendererTestDevice.make(DeviceConfig(preferredBackends: [api], enableValidation: true))
        let renderer = try NativeRenderer(device: device, assets: assets)
        defer { try? device.waitUntilIdle() }
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 128, height: 128))
        packet.scene.camera = RenderCamera(eye: SIMD3(3,2,5), target: .zero, near: 0.1, far: 100)
        packet.scene.instances = []
        try renderer.renderChecked(packet: packet)
        let empty = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        packet.frameIndex = 1
        packet.scene.instances = [RenderInstance(meshIndex: entry.meshIndex, transform: matrix_identity_float4x4)]
        try renderer.renderChecked(packet: packet)
        let rounded = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount, 192)
        XCTAssertGreaterThan(try GridImage.difference(empty,rounded).pixelsOverThree, 100)
        document.modifiers = []
        try document.save(to: url)
        XCTAssertEqual(try assets.loadProject(at: root.path).first?.meshIndex, entry.meshIndex)
        packet.frameIndex = 2
        try renderer.renderChecked(packet: packet)
        let box = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount, 12)
        XCTAssertGreaterThan(try GridImage.difference(rounded,box).pixelsOverThree, 100)
    }
}
