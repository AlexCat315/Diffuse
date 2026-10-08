// NativeRHI Vulkan — immediate (out-of-frame) data transfers.
//
// Device-local destinations are filled through a host-visible staging buffer and
// a one-shot transfer; host-visible destinations are mapped directly. The hot
// per-frame path uses the persistently-mapped upload ring instead.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws {
        guard let record = registries.buffers[buffer.id] else {
            throw RHIError.invalidArgument("unknown buffer")
        }
        try rhiByteRange(offset: offset, size: data.count, capacity: record.size)
        if data.isEmpty { return }
        if let base = record.allocation.mappedBase {
            base.advanced(by: Int(record.allocation.offset) + offset).copyMemory(
                from: (data as NSData).bytes, byteCount: data.count)
            return
        }
        let staging = try makeStagingBuffer(size: data.count)
        defer { destroyStagingBuffer(staging) }
        staging.pointer.copyMemory(from: (data as NSData).bytes, byteCount: data.count)

        var copy = VkBufferCopy()
        copy.srcOffset = 0
        copy.dstOffset = VkDeviceSize(offset)
        copy.size = VkDeviceSize(data.count)
        try oneShot { cmd in
            draw.cmdCopyBuffer(cmd, staging.buffer, record.buffer, 1, &copy)
        }
    }

    func uploadTextureData(_ texture: Texture, data: Data, width: Int, height: Int, bytesPerRow: Int) throws {
        guard var record = registries.textures[texture.id] else {
            throw RHIError.invalidArgument("unknown texture")
        }
        _ = try rhiTextureTransferBytes(width: width, height: height, rowBytes: bytesPerRow, format: record.format,
            textureWidth: record.width, textureHeight: record.height, capacity: data.count)
        let staging = try makeStagingBuffer(size: data.count)
        defer { destroyStagingBuffer(staging) }
        staging.pointer.copyMemory(from: (data as NSData).bytes, byteCount: data.count)

        var region = VkBufferImageCopy()
        region.bufferOffset = 0
        region.bufferRowLength = UInt32(bytesPerRow / record.format.byteCount)
        region.bufferImageHeight = 0
        region.imageSubresource = VkImageSubresourceLayers(
            aspectMask: UInt32(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)

        let oldLayout = record.layout
        let finalLayout = record.usage.contains(.sampled) ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_GENERAL
        try oneShot { cmd in
            transition(cmd: cmd, texture: record, from: oldLayout,
                       to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL)
            draw.cmdCopyBufferToImage(cmd, staging.buffer, record.image,
                                      VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
            transition(cmd: cmd, texture: record, from: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                       to: finalLayout)
        }
        record.layout = finalLayout
        registries.textures[texture.id] = record
    }

    func readTextureData(_ texture: Texture, width: Int, height: Int, bytesPerRow: Int,
                         into destination: UnsafeMutableRawBufferPointer) throws {
        guard let record = registries.textures[texture.id] else {
            throw RHIError.invalidArgument("unknown texture")
        }
        try rhiRequire(record.layout != VK_IMAGE_LAYOUT_UNDEFINED, "cannot read an uninitialized Vulkan texture")
        let byteCount = try rhiTextureTransferBytes(width: width, height: height, rowBytes: bytesPerRow, format: record.format,
            textureWidth: record.width, textureHeight: record.height, capacity: destination.count)
        let readback = try makeStagingBuffer(size: byteCount)
        defer { destroyStagingBuffer(readback) }

        var region = VkBufferImageCopy()
        region.bufferOffset = 0
        region.bufferRowLength = UInt32(bytesPerRow / record.format.byteCount)
        region.bufferImageHeight = 0
        region.imageSubresource = VkImageSubresourceLayers(
            aspectMask: UInt32(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)

        try oneShot { cmd in
            transition(cmd: cmd, texture: record, from: record.layout,
                       to: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL)
            draw.cmdCopyImageToBuffer(cmd, record.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                      readback.buffer, 1, &region)
            transition(cmd: cmd, texture: record, from: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                       to: record.layout)
        }
        destination.baseAddress?.copyMemory(from: readback.pointer, byteCount: byteCount)
    }

    // MARK: Staging buffer helpers

    private struct StagingBuffer {
        let buffer: VkBuffer
        let allocation: VulkanMemoryAllocation
        let pointer: UnsafeMutableRawPointer
    }

    private func makeStagingBuffer(size: Int) throws -> StagingBuffer {
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(max(1, size))
        // Transient uploads are also bound directly by renderer passes. Vulkan
        // requires each binding use to be declared when the buffer is created.
        info.usage = UInt32(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
            | VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue
            | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue | VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue
            | VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue)
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        guard let buffer = vkWithOutHandle({
            context.core.createBuffer(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }

        var req = VkMemoryRequirements()
        context.core.getBufferMemoryRequirements(context.device, buffer, &req)
        let allocation = try allocator.allocate(
            size: req.size, alignment: req.alignment,
            memoryTypeBits: req.memoryTypeBits,
            requiredFlags: UInt32(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue))
        _ = context.core.bindBufferMemory(context.device, buffer, allocation.memory, allocation.offset)
        guard let base = allocation.mappedBase else { throw RHIError.outOfMemory }
        return StagingBuffer(buffer: buffer, allocation: allocation,
                             pointer: base.advanced(by: Int(allocation.offset)))
    }

    private func destroyStagingBuffer(_ staging: StagingBuffer) {
        context.core.destroyBuffer(context.device, staging.buffer, nil)
        allocator.free(staging.allocation)
    }

    // MARK: One-shot command recording

    private func oneShot(_ body: (VkCommandBuffer) -> Void) throws {
        if scratchCommandPool == nil {
            var poolInfo = VkCommandPoolCreateInfo()
            poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
            poolInfo.queueFamilyIndex = context.queues.graphics.family
            poolInfo.flags = UInt32(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
            scratchCommandPool = vkWithOutHandle {
                context.resources.createCommandPool(context.device, &poolInfo, nil, $0)
            }
        }
        if scratchFence == nil {
            var fenceInfo = VkFenceCreateInfo()
            fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
            scratchFence = vkWithOutHandle {
                context.sync.createFence(context.device, &fenceInfo, nil, $0)
            }
        }
        guard let pool = scratchCommandPool, let fence = scratchFence else {
            throw RHIError.outOfMemory
        }
        try rhiRequire(draw.resetCommandPool(context.device, pool, 0) == VK_SUCCESS, "immediate command pool reset failed")
        var cmd: VkCommandBuffer = vkNull()
        var allocInfo = VkCommandBufferAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        allocInfo.commandPool = pool
        allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        allocInfo.commandBufferCount = 1
        guard context.resources.allocateCommandBuffers(context.device, &allocInfo, &cmd) == VK_SUCCESS else {
            throw RHIError.outOfMemory
        }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = UInt32(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        try rhiRequire(draw.beginCommandBuffer(cmd, &begin) == VK_SUCCESS, "immediate command begin failed")
        body(cmd)
        try rhiRequire(draw.endCommandBuffer(cmd) == VK_SUCCESS, "immediate command end failed")

        var commandBuffers: [VkCommandBuffer?] = [cmd]
        var submit = VkSubmitInfo()
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
        submit.commandBufferCount = 1

        var fenceArr: [VkFence] = [fence]
        let result = commandBuffers.withUnsafeBufferPointer { pointer in
            submit.pCommandBuffers = pointer.baseAddress
            return sync.queueSubmit(context.queues.graphics.handle, 1, &submit, fence)
        }
        guard result == VK_SUCCESS else { throw RHIError.submitFailed("Vulkan immediate transfer submit failed") }
        try rhiRequire(sync.waitForFences(context.device, 1, &fenceArr, VK_TRUE, UInt64.max) == VK_SUCCESS, "immediate fence wait failed")
        try rhiRequire(sync.resetFences(context.device, 1, &fenceArr) == VK_SUCCESS, "immediate fence reset failed")
    }

    private func transition(cmd: VkCommandBuffer, texture: VulkanTextureRecord,
                            from oldLayout: VkImageLayout,
                            to newLayout: VkImageLayout) {
        var barrier = VkImageMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        barrier.oldLayout = oldLayout
        barrier.newLayout = newLayout
        barrier.srcQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
        barrier.dstQueueFamilyIndex = UInt32(VK_QUEUE_FAMILY_IGNORED)
        barrier.image = texture.image
        barrier.subresourceRange = VkImageSubresourceRange(
            aspectMask: UInt32(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), baseMipLevel: 0,
            levelCount: texture.mipLevels, baseArrayLayer: 0, layerCount: texture.layers)
        barrier.srcAccessMask = VulkanSynchronization.layoutAccess(oldLayout)
        barrier.dstAccessMask = VulkanSynchronization.layoutAccess(newLayout)
        draw.cmdPipelineBarrier(cmd, VulkanSynchronization.stages,
                                VulkanSynchronization.stages, 0,
                                0, nil, 0, nil, 1, &barrier)
    }
}

#endif // canImport(CVulkanHeaders)
