import Foundation
import RenderBackend
import RHIWGPU

/// Uses the existing production WGPURenderer, including its real resource table
/// and frame planning. Scene packets start at r3, where viewport resolve makes
/// the actual rendered texture available for readback.
public final class WGPUSceneReference {
    public let backend: WGPUBackend
    public let renderer: WGPURenderer
    public init(validation: Bool = false) throws {
        backend = try WGPUReferenceConfiguration.make(validation: validation)
        renderer = WGPURenderer(backend: backend); renderer.initialize()
    }
    deinit { try? backend.waitUntilIdle() }
    public func render(packet: RenderPacket) throws -> RenderFrameStats {
        guard packet.renderSettings.stage.rawValue >= RenderSettings.ReplacementStage.r3ViewportInterop.rawValue else {
            throw WGPUBackendError.initFailed("scene comparison requires r3 or later to publish the rendered viewport")
        }
        renderer.render(packet: packet)
        guard renderer.lastFrameStats.frameIndex == packet.frameIndex,
              renderer.currentViewportSurfaceState().isValid else {
            throw WGPUBackendError.initFailed("scene reference did not complete the packet")
        }
        return renderer.lastFrameStats
    }
    public func finish() throws { try backend.waitUntilIdle() }
    public func readback() throws -> Data {
        let state = renderer.currentViewportSurfaceState()
        guard state.isValid, case .wgpu(let texture) = state.image?.storage else {
            throw WGPUBackendError.initFailed("scene reference surface missing")
        }
        let row = (state.region.size.width * 4 + 255) / 256 * 256
        let buffer = try backend.createBuffer(size: UInt64(row * state.region.size.height), usage: [.copyDst, .mapRead])
        let encoder = try backend.createCommandEncoder()
        encoder.copyTextureToBuffer(source: texture, destination: buffer, bytesPerRow: row,
            rowsPerImage: state.region.size.height, width: state.region.size.width, height: state.region.size.height)
        backend.submit(try encoder.finish())
        try backend.bufferMapSync(buffer, size: UInt64(row * state.region.size.height))
        defer { buffer.unmap() }
        guard let pointer = buffer.getMappedRange(size: UInt64(row * state.region.size.height)) else {
            throw WGPUBackendError.initFailed("scene reference readback failed")
        }
        var data = Data()
        for y in 0..<Int(state.region.size.height) { data.append(pointer.advanced(by: y * Int(row)).assumingMemoryBound(to: UInt8.self), count: Int(state.region.size.width * 4)) }
        return data
    }
}
