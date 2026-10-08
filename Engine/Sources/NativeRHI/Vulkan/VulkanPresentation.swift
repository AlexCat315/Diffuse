#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

struct VulkanPresentationState {
    var acquiredID: UInt32?
    var pendingAcquire = false
    // Per-image binary semaphores are reused only after that image is acquired
    // again, which proves the previous presentation consumed the semaphore.
    var ready: [UInt32: VkSemaphore] = [:]
}
#endif
