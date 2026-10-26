import Foundation
import NativeRHI
import NativeRendererValidation
import SceneRuntime
@testable import RenderBackend
import SIMDCompat
import XCTest

final class NativePostTests: XCTestCase {
    func testFingerprintPreservesDuplicatesAndIgnoresExtractionOrder() {
        var packet = PBRProbeScene.packet(size: .init(width: 64,height: 64))
        let a = packet.scene.instances[0], b = packet.scene.instances[1]
        packet.scene.instances = [a,a]
        let first = OpaqueSceneFingerprint.make(packet: packet,settingsGeneration: 1)
        packet.scene.instances = [b,b]
        XCTAssertNotEqual(first,OpaqueSceneFingerprint.make(packet: packet,settingsGeneration: 1))
        packet.scene.instances = [a,b]
        let mixed = OpaqueSceneFingerprint.make(packet: packet,settingsGeneration: 1)
        packet.scene.instances.reverse()
        XCTAssertEqual(mixed,OpaqueSceneFingerprint.make(packet: packet,settingsGeneration: 1))
    }
    func testFrameHistoryInvalidatesResourceEpochAfterFailedResize() {
        var packet = PostProbeScene.packet(size: .init(width: 64,height: 64))
        var state = RenderTemporalState()
        state.prepare(packet: packet,resources: .init(meshRevision: 1,postRevision: 1,usedSize: packet.drawableSize),hdr: true)
        state.historyValid = true
        let submitted = state
        var abandoned = state
        packet.drawableSize = .init(width: 128,height: 64)
        abandoned.prepare(packet: packet,resources: .init(meshRevision: 1,postRevision: 2,usedSize: packet.drawableSize),hdr: true)
        state = submitted
        state.prepare(packet: packet,resources: .init(meshRevision: 1,postRevision: 2,usedSize: packet.drawableSize),hdr: true)
        XCTAssertFalse(state.historyValid); XCTAssertTrue(state.moving)
    }
    func testUsedRegionResizeInvalidatesHistoryWithoutReallocation() {
        var packet = PostProbeScene.packet(size: .init(width: 128,height: 96))
        var state = RenderTemporalState()
        state.prepare(packet: packet,resources: .init(meshRevision: 1,postRevision: 1,usedSize: packet.drawableSize),hdr: true)
        state.historyValid = true; state.snapshotValid = true
        packet.drawableSize = .init(width: 96,height: 64)
        state.prepare(packet: packet,resources: .init(meshRevision: 1,postRevision: 1,usedSize: packet.drawableSize),hdr: true)
        XCTAssertFalse(state.historyValid); XCTAssertFalse(state.snapshotValid); XCTAssertFalse(state.cacheHit)
        let frame = PostEffectUniforms.frame(used: packet.drawableSize,capacity: .init(width: 256,height: 256))
        XCTAssertEqual(frame.uvScaleMax,SIMD4(96/256.0,64/256.0,95.5/256,63.5/256))
    }
    #if os(macOS)
    func testMetalPostHistoryResizeAndCacheParity() throws { try parity(.metal) }
    func testMetalStatelessPostEffectsChangePixels() throws { try effects(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPostHistoryResizeAndCacheParity() throws { try parity(.vulkan) }
    func testVulkanStatelessPostEffectsChangePixels() throws { try effects(.vulkan) }
    #endif

    private func effects(_ api: GraphicsAPI) throws {
        let device = try makeDevice(api), renderer = try NativeRenderer(device: device)
        let reference = try SceneCapture(validation: true, api: api)
        var packet = PostProbeScene.packet(size: .init(width: 256,height: 192))
        clearEffects(&packet); packet.renderSettings.viewport.gridEnabled = false
        let baseline = try compare(packet,renderer: renderer,reference: reference,label: "baseline")
        for (index,kind) in [RenderPassKind.ssao,.ssr,.bloom,.fxaa].enumerated() {
            clearEffects(&packet); packet.frameIndex = index*2+1
            switch kind {
            case .ssao: packet.renderSettings.postProcessing.ssao = true
            case .ssr: packet.renderSettings.postProcessing.ssr = true
            case .bloom: packet.renderSettings.postProcessing.bloom = true
            case .fxaa: packet.renderSettings.postProcessing.fxaa = true
            default: break
            }
            _ = try compare(packet,renderer: renderer,reference: reference,label: "\(kind)-moving")
            packet.frameIndex += 1
            let output = try compare(packet,renderer: renderer,reference: reference,label: "\(kind)-settled")
            XCTAssertGreaterThan(try GridImage.difference(baseline,output).pixelsOverThree,20,"\(kind) must affect actual pixels")
        }
    }
    private func parity(_ api: GraphicsAPI) throws {
        let device = try makeDevice(api), renderer = try NativeRenderer(device: device)
        var reference = try SceneCapture(validation: true, api: api)
        var packet = PostProbeScene.packet(size: .init(width: 256,height: 192))
        clearEffects(&packet)
        var previousColor: Texture?
        for frame in 0..<24 {
            packet.frameIndex = frame
            switch frame {
            case 1: packet.renderSettings.postProcessing.ssao = true
            case 3: packet.renderSettings.postProcessing.ssr = true
            case 5: packet.renderSettings.postProcessing.taa = true
            case 6: packet.renderSettings.postProcessing.bloom = true; packet.renderSettings.postProcessing.fxaa = true; packet.scene.camera.eye.x += 0.2
            case 8: packet.renderSettings.viewport.gridEnabled = false
            case 9: packet.drawableSize = .init(width: 192,height: 128)
            case 10: packet.drawableSize = .init(width: 320,height: 200)
            case 11: packet.renderSettings.postProcessing.taa = false
            case 12: packet.renderSettings.postProcessing.taa = true
            case 20: packet.scene.instances[packet.scene.instances.count-1].material.baseColorFactor = SIMD4(0.75,0.25,0.15,0.35)
            case 21:
                var invalid = packet; invalid.drawableSize = .init(width: 640,height: 384)
                invalid.scene.instances.append(RenderInstance(meshIndex: 999,transform: matrix_identity_float4x4))
                XCTAssertThrowsError(try renderer.renderChecked(packet: invalid))
                // Recreated targets require a fresh history after recovery.
                reference = try SceneCapture(validation: true, api: api)
            case 22: clearEffects(&packet)
            case 23:
                packet.renderSettings.postProcessing.taa = true
                packet.renderSettings.postProcessing.ssao = true; packet.renderSettings.postProcessing.ssr = true
                packet.renderSettings.postProcessing.bloom = true; packet.renderSettings.postProcessing.fxaa = true
                packet.scene.camera.projection = .orthographic; packet.scene.camera.orthographicHeight = 14
            default: break
            }
            _ = try compare(packet,renderer: renderer,reference: reference,label: "frame-\(frame)")
            if frame == 9 { XCTAssertEqual(renderer.colorTexture,previousColor,"shrinking viewport must reuse allocated targets") }
            if frame == 10 { XCTAssertNotEqual(renderer.colorTexture,previousColor,"capacity grows for larger viewport") }
            previousColor = renderer.colorTexture
            XCTAssertEqual(renderer.lastFrameUsedOpaqueCache,reference.renderer.lastFrameUsedOpaqueCache,"cache frame \(frame)")
            if frame == 3 { XCTAssertNil(renderer.lastFrameStats.passDrawCallCounts[.ssr]) }
            if frame == 4 { XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.ssr],1) }
            if frame == 19 { XCTAssertTrue(renderer.lastFrameUsedOpaqueCache); XCTAssertNil(renderer.lastFrameStats.passDrawCallCounts[.taa]) }
        }
    }
    private func clearEffects(_ packet: inout RenderPacket) {
        packet.renderSettings.postProcessing.ssao = false; packet.renderSettings.postProcessing.ssr = false
        packet.renderSettings.postProcessing.taa = false; packet.renderSettings.postProcessing.bloom = false; packet.renderSettings.postProcessing.fxaa = false
    }
    private func makeDevice(_ api: GraphicsAPI) throws -> Device {
        try RendererTestDevice.make(DeviceConfig(preferredBackends: [api],enableValidation: false,framesInFlight: 3))
    }
    private func compare(_ packet: RenderPacket, renderer: NativeRenderer, reference: SceneCapture, label: String) throws -> Data {
        try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
        let native = try GridImage.readback(device: renderer.device,texture: XCTUnwrap(renderer.colorTexture),size: packet.drawableSize)
        let expected = try reference.readback(), delta = try GridImage.difference(native,expected)
        XCTAssertLessThan(delta.meanAbsoluteChannelError,0.5,"\(label): \(delta)")
        XCTAssertLessThan(delta.pixelsOverThree,max(1,delta.pixelCount/100),"\(label): \(delta)")
        let directory = URL(fileURLWithPath: "/tmp/cove-native-post")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        try GridImage.writePPM(native,size: packet.drawableSize,to: directory.appendingPathComponent("\(label).ppm"))
        try GridImage.writePPM(expected,size: packet.drawableSize,to: directory.appendingPathComponent("repeat-\(label).ppm"))
        return native
    }
}
