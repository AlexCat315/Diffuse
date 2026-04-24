import CWGPUBridge

public final class GPUCommandEncoder {
    let handle: UnsafeMutableRawPointer
    private var finished = false

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        if !finished {
            wgpu_bridge_release_command_encoder(handle)
        }
    }

    public func beginRenderPass(colorView: GPUTextureView,
                                resolveTargetView: GPUTextureView? = nil,
                                loadOp: GPULoadOp = .clear,
                                storeOp: GPUStoreOp = .store,
                                clearColor: GPUColor = .black,
                                depthView: GPUTextureView? = nil,
                                depthLoadOp: GPULoadOp = .clear,
                                depthStoreOp: GPUStoreOp = .store,
                                depthClearValue: Float = 1.0,
                                stencilLoadOp: GPULoadOp = .clear,
                                stencilStoreOp: GPUStoreOp = .discard,
                                stencilClearValue: UInt32 = 0) throws -> GPURenderPassEncoder {
        var passPtr: UnsafeMutableRawPointer?

        var depthAttachment: WGPUBridgeDepthStencilAttachment?
        if let depthView {
            depthAttachment = WGPUBridgeDepthStencilAttachment(
                view: depthView.handle,
                depth_load_op: depthLoadOp.bridgeValue,
                depth_store_op: depthStoreOp.bridgeValue,
                clear_depth: depthClearValue,
                stencil_load_op: stencilLoadOp.bridgeValue,
                stencil_store_op: stencilStoreOp.bridgeValue,
                stencil_clear_value: stencilClearValue
            )
        }

        let ok: Int32
        if var da = depthAttachment {
            ok = wgpu_bridge_begin_render_pass(
                handle, colorView.handle, resolveTargetView?.handle,
                loadOp.bridgeValue, storeOp.bridgeValue,
                clearColor.bridgeValue, &da, &passPtr
            )
        } else {
            ok = wgpu_bridge_begin_render_pass(
                handle, colorView.handle, resolveTargetView?.handle,
                loadOp.bridgeValue, storeOp.bridgeValue,
                clearColor.bridgeValue, nil, &passPtr
            )
        }

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
        // wgpu requires the encoder to be released before submitting the command buffer.
        wgpu_bridge_release_command_encoder(handle)
        finished = true
        return GPUCommandBuffer(handle: cbPtr)
    }

    public func beginComputePass() throws -> GPUComputePassEncoder {
        var passPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_begin_compute_pass(handle, &passPtr)
        guard ok == 1, let passPtr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPUComputePassEncoder(handle: passPtr)
    }

    public func copyTextureToTexture(source: GPUTexture, sourceMip: UInt32 = 0,
                                     destination: GPUTexture, destinationMip: UInt32 = 0,
                                     width: UInt32, height: UInt32,
                                     depthOrLayers: UInt32 = 1) {
        wgpu_bridge_copy_texture_to_texture(handle,
                                            source.handle, sourceMip,
                                            destination.handle, destinationMip,
                                            width, height, depthOrLayers)
    }

    public func copyTextureToBuffer(source: GPUTexture, sourceMip: UInt32 = 0,
                                    destination: GPUBuffer,
                                    bufferOffset: UInt64 = 0,
                                    bytesPerRow: UInt32,
                                    rowsPerImage: UInt32,
                                    width: UInt32, height: UInt32,
                                    depthOrLayers: UInt32 = 1) {
        wgpu_bridge_copy_texture_to_buffer(handle,
                                           source.handle, sourceMip,
                                           destination.handle, bufferOffset,
                                           bytesPerRow, rowsPerImage,
                                           width, height, depthOrLayers)
    }
}

public final class GPURenderPassEncoder {
    let handle: UnsafeMutableRawPointer
    private var ended = false

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        if !ended {
            wgpu_bridge_release_render_pass_encoder(handle)
        }
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

    public func setBindGroup(_ bindGroup: GPUBindGroup,
                             index: UInt32 = 0,
                             dynamicOffsets: [UInt32]) {
        if dynamicOffsets.isEmpty {
            wgpu_bridge_render_pass_set_bind_group(handle, index, bindGroup.handle)
            return
        }
        dynamicOffsets.withUnsafeBufferPointer { offsets in
            wgpu_bridge_render_pass_set_bind_group_dynamic(
                handle,
                index,
                bindGroup.handle,
                UInt32(offsets.count),
                offsets.baseAddress
            )
        }
    }

    public func setViewport(x: Float, y: Float, width: Float, height: Float,
                            minDepth: Float = 0.0, maxDepth: Float = 1.0) {
        wgpu_bridge_render_pass_set_viewport(handle, x, y, width, height, minDepth, maxDepth)
    }

    public func setScissorRect(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        wgpu_bridge_render_pass_set_scissor_rect(handle, x, y, width, height)
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

    public func drawIndirect(buffer: GPUBuffer, offset: UInt64 = 0) {
        wgpu_bridge_render_pass_draw_indirect(handle, buffer.handle, offset)
    }

    public func drawIndexedIndirect(buffer: GPUBuffer, offset: UInt64 = 0) {
        wgpu_bridge_render_pass_draw_indexed_indirect(handle, buffer.handle, offset)
    }

    public func executeBundles(_ bundles: [GPURenderBundle]) {
        guard !bundles.isEmpty else { return }
        var handles: [UnsafeMutableRawPointer?] = bundles.map { $0.handle }
        handles.withUnsafeMutableBufferPointer { buf in
            wgpu_bridge_render_pass_execute_bundles(handle, buf.baseAddress, UInt32(bundles.count))
        }
    }

    public func end() {
        guard !ended else { return }
        wgpu_bridge_render_pass_end(handle)
        // wgpu requires the render pass encoder to be released before encoder.finish()
        wgpu_bridge_release_render_pass_encoder(handle)
        ended = true
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
