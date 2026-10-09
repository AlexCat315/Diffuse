#if os(macOS)
import Foundation
import XCTest
import EngineKernel
import NativeRHI
import NativeRendererValidation
import RenderBackend
@testable import GuavaUIRuntime

private final class HUDSubmissionProbe: InGameUIProviding, @unchecked Sendable {
    enum Failure { case none, recording, submission }
    let hud: NativeInGameUIRenderer
    var failure: Failure = .none
    var acknowledgements = 0
    init(hud: NativeInGameUIRenderer) { self.hud = hud }
    func recordInGameUI(packet: RenderPacket, target: InGameUIRenderTarget) throws -> InGameUIRecording? {
        let recorded = try hud.recordInGameUI(packet: packet, target: target)
        if failure == .recording { throw RHIError.invalidArgument("injected HUD recording failure") }
        if failure == .submission, case .native(let native) = target {
            native.commands.copyPass { $0.copyTexture(src: native.color.texture, dst: native.color.texture, width: Int.max, height: 1) }
        }
        guard let recorded else { return nil }
        return InGameUIRecording(drawCallCount: recorded.drawCallCount) {
            self.acknowledgements += 1; recorded.didSubmit()
        }
    }
}

final class NativeInGameUILifecycleTests: XCTestCase {
    func testMissingProviderAndFailedSceneSubmissionPreservePublishedFrameAndAtlas() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let scene = try NativeRenderer(device: device)
        let source = InGameDrawListSource()
        let probe = HUDSubmissionProbe(hud: try NativeInGameUIRenderer(device: device, source: source))
        let old = InGameUIRegistry.shared.provider
        InGameUIRegistry.shared.provider = nil
        defer { InGameUIRegistry.shared.provider = old }
        let size = RenderDrawableSize(width: 128, height: 64)
        var packet = MeshProbeScene.packet(size: size)
        packet.inGameCanvas.rect(x: 0, y: 0, w: 32, h: 32, color: .red)
        XCTAssertThrowsError(try scene.renderChecked(packet: packet))
        XCTAssertNil(scene.colorTexture, "missing provider is rejected before scene allocation")
        packet.inGameCanvas = InGameCanvas()
        try scene.renderChecked(packet: packet)
        let previous = scene.currentViewportSurfaceState()
        let before = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
        InGameUIRegistry.shared.provider = probe
        for failure in [HUDSubmissionProbe.Failure.recording, .submission] {
            source.publish(snapshot(alpha: failure == .recording ? 64 : 128))
            probe.failure = failure; packet.frameIndex += 1
            XCTAssertThrowsError(try scene.renderChecked(packet: packet))
            XCTAssertEqual(probe.acknowledgements, 0)
            XCTAssertEqual(scene.currentViewportSurfaceState(), previous)
            XCTAssertEqual(scene.lastFrameStats.frameIndex, 0)
            XCTAssertEqual(try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size), before)
        }
        // No producer tick or atlas re-publication: the consumed updates must
        // survive both an abandoned recording and backend submission rejection.
        probe.failure = .none; packet.frameIndex += 1
        try scene.renderChecked(packet: packet)
        XCTAssertEqual(probe.acknowledgements, 1)
        let actual = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
        // UI glyphs preserve the existing gamma-adjusted coverage contract.
        let coverage = pow(128.0 / 255.0, 0.75)
        let expectedRed = Int((255.0 * coverage + Double(before[2]) * (1.0 - coverage)).rounded())
        XCTAssertLessThanOrEqual(abs(Int(actual[2]) - expectedRed), 1, "before=\(Array(before[0..<4])) actual=\(Array(actual[0..<4])) expected=\(expectedRed)")
        XCTAssertEqual(Array(actual[(96 * 4)..<(97 * 4)]), [33, 200, 11, 255], "color atlas also survives failed submission")
        XCTAssertEqual(scene.lastFrameStats.activePasses.last, .inGameUI)
    }

    func testInvisibleAtlasAndBackendMismatchKeepUpdatesForNextGeometry() throws {
        let context = try NativeViewportTestContext()
        let source = InGameDrawListSource()
        let consumer = try NativeInGameUIRenderer(device: context.device, source: source)
        var frame = snapshot(alpha: 255)
        source.publish(frame)
        let output = try context.deviceTexture(size: SIMD2(256, 128))
        var packet = MeshProbeScene.packet(size: .init(width: 128, height: 64))
        let wrong = try context.reference.backend.createTexture(width: 128, height: 64, format: .bgra8Unorm, usage: .renderAttachment)
        XCTAssertThrowsError(try consumer.recordInGameUI(packet: packet, target: .wgpu(
            WGPUInGameUITarget(backend: context.reference.backend, encoder: context.reference.backend.createCommandEncoder(),
                color: wrong.createView(), format: .bgra8Unorm))))
        let foreign = try Device.make(DeviceConfig(preferredBackends: [.metal]))
        XCTAssertThrowsError(try consumer.recordInGameUI(packet: packet, target: .native(
            NativeInGameUITarget(device: foreign, commands: CommandBuffer(), color: RenderColorTarget(texture: output.texture), format: .bgra8Unorm))))
        XCTAssertEqual(source.consume()?.atlasUpdates.count, 2, "affinity validation happens before consuming snapshots")
        frame.vertices = []; frame.indices = []; frame.batches = []
        source.publish(frame)
        let target = NativeInGameUITarget(device: context.device, commands: CommandBuffer(), color: RenderColorTarget(texture: output.texture), format: .bgra8Unorm)
        XCTAssertNil(try consumer.recordInGameUI(packet: packet, target: .native(target)))
        frame = snapshot(alpha: 255); frame.atlasUpdates = []
        source.publish(frame)
        try context.device.beginFrame()
        do {
            let commands = CommandBuffer()
            let recording = try XCTUnwrap(consumer.recordInGameUI(packet: packet, target: .native(
                NativeInGameUITarget(device: context.device, commands: commands,
                    color: RenderColorTarget(texture: output.texture, loadAction: .clear(SIMD4(0, 0, 0, 1))), format: .bgra8Unorm))))
            try context.device.submit(commands); recording.didSubmit(); recording.didSubmit()
            context.device.endFrame()
        } catch { context.device.endFrame(); throw error }
        packet.drawableSize = .init(width: 256, height: 128)
        let pixels = try GridImage.readback(device: context.device, texture: output.texture, size: packet.drawableSize)
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(pixels[(96 * 4)..<(97 * 4)]), [33, 200, 11, 255])
        XCTAssertEqual(Array(pixels[(192 * 4)..<(193 * 4)]), [0, 0, 0, 255], "HUD viewport uses packet extent rather than allocation capacity")
        XCTAssertEqual(Array(pixels[(100 * 256 * 4)..<(100 * 256 * 4 + 4)]), [0, 0, 0, 255])
    }

    func testWGPUHUDRecordingFailureInvalidatesUnsubmittedHistory() throws {
        let context = try NativeViewportTestContext()
        let source = InGameDrawListSource()
        source.publish(snapshot(alpha: 255))
        let wrong = try NativeInGameUIRenderer(device: context.device, source: source)
        let correct = WGPUInGameUIRenderer(renderer: DrawListRenderer(backend: context.reference.backend), source: source)
        let old = InGameUIRegistry.shared.provider
        InGameUIRegistry.shared.provider = nil
        defer { InGameUIRegistry.shared.provider = old }
        var packet = PostProbeScene.packet(size: .init(width: 128, height: 64))
        packet.renderSettings.enableTAA = false; packet.renderSettings.enableSSR = false
        for frame in 0..<3 { packet.frameIndex = frame; _ = try context.reference.render(packet: packet) }
        XCTAssertTrue(context.reference.renderer.lastFrameUsedOpaqueCache)
        let surface = context.reference.renderer.currentViewportSurfaceState()
        let before = try context.reference.readback()
        InGameUIRegistry.shared.provider = wrong; packet.frameIndex += 1
        XCTAssertThrowsError(try context.reference.render(packet: packet))
        XCTAssertEqual(context.reference.renderer.currentViewportSurfaceState(), surface)
        XCTAssertEqual(try context.reference.readback(), before)
        InGameUIRegistry.shared.provider = correct; packet.frameIndex += 1
        let stats = try context.reference.render(packet: packet)
        XCTAssertFalse(context.reference.renderer.lastFrameUsedOpaqueCache)
        XCTAssertEqual(stats.activePasses.last, .inGameUI)
        let actual = try context.reference.readback()
        XCTAssertEqual(Array(actual[0..<4]), [0, 0, 255, 255])
        XCTAssertEqual(Array(actual[(96 * 4)..<(97 * 4)]), [33, 200, 11, 255])
    }

    private func snapshot(alpha: UInt8) -> DrawListSnapshot {
        let list = DrawList()
        let glyph = GlyphAtlasInfo(glyphIndex: 1, width: 32, height: 32, bearingX: 0, bearingY: 0, advance: 32,
            uvMinX: 0, uvMinY: 0, uvMaxX: 1, uvMaxY: 1)
        list.addAtlasGlyph(glyph, x: 0, y: 0, color: Color(r: 1, g: 0, b: 0), textureID: 1)
        list.addImageQuad(rect: UIRect(x: 32, y: 0, width: 32, height: 32), textureID: TextureID(1).colorGlyphAtlasID)
        return DrawListSnapshot(vertices: list.vertices, indices: list.indices, batches: list.batches, logicalSize: SIMD2(64, 32), atlasUpdates: [
            DrawListAtlasDirty(pixels: [alpha], regionX: 0, regionY: 0, regionWidth: 1, regionHeight: 1,
                textureWidth: 1, textureHeight: 1, textureID: 1),
            DrawListAtlasDirty(pixels: [11, 200, 33, 255], regionX: 0, regionY: 0, regionWidth: 1, regionHeight: 1,
                textureWidth: 1, textureHeight: 1, textureID: TextureID(1).colorGlyphAtlasID, format: .color)
        ])
    }
}

private extension NativeViewportTestContext {
    func deviceTexture(size: SIMD2<Int>) throws -> TextureResource {
        try TextureResource(device: device, descriptor: TextureDescriptor(width: size.x, height: size.y,
            format: .bgra8Unorm, usage: [.colorTarget, .transferSource]))
    }
}
#endif
