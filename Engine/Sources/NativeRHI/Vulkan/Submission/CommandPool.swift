#if (os(Windows) || os(Linux) || os(Android)) && canImport(CVulkanHeaders)
import CVulkanHeaders

/// A frame slot reuses its peak number of command buffers. Resetting a Vulkan
/// pool resets buffer state; it does not free the allocated buffer objects.
final class VulkanCommandPool {
    let handle: VkCommandPool
    private var buffers: [VkCommandBuffer] = []
    private var used = 0

    init(handle: VkCommandPool) { self.handle = handle }

    func rewind() { used = 0 }

    func commandBuffer(context: VulkanContext) throws -> VkCommandBuffer {
        if used == buffers.count {
            var command: VkCommandBuffer = vkNull()
            var info = VkCommandBufferAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
            info.commandPool = handle
            info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
            info.commandBufferCount = 1
            guard context.resources.allocateCommandBuffers(context.device, &info, &command) == VK_SUCCESS else {
                throw RHIError.submitFailed("vkAllocateCommandBuffers failed")
            }
            buffers.append(command)
        }
        defer { used += 1 }
        return buffers[used]
    }
}
#endif
