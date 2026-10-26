@testable import EditorCore
#if os(macOS)
import Foundation
import XCTest
import EngineKernel
import NativeRHI
import NativeRendererValidation
import RenderBackend
import CoveUICompose
import CoveUI
@testable import CoveUIRuntime

final class NativeInGameUIIntegrationTests: XCTestCase {
    @MainActor
    func testProductionSceneHUDParityAcrossScaleAndTargetCapacity() async throws {
        let context = try NativeViewportTestContext()
        let hud = context.hud
        let scene = try NativeRenderer(device: context.device, inGameUI: context.hud)
        let nativeHUD = try InGameUIHost(device: context.device)
        let referenceHUD = try InGameUIHost(device: context.reference.device)
        nativeHUD.setRootView(Text("HUD 中🙂"))
        referenceHUD.setRootView(Text("HUD 中🙂"))
        let logicalSizes = [SIMD2<Int>(192, 128), SIMD2(80, 64), SIMD2(160, 96)]
        var evidence: [[String: Any]] = []
        for post in [false, true] {
            for (index, scale) in [Float(1), 1.5, 2].enumerated() {
                let logical = logicalSizes[index]
                let size = RenderDrawableSize(width: UInt32(Float(logical.x) * scale), height: UInt32(Float(logical.y) * scale))
                var packet = post ? PostProbeScene.packet(size: size) : MeshProbeScene.packet(size: size)
                packet.frameIndex = (post ? 3 : 0) + index
                packet.renderSettings.postProcessing.taa = false; packet.renderSettings.postProcessing.ssr = false
                hud.provider = nil
                try scene.renderChecked(packet: packet)
                let base = try GridImage.readback(device: context.device, texture: XCTUnwrap(scene.colorTexture), size: size)
                if index != 0 {
                    packet.inGameCanvas.rect(x: 4, y: 32, w: 70, h: 28, color: .blue, cornerRadius: 4)
                    packet.inGameCanvas.label("Score 8 🙂", x: 6, y: 35, fontSize: 14)
                    packet.inGameCanvas.progressBar(x: 6, y: 55, w: 64, h: 4, value: 0.65)
                }
                // Two unconsumed ticks exercise atlas accumulation when the
                // render thread skips a producer frame, including scale changes.
                for _ in 0..<2 {
                    nativeHUD.tick(width: logical.x, height: logical.y, contentScale: scale, canvas: packet.inGameCanvas)
                    referenceHUD.tick(width: logical.x, height: logical.y, contentScale: scale, canvas: packet.inGameCanvas)
                }
                hud.provider = nativeHUD
                try scene.renderChecked(packet: packet)
                let native = try GridImage.readback(device: context.device, texture: XCTUnwrap(scene.colorTexture), size: size)
                XCTAssertEqual(scene.lastFrameStats.activePasses.last, .inGameUI)
                XCTAssertGreaterThan(scene.lastFrameStats.passDrawCallCounts[.inGameUI] ?? 0, 0)
                if index != 0 {
                    var visibleLabelPixels = 0
                    for y in Int(35 * scale)..<Int(52 * scale) {
                        for x in Int(6 * scale)..<min(Int(size.width), Int(70 * scale)) {
                            let pixel = (y * Int(size.width) + x) * 4
                            if native[pixel] > 180 && native[pixel + 1] > 180 && native[pixel + 2] > 180 { visibleLabelPixels += 1 }
                        }
                    }
                    XCTAssertGreaterThan(visibleLabelPixels, 20, "unchanged script label must remain visible after atlas/scale replacement")
                }
                let hudDelta = try GridImage.difference(native, base)
                XCTAssertGreaterThan(hudDelta.pixelsOverThree, 100, "declarative HUD must render even with an empty script canvas")
                hud.provider = referenceHUD
                let stats = try context.reference.render(packet: packet)
                XCTAssertEqual(stats.activePasses.last, .inGameUI)
                let expected = try context.reference.readback()
                let delta = try GridImage.difference(native, expected)
                XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5, "\(post)/\(scale): \(delta)")
                XCTAssertLessThan(Double(delta.pixelsOverThree) / Double(delta.pixelCount), 0.01)
                evidence.append(["post": post, "scale": scale, "width": size.width, "height": size.height,
                    "mean": delta.meanAbsoluteChannelError, "maximum": delta.maximumChannelError,
                    "pixelsOverThree": delta.pixelsOverThree, "pixelCount": delta.pixelCount,
                    "nativeHUDDrawCalls": scene.lastFrameStats.passDrawCallCounts[.inGameUI] ?? 0,
                    "repeatHUDDrawCalls": stats.passDrawCallCounts[.inGameUI] ?? 0])
                print("native-in-game-ui post=\(post) scale=\(scale) size=\(size) delta=\(delta)")
                if post && index == 2 {
                    try GridImage.writePPM(native, size: size, to: URL(fileURLWithPath: "/tmp/cove-native-hud.ppm"))
                    try GridImage.writePPM(expected, size: size, to: URL(fileURLWithPath: "/tmp/cove-repeat-hud.ppm"))
                }
            }
        }
        let report = try JSONSerialization.data(withJSONObject: ["backend": "Metal", "samples": evidence], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: URL(fileURLWithPath: "/tmp/cove-native-hud-parity.json"))
    }

    @MainActor
    func testHUDRefreshesOutsideOpaqueCacheAndEmptySnapshotClearsIt() async throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let hud = HUDRouter()
        let scene = try NativeRenderer(device: device, inGameUI: hud)
        let host = try InGameUIHost(device: device)
        hud.provider = host
        let size = RenderDrawableSize(width: 192, height: 128)
        var packet = PostProbeScene.packet(size: size)
        packet.renderSettings.postProcessing.taa = false; packet.renderSettings.postProcessing.ssr = false
        packet.inGameCanvas.rect(x: 0, y: 0, w: 32, h: 24, color: .red)
        host.tick(width: 192, height: 128, canvas: packet.inGameCanvas)
        for frame in 0..<3 { packet.frameIndex = frame; try scene.renderChecked(packet: packet) }
        XCTAssertTrue(scene.lastFrameUsedOpaqueCache)
        let red = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
        XCTAssertEqual(Array(red[0..<4]), [0, 0, 255, 255])
        packet.frameIndex += 1; packet.inGameCanvas = InGameCanvas()
        packet.inGameCanvas.rect(x: 0, y: 0, w: 32, h: 24, color: .blue)
        host.tick(width: 192, height: 128, canvas: packet.inGameCanvas)
        try scene.renderChecked(packet: packet)
        XCTAssertTrue(scene.lastFrameUsedOpaqueCache)
        let blue = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
        XCTAssertEqual(Array(blue[0..<4]), [255, 102, 0, 255])
        packet.frameIndex += 1; packet.inGameCanvas = InGameCanvas()
        host.tick(width: 192, height: 128)
        try scene.renderChecked(packet: packet)
        XCTAssertTrue(scene.lastFrameUsedOpaqueCache)
        XCTAssertFalse(scene.lastFrameStats.activePasses.contains(.inGameUI))
        let cleared = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size)
        hud.provider = nil
        packet.frameIndex += 1; try scene.renderChecked(packet: packet)
        XCTAssertEqual(cleared, try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: size))
    }
}
#endif
