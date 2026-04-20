import CWGPUBridge

public final class GPUCommandEncoder {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_command_encoder(handle)
    }

    public func beginRenderPass(colorView: GPUTextureView,
                                loadOp: GPULoadOp = .clear,
                                storeOp: GPUStoreOp = .store,
                                clearColor: GPUColor = .black) throws -> GPURenderPassEncoder {
        var passPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_begin_render_pass(
            handle,
            colorView.handle,
            loadOp.bridgeValue,
            storeOp.bridgeValue,
            clearColor.bridgeValue,
            &passPtr
        )
        guard ok == 1, let passPtr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPURenderPassEncoder(handle: passPtr)
    }

    public func finish() throws -> GPUCommandBuffer {
        var cbPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_encoder_finish(handle, &cbPtr)
        guard ok == 1, let cbPtr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPUCommandBuffer(handle: cbPtr)
    }
}

public final class GPURenderPassEncoder {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_render_pass_encoder(handle)
    }

    public func setPipeline(_ pipeline: GPURenderPipeline) {
        wgpu_bridge_render_pass_set_pipeline(handle, pipeline.handle)
    }

    public func setVertexBuffer(_ buffer: GPUBuffer, slot: UInt32 = 0,
                                offset: UInt64 = 0, size: UInt64? = nil) {
        let sz = size ?? buffer.size
        wgpu_bridge_render_pass_set_vertex_buffer(handle, slot, buffer.handle, offset, sz)
    }

    public func setIndexBuffer(_ buffer: GPUBuffer, format: GPUIndexFormat = .uint32,
                               offset: UInt64 = 0, size: UInt64? = nil) {
        let sz = size ?? buffer.size
        wgpu_bridge_render_pass_set_index_buffer(handle, buffer.handle,
                                                 format.bridgeValue, offset, sz)
    }

    public func setBindGroup(_ bindGroup: GPUBindGroup, index: UInt32 = 0) {
        wgpu_bridge_render_pass_set_bind_group(handle, index, bindGroup.handle)
    }

    public func draw(vertexCount: UInt32,
                     instanceCount: UInt32 = 1,
                     firstVertex: UInt32 = 0,
                     firstInstance: UInt32 = 0) {
        wgpu_bridge_render_pass_draw(handle, vertexCount, instanceCount, firstVertex, firstInstance)
    }

    public func drawIndexed(indexCount: UInt32,
                            instanceCount: UInt32 = 1,
                            firstIndex: UInt32 = 0,
                            baseVertex: Int32 = 0,
                            firstInstance: UInt32 = 0) {
        wgpu_bridge_render_pass_draw_indexed(handle, indexCount, instanceCount,
                                             firstIndex, baseVertex, firstInstance)
    }

    public func end() {
        wgpu_bridge_render_pass_end(handle)
    }
}

public final class GPUCommandBuffer {
    var handle: UnsafeMutableRawPointer?

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        if let handle {
            wgpu_bridge_release_command_buffer(handle)
        }
    }

    func take() -> UnsafeMutableRawPointer? {
        let h = handle
        handle = nil
        return h
    }
}
