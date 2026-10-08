#if canImport(AppKit) && canImport(Metal)
import AppKit
import Metal
import QuartzCore
import XCTest
import NativeRHI
import RenderBackend
import NativeRendererValidation

final class NativeGridSurfaceTests: XCTestCase {
    @MainActor func testMetalRendererPresentsAndResizes() async throws { try render(.metal) }
    @MainActor func testVulkanRendererPresentsAndResizes() async throws { try render(.vulkan) }
    @MainActor private func render(_ api: GraphicsAPI) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let layer = CAMetalLayer(); layer.device = MTLCreateSystemDefaultDevice(); layer.pixelFormat = .bgra8Unorm
        let view = try XCTUnwrap(window.contentView); view.wantsLayer = true; view.layer = layer
        layer.frame = view.bounds
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeGridRenderer(device: device, surface: .metalLayer(Unmanaged.passUnretained(layer).toOpaque()))
        for frame in 0..<6 {
            let size: UInt32 = frame < 3 ? 96 : 64
            layer.drawableSize = CGSize(width: Int(size), height: Int(size))
            try renderer.renderChecked(packet: GridProbeScene.packet(size: RenderDrawableSize(width: size, height: size), frame: frame))
            XCTAssertEqual(renderer.lastFrameStats.drawCallCount, 1)
        }
        try device.waitUntilIdle()
    }
}
#endif
