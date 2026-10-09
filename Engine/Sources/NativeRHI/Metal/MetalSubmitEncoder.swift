// NativeRHI Metal backend — PlannedSubmit → MTLCommandBuffer encoding.
//
// Submission is asynchronous: work is encoded into an `MTLCommandBuffer`,
// timeline semaphores map to `MTLSharedEvent` encode-wait/signal, and the
// frontend completion callback fires from `addCompletedHandler`. There is no
// `waitUntilCompleted` and no per-submit idle.

#if os(macOS)
import Metal

extension MetalDevice {
    public func submit(_ submit: PlannedSubmit, completion: @escaping () -> Void) throws {
        let queue: MTLCommandQueue = submit.queue == .compute ? computeQueue : graphicsQueue
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw RHIError.submitFailed("cannot create command buffer")
        }

        // Wait on timeline semaphores (cross-queue release fences).
        for semaphore in submit.waitSemaphores {
            guard let event = sharedEvent(forID: semaphore.id) else {
                throw RHIError.submitFailed("cannot create shared event for wait semaphore \(semaphore.id)")
            }
            commandBuffer.encodeWaitForEvent(event, value: semaphore.value)
        }

        var encoder = MetalPassEncoder(device: device, registries: registries, commandBuffer: commandBuffer)
        defer { encoder.endActiveEncoders() }
        for command in submit.commands {
            try encoder.encode(command)
        }
        encoder.endActiveEncoders()

        // Signal timeline semaphores when this buffer completes.
        for semaphore in submit.signalSemaphores {
            guard let event = sharedEvent(forID: semaphore.id) else {
                throw RHIError.submitFailed("cannot create shared event for signal semaphore \(semaphore.id)")
            }
            commandBuffer.encodeSignalEvent(event, value: semaphore.value)
        }

        let status = submissionStatus
        let callback = MetalCompletionCallback(completion)
        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error { status.record(error.localizedDescription) }
            callback.call()
        }
        commandBuffer.commit()
    }

    func sharedEvent(forID id: UInt32) -> MTLSharedEvent? {
        if let existing = registries.sharedEvents[id] { return existing }
        guard let event = device.makeSharedEvent() else { return nil }
        registries.sharedEvents[id] = event
        return event
    }
}

/// Completion belongs to one command buffer and is invoked once on its GPU
/// completion thread. Its caller supplies synchronization for captured state.
final class MetalCompletionCallback: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func call() { body() }
}

/// Encodes a stream of `PlannedCommand`s for one command buffer. Holds the
/// per-encoder state Metal needs to remember between commands (current
/// pipeline, index buffer, primitive type).
private struct MetalPassEncoder {
    let device: MTLDevice
    let registries: MetalRegistries
    let commandBuffer: MTLCommandBuffer

    // Current encoder state.
    private var renderEncoder: MTLRenderCommandEncoder?
    private var renderBindings: MetalRenderBindings?
    private var computeEncoder: MTLComputeCommandEncoder?
    private var currentMeshPipeline: MetalMeshPipeline?
    private var computeThreadgroupSize = ThreadgroupSize()
    private var currentPrimitive: MTLPrimitiveType = .triangle
    private var currentIndexBuffer: MTLBuffer?
    private var currentIndexOffset: Int = 0
    private var currentIndexType: MTLIndexType = .uint32

    init(device: MTLDevice, registries: MetalRegistries, commandBuffer: MTLCommandBuffer) {
        self.device = device
        self.registries = registries
        self.commandBuffer = commandBuffer
    }

    mutating func encode(_ command: PlannedCommand) throws {
        switch command {
        case .accelerationStructureBuild(let build):
            endActiveEncoders()
            guard let native = registries.accelerationStructures[build.structure.id] else {
                throw RHIError.invalidArgument("unknown acceleration structure build target")
            }
            guard let scratch = device.makeBuffer(length: max(1, native.scratchSize), options: .storageModePrivate),
                  let encoder = commandBuffer.makeAccelerationStructureCommandEncoder() else {
                throw RHIError.outOfMemory
            }
            encoder.build(accelerationStructure: native.structure, descriptor: native.descriptor,
                          scratchBuffer: scratch, scratchBufferOffset: 0)
            encoder.endEncoding()

        case .barriers:
            // Metal tracks resource hazards automatically within a command
            // buffer; cross-queue fences are expressed via shared events.
            break

        case .renderPass(let record):
            endActiveEncoders()
            try encodeRenderPass(record)

        case .computePass(let record):
            endActiveEncoders()
            try encodeComputePass(record)

        case .copyPass(let record):
            endActiveEncoders()
            try encodeCopyPass(record)
        }
    }

    fileprivate mutating func endActiveEncoders() {
        renderEncoder?.endEncoding()
        renderEncoder = nil
        renderBindings = nil
        computeEncoder?.endEncoding()
        computeEncoder = nil
    }

    // MARK: Render pass

    private func validateRenderAttachments(_ record: RenderPassRecord) throws {
        let signature = try rhiRenderPassSignature(record.descriptor) { handle in
            guard let texture = registries.textures[handle.id] else {
                throw RHIError.invalidArgument("unknown render attachment")
            }
            let depth = [.depth32Float, .depth24Unorm_stencil8, .depth32Float_stencil8].contains(texture.pixelFormat)
            let usage: TextureUsage = texture.usage.contains(.renderTarget)
                ? (depth ? .depthStencilTarget : .colorTarget) : []
            var info = RenderTextureInfo(extent: SIMD2(texture.width, texture.height), sampleCount: texture.sampleCount,
                format: texture.pixelFormat, usage: usage,
                singleLayer2D: (texture.textureType == .type2D || texture.textureType == .type2DMultisample), isDepth: depth)
            info.supportsColorResolve = texture.pixelFormat != .r32Uint
            return info
        }
        for command in record.body {
            switch command {
            case .setPipeline(let handle):
                guard let pipeline = registries.renderPipelines[handle.id] else {
                    throw RHIError.invalidArgument("unknown graphics pipeline")
                }
                let descriptor = pipeline.descriptor
                try signature.validate(colors: descriptor.colorAttachments.map { mtlPixelFormat($0.format) },
                    depth: descriptor.depthFormat.map(mtlPixelFormat), samples: descriptor.sampleCount)
            case .setMeshPipeline(let handle):
                guard let pipeline = registries.meshPipelines[handle.id] else {
                    throw RHIError.invalidArgument("unknown mesh pipeline")
                }
                try signature.validate(colors: pipeline.descriptor.colorAttachments.map { mtlPixelFormat($0.format) },
                    depth: pipeline.descriptor.depthFormat.map(mtlPixelFormat), samples: 1)
            default: break
            }
        }
    }

    private mutating func encodeRenderPass(_ record: RenderPassRecord) throws {
        try validateRenderAttachments(record)
        let rpd = MTLRenderPassDescriptor()

        for (index, target) in record.descriptor.colorTargets.enumerated() {
            guard let texture = registries.textures[target.texture.id], index < 8, let attachment = rpd.colorAttachments[index] else { throw RHIError.invalidArgument("invalid render color target") }
            attachment.texture = texture
            attachment.loadAction = mtlLoadAction(target.loadAction)
            attachment.storeAction = target.store ? .store : .dontCare
            if let resolve = target.resolveTexture {
                attachment.resolveTexture = registries.textures[resolve.id]
                attachment.storeAction = target.store ? .storeAndMultisampleResolve : .multisampleResolve
            }
            if case .clear(let color) = target.loadAction {
                attachment.clearColor = MTLClearColor(
                    red: Double(color.x), green: Double(color.y),
                    blue: Double(color.z), alpha: Double(color.w)
                )
            }
        }

        if let depth = record.descriptor.depthTarget {
            guard let texture = registries.textures[depth.texture.id] else {
                throw RHIError.invalidArgument("render pass references unknown depth texture")
            }
            rpd.depthAttachment.texture = texture
            rpd.depthAttachment.loadAction = mtlDepthLoadAction(depth.loadAction)
            rpd.depthAttachment.storeAction = depth.store ? .store : .dontCare
            if case .clear(let value) = depth.loadAction {
                rpd.depthAttachment.clearDepth = value
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            throw RHIError.submitFailed("cannot create render command encoder")
        }
        renderEncoder = encoder
        renderBindings = MetalRenderBindings()
        currentIndexBuffer = nil
        currentMeshPipeline = nil

        for renderCommand in record.body {
            try encodeRenderCommand(renderCommand)
        }
    }

    private mutating func encodeRenderCommand(_ command: RenderCommand) throws {
        guard let encoder = renderEncoder else { throw RHIError.invalidArgument("render encoder is not active") }
        switch command {
        case .setMeshPipeline(let pipeline):
            guard let mesh = registries.meshPipelines[pipeline.id] else {
                throw RHIError.invalidArgument("unknown mesh pipeline")
            }
            currentMeshPipeline = mesh
            encoder.setRenderPipelineState(mesh.state)
            encoder.setDepthStencilState(nil)
            encoder.setCullMode(mtlCullMode(mesh.rasterization.cullMode))
            encoder.setFrontFacing(mtlWinding(mesh.rasterization.frontWinding))
            encoder.setTriangleFillMode(mtlTriangleFillMode(mesh.rasterization.fillMode))

        case .drawMeshTasks(let grid):
            try grid.validate()
            guard let mesh = currentMeshPipeline else {
                throw RHIError.invalidArgument("drawMeshTasks requires a mesh pipeline")
            }
            encoder.drawMeshThreadgroups(grid.metalSize,
                threadsPerObjectThreadgroup: mesh.taskSize.metalSize,
                threadsPerMeshThreadgroup: mesh.meshSize.metalSize)

        case .setPipeline(let pipeline):
            currentMeshPipeline = nil
            guard let state = registries.renderPipelines[pipeline.id] else {
                throw RHIError.invalidArgument("unknown graphics pipeline")
            }
            encoder.setRenderPipelineState(state.state)
            currentPrimitive = registries.pipelinePrimitives[pipeline.id] ?? .triangle
            encoder.setDepthStencilState(registries.depthStates[pipeline.id])
            if let raster = registries.pipelineRasterStates[pipeline.id] {
                encoder.setCullMode(mtlCullMode(raster.cullMode))
                encoder.setFrontFacing(mtlWinding(raster.frontWinding))
                encoder.setTriangleFillMode(mtlTriangleFillMode(raster.fillMode))
            }

        case .setBindingSet(let slot, let set):
            try rhiRequire(slot == 0, "Metal direct binding currently supports set 0 only")
            try bindRenderBindingSet(set, encoder: encoder)

        case .setVertexBuffer(let slot, let buffer, let offset):
            guard let mtlBuffer = registries.buffers[buffer.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
            try rhiByteRange(offset: offset, size: 0, capacity: mtlBuffer.length)
            encoder.setVertexBuffer(mtlBuffer, offset: offset, index: Int(kMetalVertexBufferBaseIndex) + Int(slot))

        case .setIndexBuffer(let buffer, let offset, let type):
            guard let mtlBuffer = registries.buffers[buffer.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
            try rhiByteRange(offset: offset, size: 0, capacity: mtlBuffer.length)
            currentIndexBuffer = mtlBuffer
            currentIndexOffset = offset
            currentIndexType = mtlIndexType(type)

        case .pushConstant(let stage, let slot, let data):
            if !data.isEmpty { renderBindings?.invalidateBuffer(slot: slot, stage: stage) }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                switch stage {
                case .vertex:
                    encoder.setVertexBytes(base, length: data.count, index: Int(slot))
                case .fragment:
                    encoder.setFragmentBytes(base, length: data.count, index: Int(slot))
                case .task:
                    encoder.setObjectBytes(base, length: data.count, index: Int(slot))
                case .mesh:
                    encoder.setMeshBytes(base, length: data.count, index: Int(slot))
                case .compute:
                    break
                }
            }

        case .setViewport(let viewport):
            encoder.setViewport(MTLViewport(
                originX: viewport.x, originY: viewport.y,
                width: viewport.width, height: viewport.height,
                znear: viewport.minDepth, zfar: viewport.maxDepth
            ))

        case .setScissor(let scissor):
            encoder.setScissorRect(MTLScissorRect(
                x: scissor.x, y: scissor.y, width: scissor.width, height: scissor.height
            ))

        case .draw(let vertexCount, let instanceCount, let firstVertex, let firstInstance):
            encoder.drawPrimitives(
                type: currentPrimitive,
                vertexStart: firstVertex,
                vertexCount: vertexCount,
                instanceCount: instanceCount,
                baseInstance: firstInstance
            )

        case .drawIndexed(let args):
            guard let indexBuffer = currentIndexBuffer else {
                throw RHIError.invalidArgument("drawIndexed requires an index buffer")
            }
            let indexSize = currentIndexType == .uint16 ? 2 : 4
            encoder.drawIndexedPrimitives(
                type: currentPrimitive,
                indexCount: args.indexCount,
                indexType: currentIndexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: currentIndexOffset + args.firstIndex * indexSize,
                instanceCount: args.instanceCount,
                baseVertex: args.vertexOffset,
                baseInstance: args.firstInstance
            )

        case .drawIndirect(let buffer, let offset, let count):
            guard let mtlBuffer = registries.buffers[buffer.id] else {
                throw RHIError.invalidArgument("unknown indirect draw buffer")
            }
            let stride = MemoryLayout<MTLDrawPrimitivesIndirectArguments>.stride
            let (size, overflow) = count.multipliedReportingOverflow(by: stride)
            try rhiRequire(count > 0 && offset >= 0 && offset % 4 == 0 && !overflow
                && offset <= mtlBuffer.length && size <= mtlBuffer.length - offset,
                "indirect draw arguments exceed buffer bounds")
            for index in 0..<count {
                encoder.drawPrimitives(type: currentPrimitive, indirectBuffer: mtlBuffer,
                                       indirectBufferOffset: offset + index * stride)
            }
        }
    }

    private func bindRenderBindingSet(_ handle: BindingSet, encoder: MTLRenderCommandEncoder) throws {
        guard let bindingSet = registries.bindingSets[handle.id] else { throw RHIError.invalidArgument("unknown render binding set") }
        guard let bindings = renderBindings else { throw RHIError.invalidArgument("render binding state is not active") }
        let active: ShaderVisibility = currentMeshPipeline == nil ? .graphics : [.task, .mesh, .fragment]
        for entry in bindingSet.entries {
            let stages = entry.visibility.intersection(active)
            guard !stages.isEmpty else { continue }
            // Resolve and validate once, then bind to every visible stage.
            // Avoid allocating stage arrays for every entry of every draw.
            try bindEntry(entry,
                buffer: { buffer, offset in
                    if stages.contains(.vertex), bindings.bufferChanged(buffer, offset: offset, slot: entry.slot, stage: .vertex) {
                        encoder.setVertexBuffer(buffer, offset: offset, index: Int(entry.slot))
                    }
                    if stages.contains(.fragment), bindings.bufferChanged(buffer, offset: offset, slot: entry.slot, stage: .fragment) {
                        encoder.setFragmentBuffer(buffer, offset: offset, index: Int(entry.slot))
                    }
                    if stages.contains(.mesh), bindings.bufferChanged(buffer, offset: offset, slot: entry.slot, stage: .mesh) {
                        encoder.setMeshBuffer(buffer, offset: offset, index: Int(entry.slot))
                    }
                    if stages.contains(.task), bindings.bufferChanged(buffer, offset: offset, slot: entry.slot, stage: .task) {
                        encoder.setObjectBuffer(buffer, offset: offset, index: Int(entry.slot))
                    }
                }, texture: { texture in
                    if stages.contains(.vertex), bindings.textureChanged(texture, slot: entry.slot, stage: .vertex) {
                        encoder.setVertexTexture(texture, index: Int(entry.slot))
                    }
                    if stages.contains(.fragment), bindings.textureChanged(texture, slot: entry.slot, stage: .fragment) {
                        encoder.setFragmentTexture(texture, index: Int(entry.slot))
                    }
                    if stages.contains(.mesh), bindings.textureChanged(texture, slot: entry.slot, stage: .mesh) {
                        encoder.setMeshTexture(texture, index: Int(entry.slot))
                    }
                    if stages.contains(.task), bindings.textureChanged(texture, slot: entry.slot, stage: .task) {
                        encoder.setObjectTexture(texture, index: Int(entry.slot))
                    }
                }, sampler: { sampler in
                    if stages.contains(.vertex), bindings.samplerChanged(sampler, slot: entry.slot, stage: .vertex) {
                        encoder.setVertexSamplerState(sampler, index: Int(entry.slot))
                    }
                    if stages.contains(.fragment), bindings.samplerChanged(sampler, slot: entry.slot, stage: .fragment) {
                        encoder.setFragmentSamplerState(sampler, index: Int(entry.slot))
                    }
                    if stages.contains(.mesh), bindings.samplerChanged(sampler, slot: entry.slot, stage: .mesh) {
                        encoder.setMeshSamplerState(sampler, index: Int(entry.slot))
                    }
                    if stages.contains(.task), bindings.samplerChanged(sampler, slot: entry.slot, stage: .task) {
                        encoder.setObjectSamplerState(sampler, index: Int(entry.slot))
                    }
                })
        }
    }

    // MARK: Compute pass

    private mutating func encodeComputePass(_ record: ComputePassRecord) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RHIError.submitFailed("cannot create compute command encoder")
        }
        computeEncoder = encoder
        computeThreadgroupSize = ThreadgroupSize()
        for computeCommand in record.body {
            try encodeComputeCommand(computeCommand, encoder: encoder)
        }
    }

    private mutating func encodeComputeCommand(_ command: ComputeCommand, encoder: MTLComputeCommandEncoder) throws {
        switch command {
        case .setPipeline(let pipeline):
            guard let state = registries.computePipelines[pipeline.id] else {
                throw RHIError.invalidArgument("unknown compute pipeline")
            }
            computeThreadgroupSize = registries.computeThreadgroupSizes[pipeline.id] ?? ThreadgroupSize()
            encoder.setComputePipelineState(state)

        case .setBindingSet(let slot, let set):
            try rhiRequire(slot == 0, "Metal direct binding currently supports set 0 only")
            guard let bindingSet = registries.bindingSets[set.id] else {
                throw RHIError.invalidArgument("unknown compute binding set")
            }
            for entry in bindingSet.entries where entry.visibility.contains(.compute) {
                if case .accelerationStructure(let handle) = entry.resource {
                    guard let native = registries.accelerationStructures[handle.id] else {
                        throw RHIError.invalidArgument("unknown acceleration structure binding")
                    }
                    encoder.setAccelerationStructure(native.structure, bufferIndex: Int(entry.slot))
                    // TLAS traversal indirectly references each BLAS.
                    for resource in native.dependencies { encoder.useResource(resource, usage: .read) }
                    continue
                }
                try bindEntry(entry,
                          buffer: { buf, offset in encoder.setBuffer(buf, offset: offset, index: Int(entry.slot)) },
                          texture: { tex in encoder.setTexture(tex, index: Int(entry.slot)) },
                          sampler: { sampler in encoder.setSamplerState(sampler, index: Int(entry.slot)) })
            }

        case .pushConstant(_, let slot, let data):
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                encoder.setBytes(base, length: data.count, index: Int(slot))
            }

        case .dispatch(let groupsX, let groupsY, let groupsZ):
            try ThreadgroupSize(x: groupsX, y: groupsY, z: groupsZ).validate()
            // Dispatch dimensions count groups; local size comes from shader reflection.
            encoder.dispatchThreadgroups(
                MTLSize(width: groupsX, height: groupsY, depth: groupsZ),
                threadsPerThreadgroup: computeThreadgroupSize.metalSize
            )

            encoder.memoryBarrier(scope: [.buffers, .textures])
        case .dispatchIndirect(let buffer, let offset):
            guard let mtlBuffer = registries.buffers[buffer.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
            try rhiByteRange(offset: offset, size: 12, capacity: mtlBuffer.length)
            encoder.dispatchThreadgroups(
                indirectBuffer: mtlBuffer,
                indirectBufferOffset: offset,
                threadsPerThreadgroup: computeThreadgroupSize.metalSize
            )
            encoder.memoryBarrier(scope: [.buffers, .textures])
        }
    }

    // MARK: Copy pass

    private mutating func encodeCopyPass(_ record: CopyPassRecord) throws {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { throw RHIError.outOfMemory }
        defer { encoder.endEncoding() }
        for copyCommand in record.body {
            switch copyCommand {
            case .copyTexture(let source, let destination, let width, let height):
                guard let src = registries.textures[source.id], let dst = registries.textures[destination.id] else {
                    throw RHIError.invalidArgument("unknown texture copy resource")
                }
                try rhiRequire(src !== dst && src.textureType == .type2D && dst.textureType == .type2D
                    && src.sampleCount == 1 && dst.sampleCount == 1, "texture copy requires distinct single-sample 2D textures")
                try rhiColorTextureCopyExtent(width: width, height: height,
                    source: (src.width,src.height,rhiColorFormat(src.pixelFormat)),
                    destination: (dst.width,dst.height,rhiColorFormat(dst.pixelFormat)))
                encoder.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0,y: 0,z: 0),
                    sourceSize: MTLSize(width: width,height: height,depth: 1), to: dst, destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0,y: 0,z: 0))
            case .copyBuffer(let src, let srcOffset, let dst, let dstOffset, let size):
                guard let srcBuffer = registries.buffers[src.id],
                      let dstBuffer = registries.buffers[dst.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
                try rhiByteRange(offset: srcOffset, size: size, capacity: srcBuffer.length)
                try rhiByteRange(offset: dstOffset, size: size, capacity: dstBuffer.length)
                try rhiRequire(srcBuffer !== dstBuffer, "copies within one buffer are not supported")
                encoder.copy(from: srcBuffer, sourceOffset: srcOffset,
                             to: dstBuffer, destinationOffset: dstOffset, size: size)

            case .copyBufferToTexture(let upload):
                guard let srcBuffer = registries.buffers[upload.buffer.id],
                      let dstTexture = registries.textures[upload.texture.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
                try rhiRequire(dstTexture.sampleCount == 1, "buffer texture copies require a single-sample texture")
                let layers = dstTexture.textureType == .typeCube ? 6 : dstTexture.arrayLength
                let extent = try rhiTextureSubresourceExtent(upload.subresource, width: dstTexture.width,
                    height: dstTexture.height, mipLevels: dstTexture.mipmapLevelCount, layers: layers)
                let bytes = try rhiTextureUploadBytes(region: upload.region, rowBytes: upload.bytesPerRow,
                    format: rhiColorFormat(dstTexture.pixelFormat), textureWidth: extent.width,
                    textureHeight: extent.height, capacity: srcBuffer.length)
                try rhiByteRange(offset: upload.offset, size: bytes, capacity: srcBuffer.length)
                encoder.copy(
                    from: srcBuffer, sourceOffset: upload.offset,
                    sourceBytesPerRow: upload.bytesPerRow,
                    sourceBytesPerImage: upload.bytesPerRow * upload.region.height,
                    sourceSize: MTLSize(width: upload.region.width, height: upload.region.height, depth: 1),
                    to: dstTexture, destinationSlice: upload.subresource.layer, destinationLevel: upload.subresource.mipLevel,
                    destinationOrigin: MTLOrigin(x: upload.region.origin.x, y: upload.region.origin.y, z: 0)
                )

            case .copyTextureToBuffer(let texture, let width, let height, let buffer, let offset, let bytesPerRow):
                guard let srcTexture = registries.textures[texture.id],
                      let dstBuffer = registries.buffers[buffer.id] else { throw RHIError.invalidArgument("unknown buffer or texture") }
                try rhiRequire(srcTexture.sampleCount == 1, "buffer texture copies require a single-sample texture")
                let bytes = try rhiTextureTransferBytes(width: width, height: height, rowBytes: bytesPerRow, format: rhiColorFormat(srcTexture.pixelFormat), textureWidth: srcTexture.width, textureHeight: srcTexture.height, capacity: dstBuffer.length)
                try rhiByteRange(offset: offset, size: bytes, capacity: dstBuffer.length)
                encoder.copy(
                    from: srcTexture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: dstBuffer, destinationOffset: offset,
                    destinationBytesPerRow: bytesPerRow,
                    destinationBytesPerImage: bytesPerRow * height
                )
            }
        }
    }

    // MARK: Binding resolution

    private func bindEntry(
        _ entry: MetalBoundEntry,
        buffer: (MTLBuffer, Int) -> Void,
        texture: (MTLTexture) -> Void,
        sampler: (MTLSamplerState) -> Void
    ) throws {
        switch entry.resource {
        case .sampler(let s):
            guard let state = registries.samplers[s.id] else { throw RHIError.invalidArgument("unknown sampler binding") }
            sampler(state)
        case .texture(let t), .storageTexture(let t):
            guard let tex = registries.textures[t.id] else { throw RHIError.invalidArgument("unknown texture binding") }
            texture(tex)
        case .uniformBuffer(let b, let offset, _), .storageBuffer(let b, let offset):
            guard let mtlBuffer = registries.buffers[b.id] else { throw RHIError.invalidArgument("unknown buffer binding") }
            try rhiByteRange(offset: offset, size: 0, capacity: mtlBuffer.length)
            buffer(mtlBuffer, offset)
        case .accelerationStructure:
            // Not used by the current pipeline model.
            break
        }
    }
}

#endif
