// NativeRHI Vulkan — swapchain and surface management.
//
// Images are acquired into a fixed pool and recycled: acquire never appends to
// a growing array. OUT_OF_DATE / SUBOPTIMAL triggers a recreate. Present has no
// queue idle on the hot path.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

final class VulkanSwapchain {
    private let context: VulkanContext
    private let surface: VkSurfaceKHR
    private(set) var handle: VkSwapchainKHR
    private(set) var format: VkFormat
    private(set) var extent: VkExtent2D
    /// Fixed pool of swapchain images and their frontend texture IDs.
    private(set) var images: [VkImage]
    private(set) var textureIDs: [UInt32]
    private let vsync: Bool

    private init(context: VulkanContext,
                 surface: VkSurfaceKHR,
                 handle: VkSwapchainKHR,
                 format: VkFormat,
                 extent: VkExtent2D,
                 images: [VkImage],
                 textureIDs: [UInt32],
                 vsync: Bool) {
        self.context = context
        self.surface = surface
        self.handle = handle
        self.format = format
        self.extent = extent
        self.images = images
        self.textureIDs = textureIDs
        self.vsync = vsync
    }

    static func create(context: VulkanContext,
                       surface: VulkanSurface,
                       registries: VulkanRegistries) throws -> VulkanSwapchain {
        let swapchain = try build(context: context,
                                  surface: surface.surface,
                                  width: surface.width,
                                  height: surface.height,
                                  colorFormat: surface.colorFormat,
                                  vsync: surface.vsync,
                                  oldSwapchain: vkNull(),
                                  registries: registries)
        return swapchain
    }

    /// Recreates the swapchain after a resize or OUT_OF_DATE. The previous image
    /// records are dropped; the fixed pool is rebuilt.
    func recreate(registries: VulkanRegistries) throws {
        _ = context.instanceCommands.deviceWaitIdle(context.device)
        let old = handle
        let oldIDs = textureIDs
        let rebuilt = try Self.build(
            context: context,
            surface: surface,
            width: Int(extent.width),
            height: Int(extent.height),
            colorFormat: .bgra8Unorm,
            vsync: vsync,
            oldSwapchain: old,
            registries: registries
        )
        handle = rebuilt.handle
        format = rebuilt.format
        extent = rebuilt.extent
        images = rebuilt.images
        textureIDs = rebuilt.textureIDs
        for id in oldIDs { if let record = registries.textures.removeValue(forKey: id) { context.core.destroyImageView(context.device, record.view, nil) } }
        context.sync.destroySwapchain(context.device, old, nil)
    }

    /// Acquires the next image into `semaphore`. Returns the image index and the
    /// raw result so the caller can handle OUT_OF_DATE / SUBOPTIMAL.
    func acquire(semaphore: VkSemaphore, timeout: UInt64) -> (index: UInt32, result: VkResult) {
        var index: UInt32 = 0
        let result = context.sync.acquireNextImage(context.device, handle, timeout,
                                                   semaphore, vkNull(), &index)
        return (index, result)
    }

    func present(queue: VkQueue, semaphore: VkSemaphore, index: UInt32) -> VkResult {
        let arena = VulkanScratch()
        var info = VkPresentInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR
        info.waitSemaphoreCount = 1; info.pWaitSemaphores = arena.store([Optional(semaphore)])
        info.swapchainCount = 1; info.pSwapchains = arena.store([Optional(handle)])
        info.pImageIndices = arena.store([index])
        return withExtendedLifetime(arena) { context.sync.queuePresent(queue, &info) }
    }

    func destroy(registries: VulkanRegistries) {
        for id in textureIDs { if let record = registries.textures.removeValue(forKey: id) { context.core.destroyImageView(context.device, record.view, nil) } }
        context.sync.destroySwapchain(context.device, handle, nil)
        context.instanceCommands.destroySurfaceKHR(context.instance, surface, nil)
    }

    // MARK: Build

    private static func build(
        context: VulkanContext,
        surface: VkSurfaceKHR,
        width: Int,
        height: Int,
        colorFormat: TextureFormat,
        vsync: Bool,
        oldSwapchain: VkSwapchainKHR,
        registries: VulkanRegistries
    ) throws -> VulkanSwapchain {
        var caps = VkSurfaceCapabilitiesKHR()
        _ = context.instanceCommands.getSurfaceCapabilities(context.physicalDevice, surface, &caps)

        let extent = VkExtent2D(
            width: width == 0 ? caps.currentExtent.width : UInt32(width),
            height: height == 0 ? caps.currentExtent.height : UInt32(height)
        )

        // Pick a surface format.
        var formatCount: UInt32 = 0
        _ = context.instanceCommands.getSurfaceFormats(context.physicalDevice, surface, &formatCount, nil)
        var formats: [VkSurfaceFormatKHR] = Array(repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
        _ = context.instanceCommands.getSurfaceFormats(context.physicalDevice, surface, &formatCount, &formats)
        let desired = VulkanFormats.vkFormat(colorFormat)
        var chosen = formats.first ?? VkSurfaceFormatKHR()
        for candidate in formats {
            if candidate.format == desired { chosen = candidate; break }
        }

        // Present mode: FIFO for vsync, MAILBOX otherwise.
        var modeCount: UInt32 = 0
        _ = context.instanceCommands.getSurfacePresentModes(context.physicalDevice, surface, &modeCount, nil)
        var modes: [VkPresentModeKHR] = Array(repeating: VK_PRESENT_MODE_FIFO_KHR, count: Int(modeCount))
        _ = context.instanceCommands.getSurfacePresentModes(context.physicalDevice, surface, &modeCount, &modes)
        let presentMode: VkPresentModeKHR
        if vsync {
            presentMode = VK_PRESENT_MODE_FIFO_KHR
        } else if modes.contains(VK_PRESENT_MODE_MAILBOX_KHR) {
            presentMode = VK_PRESENT_MODE_MAILBOX_KHR
        } else {
            presentMode = VK_PRESENT_MODE_FIFO_KHR
        }

        let imageCount = caps.maxImageCount == 0 ? caps.minImageCount + 1 : min(caps.minImageCount + 1, caps.maxImageCount)

        var info = VkSwapchainCreateInfoKHR()
        info.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR
        info.surface = surface
        info.minImageCount = imageCount
        info.imageFormat = chosen.format
        info.imageColorSpace = chosen.colorSpace
        info.imageExtent = extent
        info.imageArrayLayers = 1
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
        info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE
        info.preTransform = caps.currentTransform
        let alphaBits = caps.supportedCompositeAlpha
        info.compositeAlpha = VkCompositeAlphaFlagBitsKHR(rawValue: alphaBits & (~alphaBits &+ 1))
        info.presentMode = presentMode
        info.clipped = VK_TRUE
        info.oldSwapchain = oldSwapchain

        guard let swapchain = vkWithOutHandle({
            context.sync.createSwapchain(context.device, &info, nil, $0)
        }) else {
            throw RHIError.swapchainAcquireFailed("vkCreateSwapchainKHR failed")
        }

        var actualCount: UInt32 = 0
        _ = context.sync.getSwapchainImages(context.device, swapchain, &actualCount, nil)
        var images: [VkImage] = Array(repeating: vkNull(), count: Int(actualCount))
        _ = context.sync.getSwapchainImages(context.device, swapchain, &actualCount, &images)

        // Wrap each swapchain image as a Texture record in the fixed pool.
        var textureIDs: [UInt32] = []
        for image in images {
            let id = registries.nextInternalID()
            var viewInfo = VkImageViewCreateInfo()
            viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO; viewInfo.image = image; viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
            viewInfo.format = chosen.format; viewInfo.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
            guard let view = vkWithOutHandle({ _ = context.core.createImageView(context.device, &viewInfo, nil, $0) }) else { throw RHIError.outOfMemory }
            registries.textures[id] = VulkanTextureRecord(
                image: image,
                allocation: nil,
                view: view,
                format: VulkanFormats.textureFormat(chosen.format),
                width: Int(extent.width),
                height: Int(extent.height),
                depth: 1,
                mipLevels: 1,
                usage: [.present, .colorTarget, .transferDestination],
                isSwapchain: true,
                layout: VK_IMAGE_LAYOUT_UNDEFINED
            )
            textureIDs.append(id)
        }

        return VulkanSwapchain(
            context: context,
            surface: surface,
            handle: swapchain,
            format: chosen.format,
            extent: extent,
            images: images,
            textureIDs: textureIDs,
            vsync: vsync
        )
    }
}

/// The already-created VkSurfaceKHR plus the sizing the caller requested.
struct VulkanSurface {
    let surface: VkSurfaceKHR
    let width: Int
    let height: Int
    let colorFormat: TextureFormat
    let vsync: Bool
}

#endif // canImport(CVulkanHeaders)
