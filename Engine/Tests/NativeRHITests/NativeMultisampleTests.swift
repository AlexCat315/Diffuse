import Foundation
import XCTest
@testable import NativeRHI

private struct PackedColorVertex {
    var position: SIMD2<Float>
    var color: UInt32
}

private struct PackedColorShaders {
    let vertex: ShaderModule
    let fragment: ShaderModule
    let layout: PipelineLayout

    init(device: Device, target: String) throws {
        vertex = try device.makeShaderModule(ShaderFixtures.compile("packed-color", entry: "vertexMain",
            stage: .vertex, target: target).moduleDescriptor())
        fragment = try device.makeShaderModule(ShaderFixtures.compile("packed-color", entry: "fragmentMain",
            stage: .fragment, target: target).moduleDescriptor())
        layout = try device.makePipelineLayout(PipelineLayoutDescriptor(setLayouts: []))
    }

    func pipeline(device: Device, format: TextureFormat, samples: Int) throws -> GraphicsPipeline {
        var raster = RasterizationState(); raster.cullMode = .none
        var descriptor = GraphicsPipelineDescriptor(layout: layout, vertex: vertex, fragment: fragment,
            colorAttachments: [ColorAttachmentDescriptor(format: format)], depthFormat: nil,
            rasterization: raster, depthStencil: nil, vertexLayout: VertexLayoutDescriptor(attributes: [
                VertexAttribute(location: 0, format: .float2, offset: 0),
                VertexAttribute(location: 1, format: .unorm8x4, offset: 8)
            ], bufferLayouts: [VertexBufferLayout(stride: MemoryLayout<PackedColorVertex>.stride)]))
        descriptor.sampleCount = samples
        return try device.makeGraphicsPipeline(descriptor)
    }
}

final class NativeMultisampleTests: XCTestCase {
    #if os(macOS)
    func testMetalPackedColorAndFourSampleCoverage() throws { try draw(.metal, target: "metal") }
    func testMetalResolveClearLoadStoreAndValidation() throws { try clearAndReject(.metal, target: "metal") }
    func testMetalHDRAndDepthResolve() throws { try hdrAndDepth(.metal) }
    #endif
    #if os(Windows) || os(Linux)
    func testVulkanPackedColorAndFourSampleCoverage() throws { try draw(.vulkan, target: "spirv") }
    func testVulkanResolveClearLoadStoreAndValidation() throws { try clearAndReject(.vulkan, target: "spirv") }
    func testVulkanHDRAndDepthResolve() throws { try hdrAndDepth(.vulkan) }
    #endif
    #if os(Windows)
    func testDX12PackedColorAndFourSampleCoverage() throws { try draw(.dx12, target: "dxil") }
    func testDX12ResolveClearLoadStoreAndValidation() throws { try clearAndReject(.dx12, target: "dxil") }
    func testDX12HDRAndDepthResolve() throws { try hdrAndDepth(.dx12) }
    #endif

    private func submit(_ commands: CommandBuffer, device: Device) throws {
        try device.beginFrame()
        do { try device.submit(commands) }
        catch { device.endFrame(); throw error }
        device.endFrame()
        try device.waitUntilIdle()
    }

    private func read(_ texture: Texture, device: Device, width: Int = 24, height: Int = 20) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes {
            try device.readTextureData(texture, width: width, height: height, bytesPerRow: width * 4, into: $0)
        }
        return bytes
    }

    private func draw(_ api: GraphicsAPI, target: String) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api]))
        let shaders = try PackedColorShaders(device: device, target: target)
        // SIMD2 aligns the struct to eight bytes; color has offset 8, stride 16.
        XCTAssertEqual(MemoryLayout<PackedColorVertex>.offset(of: \.color), 8)
        let vertices = [PackedColorVertex(position: SIMD2(-0.85, -0.83), color: 0xffc08040),
                        PackedColorVertex(position: SIMD2(0.79, -0.71), color: 0xffc08040),
                        PackedColorVertex(position: SIMD2(-0.19, 0.89), color: 0xffc08040)]
        let buffer = try device.makeBuffer(BufferDescriptor(size: vertices.count * MemoryLayout<PackedColorVertex>.stride, usage: .vertex))
        try vertices.withUnsafeBytes { try device.uploadBufferData(buffer, data: Data($0)) }
        for format in [TextureFormat.rgba8Unorm, .bgra8Unorm, .rgba8UnormSRGB, .bgra8UnormSRGB] {
            let output = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: format,
                usage: [.colorTarget, .transferSource]))
            let multisample = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: format,
                usage: .colorTarget, sampleCount: 4))
            defer { device.destroy(output); device.destroy(multisample) }
            let singlePipeline = try shaders.pipeline(device: device, format: format, samples: 1)
            let multisamplePipeline = try shaders.pipeline(device: device, format: format, samples: 4)
            let expectedRGBA: [UInt8] = (format == .rgba8UnormSRGB || format == .bgra8UnormSRGB)
                ? [137, 188, 225, 255] : [64, 128, 192, 255]
            let expected = (format == .bgra8Unorm || format == .bgra8UnormSRGB)
                ? [expectedRGBA[2], expectedRGBA[1], expectedRGBA[0], expectedRGBA[3]] : expectedRGBA
            for samples in [1, 4] {
                var color = RenderColorTarget(texture: samples == 1 ? output : multisample,
                    loadAction: .clear(SIMD4(0, 0, 0, 0)), store: false)
                if samples == 4 { color.resolveTexture = output } else { color.store = true }
                let commands = CommandBuffer()
                commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [color])) {
                    $0.setPipeline(samples == 1 ? singlePipeline : multisamplePipeline)
                    $0.setVertexBuffer(buffer); $0.draw(vertexCount: 3)
                }
                // Resolve is also consumed immediately by a subsequent copy pass.
                let copied = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: format,
                    usage: [.transferSource, .transferDestination]))
                defer { device.destroy(copied) }
                commands.copyPass { $0.copyTexture(src: output, dst: copied, width: 24, height: 20) }
                try submit(commands, device: device)
                let pixels = try read(copied, device: device)
                let center = (10 * 24 + 12) * 4
                for channel in 0..<4 { XCTAssertEqual(Int(pixels[center + channel]), Int(expected[channel]), accuracy: 1) }
                XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0, 0])
                let partial = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 0 && pixels[$0] < 255 }
                XCTAssertEqual(partial.isEmpty, samples == 1, "four-sample resolve must preserve fractional edge coverage")
            }
        }
    }

    private func hdrAndDepth(_ api: GraphicsAPI) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api]))
        let source = try device.makeTexture(TextureDescriptor(width: 8, height: 6, format: .rgba16Float,
            usage: .colorTarget, sampleCount: 4))
        let depth = try device.makeTexture(TextureDescriptor(width: 8, height: 6, format: .depth32Float,
            usage: .depthStencilTarget, sampleCount: 4))
        // A resolve destination can also have sampled lower mips; attachment access is mip 0.
        let output = try device.makeTexture(TextureDescriptor(width: 8, height: 6, format: .rgba16Float,
            usage: [.colorTarget, .sampled, .transferSource, .transferDestination], mipLevels: 3))
        let lowerMip = Data(repeating: 0x3c, count: 4 * 3 * 8)
        try device.uploadTextureData(output, data: lowerMip, region: .init(width: 4, height: 3),
            bytesPerRow: 32, subresource: .init(mipLevel: 1))
        var color = RenderColorTarget(texture: source, loadAction: .clear(SIMD4(0.25, 2, 4, 0.5)), store: false)
        color.resolveTexture = output
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [color],
            depthTarget: RenderDepthTarget(texture: depth, loadAction: .clear(0.75), store: false))) { _ in }
        try submit(commands, device: device)
        var bits = [UInt16](repeating: 0, count: 8 * 6 * 4)
        try bits.withUnsafeMutableBytes {
            try device.readTextureData(output, width: 8, height: 6, bytesPerRow: 64, into: $0)
        }
        let expected = [Float16(0.25).bitPattern, Float16(2).bitPattern, Float16(4).bitPattern, Float16(0.5).bitPattern]
        for pixel in stride(from: 0, to: bits.count, by: 4) { XCTAssertEqual(Array(bits[pixel..<pixel + 4]), expected) }
        var actualMip = Data(count: lowerMip.count)
        try actualMip.withUnsafeMutableBytes {
            try device.readTextureData(output, width: 4, height: 3, bytesPerRow: 32, subresource: .init(mipLevel: 1), into: $0)
        }
        XCTAssertEqual(actualMip, lowerMip)
        let singleDepth = try device.makeTexture(TextureDescriptor(width: 8, height: 6, format: .depth32Float, usage: .depthStencilTarget))
        let invalid = CommandBuffer()
        invalid.renderPass(descriptor: RenderPassDescriptor(colorTargets: [color],
            depthTarget: RenderDepthTarget(texture: singleDepth))) { _ in }
        try device.beginFrame(); defer { device.endFrame() }
        XCTAssertThrowsError(try device.submit(invalid))
    }

    private func clearAndReject(_ api: GraphicsAPI, target: String) throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [api]))
        let shaders = try PackedColorShaders(device: device, target: target)
        let source = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource, .transferDestination], sampleCount: 4))
        let output = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: .rgba8Unorm,
            usage: [.colorTarget, .transferSource]))
        var first = RenderColorTarget(texture: source, loadAction: .clear(SIMD4(0.25, 0.5, 0.75, 1)))
        first.resolveTexture = output
        var second = first; second.loadAction = .load; second.store = false
        let commands = CommandBuffer()
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [first])) { _ in }
        commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [second])) { _ in }
        try submit(commands, device: device)
        let pixels = try read(output, device: device)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for (channel, expected) in [64, 128, 191, 255].enumerated() {
                XCTAssertEqual(Int(pixels[pixel + channel]), expected, accuracy: 1)
            }
        }
        let pipeline = try shaders.pipeline(device: device, format: .rgba8Unorm, samples: 1)
        let wrongSize = try device.makeTexture(TextureDescriptor(width: 25, height: 20, format: .rgba8Unorm, usage: .colorTarget))
        let wrongFormat = try device.makeTexture(TextureDescriptor(width: 24, height: 20, format: .bgra8Unorm, usage: .colorTarget))
        var badSize = first; badSize.resolveTexture = wrongSize
        var badFormat = first; badFormat.resolveTexture = wrongFormat
        var alias = first; alias.resolveTexture = source
        var singleSource = first; singleSource.texture = output; singleSource.resolveTexture = wrongFormat
        try device.beginFrame()
        var activeFrame = true
        defer { if activeFrame { device.endFrame() } }
        for bad in [badSize, badFormat, alias, singleSource] {
            let invalid = CommandBuffer(); invalid.renderPass(descriptor: RenderPassDescriptor(colorTargets: [bad])) { _ in }
            XCTAssertThrowsError(try device.submit(invalid))
        }
        let invalidPipeline = CommandBuffer()
        invalidPipeline.renderPass(descriptor: RenderPassDescriptor(colorTargets: [first])) { $0.setPipeline(pipeline) }
        XCTAssertThrowsError(try device.submit(invalidPipeline))
        XCTAssertThrowsError(try device.uploadTextureData(source, data: Data(count: 4), region: .init(width: 1, height: 1), bytesPerRow: 4))
        var bytes = Data(count: 4)
        XCTAssertThrowsError(try bytes.withUnsafeMutableBytes { try device.readTextureData(source, width: 1, height: 1, bytesPerRow: 4, into: $0) })
        let transfer = try device.makeBuffer(BufferDescriptor(size: 16, usage: [.transferSource, .transferDestination]))
        for upload in [true, false] {
            let invalid = CommandBuffer()
            invalid.copyPass {
                if upload { $0.uploadBufferToTexture(buffer: transfer, bytesPerRow: 4, texture: source, width: 1, height: 1) }
                else { $0.copyTextureToBuffer(texture: source, width: 1, height: 1, buffer: transfer, bytesPerRow: 4) }
            }
            XCTAssertThrowsError(try device.submit(invalid))
        }
        // Failed encoding must not poison the frame or consume planner state.
        let recovery = CommandBuffer()
        recovery.renderPass(descriptor: RenderPassDescriptor(colorTargets: [first])) { _ in }
        try device.submit(recovery)
        device.endFrame(); activeFrame = false
        try device.waitUntilIdle()
        XCTAssertEqual(try read(output, device: device), pixels)
    }
}
