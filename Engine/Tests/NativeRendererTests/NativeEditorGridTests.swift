import XCTest
import Foundation
import NativeRHI
import RenderBackend
import NativeRendererValidation
import SceneRuntime

final class NativeEditorGridTests: XCTestCase {
    func testMetalGridMatchesWGSL() throws { try parity(.metal) }
    func testVulkanGridMatchesWGSL() throws { try parity(.vulkan) }
    func testMetalGridLoadsDepthAndColor() throws { try depthAndColor(.metal) }
    func testVulkanGridLoadsDepthAndColor() throws { try depthAndColor(.vulkan) }
    func testMetalRendererResizeAndTransientFrames() throws { try resize(.metal) }
    func testVulkanRendererResizeAndTransientFrames() throws { try resize(.vulkan) }
    func testMetalUniformRangeValidation() throws { try uniformRanges(.metal) }
    func testVulkanUniformRangeValidation() throws { try uniformRanges(.vulkan) }

    private func uniformRanges(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
        let layout = try device.makeBindingLayout(BindingLayoutDescriptor(entries: [
            BindingLayoutEntry(slot: 0, type: .uniformBuffer, visibility: .fragment)]))
        let buffer = try device.makeBuffer(BufferDescriptor(size: 512, usage: .uniform))
        defer { device.destroy(buffer) }
        for size in [0, -1, 513] {
            XCTAssertThrowsError(try device.makeBindingSet(layout: layout, descriptor: BindingSetDescriptor(entries: [
                BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer, size: size))])))
        }
        _ = try device.makeBindingSet(layout: layout, descriptor: BindingSetDescriptor(entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer, size: 192))]))
    }

    private func depthAndColor(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false))
        let grid = try NativeEditorGridPass(device: device)
        let size = RenderDrawableSize(width: 128, height: 128)
        let color = try device.makeTexture(TextureDescriptor(width: 128, height: 128,
            format: .bgra8Unorm, usage: [.colorTarget, .transferSource]))
        let depth = try device.makeTexture(TextureDescriptor(width: 128, height: 128,
            format: .depth32Float, usage: .depthStencilTarget))
        defer { device.destroy(color); device.destroy(depth) }
        let packet = GridProbeScene.packet(size: size)
        let background = SIMD4<Float>(0.08, 0.10, 0.14, 1)
        var images: [Data] = []
        for clear in [0.0, 1.0] {
            try device.beginFrame()
            let commands = CommandBuffer()
            commands.renderPass(descriptor: RenderPassDescriptor(
                colorTargets: [RenderColorTarget(texture: color, loadAction: .clear(background))],
                depthTarget: RenderDepthTarget(texture: depth, loadAction: .clear(clear)))) { _ in }
            try grid.encode(packet: packet, color: RenderColorTarget(texture: color, loadAction: .load),
                depth: RenderDepthTarget(texture: depth, loadAction: .load), into: commands)
            try device.submit(commands); device.endFrame()
            images.append(try GridImage.readback(device: device, texture: color, size: size))
        }
        let reference = try WGPUGridReference(size: size, validation: true)
        _ = try reference.render(packet: packet, depthClear: 0)
        XCTAssertEqual(images[0], try reference.readback(), "depth zero must occlude the grid and preserve color")
        XCTAssertGreaterThan(try GridImage.difference(images[0], images[1]).pixelsOverThree, 300)
    }

    private func resize(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeGridRenderer(device: device)
        var packet = GridProbeScene.packet(size: RenderDrawableSize(width: 160, height: 96))
        for frame in 0..<36 {
            packet.frameIndex = frame
            if frame >= 17 { packet.drawableSize = RenderDrawableSize(width: 96, height: 160) }
            packet.renderSettings.editorGridSpacing = frame.isMultiple(of: 2) ? 0.25 : 0.75
            try renderer.renderChecked(packet: packet)
        }
        let texture = try XCTUnwrap(renderer.colorTexture)
        let image = try GridImage.readback(device: device, texture: texture, size: packet.drawableSize)
        let reference = try WGPUGridReference(size: packet.drawableSize, validation: true)
        _ = try reference.render(packet: packet)
        XCTAssertLessThan(try GridImage.difference(image, reference.readback()).meanAbsoluteChannelError, 0.5)
        XCTAssertEqual(renderer.lastFrameStats.frameIndex, 35)
        XCTAssertEqual(renderer.lastFrameStats.passDrawCallCounts[.editorGrid], 1)
        // A rejected frame leaves the frame ring usable for the next packet.
        packet.drawableSize.width = 0
        XCTAssertThrowsError(try renderer.renderChecked(packet: packet))
        packet.drawableSize.width = 96; packet.frameIndex = 36
        try renderer.renderChecked(packet: packet)
        try device.waitUntilIdle()
    }
    private func parity(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api], enableValidation: false, framesInFlight: 3))
        let renderer = try NativeGridRenderer(device: device)
        let size = RenderDrawableSize(width: 192, height: 128)
        let reference = try WGPUGridReference(size: size, validation: true)
        let cameras = [
            RenderCamera(eye: SIMD3(7, 6, 9), target: .zero, near: 0.1, far: 100),
            RenderCamera(eye: SIMD3(0, 0, 8), target: .zero, projection: .orthographic, orthographicHeight: 8),
            RenderCamera(eye: SIMD3(8, 0, 0), target: .zero, projection: .orthographic, orthographicHeight: 8),
            RenderCamera(eye: SIMD3(0, 8, 0), target: .zero, up: SIMD3(0, 0, -1), projection: .orthographic, orthographicHeight: 8),
            RenderCamera(eye: SIMD3(3, 1, 5), target: SIMD3(3, 4, 7), near: 0.1, far: 100),
        ]
        for (index, camera) in cameras.enumerated() {
            var packet = GridProbeScene.packet(size: size, frame: index, camera: camera)
            try renderer.renderChecked(packet: packet); _ = try reference.render(packet: packet)
            let texture = try XCTUnwrap(renderer.colorTexture)
            let native = try GridImage.readback(device: device, texture: texture, size: size)
            let expected = try reference.readback()
            let delta = try GridImage.difference(native, expected)
            XCTAssertLessThan(delta.meanAbsoluteChannelError, 0.5, "\(api) camera \(index): \(delta)")
            XCTAssertLessThan(delta.pixelsOverThree, delta.pixelCount / 100, "\(api) camera \(index): \(delta)")
            packet.renderSettings.enableEditorGrid = false
            try renderer.renderChecked(packet: packet)
            let clear = try GridImage.readback(device: device, texture: texture, size: size)
            if index < 4 {
                let coverage = try GridImage.difference(native, clear)
                XCTAssertGreaterThan(coverage.pixelsOverThree, 300)
            } else { XCTAssertEqual(native, clear, "looking above the ground must discard the grid") }
            XCTAssertEqual(renderer.lastFrameStats.drawCallCount, 0)
        }
    }
}
