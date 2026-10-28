import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeGeometryTests: XCTestCase {
    func testInteractivePreviewAndCancellationChangeAndRestorePixels() throws {
        #if os(macOS)
        let api = GraphicsAPI.metal
        #elseif os(Windows)
        let api = GraphicsAPI.dx12
        #else
        let api = GraphicsAPI.vulkan
        #endif
        let assets = AssetRegistry()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = GeometryDocument(name: "original",source: .box(size: SIMD3(repeating: 2)))
        let original = try document.evaluate()
        try document.save(to: root.appendingPathComponent("cube.dmesh"))
        let slot = try XCTUnwrap(assets.loadProject(at: root.path).first?.meshIndex)
        let device = try RendererTestDevice.make(DeviceConfig(preferredBackends: [api],enableValidation: true))
        let renderer = try NativeRenderer(device: device,assets: assets)
        defer { try? device.waitUntilIdle() }
        var packet = MeshProbeScene.packet(size: .init(width: 128,height: 128))
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,6),target: .zero,near: 0.1,far: 100)
        packet.scene.instances = [RenderInstance(meshIndex: slot,transform: matrix_identity_float4x4)]
        try renderer.renderChecked(packet: packet)
        let before = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        var mesh = original.controlMesh
        var delta = matrix_identity_float4x4; delta.columns.3.x = 0.8
        try mesh.transform(vertices: Set(mesh.positions.indices),by: delta)
        let preview = try mesh.bake(name: "preview")
        assets.registerTransientMesh(preview.mesh,at: slot,assetID: "preview",topologySlices: [preview.topologySlice],polygonMesh: preview.controlMesh)
        packet.frameIndex = 1
        try renderer.renderChecked(packet: packet)
        let moved = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertGreaterThan(try GridImage.difference(before,moved).pixelsOverThree,100)
        assets.unregisterTransientMesh(at: slot)
        packet.frameIndex = 2
        try renderer.renderChecked(packet: packet)
        let cancelled = try GridImage.readback(device: device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        XCTAssertEqual(before,cancelled)
    }

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
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: entry.meshIndex)?.count, 192)
        XCTAssertEqual(assets.polygonMesh(for: entry.meshIndex)?.faces.count, 96)
        XCTAssertNotNil(MeshBoundsRegistry.shared.bounds(for: entry.meshIndex))
        XCTAssertGreaterThan(try GridImage.difference(empty,rounded).pixelsOverThree, 100)
        document.modifiers = []
        try document.save(to: url)
        XCTAssertEqual(try assets.loadProject(at: root.path).first?.meshIndex, entry.meshIndex)
        packet.frameIndex = 2
        try renderer.renderChecked(packet: packet)
        let box = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount, 12)
        XCTAssertEqual(MeshWireframeRegistry.shared.edges(for: entry.meshIndex)?.count, 12)
        XCTAssertGreaterThan(try GridImage.difference(rounded,box).pixelsOverThree, 100)
        try FileManager.default.removeItem(at: url)
        _ = try assets.loadProject(at: root.path)
        packet.frameIndex = 3; packet.scene.instances = []
        try renderer.renderChecked(packet: packet)
        XCTAssertNil(MeshWireframeRegistry.shared.edges(for: entry.meshIndex))
        XCTAssertNil(MeshBoundsRegistry.shared.bounds(for: entry.meshIndex))
        XCTAssertNotNil(MeshWireframeRegistry.shared.edges(for: 0))
    }
}
