import CWGPUBridge

public struct GPURenderBundleEncoderDescriptor: Sendable {
    public var colorFormats: [GPUTextureFormat]
    public var depthStencilFormat: GPUTextureFormat?
    public var sampleCount: UInt32
    public var depthReadOnly: Bool
    public var stencilReadOnly: Bool

    public init(colorFormats: [GPUTextureFormat],
                depthStencilFormat: GPUTextureFormat? = nil,
                sampleCount: UInt32 = 1,
                depthReadOnly: Bool = false,
                stencilReadOnly: Bool = false) {
        self.colorFormats = colorFormats
        self.depthStencilFormat = depthStencilFormat
        self.sampleCount = sampleCount
        self.depthReadOnly = depthReadOnly
        self.stencilReadOnly = stencilReadOnly
    }
}

public final class GPURenderBundle {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_render_bundle(handle)
    }
}

extension GPURenderBundle: @unchecked Sendable {}

public final class GPURenderBundleEncoder {
    let handle: UnsafeMutableRawPointer
    private var finished = false

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        if !finished {
            wgpu_bridge_release_render_bundle_encoder(handle)
        }
    }

    public func setPipeline(_ pipeline: GPURenderPipeline) {
        wgpu_bridge_render_bundle_set_pipeline(handle, pipeline.handle)
    }

    public func setVertexBuffer(_ buffer: GPUBuffer,
                                slot: UInt32 = 0,
                                offset: UInt64 = 0,
                                size: UInt64 = UInt64.max) {
        wgpu_bridge_render_bundle_set_vertex_buffer(handle, slot, buffer.handle, offset, size)
    }

    public func setIndexBuffer(_ buffer: GPUBuffer,
                               format: GPUIndexFormat,
                               offset: UInt64 = 0,
                               size: UInt64 = UInt64.max) {
        wgpu_bridge_render_bundle_set_index_buffer(handle, buffer.handle, format.bridgeValue, offset, size)
    }

    public func setBindGroup(_ bindGroup: GPUBindGroup, index: UInt32 = 0) {
        wgpu_bridge_render_bundle_set_bind_group(handle, index, bindGroup.handle)
    }

    public func draw(vertexCount: UInt32,
                     instanceCount: UInt32 = 1,
                     firstVertex: UInt32 = 0,
                     firstInstance: UInt32 = 0) {
        wgpu_bridge_render_bundle_draw(handle, vertexCount, instanceCount, firstVertex, firstInstance)
    }

    public func drawIndexed(indexCount: UInt32,
                            instanceCount: UInt32 = 1,
                            firstIndex: UInt32 = 0,
                            baseVertex: Int32 = 0,
                            firstInstance: UInt32 = 0) {
        wgpu_bridge_render_bundle_draw_indexed(handle, indexCount, instanceCount,
                                               firstIndex, baseVertex, firstInstance)
    }

    public func drawIndirect(buffer: GPUBuffer, offset: UInt64 = 0) {
        wgpu_bridge_render_bundle_draw_indirect(handle, buffer.handle, offset)
    }

    public func drawIndexedIndirect(buffer: GPUBuffer, offset: UInt64 = 0) {
        wgpu_bridge_render_bundle_draw_indexed_indirect(handle, buffer.handle, offset)
    }

    public func finish() throws -> GPURenderBundle {
        var out: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_render_bundle_encoder_finish(handle, &out)
        finished = true
        wgpu_bridge_release_render_bundle_encoder(handle)
        guard ok != 0, let h = out else {
            throw RHIError.bundleFinishFailed
        }
        return GPURenderBundle(handle: h)
    }
}

public enum RHIError: Error {
    case bundleFinishFailed
    case bundleEncoderCreationFailed
    case asyncPipelineFailed
}
