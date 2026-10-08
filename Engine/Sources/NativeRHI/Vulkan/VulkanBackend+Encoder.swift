#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func encode(cmd: VkCommandBuffer, commands: [PlannedCommand]) throws {
        for command in commands {
            switch command {
            case .accelerationStructureBuild(let build): try encodeAccelerationBuild(cmd: cmd, handle: build.structure)
            case .renderPass(let record): try encodeRenderPass(cmd: cmd, record: record)
            case .computePass(let record): try encodeComputePass(cmd: cmd, record: record)
            case .copyPass(let record): try encodeCopyPass(cmd: cmd, record: record)
            case .barriers(let barriers): try encodeBarriers(cmd: cmd, barriers: barriers)
            }
        }
    }

    private func encodeRenderPass(cmd: VkCommandBuffer, record: RenderPassRecord) throws {
        let signature = try renderPassSignature(record.descriptor)
        let arena = VulkanScratch()
        let targets = try record.descriptor.colorTargets.map { target -> VkRenderingAttachmentInfo in
            try transitionTexture(cmd: cmd, handle: target.texture, state: .renderTarget)
            guard let texture = registries.textures[target.texture.id] else { throw RHIError.invalidArgument("unknown color target") }
            var info = VkRenderingAttachmentInfo()
            info.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
            info.imageView = texture.attachmentView ?? texture.view
            info.imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            if let handle = target.resolveTexture {
                try transitionTexture(cmd: cmd, handle: handle, state: .renderTarget)
                guard let resolve = registries.textures[handle.id] else {
                    throw RHIError.invalidArgument("unknown resolve target")
                }
                info.resolveMode = VK_RESOLVE_MODE_AVERAGE_BIT
                info.resolveImageView = resolve.attachmentView ?? resolve.view
                info.resolveImageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
            }
            info.storeOp = target.store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
            switch target.loadAction {
            case .load: info.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
            case .dontCare: info.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
            case .clear(let color):
                info.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
                info.clearValue.color = VkClearColorValue(float32: (color.x, color.y, color.z, color.w))
            }
            return info
        }
        let extent = (width: signature.extent.x, height: signature.extent.y)
        var rendering = VkRenderingInfo()
        rendering.sType = VK_STRUCTURE_TYPE_RENDERING_INFO
        rendering.renderArea.extent = VkExtent2D(width: UInt32(extent.width), height: UInt32(extent.height))
        rendering.layerCount = 1
        rendering.colorAttachmentCount = UInt32(targets.count)
        rendering.pColorAttachments = arena.store(targets)
        if let target = record.descriptor.depthTarget {
            try transitionTexture(cmd: cmd, handle: target.texture, state: .depthWrite)
            guard let texture = registries.textures[target.texture.id], texture.format.isDepth else {
                throw RHIError.invalidArgument("invalid depth target")
            }
            var depth = VkRenderingAttachmentInfo()
            depth.sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO
            depth.imageView = texture.attachmentView ?? texture.view
            depth.imageLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
            depth.storeOp = target.store ? VK_ATTACHMENT_STORE_OP_STORE : VK_ATTACHMENT_STORE_OP_DONT_CARE
            switch target.loadAction {
            case .load: depth.loadOp = VK_ATTACHMENT_LOAD_OP_LOAD
            case .dontCare: depth.loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE
            case .clear(let value):
                depth.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
                depth.clearValue.depthStencil = VkClearDepthStencilValue(depth: Float(value), stencil: 0)
            }
            rendering.pDepthAttachment = UnsafePointer(arena.make(depth))

        }
        withExtendedLifetime(arena) { context.rendering.begin(cmd, &rendering) }
        defer { context.rendering.end(cmd) }
        // NativeRHI clip space has +Y up and framebuffer coordinates have +Y down.
        // Vulkan 1.3 supports the negative-height viewport transform directly.
        var viewport = VkViewport(x: 0, y: Float(extent.height), width: Float(extent.width), height: -Float(extent.height), minDepth: 0, maxDepth: 1)
        var scissor = rendering.renderArea
        draw.cmdSetViewport(cmd, 0, 1, &viewport)
        draw.cmdSetScissor(cmd, 0, 1, &scissor)
        var layoutID: UInt32?
        var indexBound = false
        var meshBound = false
        for command in record.body {
            switch command {
            case .setMeshPipeline(let handle):
                guard let pipeline = registries.meshPipelines[handle.id] else { throw RHIError.invalidArgument("unknown mesh pipeline") }
                try validateRenderTargets(record.descriptor, pipeline: meshGraphicsDescriptor(pipeline.descriptor))
                layoutID = pipeline.descriptor.layout.id; meshBound = true
                draw.cmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)
            case .drawMeshTasks(let groups):
                guard meshBound, let dispatch = context.advanced.drawMesh else { throw RHIError.invalidArgument("mesh dispatch requires mesh pipeline") }
                dispatch(cmd, try rhiCount(groups.x), try rhiCount(groups.y), try rhiCount(groups.z))
            case .setPipeline(let handle):
                guard let pipeline = registries.graphicsPipelines[handle.id] else { throw RHIError.invalidArgument("unknown graphics pipeline") }
                try validateRenderTargets(record.descriptor, pipeline: pipeline.descriptor)
                layoutID = pipeline.descriptor.layout.id; meshBound = false
                draw.cmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline.pipeline)
            case .setBindingSet(let slot, let handle):
                try bindSet(cmd: cmd, bindPoint: VK_PIPELINE_BIND_POINT_GRAPHICS, layoutID: layoutID, slot: slot, handle: handle)
            case .pushConstant(let stage, let slot, let data):
                try pushConstants(cmd: cmd, layoutID: layoutID, stage: stage, slot: slot, data: data)
            case .setVertexBuffer(let slot, let handle, let offset):
                guard let buffer = registries.buffers[handle.id] else { throw RHIError.invalidArgument("unknown vertex buffer") }
                try rhiByteRange(offset: offset, size: 0, capacity: buffer.size)
                var native = buffer.buffer
                var byteOffset = VkDeviceSize(offset)
                draw.cmdBindVertexBuffers(cmd, slot, 1, &native, &byteOffset)
            case .setIndexBuffer(let handle, let offset, let type):
                guard let buffer = registries.buffers[handle.id] else { throw RHIError.invalidArgument("unknown index buffer") }
                try rhiByteRange(offset: offset, size: 0, capacity: buffer.size)
                draw.cmdBindIndexBuffer(cmd, buffer.buffer, VkDeviceSize(offset), VulkanFormats.vkIndexType(type))
                indexBound = true
            case .setViewport(let value):
                viewport = VkViewport(x: Float(value.x), y: Float(value.y + value.height), width: Float(value.width), height: -Float(value.height),
                                      minDepth: Float(value.minDepth), maxDepth: Float(value.maxDepth))
                draw.cmdSetViewport(cmd, 0, 1, &viewport)
            case .setScissor(let value):
                scissor = VkRect2D(offset: VkOffset2D(x: Int32(value.x), y: Int32(value.y)),
                                  extent: VkExtent2D(width: try rhiCount(value.width), height: try rhiCount(value.height)))
                draw.cmdSetScissor(cmd, 0, 1, &scissor)
            case .draw(let vertices, let instances, let firstVertex, let firstInstance):
                try rhiRequire(layoutID != nil && !meshBound, "draw requires a graphics pipeline")
                draw.cmdDraw(cmd, try rhiCount(vertices), try rhiCount(instances), try rhiCount(firstVertex), try rhiCount(firstInstance))
            case .drawIndexed(let arguments):
                try rhiRequire(indexBound && layoutID != nil, "indexed draw requires a pipeline and index buffer")
                draw.cmdDrawIndexed(cmd, try rhiCount(arguments.indexCount), try rhiCount(arguments.instanceCount),
                    try rhiCount(arguments.firstIndex), Int32(arguments.vertexOffset), try rhiCount(arguments.firstInstance))
            case .drawIndirect(let handle, let offset, let count):
                guard let buffer = registries.buffers[handle.id], layoutID != nil else { throw RHIError.invalidArgument("invalid indirect draw") }
                try rhiByteRange(offset: offset, size: Int(try rhiCount(count)) * 16, capacity: buffer.size)
                try rhiRequire(!meshBound && offset % 4 == 0, "invalid indirect draw alignment or pipeline")
                for index in 0..<count { context.auxiliary.drawIndirect(cmd, buffer.buffer, VkDeviceSize(offset + index * 16), 1, 16) }
            }
        }
    }

    private func encodeComputePass(cmd: VkCommandBuffer, record: ComputePassRecord) throws {
        var layoutID: UInt32?
        for command in record.body {
            switch command {
            case .setPipeline(let handle):
                guard let pipeline = registries.computePipelines[handle.id] else { throw RHIError.invalidArgument("unknown compute pipeline") }
                layoutID = pipeline.descriptor.layout.id
                draw.cmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline.pipeline)
            case .setBindingSet(let slot, let handle):
                try bindSet(cmd: cmd, bindPoint: VK_PIPELINE_BIND_POINT_COMPUTE, layoutID: layoutID, slot: slot, handle: handle)
            case .pushConstant(let stage, let slot, let data):
                try pushConstants(cmd: cmd, layoutID: layoutID, stage: stage, slot: slot, data: data)
            case .dispatch(let x, let y, let z):
                try rhiRequire(layoutID != nil && x > 0 && y > 0 && z > 0, "dispatch requires a pipeline and positive groups")
                let limit = context.limits.maxComputeWorkGroupCount
                try rhiRequire(x <= Int(limit.0) && y <= Int(limit.1) && z <= Int(limit.2), "dispatch exceeds Vulkan workgroup limits")
                draw.cmdDispatch(cmd, try rhiCount(x), try rhiCount(y), try rhiCount(z))
                memoryDependency(cmd: cmd, source: VK_ACCESS_SHADER_WRITE_BIT.rawValue, destination: VK_ACCESS_SHADER_READ_BIT.rawValue | VK_ACCESS_SHADER_WRITE_BIT.rawValue)
            case .dispatchIndirect(let handle, let offset):
                guard let buffer = registries.buffers[handle.id], layoutID != nil else { throw RHIError.invalidArgument("invalid indirect dispatch") }
                try rhiByteRange(offset: offset, size: 12, capacity: buffer.size)
                try rhiRequire(offset % 4 == 0, "indirect dispatch offset must be aligned")
                context.auxiliary.dispatchIndirect(cmd, buffer.buffer, VkDeviceSize(offset))
                memoryDependency(cmd: cmd, source: VK_ACCESS_SHADER_WRITE_BIT.rawValue, destination: VK_ACCESS_SHADER_READ_BIT.rawValue | VK_ACCESS_SHADER_WRITE_BIT.rawValue)
            }
        }
    }

    private func bindSet(cmd: VkCommandBuffer, bindPoint: VkPipelineBindPoint, layoutID: UInt32?, slot: UInt32, handle: BindingSet) throws {
        guard let layoutID, let layout = registries.pipelineLayouts[layoutID], let set = registries.bindingSets[handle.id],
              Int(slot) < layout.descriptor.setLayouts.count, layout.descriptor.setLayouts[Int(slot)].id == set.layoutID else {
            throw RHIError.layoutMismatch("binding set does not match the active pipeline layout")
        }
        var native = set.descriptorSet
        draw.cmdBindDescriptorSets(cmd, bindPoint, layout.native, slot, 1, &native, 0, nil)
    }

    private func pushConstants(cmd: VkCommandBuffer, layoutID: UInt32?, stage: ShaderStage, slot: UInt32, data: Data) throws {
        guard let layoutID, let layout = registries.pipelineLayouts[layoutID],
              let range = layout.pushRanges.first(where: { $0.declaration.stage == stage && $0.declaration.slot == slot }),
              data.count <= range.declaration.byteCount, data.count % 4 == 0 else {
            throw RHIError.layoutMismatch("push constants do not match the active pipeline layout")
        }
        data.withUnsafeBytes {
            draw.cmdPushConstants(cmd, layout.native, VulkanLayoutFormats.stageFlags(stage), range.offset, UInt32(data.count), $0.baseAddress)
        }
    }

    private func validateRenderTargets(_ pass: RenderPassDescriptor, pipeline: GraphicsPipelineDescriptor) throws {
        try renderPassSignature(pass).validate(colors: pipeline.colorAttachments.map { VulkanFormats.vkFormat($0.format) },
            depth: pipeline.depthFormat.map(VulkanFormats.vkFormat), samples: pipeline.sampleCount)
    }

    private func renderPassSignature(_ pass: RenderPassDescriptor) throws -> RenderPassSignature<VkFormat> {
        try rhiRenderPassSignature(pass) { handle in
            guard let texture = registries.textures[handle.id] else { throw RHIError.invalidArgument("unknown render attachment") }
            var info = RenderTextureInfo(extent: SIMD2(texture.width, texture.height), sampleCount: texture.sampleCount,
                format: VulkanFormats.vkFormat(texture.format), usage: texture.usage,
                singleLayer2D: texture.dimension == .texture2D && texture.layers == 1, isDepth: texture.format.isDepth)
            info.supportsColorResolve = texture.format != .r32Uint
            return info
        }
    }

    private func encodeCopyPass(cmd: VkCommandBuffer, record: CopyPassRecord) throws {
        for command in record.body {
            switch command {
            case .copyTexture(let source, let destination, let width, let height):
                guard let src = registries.textures[source.id], let dst = registries.textures[destination.id] else {
                    throw RHIError.invalidArgument("unknown texture copy resource")
                }
                try rhiRequire(source != destination && src.dimension == .texture2D && dst.dimension == .texture2D
                    && src.sampleCount == 1 && dst.sampleCount == 1
                    && src.layers == 1 && dst.layers == 1 && src.usage.contains(.transferSource)
                    && dst.usage.contains(.transferDestination), "texture copy requires distinct transferable 2D textures")
                try rhiColorTextureCopyExtent(width: width, height: height,
                    source: (src.width,src.height,src.format), destination: (dst.width,dst.height,dst.format))
                try transitionTexture(cmd: cmd, handle: source, state: .copySource)
                try transitionTexture(cmd: cmd, handle: destination, state: .copyDestination)
                var region = VkImageCopy()
                region.srcSubresource = VkImageSubresourceLayers(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue,
                    mipLevel: 0,baseArrayLayer: 0,layerCount: 1)
                region.dstSubresource = region.srcSubresource
                region.extent = VkExtent3D(width: UInt32(width),height: UInt32(height),depth: 1)
                context.auxiliary.copyImage(cmd,src.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                    dst.image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&region)
            case .copyBuffer(let source, let sourceOffset, let destination, let destinationOffset, let size):
                guard let src = registries.buffers[source.id], let dst = registries.buffers[destination.id] else {
                    throw RHIError.invalidArgument("unknown copy buffer")
                }
                try rhiByteRange(offset: sourceOffset, size: size, capacity: src.size)
                try rhiByteRange(offset: destinationOffset, size: size, capacity: dst.size)
                var region = VkBufferCopy(srcOffset: VkDeviceSize(sourceOffset), dstOffset: VkDeviceSize(destinationOffset), size: VkDeviceSize(size))
                draw.cmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &region)
            case .copyBufferToTexture(let buffer, let offset, let rowBytes, let texture, let width, let height):
                try textureCopy(cmd: cmd, buffer: buffer, offset: offset, rowBytes: rowBytes, texture: texture, width: width, height: height, upload: true)
            case .copyTextureToBuffer(let texture, let width, let height, let buffer, let offset, let rowBytes):
                try textureCopy(cmd: cmd, buffer: buffer, offset: offset, rowBytes: rowBytes, texture: texture, width: width, height: height, upload: false)
            }
            memoryDependency(cmd: cmd, source: VK_ACCESS_TRANSFER_WRITE_BIT.rawValue, destination: VK_ACCESS_TRANSFER_READ_BIT.rawValue | VK_ACCESS_TRANSFER_WRITE_BIT.rawValue)
        }
    }

    private func textureCopy(cmd: VkCommandBuffer, buffer: Buffer, offset: Int, rowBytes: Int, texture: Texture,
                             width: Int, height: Int, upload: Bool) throws {
        guard let image = registries.textures[texture.id], let native = registries.buffers[buffer.id] else {
            throw RHIError.invalidArgument("unknown texture copy resource")
        }
        try rhiRequire(image.sampleCount == 1, "buffer texture copies require a single-sample texture")
        let bytes = try rhiTextureTransferBytes(width: width, height: height, rowBytes: rowBytes, format: image.format,
            textureWidth: image.width, textureHeight: image.height, capacity: native.size - min(max(0, offset), native.size))
        try rhiByteRange(offset: offset, size: bytes, capacity: native.size)
        try transitionTexture(cmd: cmd, handle: texture, state: upload ? .copyDestination : .copySource)
        var region = VkBufferImageCopy()
        region.bufferOffset = VkDeviceSize(offset)
        region.bufferRowLength = UInt32(rowBytes / image.format.byteCount)
        region.imageSubresource = VkImageSubresourceLayers(aspectMask: VulkanSynchronization.aspect(image.format),
            mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        if upload {
            draw.cmdCopyBufferToImage(cmd, native.buffer, image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
        } else {
            draw.cmdCopyImageToBuffer(cmd, image.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, native.buffer, 1, &region)
        }
    }
}
#endif
