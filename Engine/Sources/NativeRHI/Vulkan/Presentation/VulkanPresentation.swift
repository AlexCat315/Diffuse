#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

struct VulkanPresentationState {
    var acquiredID: UInt32?
    var pendingAcquire = false
    // Per-image binary semaphores are reused only after that image is acquired
    // again, which proves the previous presentation consumed the semaphore.
    var ready: [UInt32: VkSemaphore] = [:]
}

/// Each native window owns its acquire semaphores and presentation pool.
final class VulkanWindowSwapchain {
    let chain: VulkanSwapchain
    var generation: UInt64
    var presentation = VulkanPresentationState()
    var acquireSemaphores: [Int: VkSemaphore] = [:]
    var needsRecreate = false

    init(chain: VulkanSwapchain, generation: UInt64) {
        self.chain = chain; self.generation = generation
    }
}
#endif
