// NativeRHI Metal backend — binding sets, immediate data transfer, swapchain,
// the per-frame uploader, and idle synchronization.

#if os(macOS)
import Metal
import QuartzCore

extension MetalDevice {
    // MARK: Binding sets

    public func registerBindingLayout(_ handle: BindingLayout, descriptor: BindingLayoutDescriptor) throws {
        interfaces.bindings[handle.id] = descriptor
    }

    public func registerPipelineLayout(_ handle: PipelineLayout, descriptor: PipelineLayoutDescriptor) throws {
        guard descriptor.setLayouts.count <= 1 else {
            throw RHIError.unsupportedFeature("Metal direct bindings support only set 0")
        }
        for range in descriptor.pushConstants {
            try rhiRequire(range.slot < UInt32(kMetalVertexBufferBaseIndex), "push constant buffer slot is reserved")
            let entries = descriptor.setLayouts.flatMap { interfaces.bindings[$0.id]?.entries ?? [] }
            try rhiRequire(!entries.contains { $0.slot == range.slot && $0.visibility.contains(ShaderVisibility(range.stage))
                && ($0.type == .uniformBuffer || $0.type == .storageBuffer || $0.type == .accelerationStructure) },
                "push constants overlap a buffer binding")
        }
        interfaces.pipelines[handle.id] = descriptor
    }

    public func registerBindingSet(
        _ handle: BindingSet,
        layout: BindingLayout,
        layoutEntries: [BindingLayoutEntry],
        setEntries: [BindingSetEntry]
    ) throws {
        // The frontend already validated entry counts and resource types; here
        // we record each entry with its layout stage/type for encoder-time use.
        // Dictionary insertion cannot fail, but it is never a silent no-op:
        // every set is stored and bound when referenced.
        for entry in layoutEntries {
            if entry.type == .uniformBuffer || entry.type == .storageBuffer || entry.type == .accelerationStructure {
                try rhiRequire(entry.slot < UInt32(kMetalVertexBufferBaseIndex),
                               "Metal buffer binding slots 24...31 are reserved for vertex inputs")
            }
        }
        var resolved: [MetalBoundEntry] = []
        resolved.reserveCapacity(setEntries.count)
        for setEntry in setEntries {
            try validateBindingResource(setEntry.resource)
            let layout = layoutEntries.first(where: { $0.slot == setEntry.slot })
            resolved.append(MetalBoundEntry(
                slot: setEntry.slot,
                type: layout?.type ?? .texture,
                visibility: layout?.visibility ?? .fragment,
                resource: setEntry.resource
            ))
        }
        registries.bindingSets[handle.id] = MetalBindingSet(entries: resolved)
    }

    func validateBindingResource(_ resource: BindingResource) throws {
        switch resource {
        case .uniformBuffer(let handle, let offset, _), .storageBuffer(let handle, let offset):
            guard let buffer = registries.buffers[handle.id], offset >= 0, offset < buffer.length else {
                throw RHIError.invalidArgument("binding references an unknown buffer or invalid offset")
            }
            if case .uniformBuffer(_, _, let size?) = resource {
                try rhiRequire(size > 0, "uniform binding size must be positive")
                try rhiByteRange(offset: offset, size: size, capacity: buffer.length)
            }
        case .texture(let handle), .storageTexture(let handle):
            try rhiRequire(registries.textures[handle.id] != nil, "binding references an unknown texture")
        case .sampler(let handle):
            try rhiRequire(registries.samplers[handle.id] != nil, "binding references an unknown sampler")
        case .accelerationStructure(let handle):
            try rhiRequire(registries.accelerationStructures[handle.id] != nil,
                           "binding references an unknown acceleration structure")
        }
    }

    public func unregisterBindingSet(_ handle: BindingSet) {
        registries.bindingSets[handle.id] = nil
    }

    // MARK: Immediate data transfer

    public func readBufferData(_ buffer: Buffer, offset: Int, into destination: UnsafeMutableRawBufferPointer) throws {
        guard let source = registries.buffers[buffer.id] else { throw RHIError.invalidArgument("unknown buffer") }
        try rhiByteRange(offset: offset, size: destination.count, capacity: source.length)
        if destination.isEmpty { return }
        guard let base = destination.baseAddress else { throw RHIError.invalidArgument("missing buffer readback destination") }
        try waitUntilIdle()
        base.copyMemory(from: source.contents().advanced(by: offset), byteCount: destination.count)
    }

    public func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws {
        guard let mtlBuffer = registries.buffers[buffer.id] else {
            throw RHIError.invalidArgument("uploadBufferData: unknown buffer \(buffer.id)")
        }
        try rhiByteRange(offset: offset, size: data.count, capacity: mtlBuffer.length)
        // Buffers are shared-storage (CPU/GPU coherent on Apple Silicon), so a
        // direct memcpy into contents is safe without a blit sync.
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            mtlBuffer.contents().advanced(by: offset).copyMemory(
                from: source, byteCount: data.count
            )
        }
    }

    public func uploadTextureData(
        _ texture: Texture,
        data: Data,
        region: TextureUploadRegion,
        bytesPerRow: Int,
        subresource: TextureSubresource
    ) throws {
        guard let mtlTexture = registries.textures[texture.id] else {
            throw RHIError.invalidArgument("uploadTextureData: unknown texture \(texture.id)")
        }
        let layers = mtlTexture.textureType == .typeCube ? 6 : mtlTexture.arrayLength
        try rhiRequire(mtlTexture.sampleCount == 1, "texture transfer requires a single sample")
        let extent = try rhiTextureSubresourceExtent(subresource, width: mtlTexture.width, height: mtlTexture.height,
            mipLevels: mtlTexture.mipmapLevelCount, layers: layers)
        let needed = try rhiTextureUploadBytes(region: region,rowBytes: bytesPerRow,format: rhiColorFormat(mtlTexture.pixelFormat),textureWidth: extent.width,textureHeight: extent.height,capacity: data.count)
        let staging = try sharedStagingBuffer(minimumSize: needed)
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            staging.contents().copyMemory(from: source, byteCount: needed)
        }

        // Private (device-local) texture: blit staging -> texture on a one-shot
        // command buffer. This is the synchronous upload API, so waiting is
        // appropriate (it is not the per-submit hot path).
        guard let cmdBuffer = graphicsQueue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else {
            throw RHIError.submitFailed("uploadTextureData: cannot create blit encoder")
        }
        blit.copy(
            from: staging,
            sourceOffset: 0,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * region.height,
            sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
            to: mtlTexture,
            destinationSlice: subresource.layer,
            destinationLevel: subresource.mipLevel,
            destinationOrigin: MTLOrigin(x: region.origin.x, y: region.origin.y, z: 0)
        )
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if let error = cmdBuffer.error { throw RHIError.submitFailed(error.localizedDescription) }
    }

    public func readTextureData(
        _ texture: Texture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        subresource: TextureSubresource,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        guard let mtlTexture = registries.textures[texture.id] else {
            throw RHIError.invalidArgument("readTextureData: unknown texture \(texture.id)")
        }
        let layers = mtlTexture.textureType == .typeCube ? 6 : mtlTexture.arrayLength
        try rhiRequire(mtlTexture.sampleCount == 1, "texture transfer requires a single sample")
        let extent = try rhiTextureSubresourceExtent(subresource, width: mtlTexture.width, height: mtlTexture.height,
            mipLevels: mtlTexture.mipmapLevelCount, layers: layers)
        let needed = try rhiTextureTransferBytes(width: width, height: height, rowBytes: bytesPerRow, format: rhiColorFormat(mtlTexture.pixelFormat), textureWidth: extent.width, textureHeight: extent.height, capacity: destination.count)
        guard destination.count >= needed, let destinationBase = destination.baseAddress else {
            throw RHIError.invalidArgument("readTextureData: destination buffer too small")
        }
        let staging = try sharedStagingBuffer(minimumSize: needed)

        guard let cmdBuffer = graphicsQueue.makeCommandBuffer(),
              let blit = cmdBuffer.makeBlitCommandEncoder() else {
            throw RHIError.submitFailed("readTextureData: cannot create blit encoder")
        }
        blit.copy(
            from: mtlTexture,
            sourceSlice: subresource.layer,
            sourceLevel: subresource.mipLevel,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: staging,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: needed
        )
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if let error = cmdBuffer.error { throw RHIError.submitFailed(error.localizedDescription) }
        destinationBase.copyMemory(from: staging.contents(), byteCount: needed)
    }

    /// Lazily-grown shared staging buffer reused for immediate transfers.
    private func sharedStagingBuffer(minimumSize: Int) throws -> MTLBuffer {
        if let existing = stagingBuffer, existing.length >= minimumSize {
            return existing
        }
        guard let buffer = device.makeBuffer(
            length: max(minimumSize, 1), options: .storageModeShared
        ) else {
            throw RHIError.outOfMemory
        }
        stagingBuffer = buffer
        return buffer
    }

    // MARK: Swapchain

    public func acquireSwapchainImage(_ handle: Swapchain) throws -> SwapchainImage {
        guard let window = swapchains[handle.id], window.currentDrawable == nil else {
            throw RHIError.swapchainAcquireFailed("configure a swapchain and return its acquired image first")
        }
        guard let drawable = window.layer.nextDrawable() else { throw RHIError.swapchainAcquireFailed("nextDrawable returned nil") }
        // One ID per frame slot keeps both resource and planner history bounded.
        // The frontend has waited for that slot's render and present work.
        let id = window.textureIDs[activeSlot] ?? registries.nextInternalID()
        window.textureIDs[activeSlot] = id
        registries.textures[id] = drawable.texture
        window.currentDrawable = drawable
        window.currentSwapchainTextureID = id
        return SwapchainImage(swapchain: handle, generation: window.generation, texture: Texture(id: id),
            width: drawable.texture.width, height: drawable.texture.height)
    }

    public func present(_ image: SwapchainImage, completion: @escaping () -> Void) throws {
        guard let window = swapchains[image.swapchain.id], let drawable = window.currentDrawable,
              window.currentSwapchainTextureID == image.texture.id else {
            throw RHIError.presentFailed("image was not acquired from this swapchain")
        }
        guard let commands = graphicsQueue.makeCommandBuffer() else { throw RHIError.outOfMemory }
        let callback = MetalCompletionCallback(completion), status = submissionStatus
        commands.addCompletedHandler { buffer in
            if let error = buffer.error { status.record(error.localizedDescription) }
            callback.call()
        }
        // Queue order places presentation after all preceding scene/UI work.
        commands.present(drawable)
        commands.commit()
        window.currentDrawable = nil
    }

    // MARK: Frame uploader

    public func makeFrameUploader(slot: Int) -> FrameUploader {
        activeSlot = slot
        if let existing = uploaders[slot] { return existing }
        let uploader = MetalFrameUploader(chunkSize: 4 * 1024 * 1024) { [device, registries] capacity in
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
                throw RHIError.outOfMemory
            }
            let handle = Buffer(id: registries.nextInternalID())
            registries.buffers[handle.id] = buffer
            return MetalUploadChunk(buffer: buffer, handle: handle)
        }
        uploaders[slot] = uploader
        return uploader
    }

    // MARK: Idle

    public func waitUntilIdle() throws {
        // Command queues execute FIFO. Committing a no-op buffer and waiting on
        // it guarantees every previously queued buffer on that queue finished.
        if let graphics = graphicsQueue.makeCommandBuffer() {
            graphics.commit()
            graphics.waitUntilCompleted()
        }
        if computeQueue !== graphicsQueue, let compute = computeQueue.makeCommandBuffer() {
            compute.commit()
            compute.waitUntilCompleted()
        }
        try submissionStatus.check()
    }
}

#endif
