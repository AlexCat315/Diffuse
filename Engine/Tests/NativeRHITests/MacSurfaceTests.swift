#if canImport(AppKit) && canImport(Metal)
import AppKit
import Metal
import QuartzCore
import XCTest
@testable import NativeRHI

final class MacSurfaceTests: XCTestCase {
    @MainActor func testMetalSurfacePresentAndResize() async throws { try surface(.metal) }
    @MainActor func testMetalWindowsHaveIndependentImagesAndBoundedRetainedPools() async throws {
        _ = NSApplication.shared
        func window(_ size: Int) throws -> (NSWindow, CAMetalLayer) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = try XCTUnwrap(window.contentView), layer = CAMetalLayer()
            layer.frame = view.bounds; view.wantsLayer = true; view.layer = layer
            return (window, layer)
        }
        let (firstWindow, firstLayer) = try window(32), (secondWindow, secondLayer) = try window(48)
        defer { firstWindow.close(); secondWindow.close() }
        let config = DeviceConfig(preferredBackends: [.metal], enableValidation: true, framesInFlight: 2)
        let backend = try XCTUnwrap(MetalDevice.make(config: config) as? MetalDevice)
        let device = try Device(backend: backend, config: config)
        func descriptor(_ layer: CAMetalLayer, _ width: Int, _ height: Int) -> SurfaceDescriptor {
            SurfaceDescriptor(nativeHandle: Unmanaged.passUnretained(layer).toOpaque(), width: width, height: height, colorFormat: .bgra8Unorm)
        }
        let firstResource = try SwapchainResource(device: device, descriptor: descriptor(firstLayer, 32, 32))
        let secondResource = try SwapchainResource(device: device, descriptor: descriptor(secondLayer, 48, 48))
        let first = firstResource.swapchain, second = secondResource.swapchain
        XCTAssertThrowsError(try device.makeSwapchain(descriptor(firstLayer, 32, 32)))
        // The test reads actual drawable pixels; production remains framebufferOnly.
        firstLayer.framebufferOnly = false; secondLayer.framebufferOnly = false
        var firstGeneration: UInt64?, secondGeneration: UInt64?
        for frame in 0..<40 {
            if frame == 10 {
                var invalid = descriptor(firstLayer, 16, 24); invalid.colorFormat = .rgba8Unorm
                XCTAssertThrowsError(try device.configureSwapchain(first, descriptor: invalid))
            }
            if frame == 20 {
                try device.configureSwapchain(first, descriptor: descriptor(firstLayer, 16, 24))
                firstLayer.framebufferOnly = false
            }
            try device.beginFrame()
            let a = try device.acquireSwapchainImage(first), b = try device.acquireSwapchainImage(second)
            XCTAssertNotEqual(a.texture, b.texture)
            XCTAssertEqual(a.width, frame < 20 ? 32 : 16); XCTAssertEqual(a.height, frame < 20 ? 32 : 24)
            XCTAssertEqual(b.width, 48); XCTAssertEqual(b.height, 48)
            if frame == 20 { XCTAssertNotEqual(a.generation, firstGeneration) }
            else if frame != 0 { XCTAssertEqual(a.generation, firstGeneration) }
            if frame != 0 { XCTAssertEqual(b.generation, secondGeneration) }
            firstGeneration = a.generation; secondGeneration = b.generation
            XCTAssertThrowsError(try device.acquireSwapchainImage(first))
            XCTAssertThrowsError(try device.configureSwapchain(first, descriptor: descriptor(firstLayer, 16, 24)))
            XCTAssertThrowsError(try device.present(SwapchainImage(swapchain: second, generation: b.generation,
                texture: a.texture, width: a.width, height: a.height)))
            let commands = CommandBuffer()
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: a.texture,
                loadAction: .clear(SIMD4(1, 0, 0, 1)))])) { _ in }
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: b.texture,
                loadAction: .clear(SIMD4(0, 1, 0, 1)))])) { _ in }
            try device.submit(commands)
            for image in frame.isMultiple(of: 2) ? [a, b] : [b, a] { try device.present(image) }
            XCTAssertThrowsError(try device.present(a))
            device.endFrame()
            if frame == 0 || frame == 20 || frame == 39 {
                try device.waitUntilIdle()
                for (image, expected) in [(a, [UInt8(0), 0, 255, 255]), (b, [0, 255, 0, 255])] {
                    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                    try pixels.withUnsafeMutableBytes { try device.readTextureData(image.texture, width: image.width,
                        height: image.height, bytesPerRow: image.width * 4, into: $0) }
                    for offset in stride(from: 0, to: pixels.count, by: 4) {
                        XCTAssertEqual(Array(pixels[offset..<offset + 4]), expected)
                    }
                }
            }
            XCTAssertLessThanOrEqual(backend.registries.textures.count, 4)
        }
        try firstResource.close()
        try device.waitUntilIdle()
        XCTAssertEqual(backend.swapchains.count, 1)
        try device.beginFrame()
        XCTAssertThrowsError(try device.acquireSwapchainImage(first))
        _ = try device.acquireSwapchainImage(second)
        device.endFrame() // A window without a recorded draw still returns its image.
        try device.waitUntilIdle()
        try secondResource.close()
        XCTAssertEqual(backend.swapchains.count, 0)
        XCTAssertEqual(backend.registries.textures.count, 0)
    }

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
        var wrongSurface = SurfaceDescriptor(nativeHandle: UnsafeMutableRawPointer(bitPattern: 1), width: 1, height: 1)
        wrongSurface.kind = .waylandSurface
        XCTAssertThrowsError(try device.makeSwapchain(wrongSurface))
        var swapchain: Swapchain?
        func configure(_ size: Int) throws {
            layer.drawableSize = CGSize(width: size, height: size)
            let descriptor = SurfaceDescriptor(nativeHandle: Unmanaged.passUnretained(layer).toOpaque(), width: size, height: size, colorFormat: .bgra8Unorm)
            if let swapchain { try device.configureSwapchain(swapchain, descriptor: descriptor) }
            else { swapchain = try device.makeSwapchain(descriptor) }
        }
        try configure(32)
        for index in 0..<3 {
            if index == 2 { try device.waitUntilIdle(); try configure(16) }
            try device.beginFrame()
            let image = try device.acquireSwapchainImage(XCTUnwrap(swapchain))
            XCTAssertEqual(image.width, index == 2 ? 16 : 32)
            XCTAssertEqual(image.height, index == 2 ? 16 : 32)
            let commands = CommandBuffer()
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: image.texture, loadAction: .clear(SIMD4(0,1,0,1)))])) { _ in }
            try device.submit(commands)
            try device.present(image)
            device.endFrame()
        }
        try device.waitUntilIdle()
        device.destroy(try XCTUnwrap(swapchain))
    }
}
#endif
