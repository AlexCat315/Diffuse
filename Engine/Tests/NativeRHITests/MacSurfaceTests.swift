#if canImport(AppKit) && canImport(Metal)
import AppKit
import Metal
import QuartzCore
import XCTest
@testable import NativeRHI

final class MacSurfaceTests: XCTestCase {
    @MainActor func testMetalSurfacePresentAndResize() async throws { try surface(.metal) }
    #if canImport(CVulkanHeaders)
    @MainActor func testVulkanSurfacePresentAndResize() async throws {
        guard VulkanBackend.isAvailable else { throw XCTSkip("No Vulkan ICD") }
        try surface(.vulkan)
    }
    #endif
    @MainActor private func surface(_ api: GraphicsAPI) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView)
        let layer = CAMetalLayer(); layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm; layer.drawableSize = CGSize(width: 32, height: 32)
        layer.frame = view.bounds; view.wantsLayer = true; view.layer = layer
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
        func configure(_ size: Int) throws {
            layer.drawableSize = CGSize(width: size, height: size)
            try device.configureSurface(SurfaceDescriptor(nativeHandle: Unmanaged.passUnretained(layer).toOpaque(), width: size, height: size, colorFormat: .bgra8Unorm))
        }
        try configure(32)
        for index in 0..<3 {
            if index == 2 { try device.waitUntilIdle(); try configure(16) }
            try device.beginFrame()
            let image = try device.acquireSwapchainImage()
            XCTAssertEqual(image.width, index == 2 ? 16 : 32)
            XCTAssertEqual(image.height, index == 2 ? 16 : 32)
            let commands = CommandBuffer()
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: image.texture, loadAction: .clear(SIMD4(0,1,0,1)))])) { _ in }
            try device.submit(commands)
            try device.present(image)
            device.endFrame()
        }
        try device.waitUntilIdle()
    }
}
#endif
