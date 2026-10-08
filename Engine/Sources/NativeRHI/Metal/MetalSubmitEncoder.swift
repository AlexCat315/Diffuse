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
        commandBuffer.addCompletedHandler { buffer in
            if let error = buffer.error { status.record(error.localizedDescription) }
            completion()
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

/// Encodes a stream of `PlannedCommand`s for one command buffer. Holds the
/// per-encoder state Metal needs to remember between commands (current
/// pipeline, index buffer, primitive type).
private struct MetalPassEncoder {
    let device: MTLDevice
    let registries: MetalRegistries
    let commandBuffer: MTLCommandBuffer

    // Current encoder state.
    private var renderEncoder: MTLRenderCommandEncoder?
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
            encodeCopyPass(record)
        }
    }

    fileprivate mutating func endActiveEncoders() {
        renderEncoder?.endEncoding()
        renderEncoder = nil
        computeEncoder?.endEncoding()
        computeEncoder = nil
    }

    // MARK: Render pass

    private mutating func encodeRenderPass(_ record: RenderPassRecord) throws {
        let rpd = MTLRenderPassDescriptor()

        for (index, target) in record.descriptor.colorTargets.enumerated() {
            guard let texture = registries.textures[target.texture.id] else { continue }
            guard let attachment = rpd.colorAttachments[index] else { continue }
            attachment.texture = texture
            attachment.loadAction = mtlLoadAction(target.loadAction)
            attachment.storeAction = target.store ? .store : .dontCare
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
        currentIndexBuffer = nil
        currentMeshPipeline = nil

        for renderCommand in record.body {
            try encodeRenderCommand(renderCommand)
        }
    }

    private mutating func encodeRenderCommand(_ command: RenderCommand) throws {
        guard let encoder = renderEncoder else { return }
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
            encoder.setRenderPipelineState(state)
            currentPrimitive = registries.pipelinePrimitives[pipeline.id] ?? .triangle
            if let depthState = registries.depthStates[pipeline.id] {
                encoder.setDepthStencilState(depthState)
            }
            if let raster = registries.pipelineRasterStates[pipeline.id] {
                encoder.setCullMode(mtlCullMode(raster.cullMode))
                encoder.setFrontFacing(mtlWinding(raster.frontWinding))
                encoder.setTriangleFillMode(mtlTriangleFillMode(raster.fillMode))
            }

        case .setBindingSet(let slot, let set):
            try rhiRequire(slot == 0, "Metal direct binding currently supports set 0 only")
            try bindRenderBindingSet(set, encoder: encoder)

        case .setVertexBuffer(let slot, let buffer, let offset):
            guard let mtlBuffer = registries.buffers[buffer.id] else { break }
            encoder.setVertexBuffer(mtlBuffer, offset: offset, index: Int(kMetalVertexBufferBaseIndex) + Int(slot))

        case .setIndexBuffer(let buffer, let offset, let type):
            guard let mtlBuffer = registries.buffers[buffer.id] else { break }
            currentIndexBuffer = mtlBuffer
            currentIndexOffset = offset
            currentIndexType = mtlIndexType(type)

        case .pushConstant(let stage, let slot, let data):
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

    private func bindRenderBindingSet(_ set: BindingSet, encoder: MTLRenderCommandEncoder) throws {
        guard let bindingSet = registries.bindingSets[set.id] else {
            throw RHIError.invalidArgument("unknown render binding set")
        }
        for entry in bindingSet.entries {
            bindEntry(entry,
                      buffer: { buf, offset in
                          switch entry.stage {
                          case .vertex:   encoder.setVertexBuffer(buf, offset: offset, index: Int(entry.slot))
                          case .fragment: encoder.setFragmentBuffer(buf, offset: offset, index: Int(entry.slot))
                          case .task: encoder.setObjectBuffer(buf, offset: offset, index: Int(entry.slot))
                          case .mesh: encoder.setMeshBuffer(buf, offset: offset, index: Int(entry.slot))
                          case .compute: break
                          }
                      },
                      texture: { tex in
                          switch entry.stage {
                          case .vertex:   encoder.setVertexTexture(tex, index: Int(entry.slot))
                          case .fragment: encoder.setFragmentTexture(tex, index: Int(entry.slot))
                          case .task: encoder.setObjectTexture(tex, index: Int(entry.slot))
                          case .mesh: encoder.setMeshTexture(tex, index: Int(entry.slot))
                          case .compute: break
                          }
                      },
                      sampler: { sampler in
                          switch entry.stage {
                          case .vertex:   encoder.setVertexSamplerState(sampler, index: Int(entry.slot))
                          case .fragment: encoder.setFragmentSamplerState(sampler, index: Int(entry.slot))
                          case .task: encoder.setObjectSamplerState(sampler, index: Int(entry.slot))
                          case .mesh: encoder.setMeshSamplerState(sampler, index: Int(entry.slot))
                          case .compute: break
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
            for entry in bindingSet.entries {
                if case .accelerationStructure(let handle) = entry.resource {
                    guard let native = registries.accelerationStructures[handle.id] else {
                        throw RHIError.invalidArgument("unknown acceleration structure binding")
                    }
                    encoder.setAccelerationStructure(native.structure, bufferIndex: Int(entry.slot))
                    // TLAS traversal indirectly references each BLAS.
                    for resource in native.dependencies { encoder.useResource(resource, usage: .read) }
                    continue
                }
                bindEntry(entry,
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

        case .dispatchIndirect(let buffer, let offset):
            guard let mtlBuffer = registries.buffers[buffer.id] else { break }
            encoder.dispatchThreadgroups(
                indirectBuffer: mtlBuffer,
                indirectBufferOffset: offset,
                threadsPerThreadgroup: computeThreadgroupSize.metalSize
            )
        }
    }

    // MARK: Copy pass

    private mutating func encodeCopyPass(_ record: CopyPassRecord) {
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        for copyCommand in record.body {
            switch copyCommand {
            case .copyBuffer(let src, let srcOffset, let dst, let dstOffset, let size):
                guard let srcBuffer = registries.buffers[src.id],
                      let dstBuffer = registries.buffers[dst.id] else { break }
                encoder.copy(from: srcBuffer, sourceOffset: srcOffset,
                             to: dstBuffer, destinationOffset: dstOffset, size: size)

            case .copyBufferToTexture(let buffer, let offset, let bytesPerRow, let texture, let width, let height):
                guard let srcBuffer = registries.buffers[buffer.id],
                      let dstTexture = registries.textures[texture.id] else { break }
                encoder.copy(
                    from: srcBuffer, sourceOffset: offset,
                    sourceBytesPerRow: bytesPerRow,
                    sourceBytesPerImage: bytesPerRow * height,
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: dstTexture, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )

            case .copyTextureToBuffer(let texture, let width, let height, let buffer, let offset, let bytesPerRow):
                guard let srcTexture = registries.textures[texture.id],
                      let dstBuffer = registries.buffers[buffer.id] else { break }
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
        encoder.endEncoding()
    }

    // MARK: Binding resolution

    private func bindEntry(
        _ entry: MetalBoundEntry,
        buffer: (MTLBuffer, Int) -> Void,
        texture: (MTLTexture) -> Void,
        sampler: (MTLSamplerState) -> Void
    ) {
        switch entry.resource {
        case .sampler(let s):
            guard let state = registries.samplers[s.id] else { return }
            sampler(state)
        case .texture(let t), .storageTexture(let t):
            guard let tex = registries.textures[t.id] else { return }
            texture(tex)
        case .uniformBuffer(let b, let offset), .storageBuffer(let b, let offset):
            guard let mtlBuffer = registries.buffers[b.id] else { return }
            buffer(mtlBuffer, offset)
        case .accelerationStructure:
            // Not used by the current pipeline model.
            break
        }
    }
}

#endif
