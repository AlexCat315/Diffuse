// NativeRHI Vulkan — encodes a planned command stream into a Vulkan command
// buffer. Render passes build a temporary framebuffer from their attachment
// views; barriers lower to vkCmdPipelineBarrier.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func encode(cmd: VkCommandBuffer, commands: [PlannedCommand]) throws {
        for command in commands {
            switch command {
            case .accelerationStructureBuild:
                throw RHIError.unsupportedFeature("Vulkan acceleration builds are not implemented")
            case .renderPass(let record): try encodeRenderPass(cmd: cmd, record: record)
            case .computePass(let record): encodeComputePass(cmd: cmd, record: record)
            case .copyPass(let record): encodeCopyPass(cmd: cmd, record: record)
            case .barriers(let barriers): encodeBarriers(cmd: cmd, barriers: barriers)
            }
        }
    }

    private func encodeRenderPass(cmd: VkCommandBuffer, record: RenderPassRecord) throws {
        let descriptor = record.descriptor
        guard !descriptor.colorTargets.isEmpty else { return }
        guard let firstRecord = registries.textures[descriptor.colorTargets[0].texture.id] else { return }
        let width = firstRecord.width
        let height = firstRecord.height

        // Resolve attachment views and clear values.
        var attachments: [VkImageView?] = []
        var clearValues: [VkClearValue] = []
        for target in descriptor.colorTargets {
            guard let record = registries.textures[target.texture.id] else { continue }
            attachments.append(record.view)
            var value = VkClearValue()
            switch target.loadAction {
            case .clear(let color):
                value.color = VkClearColorValue(float32: (color.x, color.y, color.z, color.w))
            default:
                value.color = VkClearColorValue(float32: (0, 0, 0, 1))
            }
            clearValues.append(value)
        }
        if let depth = descriptor.depthTarget, let record = registries.textures[depth.texture.id] {
            attachments.append(record.view)
            var value = VkClearValue()
            switch depth.loadAction {
            case .clear(let d): value.depthStencil = VkClearDepthStencilValue(depth: Float(d), stencil: 0)
            default: value.depthStencil = VkClearDepthStencilValue(depth: 1, stencil: 0)
            }
            clearValues.append(value)
        }

        guard let pipelineRecord = registries.graphicsPipelines.values.first,
              attachments.count == clearValues.count else { return }
        let renderPass = pipelineRecord.renderPass

        var fbInfo = VkFramebufferCreateInfo()
        fbInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        fbInfo.renderPass = renderPass
        fbInfo.attachmentCount = UInt32(attachments.count)
        attachments.withUnsafeBufferPointer { fbInfo.pAttachments = $0.baseAddress }
        fbInfo.width = UInt32(width)
        fbInfo.height = UInt32(height)
        fbInfo.layers = 1
        guard let fb = vkWithOutHandle({
            context.resources.createFramebuffer(context.device, &fbInfo, nil, $0)
        }) else { return }
        defer { context.resources.destroyFramebuffer(context.device, fb, nil) }

        var begin = VkRenderPassBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        begin.renderPass = renderPass
        begin.framebuffer = fb
        begin.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0),
                                    extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
        begin.clearValueCount = UInt32(clearValues.count)
        clearValues.withUnsafeBufferPointer { begin.pClearValues = $0.baseAddress }
        draw.cmdBeginRenderPass(cmd, &begin, VK_SUBPASS_CONTENTS_INLINE)

        for item in record.body {
            switch item {
            case .setMeshPipeline, .drawMeshTasks:
                throw RHIError.unsupportedFeature("Vulkan mesh commands are not implemented")
            case .setPipeline(let pipeline):
                guard let record = registries.graphicsPipelines[pipeline.id] else { break }
                draw.cmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, record.pipeline)
            case .setBindingSet:
                break
            case .setVertexBuffer(let slot, let buffer, let offset):
                guard let record = registries.buffers[buffer.id] else { break }
                var buf: [VkBuffer] = [record.buffer]
                var off: [VkDeviceSize] = [VkDeviceSize(offset)]
                draw.cmdBindVertexBuffers(cmd, slot, 1, &buf, &off)
            case .setIndexBuffer(let buffer, let offset, let type):
                guard let record = registries.buffers[buffer.id] else { break }
                draw.cmdBindIndexBuffer(cmd, record.buffer, VkDeviceSize(offset),
                                        VulkanFormats.vkIndexType(type))
            case .pushConstant:
                break
            case .setViewport(let viewport):
                var vp = VkViewport(x: Float(viewport.x), y: Float(viewport.y),
                                    width: Float(viewport.width), height: Float(viewport.height),
                                    minDepth: Float(viewport.minDepth), maxDepth: Float(viewport.maxDepth))
                draw.cmdSetViewport(cmd, 0, 1, &vp)
            case .setScissor(let scissor):
                var rect = VkRect2D(offset: VkOffset2D(x: Int32(scissor.x), y: Int32(scissor.y)),
                                    extent: VkExtent2D(width: UInt32(scissor.width), height: UInt32(scissor.height)))
                draw.cmdSetScissor(cmd, 0, 1, &rect)
            case .draw(let vertexCount, let instanceCount, let firstVertex, let firstInstance):
                draw.cmdDraw(cmd, UInt32(vertexCount), UInt32(instanceCount),
                             UInt32(firstVertex), UInt32(firstInstance))
            case .drawIndexed(let args):
                draw.cmdDrawIndexed(cmd, UInt32(args.indexCount), UInt32(args.instanceCount),
                                     UInt32(args.firstIndex), Int32(args.vertexOffset),
                                     UInt32(args.firstInstance))
            case .drawIndirect:
                break
            }
        }
        draw.cmdEndRenderPass(cmd)
    }

    private func encodeComputePass(cmd: VkCommandBuffer, record: ComputePassRecord) {
        for item in record.body {
            switch item {
            case .setPipeline(let pipeline):
                guard let record = registries.computePipelines[pipeline.id] else { break }
                draw.cmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, record.pipeline)
            case .setBindingSet:
                break
            case .pushConstant:
                break
            case .dispatch(let x, let y, let z):
                draw.cmdDispatch(cmd, UInt32(x), UInt32(y), UInt32(z))
            case .dispatchIndirect:
                break
            }
        }
    }

    private func encodeCopyPass(cmd: VkCommandBuffer, record: CopyPassRecord) {
        for item in record.body {
            switch item {
            case .copyBuffer(let src, let srcOffset, let dst, let dstOffset, let size):
                guard let srcRecord = registries.buffers[src.id],
                      let dstRecord = registries.buffers[dst.id] else { break }
                var region = VkBufferCopy(srcOffset: VkDeviceSize(srcOffset),
                                          dstOffset: VkDeviceSize(dstOffset),
                                          size: VkDeviceSize(size))
                draw.cmdCopyBuffer(cmd, srcRecord.buffer, dstRecord.buffer, 1, &region)
            case .copyBufferToTexture:
                break
            case .copyTextureToBuffer:
                break
            }
        }
    }

    private func encodeBarriers(cmd: VkCommandBuffer, barriers: [BarrierCommand]) {
        for barrier in barriers {
            guard barrier.resource.kind == .buffer,
                  let record = registries.buffers[barrier.resource.id] else { continue }
            var memory = VkBufferMemoryBarrier()
            memory.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
            memory.srcAccessMask = VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue)
            memory.dstAccessMask = VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue)
            memory.srcQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
            memory.dstQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
            memory.buffer = record.buffer
            memory.offset = 0
            memory.size = VkDeviceSize(record.size)
            let stages = VkPipelineStageFlags(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue)
            draw.cmdPipelineBarrier(cmd, stages, stages, 0, 0, nil, 1, &memory, 0, nil)
        }
    }
}

#endif // canImport(CVulkanHeaders)
