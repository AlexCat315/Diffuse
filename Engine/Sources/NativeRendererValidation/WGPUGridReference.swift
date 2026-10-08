import EngineKernel
import Foundation
import RenderBackend
import RHIWGPU

/// A single WGSL grid pass on matching targets, without the rest of the WGPU
/// frame graph. Used only for parity checks and equivalent-work benchmarks.
public final class WGPUGridReference {
    public let backend: WGPUBackend
    public let color: GPUTexture
    private let colorView: GPUTextureView
    private let depth: GPUTexture
    private let depthView: GPUTextureView
    private let pipeline: GPURenderPipeline
    private let buffers: [GPUBuffer]
    private let groups: [GPUBindGroup]
    private let size: RenderDrawableSize
    private var frame = 0

    public init(size: RenderDrawableSize, validation: Bool = false) throws {
        if let override = ProcessInfo.processInfo.environment["GUAVA_WGPU_BACKEND"], override.lowercased() != "metal" {
            throw WGPUBackendError.initFailed("grid comparison requires GUAVA_WGPU_BACKEND=metal or no backend override")
        }
        self.size = size
        backend = WGPUBackend(config: WGPUDeviceConfig(validationEnabled: validation, framesInFlight: 3, preferredBackends: [.metal]))
        try backend.initialize()
        color = try backend.createTexture(width: size.width, height: size.height,
            format: .bgra8Unorm, usage: [.renderAttachment, .copySrc])
        colorView = try color.createView()
        depth = try backend.createTexture(width: size.width, height: size.height,
            format: .depth32Float, usage: .renderAttachment)
        depthView = try depth.createView()
        let bundle = PackageResourceBundle.required(named: "GuavaEngine_RenderBackend")
        guard let url = bundle.url(forResource: "editor_grid", withExtension: "wgsl", subdirectory: "Shaders/WGSL") else {
            throw WGPUBackendError.initFailed("missing WGSL grid reference")
        }
        let shader = try backend.createShaderModule(wgsl: String(contentsOf: url, encoding: .utf8), label: "grid-reference")
        pipeline = try backend.createRenderPipeline(desc: GPURenderPipelineDescriptor(shaderModule: shader,
            colorFormat: .bgra8Unorm, cullMode: .none, blend: .alphaBlending,
            depthStencil: GPUDepthStencilPipelineState(format: .depth32Float, depthWriteEnabled: false, depthCompare: .lessEqual)))
        let layout = try pipeline.getBindGroupLayout(group: 0)
        let factory = backend
        buffers = try (0..<3).map { _ in try factory.createBuffer(size: 256, usage: [.uniform, .copyDst]) }
        groups = try buffers.map { try factory.createBindGroup(layout: layout, entries: [
            GPUBindGroupEntry(binding: 0, buffer: $0, offset: 0, size: UInt64(MemoryLayout<EditorGridUniforms>.stride))]) }
    }
    deinit { try? backend.waitUntilIdle() }

    public func render(packet: RenderPacket, depthClear: Float = 1) throws -> RenderFrameStats {
        guard packet.drawableSize == size else { throw WGPUBackendError.initFailed("grid reference extent differs from packet") }
        let start = DispatchTime.now().uptimeNanoseconds
        let slot = frame % 3
        let uniforms = EditorGridUniforms.make(packet: packet)
        withUnsafeBytes(of: uniforms) { if let pointer = $0.baseAddress { backend.writeBuffer(buffers[slot], data: pointer, size: $0.count) } }
        let prepared = DispatchTime.now().uptimeNanoseconds
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(colorView: colorView, clearColor: GPUColor(r: 0.08, g: 0.10, b: 0.14, a: 1),
            depthView: depthView, depthClearValue: depthClear)
        if packet.renderSettings.enableEditorGrid {
            pass.setPipeline(pipeline); pass.setBindGroup(groups[slot], index: 0)
            pass.setViewport(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
            pass.setScissorRect(x: 0, y: 0, width: size.width, height: size.height)
            pass.draw(vertexCount: 3)
        }
        pass.end()
        let commands = try encoder.finish()
        let encoded = DispatchTime.now().uptimeNanoseconds
        backend.submit(commands); frame += 1
        let submitted = DispatchTime.now().uptimeNanoseconds
        var stats = RenderFrameStats(); stats.frameIndex = packet.frameIndex
        stats.cpuPrepareNS = prepared - start; stats.cpuEncodeNS = encoded - prepared
        stats.cpuSubmitNS = submitted - encoded; stats.cpuFrameTotalNS = submitted - start
        return stats
    }
    public func finish() throws { try backend.waitUntilIdle() }
    public func readback() throws -> Data {
        let row = (size.width * 4 + 255) / 256 * 256
        let buffer = try backend.createBuffer(size: UInt64(row * size.height), usage: [.copyDst, .mapRead])
        let encoder = try backend.createCommandEncoder()
        encoder.copyTextureToBuffer(source: color, destination: buffer, bytesPerRow: row,
            rowsPerImage: size.height, width: size.width, height: size.height)
        backend.submit(try encoder.finish())
        try backend.bufferMapSync(buffer, size: UInt64(row * size.height))
        defer { buffer.unmap() }
        guard let pointer = buffer.getMappedRange(size: UInt64(row * size.height)) else {
            throw WGPUBackendError.initFailed("grid reference readback failed")
        }
        var data = Data(); data.reserveCapacity(Int(size.width * size.height * 4))
        for y in 0..<Int(size.height) { data.append(pointer.advanced(by: y * Int(row)).assumingMemoryBound(to: UInt8.self), count: Int(size.width * 4)) }
        return data
    }
}
