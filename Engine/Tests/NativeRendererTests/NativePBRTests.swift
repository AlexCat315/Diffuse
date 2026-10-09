import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

final class NativePBRTests: XCTestCase {
    func testSceneValidationAcceptsCanvasAndRejectsPostEffectsBeforeR5() throws {
        var packet = PBRProbeScene.packet(size: RenderDrawableSize(width: 64, height: 64))
        _ = try NativePacketValidation.validate(packet)
        packet.inGameCanvas.rect(x: 0, y: 0, w: 10, h: 10, color: .white)
        _ = try NativePacketValidation.validate(packet)
        packet.inGameCanvas.commands = []
        packet.renderSettings.enableTAA = true
        XCTAssertThrowsError(try NativePacketValidation.validate(packet))
        packet.renderSettings.enableTAA = false
        _ = try NativePacketValidation.validate(packet)
    }

    #if os(macOS)
    func testMetalPBRShadowHDRParity() throws { try parity(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPBRShadowHDRParity() throws { try parity(.vulkan) }
    #endif

    private func parity(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeRenderer(device: device)
        let reference = try WGPUSceneReference(validation: true)
        var asset = try MeshProbeScene.importedFixture()
        for index in asset.materials.indices {
            asset.materials[index].normalTextureIndex = 0
            asset.materials[index].metallicRoughnessTextureIndex = 0
        }
        AssetRegistry.shared.registerForTesting(asset, at: 2)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 2) }
        var packet = PBRProbeScene.packet(size: RenderDrawableSize(width: 256,height: 192))
        var transformed = matrix_identity_float4x4; transformed.columns.3 = SIMD4(0,1.4,3,1)
        packet.scene.instances.append(RenderInstance(meshIndex: 2, transform: transformed))
        var snapshots: [Data] = []
        for frame in 0..<8 {
            packet.frameIndex = frame
            switch frame {
            case 0: packet.renderSettings.enableShadows = false
            case 1: packet.renderSettings.enableShadows = true; packet.renderSettings.shadowSettings.directionalCascadeCount = 1
            case 2: packet.renderSettings.shadowSettings.directionalCascadeCount = 3
            case 3: packet.scene.environment.exposure = 0.45; packet.renderSettings.debugViewMode = .worldNormal
            case 4: packet.renderSettings.debugViewMode = .shaded; packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 14
            case 5: packet.scene.camera.eye = SIMD3(-8,6,10); packet.scene.lights = []; packet.renderSettings.enableShadows = false
            case 6: packet.drawableSize = RenderDrawableSize(width: 192,height: 128); packet.scene.environment.ambientIntensity = 0; packet.scene.environment.exposure = 2.5
            default: packet.renderSettings.stage = .r3ViewportInterop; packet.renderSettings.debugViewMode = .unlit
            }
            try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
            let native = try GridImage.readback(device: device, texture: XCTUnwrap(renderer.colorTexture), size: packet.drawableSize)
            let expected = try reference.readback()
            let delta = try GridImage.difference(native,expected)
            XCTAssertLessThan(delta.meanAbsoluteChannelError,0.5,"\(api) frame \(frame): \(delta)")
            XCTAssertLessThan(delta.pixelsOverThree,max(1,delta.pixelCount/100),"\(api) frame \(frame): \(delta)")
            if frame == 1 {
                XCTAssertEqual(renderer.lastFrameStats.shadowTileCount,2)
                XCTAssertEqual(renderer.lastFrameStats.shadowedLightCount,2)
            }
            if frame == 2 {
                XCTAssertEqual(renderer.lastFrameStats.shadowTileCount,4)
                XCTAssertEqual(renderer.lastFrameStats.shadowCascadeCount,3)
            }
            if frame < 7 { XCTAssertTrue(renderer.lastFrameStats.activePasses.contains(.tonemap)) }
            snapshots.append(native)
            let directory = URL(fileURLWithPath: "/tmp/guava-native-pbr-\(api.rawValue)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try GridImage.writePPM(native,size: packet.drawableSize,to: directory.appendingPathComponent("frame-\(frame).ppm"))
            try GridImage.writePPM(expected,size: packet.drawableSize,to: directory.appendingPathComponent("wgpu-\(frame).ppm"))
        }
        // Shadow enablement must change actual receiver pixels, and clearing all
        // light/ambient inputs must leave no stale shaded objects in the frame.
        XCTAssertGreaterThan(try GridImage.difference(snapshots[0],snapshots[1]).pixelsOverThree,20)
        XCTAssertEqual(renderer.lastFrameStats.shadowTileCount,0)
    }
}
