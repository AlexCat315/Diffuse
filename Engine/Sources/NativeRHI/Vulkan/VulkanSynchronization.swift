#if canImport(CVulkanHeaders)
import CVulkanHeaders

enum VulkanSynchronization {
    static let stages = VkPipelineStageFlags(VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue)

    static func aspect(_ format: TextureFormat) -> VkImageAspectFlags {
        if format == .depth24UnormStencil8 {
            return VkImageAspectFlags(VK_IMAGE_ASPECT_DEPTH_BIT.rawValue | VK_IMAGE_ASPECT_STENCIL_BIT.rawValue)
        }
        return VkImageAspectFlags(format.isDepth ? VK_IMAGE_ASPECT_DEPTH_BIT.rawValue : VK_IMAGE_ASPECT_COLOR_BIT.rawValue)
    }

    static func access(_ state: ResourceState) -> VkAccessFlags {
        var flags: VkAccessFlags = 0
        if state.contains(.constantBuffer) { flags |= VK_ACCESS_UNIFORM_READ_BIT.rawValue }
        if state.contains(.vertexBuffer) { flags |= VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT.rawValue }
        if state.contains(.indexBuffer) { flags |= VK_ACCESS_INDEX_READ_BIT.rawValue }
        if state.contains(.indirectArgument) { flags |= VK_ACCESS_INDIRECT_COMMAND_READ_BIT.rawValue }
        if state.contains(.shaderResource) { flags |= VK_ACCESS_SHADER_READ_BIT.rawValue }
        if state.contains(.unorderedAccess) { flags |= VK_ACCESS_SHADER_READ_BIT.rawValue | VK_ACCESS_SHADER_WRITE_BIT.rawValue }
        if state.contains(.renderTarget) { flags |= VK_ACCESS_COLOR_ATTACHMENT_READ_BIT.rawValue | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue }
        if state.contains(.depthWrite) { flags |= VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT.rawValue | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT.rawValue }
        if state.contains(.depthRead) { flags |= VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT.rawValue }
        if state.contains(.copySource) { flags |= VK_ACCESS_TRANSFER_READ_BIT.rawValue }
        if state.contains(.copyDestination) { flags |= VK_ACCESS_TRANSFER_WRITE_BIT.rawValue }
        if state.contains(.accelerationStructureRead) { flags |= VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR.rawValue }
        if state.contains(.accelerationStructureWrite) { flags |= VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR.rawValue }
        return flags
    }

    static func layout(_ state: ResourceState) -> VkImageLayout {
        if state.contains(.unorderedAccess) || (state.contains(.copySource) && state.contains(.copyDestination)) { return VK_IMAGE_LAYOUT_GENERAL }
        if state.contains(.renderTarget) { return VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL }
        if state.contains(.depthWrite) { return VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL }
        if state.contains(.depthRead) { return VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL }
        if state.contains(.copyDestination) { return VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL }
        if state.contains(.copySource) { return VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL }
        if state.contains(.present) { return VK_IMAGE_LAYOUT_PRESENT_SRC_KHR }
        if state.contains(.shaderResource) { return VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL }
        return VK_IMAGE_LAYOUT_GENERAL
    }

    static func layoutAccess(_ layout: VkImageLayout) -> VkAccessFlags {
        switch layout {
        case VK_IMAGE_LAYOUT_UNDEFINED: return 0
        case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL: return VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
        case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL: return VK_ACCESS_TRANSFER_READ_BIT.rawValue
        case VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: return VK_ACCESS_SHADER_READ_BIT.rawValue
        case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: return VK_ACCESS_COLOR_ATTACHMENT_READ_BIT.rawValue | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue
        case VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: return VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT.rawValue | VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT.rawValue
        case VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL: return VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT.rawValue
        default: return VK_ACCESS_MEMORY_READ_BIT.rawValue | VK_ACCESS_MEMORY_WRITE_BIT.rawValue
        }
    }
}

extension VulkanBackend {
    func memoryDependency(cmd: VkCommandBuffer, source: VkAccessFlags, destination: VkAccessFlags) {
        var barrier = VkMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER
        barrier.srcAccessMask = source; barrier.dstAccessMask = destination
        draw.cmdPipelineBarrier(cmd, VulkanSynchronization.stages, VulkanSynchronization.stages, 0, 1, &barrier, 0, nil, 0, nil)
    }

    func transitionTexture(cmd: VkCommandBuffer, handle: Texture, state: ResourceState) throws {
        guard var texture = registries.textures[handle.id] else { throw RHIError.invalidArgument("unknown texture") }
        var barrier = VkImageMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        barrier.oldLayout = texture.layout
        barrier.newLayout = VulkanSynchronization.layout(state)
        barrier.srcAccessMask = VulkanSynchronization.layoutAccess(texture.layout)
        barrier.dstAccessMask = VulkanSynchronization.access(state)
        barrier.srcQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
        barrier.dstQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
        barrier.image = texture.image
        barrier.subresourceRange = VkImageSubresourceRange(aspectMask: VulkanSynchronization.aspect(texture.format),
            baseMipLevel: 0, levelCount: texture.mipLevels, baseArrayLayer: 0, layerCount: texture.layers)
        draw.cmdPipelineBarrier(cmd, VulkanSynchronization.stages, VulkanSynchronization.stages, 0, 0, nil, 0, nil, 1, &barrier)
        texture.layout = barrier.newLayout
        registries.textures[handle.id] = texture
    }

    func encodeBarriers(cmd: VkCommandBuffer, barriers: [BarrierCommand]) throws {
        for barrier in barriers {
            if barrier.resource.kind == .texture {
                if barrier.syncAction != .release {
                    try transitionTexture(cmd: cmd, handle: Texture(id: barrier.resource.id), state: barrier.destinationState)
                }
            } else if barrier.resource.kind == .accelerationStructure {
                memoryDependency(cmd: cmd, source: barrier.syncAction == .acquire ? 0 : VulkanSynchronization.access(barrier.sourceState),
                    destination: barrier.syncAction == .release ? 0 : VulkanSynchronization.access(barrier.destinationState))
            } else if let record = registries.buffers[barrier.resource.id] {
                var memory = VkBufferMemoryBarrier()
                memory.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
                memory.srcAccessMask = barrier.syncAction == .acquire ? 0 : VulkanSynchronization.access(barrier.sourceState)
                memory.dstAccessMask = barrier.syncAction == .release ? 0 : VulkanSynchronization.access(barrier.destinationState)
                memory.srcQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
                memory.dstQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
                memory.buffer = record.buffer
                memory.size = VkDeviceSize(record.size)
                draw.cmdPipelineBarrier(cmd, VulkanSynchronization.stages, VulkanSynchronization.stages, 0, 0, nil, 1, &memory, 0, nil)
            }
        }
    }
}
#endif
