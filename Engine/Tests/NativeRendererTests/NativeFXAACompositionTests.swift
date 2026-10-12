import AssetPipeline
import Foundation
import NativeRHI
import NativeRendererValidation
import RenderBackend
import SceneRuntime
import SIMDCompat
import XCTest

/// The capability switches must compose into a valid pipeline in any
/// combination. FXAA is an LDR antialias and must work for a non-PBR scene too:
/// the scene renders into the LDR target and FXAA resolves it to the final color.
final class NativeFXAACompositionTests: XCTestCase {
    #if os(macOS)
    func testMetalFXAAWithoutPBRRendersAndChangesPixels() throws {
        try fxaaWithoutPBR(.metal)
    }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanFXAAWithoutPBRRendersAndChangesPixels() throws {
        try fxaaWithoutPBR(.vulkan)
    }
    #endif

    private func fxaaWithoutPBR(_ api: GraphicsAPI) throws {
        let cube = BuiltinMesh.cube(color: SIMD3(repeating: 1))
        AssetRegistry.shared.registerForTesting(cube, at: 88)
        defer { AssetRegistry.shared.unregisterTestingMesh(at: 88) }
        let device = try RendererTestDevice.make(
            DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeRenderer(device: device)
        defer { try? device.waitUntilIdle() }

        func packet(fxaa: Bool, frame: Int) -> RenderPacket {
            var packet = MeshProbeScene.packet(
                size: RenderDrawableSize(width: 256, height: 192), frame: frame)
            packet.renderSettings.enablePBR = false
            packet.renderSettings.enableDepthPrepass = false
            packet.renderSettings.enableFXAA = fxaa
            packet.scene.instances = [
                RenderInstance(meshIndex: 88, transform: matrix_identity_float4x4)
            ]
            return packet
        }

        try renderer.renderChecked(packet: packet(fxaa: false, frame: 0))
        let withoutFXAA = try GridImage.readback(
            device: device,
            texture: XCTUnwrap(renderer.colorTexture),
            size: RenderDrawableSize(width: 256, height: 192))

        // Two frames so the FXAA path is exercised on a warm frame slot too.
        try renderer.renderChecked(packet: packet(fxaa: true, frame: 1))
        try renderer.renderChecked(packet: packet(fxaa: true, frame: 2))
        let withFXAA = try GridImage.readback(
            device: device,
            texture: XCTUnwrap(renderer.colorTexture),
            size: RenderDrawableSize(width: 256, height: 192))

        let delta = try GridImage.difference(withoutFXAA, withFXAA)
        XCTAssertGreaterThan(delta.pixelsOverThree, 0, "FXAA must change actual pixels")
    }
}
