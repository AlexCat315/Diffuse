import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativeOpaqueTests: XCTestCase {
    func testMetalMatchesProductionWGPUScene() throws { try parity(.metal) }
    func testVulkanMatchesProductionWGPUScene() throws { try parity(.vulkan) }
    func testMetalResourceReplacementAndRemoval() throws { try lifecycle(.metal) }
    func testVulkanResourceReplacementAndRemoval() throws { try lifecycle(.vulkan) }

    func testMetalImportedTexturesAndSubmeshes() throws { try imported(.metal) }
    func testVulkanImportedTexturesAndSubmeshes() throws { try imported(.vulkan) }

    func testMetalVisibilityAndLOD() throws { try visibility(.metal) }
    func testVulkanVisibilityAndLOD() throws { try visibility(.vulkan) }
    private func visibility(_ api: GraphicsAPI) throws {
        let assets = AssetRegistry()
        let cube = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        var simplified = cube; simplified.indices = Array(cube.indices.prefix(3))
        assets.registerForTesting(cube, at: 45); assets.registerForTesting(simplified, at: 46)
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
        let renderer = try NativeRenderer(device: device, assets: assets)
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 96,height: 96))
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,5),target: .zero,near: 0.1,far: 100)
        var distant = matrix_identity_float4x4; distant.columns.3.x = 10000
        packet.scene.instances = [RenderInstance(mesh: RenderMeshHandle(meshIndex: 45,
            levelsOfDetail: [RenderMeshLOD(meshIndex: 46,minimumDistance: 1)]), transform: matrix_identity_float4x4),
            RenderInstance(meshIndex: 45,transform: distant)]
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.culledMeshInstanceCount,1)
        XCTAssertEqual(renderer.lastFrameStats.lodMeshInstanceCount,1)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,1)
        packet.renderSettings.enableDistanceLOD = false
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,12)
        packet.renderSettings.enableFrustumCulling = false; packet.renderSettings.enableMeshInstancing = false
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.basePass],2)
        XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount,24)
        try device.waitUntilIdle()
    }

    private func imported(_ api: GraphicsAPI) throws {
        let asset = try MeshProbeScene.importedFixture()
        XCTAssertEqual(asset.submeshes.count, 2); XCTAssertEqual(asset.textures.count, 1)
        AssetRegistry.shared.registerForTesting(asset, at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 192,height: 128))
        packet.scene.camera = RenderCamera(eye: SIMD3(0,0,5), target: .zero, near: 0.1, far: 100)
        var back = matrix_identity_float4x4; back.columns.0.x = 2; back.columns.1.y = 2; back.columns.3.z = -1.5
        packet.scene.instances = [RenderInstance(meshIndex: 2, transform: matrix_identity_float4x4),
            RenderInstance(meshIndex: 0, transform: back, material: RenderMaterial(baseColorFactor: SIMD4(0.2,0.5,0.25,1)))]
        for frame in 0..<3 {
            packet.frameIndex = frame
            if frame == 1 { packet.scene.instances.reverse() }
            if frame == 2 {
                packet.scene.instances[1].transform.columns.0.x = -1
                packet.scene.instances[1].material.baseColorFactor = SIMD4(0.4,1,0.5,1)
            }
            try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
            let image = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
            if frame == 0 {
                let pixel = (64*192+80)*4
                XCTAssertEqual(image[pixel+2],0,"imported zero red factor must survive GPU shading")
                XCTAssertGreaterThan(image[pixel],5); XCTAssertGreaterThan(image[pixel+1],5)
            }
            let delta = try GridImage.difference(image, reference.readback())
            XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5, "textured \(api): \(delta)")
            XCTAssertLessThan(delta.pixelsOverThree, delta.pixelCount/100)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.basePass], 3)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.depthPrepass], 3)
        }
        // Masked fragments leave both color and depth untouched: opaque coverage
        // must fill the checker holes, independent of instance extraction order.
        packet.scene.instances = [RenderInstance(meshIndex: 2, transform: matrix_identity_float4x4)]; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        let holes = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        packet.scene.instances = []; packet.frameIndex += 1; try renderer.renderChecked(packet: packet)
        let background = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        let offset = (48*192+120)*4
        XCTAssertEqual(holes[offset..<offset+4],background[offset..<offset+4])
        XCTAssertGreaterThan(try GridImage.difference(holes,background).pixelsOverThree, 100)
    }

    private func parity(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 256, height: 192))
        for mode in [RenderSettings.DebugViewMode.unlit, .baseColor, .worldNormal, .roughness, .metallic] {
            packet.renderSettings.debugViewMode = mode; packet.frameIndex += 1
            try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
            let native = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
            let expected = try reference.readback()
            let delta = try GridImage.difference(native, expected)
            XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5, "\(api) \(mode): \(delta)")
            XCTAssertLessThan(delta.pixelsOverThree, delta.pixelCount / 100, "\(api) \(mode): \(delta)")
            XCTAssertEqual(renderer.lastFrameStats.submittedMeshTriangleCount, reference.renderer.lastFrameStats.submittedMeshTriangleCount)
            XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.basePass], reference.renderer.lastFrameStats.passDrawCallCounts[.basePass])
            XCTAssertGreaterThan(renderer.lastFrameStats.instancedMeshBatchCount, 0)
        }
        packet.renderSettings.debugViewMode = .unlit; packet.renderSettings.enableEditorGrid = true
        packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 12
        packet.frameIndex += 1
        try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
        let native = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        XCTAssertLessThan(try GridImage.difference(native, reference.readback()).meanAbsoluteChannelError, 0.5)
        // One-pass base and depth+base must produce the same material/depth result.
        packet.renderSettings.stage = .r1MeshCamera; packet.frameIndex += 1
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(native, try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize))
    }

    private func lifecycle(_ api: GraphicsAPI) throws {
        let assets = AssetRegistry()
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeRenderer(device: device, assets: assets)
        var packet = MeshProbeScene.packet(size: RenderDrawableSize(width: 96, height: 96))
        var asset = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        asset.materials[0].baseColorFactor = SIMD4(0.4,0.7,0.2,1)
        // Sparse slots are supported; no append-only array assumption.
        assets.registerForTesting(asset, at: 45)
        packet.scene.instances = [RenderInstance(meshIndex: 45, transform: matrix_identity_float4x4)]
        try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.residentMeshCount, 3)
        let first = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        for frame in 1...18 {
            packet.frameIndex = frame
            if frame == 5 { asset.materials[0].baseColorFactor = SIMD4(0.7,0.1,0.4,1); assets.registerForTesting(asset, at: 45) }
            if frame == 10 { packet.drawableSize = RenderDrawableSize(width: 128,height: 64) }
            try renderer.renderChecked(packet: packet)
        }
        packet.drawableSize = RenderDrawableSize(width: 96,height: 96)
        try renderer.renderChecked(packet: packet)
        let replaced = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
        XCTAssertGreaterThan(try GridImage.difference(first,replaced).pixelsOverThree, 5)
        // A failed catalog transaction keeps old resources and can recover.
        var broken = asset; broken.indices = [UInt32.max,0,1]; assets.registerForTesting(broken, at: 45)
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        assets.registerForTesting(asset, at: 45); try renderer.renderChecked(packet: packet)
        assets.unregisterTestingMesh(at: 45)
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        packet.scene.instances = []; try renderer.renderChecked(packet: packet)
        XCTAssertEqual(renderer.residentMeshCount, 2)
        packet.renderSettings.debugViewMode = .shaded
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        packet.renderSettings.debugViewMode = .unlit; try renderer.renderChecked(packet: packet)
        try device.waitUntilIdle()
    }
}
