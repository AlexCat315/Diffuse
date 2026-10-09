#if os(macOS)
import Foundation
import XCTest
import EngineKernel
import NativeRHI
import NativeRendererValidation
import RenderBackend
import GuavaUICompose
import GuavaUIApp
@testable import GuavaUIRuntime

private struct ImageGalleryHUD: View {
    let path: String
    var body: some View {
        Row(spacing: 4) {
            Image(file: path, width: 44, height: 44, contentMode: .fit).cornerRadius(6).opacity(0.75)
            Image(file: path, width: 44, height: 44, contentMode: .fill).cornerRadius(8)
            Image(file: path, width: 32, height: 44, renderingMode: .alphaMask)
                .foregroundColor(Color(r: 1, g: 0.5, b: 0.1))
        }
    }
}

final class NativeImageCompositionTests: XCTestCase {
    @MainActor
    func testFileImagesCompositeIntoProductionSceneAcrossDensityChanges() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        let context = try NativeViewportTestContext()
        let scene = try NativeRenderer(device: context.device)
        let native = try InGameUIHost(device: context.device), reference = InGameUIHost(backend: context.reference.backend)
        let old = InGameUIRegistry.shared.provider
        defer { InGameUIRegistry.shared.provider = old }
        native.setRootView(ImageGalleryHUD(path: path.path)); reference.setRootView(ImageGalleryHUD(path: path.path))
        var reports: [[String: Any]] = []
        for (frame, scale) in [Float(1), 2, 1.5, 1].enumerated() {
            let size = RenderDrawableSize(width: UInt32(128 * scale), height: UInt32(64 * scale))
            let packet = MeshProbeScene.packet(size: size, frame: frame)
            InGameUIRegistry.shared.provider = nil; try scene.renderChecked(packet: packet)
            let base = try GridImage.readback(device: context.device, texture: XCTUnwrap(scene.colorTexture), size: size)
            native.tick(width: 128, height: 64, contentScale: scale)
            reference.tick(width: 128, height: 64, contentScale: scale)
            InGameUIRegistry.shared.provider = native; try scene.renderChecked(packet: packet)
            let pixels = try GridImage.readback(device: context.device, texture: XCTUnwrap(scene.colorTexture), size: size)
            InGameUIRegistry.shared.provider = reference; _ = try context.reference.render(packet: packet)
            let expected = try context.reference.readback()
            let delta = try GridImage.difference(pixels, expected)
            XCTAssertLessThanOrEqual(delta.maximumChannelError, 1)
            XCTAssertGreaterThan(try GridImage.difference(pixels, base).pixelsOverThree, 1000)
            reports.append(["scale": scale, "width": size.width, "height": size.height,
                "mean": delta.meanAbsoluteChannelError, "maximum": delta.maximumChannelError])
            if frame == 1 {
                try GridImage.writePPM(pixels, size: size, to: URL(fileURLWithPath: "/tmp/guava-native-image-hud.ppm"))
                try GridImage.writePPM(expected, size: size, to: URL(fileURLWithPath: "/tmp/guava-wgpu-image-hud.ppm"))
            }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "/tmp/guava-native-image-hud-parity.json"))
    }

    @MainActor
    func testAsyncFilePublicationCarriesOwnedPixelsToNativeRecording() async throws {
        let path = try fixture()
        defer { try? FileManager.default.removeItem(at: path) }
        let queue = ImagePublicationTestQueue()
        let oldScheduler = UIWorkSchedulerHolder.enqueue, oldProvider = InGameUIRegistry.shared.provider
        UIWorkSchedulerHolder.enqueue = queue.enqueue
        defer { UIWorkSchedulerHolder.enqueue = oldScheduler; InGameUIRegistry.shared.provider = oldProvider }
        let source = InGameDrawListSource(), bridge = InGameViewGraphBridge(source: source)
        bridge.setRootView(AsyncImage(url: path, width: 96, height: 48) { phase in
            switch phase {
            case .success(let image): image
            default: EmptyView()
            }
        })
        let start = ContinuousClock.now
        var loaded = false
        while !loaded && start.duration(to: .now) < .seconds(10) {
            queue.drain(); bridge.tick(width: 128, height: 64, contentScale: 2)
            if let snapshot = source.consume() {
                snapshot.resources.forEach(of: ImageAssetRegistry.Asset.self) { _ in loaded = true }
                source.publish(snapshot)
            }
            if !loaded { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(loaded)
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: true))
        let scene = try NativeRenderer(device: device)
        InGameUIRegistry.shared.provider = try NativeInGameUIRenderer(device: device, source: source)
        let packet = MeshProbeScene.packet(size: .init(width: 256, height: 128))
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            try scene.renderChecked(packet: packet)
        }.value
        XCTAssertEqual(scene.lastFrameStats.activePasses.last, .inGameUI)
        let pixels = try GridImage.readback(device: device, texture: XCTUnwrap(scene.colorTexture), size: packet.drawableSize)
        // File pixels reach the worker recording thread without
        // registering anything on a WGPU renderer during decode/publication.
        let red = (24 * 256 + 48) * 4, green = (24 * 256 + 144) * 4
        XCTAssertGreaterThan(pixels[red + 2], 200); XCTAssertLessThan(pixels[red + 1], 30)
        XCTAssertGreaterThan(pixels[green + 1], 150); XCTAssertLessThan(pixels[green + 2], 30)
    }

    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("guava-owned-image-\(UUID()).svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="16">
        <rect width="12" height="8" fill="#ff0011"/><rect x="12" width="12" height="8" fill="#00dd22"/>
        <rect y="8" width="12" height="8" fill="#1144ff"/><rect x="12" y="8" width="12" height="8" fill="#ffdd11" fill-opacity="0.6"/>
        </svg>
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private final class ImagePublicationTestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [() -> Void] = []
    func enqueue(_ work: @escaping () -> Void) { lock.withLock { jobs.append(work) } }
    func drain() {
        let ready = lock.withLock { let ready = jobs; jobs.removeAll(); return ready }
        ready.forEach { $0() }
    }
}
#endif
