// NativeRHI Vulkan — runtime function-pointer table and C-interop helpers.
//
// The native Vulkan loader is supplied by the Windows/Linux SDK and
// linked at build time. We bind its `vkGetInstanceProcAddr` from the linked
// image and then build a table of the instance/device entry points we use,
// grouped so each struct stays well under the maintainability limit. Handles
// imported from the headers are `OpaquePointer` (non-optional); a null handle
// is made by bit-casting a nil optional, and C out-handles are written through
// a layout-compatible rebound helper.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

// MARK: - Handle / pointer interop helpers

/// A null Vulkan handle of the requested (OpaquePointer-backed) handle type.
func vkNull<T>() -> T {
    unsafeBitCast(UInt(0), to: T.self)
}

/// Writes a C out-handle (`T*` where `T` is a non-optional OpaquePointer) into
/// an optional Swift storage. `Optional<OpaquePointer>` has the same in-memory
/// representation as a bare pointer, so the rebound pointer is ABI-compatible.
func vkWithOutHandle<T>(_ body: (UnsafeMutablePointer<T>) -> Void) -> T? {
    var storage: T? = nil
    withUnsafeMutablePointer(to: &storage) { raw in
        raw.withMemoryRebound(to: T.self, capacity: 1) { typed in
            body(typed)
        }
    }
    return storage
}

/// Reads a NUL-terminated C string stored in a fixed-width `Int8` buffer (e.g.
/// `VkPhysicalDeviceProperties.deviceName`).
func vkCString(_ buffer: UnsafePointer<CChar>) -> String {
    String(cString: buffer)
}

/// A C-string pointer for a compile-time constant Vulkan extension name.
func vkExtName(_ name: StaticString) -> UnsafePointer<CChar> {
    UnsafePointer<CChar>(OpaquePointer(name.utf8Start))
}

// MARK: - Function-pointer signatures (matched to the Vulkan C ABI)

typealias VkVoidFn = @convention(c) () -> Void

typealias PFN_vkCreateInstance = @convention(c) (
    UnsafePointer<VkInstanceCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?,
    UnsafeMutablePointer<VkInstance>?
) -> VkResult

typealias PFN_vkDestroyInstance = @convention(c) (
    VkInstance, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkEnumeratePhysicalDevices = @convention(c) (
    VkInstance, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<VkPhysicalDevice>?
) -> VkResult

typealias PFN_vkGetPhysicalDeviceProperties = @convention(c) (
    VkPhysicalDevice, UnsafeMutablePointer<VkPhysicalDeviceProperties>
) -> Void

typealias PFN_vkGetPhysicalDeviceProperties2 = @convention(c) (
    VkPhysicalDevice, UnsafeMutablePointer<VkPhysicalDeviceProperties2>
) -> Void

typealias PFN_vkGetPhysicalDeviceFeatures2 = @convention(c) (
    VkPhysicalDevice, UnsafeMutablePointer<VkPhysicalDeviceFeatures2>
) -> Void

typealias PFN_vkEnumerateDeviceExtensionProperties = @convention(c) (
    VkPhysicalDevice, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<VkExtensionProperties>?
) -> VkResult

typealias PFN_vkGetPhysicalDeviceQueueFamilyProperties = @convention(c) (
    VkPhysicalDevice, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<VkQueueFamilyProperties>?
) -> Void

typealias PFN_vkGetPhysicalDeviceMemoryProperties = @convention(c) (
    VkPhysicalDevice, UnsafeMutablePointer<VkPhysicalDeviceMemoryProperties>
) -> Void

typealias PFN_vkCreateDevice = @convention(c) (
    VkPhysicalDevice, UnsafePointer<VkDeviceCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkDevice>?
) -> VkResult

typealias PFN_vkDestroyDevice = @convention(c) (
    VkDevice, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkGetDeviceQueue = @convention(c) (
    VkDevice, UInt32, UInt32, UnsafeMutablePointer<VkQueue>?
) -> Void

typealias PFN_vkDeviceWaitIdle = @convention(c) (VkDevice) -> VkResult

typealias PFN_vkDestroySurfaceKHR = @convention(c) (
    VkInstance, VkSurfaceKHR, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = @convention(c) (
    VkPhysicalDevice, VkSurfaceKHR, UnsafeMutablePointer<VkSurfaceCapabilitiesKHR>
) -> VkResult

typealias PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = @convention(c) (
    VkPhysicalDevice, VkSurfaceKHR, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<VkSurfaceFormatKHR>?
) -> VkResult

typealias PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = @convention(c) (
    VkPhysicalDevice, VkSurfaceKHR, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<VkPresentModeKHR>?
) -> VkResult



// MARK: Device-level group A — memory, buffers, images, views, shaders, pools

typealias PFN_vkCreateBuffer = @convention(c) (
    VkDevice, UnsafePointer<VkBufferCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkBuffer>?
) -> VkResult

typealias PFN_vkDestroyBuffer = @convention(c) (
    VkDevice, VkBuffer, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkGetBufferMemoryRequirements = @convention(c) (
    VkDevice, VkBuffer, UnsafeMutablePointer<VkMemoryRequirements>
) -> Void

typealias PFN_vkBindBufferMemory = @convention(c) (
    VkDevice, VkBuffer, VkDeviceMemory, VkDeviceSize
) -> VkResult

typealias PFN_vkCreateImage = @convention(c) (
    VkDevice, UnsafePointer<VkImageCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkImage>?
) -> VkResult

typealias PFN_vkDestroyImage = @convention(c) (
    VkDevice, VkImage, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkGetImageMemoryRequirements = @convention(c) (
    VkDevice, VkImage, UnsafeMutablePointer<VkMemoryRequirements>
) -> Void

typealias PFN_vkBindImageMemory = @convention(c) (
    VkDevice, VkImage, VkDeviceMemory, VkDeviceSize
) -> VkResult

typealias PFN_vkAllocateMemory = @convention(c) (
    VkDevice, UnsafePointer<VkMemoryAllocateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkDeviceMemory>?
) -> VkResult

typealias PFN_vkFreeMemory = @convention(c) (
    VkDevice, VkDeviceMemory, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkMapMemory = @convention(c) (
    VkDevice, VkDeviceMemory, VkDeviceSize, VkDeviceSize, VkMemoryMapFlags,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> VkResult

typealias PFN_vkUnmapMemory = @convention(c) (
    VkDevice, VkDeviceMemory
) -> Void

typealias PFN_vkCreateImageView = @convention(c) (
    VkDevice, UnsafePointer<VkImageViewCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkImageView>?
) -> VkResult

typealias PFN_vkDestroyImageView = @convention(c) (
    VkDevice, VkImageView, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateShaderModule = @convention(c) (
    VkDevice, UnsafePointer<VkShaderModuleCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkShaderModule>?
) -> VkResult

typealias PFN_vkDestroyShaderModule = @convention(c) (
    VkDevice, VkShaderModule, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateDescriptorPool = @convention(c) (
    VkDevice, UnsafePointer<VkDescriptorPoolCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkDescriptorPool>?
) -> VkResult

typealias PFN_vkDestroyDescriptorPool = @convention(c) (
    VkDevice, VkDescriptorPool, UnsafePointer<VkAllocationCallbacks>?
) -> Void

// MARK: Device-level group B — pipelines, descriptor sets, samplers, passes

typealias PFN_vkCreateGraphicsPipelines = @convention(c) (
    VkDevice, VkPipelineCache, UInt32, UnsafePointer<VkGraphicsPipelineCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkPipeline>?
) -> VkResult

typealias PFN_vkCreateComputePipelines = @convention(c) (
    VkDevice, VkPipelineCache, UInt32, UnsafePointer<VkComputePipelineCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkPipeline>?
) -> VkResult

typealias PFN_vkDestroyPipeline = @convention(c) (
    VkDevice, VkPipeline, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreatePipelineLayout = @convention(c) (
    VkDevice, UnsafePointer<VkPipelineLayoutCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkPipelineLayout>?
) -> VkResult

typealias PFN_vkDestroyPipelineLayout = @convention(c) (
    VkDevice, VkPipelineLayout, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateDescriptorSetLayout = @convention(c) (
    VkDevice, UnsafePointer<VkDescriptorSetLayoutCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkDescriptorSetLayout>?
) -> VkResult

typealias PFN_vkDestroyDescriptorSetLayout = @convention(c) (
    VkDevice, VkDescriptorSetLayout, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkAllocateDescriptorSets = @convention(c) (
    VkDevice, UnsafePointer<VkDescriptorSetAllocateInfo>?,
    UnsafeMutablePointer<VkDescriptorSet>?
) -> VkResult

typealias PFN_vkUpdateDescriptorSets = @convention(c) (
    VkDevice, UInt32, UnsafePointer<VkWriteDescriptorSet>?, UInt32,
    UnsafePointer<VkCopyDescriptorSet>?
) -> Void

typealias PFN_vkCreateSampler = @convention(c) (
    VkDevice, UnsafePointer<VkSamplerCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkSampler>?
) -> VkResult

typealias PFN_vkDestroySampler = @convention(c) (
    VkDevice, VkSampler, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateRenderPass = @convention(c) (
    VkDevice, UnsafePointer<VkRenderPassCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkRenderPass>?
) -> VkResult

typealias PFN_vkDestroyRenderPass = @convention(c) (
    VkDevice, VkRenderPass, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateFramebuffer = @convention(c) (
    VkDevice, UnsafePointer<VkFramebufferCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkFramebuffer>?
) -> VkResult

typealias PFN_vkDestroyFramebuffer = @convention(c) (
    VkDevice, VkFramebuffer, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkCreateCommandPool = @convention(c) (
    VkDevice, UnsafePointer<VkCommandPoolCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkCommandPool>?
) -> VkResult

typealias PFN_vkAllocateCommandBuffers = @convention(c) (
    VkDevice, UnsafePointer<VkCommandBufferAllocateInfo>?,
    UnsafeMutablePointer<VkCommandBuffer>?
) -> VkResult

// MARK: Device-level group C — command buffer recording

typealias PFN_vkFreeCommandBuffers = @convention(c) (
    VkDevice, VkCommandPool, UInt32, UnsafePointer<VkCommandBuffer>?
) -> Void

typealias PFN_vkResetCommandPool = @convention(c) (
    VkDevice, VkCommandPool, VkCommandPoolResetFlags
) -> VkResult

typealias PFN_vkBeginCommandBuffer = @convention(c) (
    VkCommandBuffer, UnsafePointer<VkCommandBufferBeginInfo>?
) -> VkResult

typealias PFN_vkEndCommandBuffer = @convention(c) (VkCommandBuffer) -> VkResult

typealias PFN_vkCmdBeginRenderPass = @convention(c) (
    VkCommandBuffer, UnsafePointer<VkRenderPassBeginInfo>?, VkSubpassContents
) -> Void

typealias PFN_vkCmdEndRenderPass = @convention(c) (VkCommandBuffer) -> Void

typealias PFN_vkCmdBindPipeline = @convention(c) (
    VkCommandBuffer, VkPipelineBindPoint, VkPipeline
) -> Void

typealias PFN_vkCmdSetViewport = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UnsafePointer<VkViewport>?
) -> Void

typealias PFN_vkCmdSetScissor = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UnsafePointer<VkRect2D>?
) -> Void

typealias PFN_vkCmdBindVertexBuffers = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UnsafePointer<VkBuffer>?,
    UnsafePointer<VkDeviceSize>?
) -> Void

typealias PFN_vkCmdBindIndexBuffer = @convention(c) (
    VkCommandBuffer, VkBuffer, VkDeviceSize, VkIndexType
) -> Void

typealias PFN_vkCmdDraw = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UInt32, UInt32
) -> Void

typealias PFN_vkCmdDrawIndexed = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UInt32, Int32, UInt32
) -> Void

typealias PFN_vkCmdBindDescriptorSets = @convention(c) (
    VkCommandBuffer, VkPipelineBindPoint, VkPipelineLayout, UInt32, UInt32,
    UnsafePointer<VkDescriptorSet>?, UInt32, UnsafePointer<UInt32>?
) -> Void

typealias PFN_vkCmdPushConstants = @convention(c) (
    VkCommandBuffer, VkPipelineLayout, VkShaderStageFlags, UInt32, UInt32,
    UnsafeRawPointer?
) -> Void

typealias PFN_vkCmdDispatch = @convention(c) (
    VkCommandBuffer, UInt32, UInt32, UInt32
) -> Void

typealias PFN_vkCmdCopyBuffer = @convention(c) (
    VkCommandBuffer, VkBuffer, VkBuffer, UInt32, UnsafePointer<VkBufferCopy>?
) -> Void

typealias PFN_vkCmdCopyBufferToImage = @convention(c) (
    VkCommandBuffer, VkBuffer, VkImage, VkImageLayout, UInt32,
    UnsafePointer<VkBufferImageCopy>?
) -> Void

typealias PFN_vkCmdCopyImageToBuffer = @convention(c) (
    VkCommandBuffer, VkImage, VkImageLayout, VkBuffer, UInt32,
    UnsafePointer<VkBufferImageCopy>?
) -> Void

typealias PFN_vkCmdPipelineBarrier = @convention(c) (
    VkCommandBuffer, VkPipelineStageFlags, VkPipelineStageFlags, VkDependencyFlags,
    UInt32, UnsafePointer<VkMemoryBarrier>?, UInt32, UnsafePointer<VkBufferMemoryBarrier>?,
    UInt32, UnsafePointer<VkImageMemoryBarrier>?
) -> Void

// MARK: Device-level group D — synchronization, submission, swapchain

typealias PFN_vkCreateFence = @convention(c) (
    VkDevice, UnsafePointer<VkFenceCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkFence>?
) -> VkResult

typealias PFN_vkDestroyFence = @convention(c) (
    VkDevice, VkFence, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkWaitForFences = @convention(c) (
    VkDevice, UInt32, UnsafePointer<VkFence>?, VkBool32, UInt64
) -> VkResult

typealias PFN_vkResetFences = @convention(c) (
    VkDevice, UInt32, UnsafePointer<VkFence>?
) -> VkResult

typealias PFN_vkCreateSemaphore = @convention(c) (
    VkDevice, UnsafePointer<VkSemaphoreCreateInfo>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkSemaphore>?
) -> VkResult

typealias PFN_vkDestroySemaphore = @convention(c) (
    VkDevice, VkSemaphore, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkQueueSubmit = @convention(c) (
    VkQueue, UInt32, UnsafePointer<VkSubmitInfo>?, VkFence
) -> VkResult

typealias PFN_vkQueuePresentKHR = @convention(c) (
    VkQueue, UnsafePointer<VkPresentInfoKHR>?
) -> VkResult

typealias PFN_vkQueueWaitIdle = @convention(c) (VkQueue) -> VkResult

typealias PFN_vkCreateSwapchainKHR = @convention(c) (
    VkDevice, UnsafePointer<VkSwapchainCreateInfoKHR>?,
    UnsafePointer<VkAllocationCallbacks>?, UnsafeMutablePointer<VkSwapchainKHR>?
) -> VkResult

typealias PFN_vkDestroySwapchainKHR = @convention(c) (
    VkDevice, VkSwapchainKHR, UnsafePointer<VkAllocationCallbacks>?
) -> Void

typealias PFN_vkGetSwapchainImagesKHR = @convention(c) (
    VkDevice, VkSwapchainKHR, UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<VkImage>?
) -> VkResult

typealias PFN_vkAcquireNextImageKHR = @convention(c) (
    VkDevice, VkSwapchainKHR, UInt64, VkSemaphore, VkFence,
    UnsafeMutablePointer<UInt32>?
) -> VkResult

// MARK: - Grouped command tables

/// Resolves a Vulkan entry point by name, returning nil if unavailable.
typealias VulkanResolver = (String) -> UnsafeRawPointer?

/// Instance-level commands (resolved through `vkGetInstanceProcAddr`).
struct VulkanInstanceCommands {
    let destroyInstance: PFN_vkDestroyInstance
    let enumeratePhysicalDevices: PFN_vkEnumeratePhysicalDevices
    let getPhysicalDeviceProperties: PFN_vkGetPhysicalDeviceProperties
    let getPhysicalDeviceProperties2: PFN_vkGetPhysicalDeviceProperties2
    let getPhysicalDeviceFeatures2: PFN_vkGetPhysicalDeviceFeatures2
    let enumerateDeviceExtensionProperties: PFN_vkEnumerateDeviceExtensionProperties
    let getPhysicalDeviceQueueFamilyProperties: PFN_vkGetPhysicalDeviceQueueFamilyProperties
    let getPhysicalDeviceMemoryProperties: PFN_vkGetPhysicalDeviceMemoryProperties
    let createDevice: PFN_vkCreateDevice
    let destroyDevice: PFN_vkDestroyDevice
    let getDeviceQueue: PFN_vkGetDeviceQueue
    let deviceWaitIdle: PFN_vkDeviceWaitIdle
    let destroySurfaceKHR: PFN_vkDestroySurfaceKHR
    let getSurfaceSupport: CVulkanHeaders.PFN_vkGetPhysicalDeviceSurfaceSupportKHR
    let getSurfaceCapabilities: PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR
    let getSurfaceFormats: PFN_vkGetPhysicalDeviceSurfaceFormatsKHR
    let getSurfacePresentModes: PFN_vkGetPhysicalDeviceSurfacePresentModesKHR

    init(_ resolve: VulkanResolver) {
        destroyInstance = Self.bind(resolve("vkDestroyInstance"))
        enumeratePhysicalDevices = Self.bind(resolve("vkEnumeratePhysicalDevices"))
        getPhysicalDeviceProperties = Self.bind(resolve("vkGetPhysicalDeviceProperties"))
        getPhysicalDeviceProperties2 = Self.bind(resolve("vkGetPhysicalDeviceProperties2"))
        getPhysicalDeviceFeatures2 = Self.bind(resolve("vkGetPhysicalDeviceFeatures2"))
        enumerateDeviceExtensionProperties = Self.bind(resolve("vkEnumerateDeviceExtensionProperties"))
        getPhysicalDeviceQueueFamilyProperties = Self.bind(resolve("vkGetPhysicalDeviceQueueFamilyProperties"))
        getPhysicalDeviceMemoryProperties = Self.bind(resolve("vkGetPhysicalDeviceMemoryProperties"))
        createDevice = Self.bind(resolve("vkCreateDevice"))
        destroyDevice = Self.bind(resolve("vkDestroyDevice"))
        getDeviceQueue = Self.bind(resolve("vkGetDeviceQueue"))
        deviceWaitIdle = Self.bind(resolve("vkDeviceWaitIdle"))
        destroySurfaceKHR = Self.bind(resolve("vkDestroySurfaceKHR"))
        getSurfaceSupport = Self.bind(resolve("vkGetPhysicalDeviceSurfaceSupportKHR"))
        getSurfaceCapabilities = Self.bind(resolve("vkGetPhysicalDeviceSurfaceCapabilitiesKHR"))
        getSurfaceFormats = Self.bind(resolve("vkGetPhysicalDeviceSurfaceFormatsKHR"))
        getSurfacePresentModes = Self.bind(resolve("vkGetPhysicalDeviceSurfacePresentModesKHR"))
    }

    private static func bind<F>(_ ptr: UnsafeRawPointer?) -> F {
        guard let ptr else { fatalError("Required Vulkan entry point is unavailable") }
        return unsafeBitCast(OpaquePointer(ptr), to: F.self)
    }
}

/// Device-level commands — memory, buffers, images, views, shaders, pools.
struct VulkanDeviceCoreCommands {
    let createBuffer: PFN_vkCreateBuffer
    let destroyBuffer: PFN_vkDestroyBuffer
    let getBufferMemoryRequirements: PFN_vkGetBufferMemoryRequirements
    let bindBufferMemory: PFN_vkBindBufferMemory
    let createImage: PFN_vkCreateImage
    let destroyImage: PFN_vkDestroyImage
    let getImageMemoryRequirements: PFN_vkGetImageMemoryRequirements
    let bindImageMemory: PFN_vkBindImageMemory
    let allocateMemory: PFN_vkAllocateMemory
    let freeMemory: PFN_vkFreeMemory
    let mapMemory: PFN_vkMapMemory
    let unmapMemory: PFN_vkUnmapMemory
    let createImageView: PFN_vkCreateImageView
    let destroyImageView: PFN_vkDestroyImageView
    let createShaderModule: PFN_vkCreateShaderModule
    let destroyShaderModule: PFN_vkDestroyShaderModule
    let createDescriptorPool: PFN_vkCreateDescriptorPool
    let destroyDescriptorPool: PFN_vkDestroyDescriptorPool

    init(_ resolve: VulkanResolver) {
        createBuffer = Self.bind(resolve("vkCreateBuffer"))
        destroyBuffer = Self.bind(resolve("vkDestroyBuffer"))
        getBufferMemoryRequirements = Self.bind(resolve("vkGetBufferMemoryRequirements"))
        bindBufferMemory = Self.bind(resolve("vkBindBufferMemory"))
        createImage = Self.bind(resolve("vkCreateImage"))
        destroyImage = Self.bind(resolve("vkDestroyImage"))
        getImageMemoryRequirements = Self.bind(resolve("vkGetImageMemoryRequirements"))
        bindImageMemory = Self.bind(resolve("vkBindImageMemory"))
        allocateMemory = Self.bind(resolve("vkAllocateMemory"))
        freeMemory = Self.bind(resolve("vkFreeMemory"))
        mapMemory = Self.bind(resolve("vkMapMemory"))
        unmapMemory = Self.bind(resolve("vkUnmapMemory"))
        createImageView = Self.bind(resolve("vkCreateImageView"))
        destroyImageView = Self.bind(resolve("vkDestroyImageView"))
        createShaderModule = Self.bind(resolve("vkCreateShaderModule"))
        destroyShaderModule = Self.bind(resolve("vkDestroyShaderModule"))
        createDescriptorPool = Self.bind(resolve("vkCreateDescriptorPool"))
        destroyDescriptorPool = Self.bind(resolve("vkDestroyDescriptorPool"))
    }

    private static func bind<F>(_ ptr: UnsafeRawPointer?) -> F {
        guard let ptr else { fatalError("Required Vulkan entry point is unavailable") }
        return unsafeBitCast(OpaquePointer(ptr), to: F.self)
    }
}

/// Device-level commands — pipelines, descriptor sets, samplers, passes, pools.
struct VulkanDeviceResourceCommands {
    let createGraphicsPipelines: PFN_vkCreateGraphicsPipelines
    let createComputePipelines: PFN_vkCreateComputePipelines
    let destroyPipeline: PFN_vkDestroyPipeline
    let createPipelineLayout: PFN_vkCreatePipelineLayout
    let destroyPipelineLayout: PFN_vkDestroyPipelineLayout
    let createDescriptorSetLayout: PFN_vkCreateDescriptorSetLayout
    let destroyDescriptorSetLayout: PFN_vkDestroyDescriptorSetLayout
    let allocateDescriptorSets: PFN_vkAllocateDescriptorSets
    let updateDescriptorSets: PFN_vkUpdateDescriptorSets
    let createSampler: PFN_vkCreateSampler
    let destroySampler: PFN_vkDestroySampler
    let createRenderPass: PFN_vkCreateRenderPass
    let destroyRenderPass: PFN_vkDestroyRenderPass
    let createFramebuffer: PFN_vkCreateFramebuffer
    let destroyFramebuffer: PFN_vkDestroyFramebuffer
    let createCommandPool: PFN_vkCreateCommandPool
    let allocateCommandBuffers: PFN_vkAllocateCommandBuffers

    init(_ resolve: VulkanResolver) {
        createGraphicsPipelines = Self.bind(resolve("vkCreateGraphicsPipelines"))
        createComputePipelines = Self.bind(resolve("vkCreateComputePipelines"))
        destroyPipeline = Self.bind(resolve("vkDestroyPipeline"))
        createPipelineLayout = Self.bind(resolve("vkCreatePipelineLayout"))
        destroyPipelineLayout = Self.bind(resolve("vkDestroyPipelineLayout"))
        createDescriptorSetLayout = Self.bind(resolve("vkCreateDescriptorSetLayout"))
        destroyDescriptorSetLayout = Self.bind(resolve("vkDestroyDescriptorSetLayout"))
        allocateDescriptorSets = Self.bind(resolve("vkAllocateDescriptorSets"))
        updateDescriptorSets = Self.bind(resolve("vkUpdateDescriptorSets"))
        createSampler = Self.bind(resolve("vkCreateSampler"))
        destroySampler = Self.bind(resolve("vkDestroySampler"))
        createRenderPass = Self.bind(resolve("vkCreateRenderPass"))
        destroyRenderPass = Self.bind(resolve("vkDestroyRenderPass"))
        createFramebuffer = Self.bind(resolve("vkCreateFramebuffer"))
        destroyFramebuffer = Self.bind(resolve("vkDestroyFramebuffer"))
        createCommandPool = Self.bind(resolve("vkCreateCommandPool"))
        allocateCommandBuffers = Self.bind(resolve("vkAllocateCommandBuffers"))
    }

    private static func bind<F>(_ ptr: UnsafeRawPointer?) -> F {
        guard let ptr else { fatalError("Required Vulkan entry point is unavailable") }
        return unsafeBitCast(OpaquePointer(ptr), to: F.self)
    }
}

/// Device-level commands — command buffer recording.
struct VulkanDeviceDrawCommands {
    let freeCommandBuffers: PFN_vkFreeCommandBuffers
    let resetCommandPool: PFN_vkResetCommandPool
    let beginCommandBuffer: PFN_vkBeginCommandBuffer
    let endCommandBuffer: PFN_vkEndCommandBuffer
    let cmdBeginRenderPass: PFN_vkCmdBeginRenderPass
    let cmdEndRenderPass: PFN_vkCmdEndRenderPass
    let cmdBindPipeline: PFN_vkCmdBindPipeline
    let cmdSetViewport: PFN_vkCmdSetViewport
    let cmdSetScissor: PFN_vkCmdSetScissor
    let cmdBindVertexBuffers: PFN_vkCmdBindVertexBuffers
    let cmdBindIndexBuffer: PFN_vkCmdBindIndexBuffer
    let cmdDraw: PFN_vkCmdDraw
    let cmdDrawIndexed: PFN_vkCmdDrawIndexed
    let cmdBindDescriptorSets: PFN_vkCmdBindDescriptorSets
    let cmdPushConstants: PFN_vkCmdPushConstants
    let cmdDispatch: PFN_vkCmdDispatch
    let cmdCopyBuffer: PFN_vkCmdCopyBuffer
    let cmdCopyBufferToImage: PFN_vkCmdCopyBufferToImage
    let cmdCopyImageToBuffer: PFN_vkCmdCopyImageToBuffer
    let cmdPipelineBarrier: PFN_vkCmdPipelineBarrier

    init(_ resolve: VulkanResolver) {
        freeCommandBuffers = Self.bind(resolve("vkFreeCommandBuffers"))
        resetCommandPool = Self.bind(resolve("vkResetCommandPool"))
        beginCommandBuffer = Self.bind(resolve("vkBeginCommandBuffer"))
        endCommandBuffer = Self.bind(resolve("vkEndCommandBuffer"))
        cmdBeginRenderPass = Self.bind(resolve("vkCmdBeginRenderPass"))
        cmdEndRenderPass = Self.bind(resolve("vkCmdEndRenderPass"))
        cmdBindPipeline = Self.bind(resolve("vkCmdBindPipeline"))
        cmdSetViewport = Self.bind(resolve("vkCmdSetViewport"))
        cmdSetScissor = Self.bind(resolve("vkCmdSetScissor"))
        cmdBindVertexBuffers = Self.bind(resolve("vkCmdBindVertexBuffers"))
        cmdBindIndexBuffer = Self.bind(resolve("vkCmdBindIndexBuffer"))
        cmdDraw = Self.bind(resolve("vkCmdDraw"))
        cmdDrawIndexed = Self.bind(resolve("vkCmdDrawIndexed"))
        cmdBindDescriptorSets = Self.bind(resolve("vkCmdBindDescriptorSets"))
        cmdPushConstants = Self.bind(resolve("vkCmdPushConstants"))
        cmdDispatch = Self.bind(resolve("vkCmdDispatch"))
        cmdCopyBuffer = Self.bind(resolve("vkCmdCopyBuffer"))
        cmdCopyBufferToImage = Self.bind(resolve("vkCmdCopyBufferToImage"))
        cmdCopyImageToBuffer = Self.bind(resolve("vkCmdCopyImageToBuffer"))
        cmdPipelineBarrier = Self.bind(resolve("vkCmdPipelineBarrier"))
    }

    private static func bind<F>(_ ptr: UnsafeRawPointer?) -> F {
        guard let ptr else { fatalError("Required Vulkan entry point is unavailable") }
        return unsafeBitCast(OpaquePointer(ptr), to: F.self)
    }
}

/// Device-level commands — synchronization, submission, swapchain.
struct VulkanDeviceSyncCommands {
    let createFence: PFN_vkCreateFence
    let destroyFence: PFN_vkDestroyFence
    let waitForFences: PFN_vkWaitForFences
    let resetFences: PFN_vkResetFences
    let createSemaphore: PFN_vkCreateSemaphore
    let destroySemaphore: PFN_vkDestroySemaphore
    let queueSubmit: PFN_vkQueueSubmit
    let queuePresent: PFN_vkQueuePresentKHR
    let queueWaitIdle: PFN_vkQueueWaitIdle
    let createSwapchain: PFN_vkCreateSwapchainKHR
    let destroySwapchain: PFN_vkDestroySwapchainKHR
    let getSwapchainImages: PFN_vkGetSwapchainImagesKHR
    let acquireNextImage: PFN_vkAcquireNextImageKHR

    init(_ resolve: VulkanResolver) {
        createFence = Self.bind(resolve("vkCreateFence"))
        destroyFence = Self.bind(resolve("vkDestroyFence"))
        waitForFences = Self.bind(resolve("vkWaitForFences"))
        resetFences = Self.bind(resolve("vkResetFences"))
        createSemaphore = Self.bind(resolve("vkCreateSemaphore"))
        destroySemaphore = Self.bind(resolve("vkDestroySemaphore"))
        queueSubmit = Self.bind(resolve("vkQueueSubmit"))
        queuePresent = Self.bind(resolve("vkQueuePresentKHR"))
        queueWaitIdle = Self.bind(resolve("vkQueueWaitIdle"))
        createSwapchain = Self.bind(resolve("vkCreateSwapchainKHR"))
        destroySwapchain = Self.bind(resolve("vkDestroySwapchainKHR"))
        getSwapchainImages = Self.bind(resolve("vkGetSwapchainImagesKHR"))
        acquireNextImage = Self.bind(resolve("vkAcquireNextImageKHR"))
    }

    private static func bind<F>(_ ptr: UnsafeRawPointer?) -> F {
        guard let ptr else { fatalError("Required Vulkan entry point is unavailable") }
        return unsafeBitCast(OpaquePointer(ptr), to: F.self)
    }
}

#endif // canImport(CVulkanHeaders)
