// NativeRHI Vulkan — swapchain and surface management.
//
// Images are acquired into a fixed pool and recycled: acquire never appends to
// a growing array. OUT_OF_DATE / SUBOPTIMAL triggers a recreate. Present has no
// queue idle on the hot path.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
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
    private let requestedColorFormat: TextureFormat

    private init(context: VulkanContext,
                 surface: VkSurfaceKHR,
                 handle: VkSwapchainKHR,
                 format: VkFormat,
                 extent: VkExtent2D,
                 images: [VkImage],
                 textureIDs: [UInt32],
                 vsync: Bool, requestedColorFormat: TextureFormat) {
        self.context = context
        self.surface = surface
        self.handle = handle
        self.format = format
        self.extent = extent
        self.images = images
        self.textureIDs = textureIDs
        self.vsync = vsync
        self.requestedColorFormat = requestedColorFormat
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
            colorFormat: requestedColorFormat,
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
        guard context.instanceCommands.getSurfaceCapabilities(context.physicalDevice, surface, &caps) == VK_SUCCESS else {
            throw RHIError.swapchainAcquireFailed("Vulkan surface capabilities unavailable")
        }
        let extent: VkExtent2D
        if caps.currentExtent.width != UInt32.max {
            extent = caps.currentExtent
        } else {
            try rhiRequire(width > 0 && height > 0 && width <= Int(UInt32.max) && height <= Int(UInt32.max), "Vulkan surface needs a positive drawable extent")
            extent = VkExtent2D(width: min(max(UInt32(width), caps.minImageExtent.width), caps.maxImageExtent.width),
                height: min(max(UInt32(height), caps.minImageExtent.height), caps.maxImageExtent.height))
        }
        guard extent.width > 0 && extent.height > 0 else {
            throw RHIError.swapchainAcquireFailed("Vulkan drawable has zero extent")
        }

        // Pick a surface format.
        var formatCount: UInt32 = 0
        guard context.instanceCommands.getSurfaceFormats(context.physicalDevice, surface, &formatCount, nil) == VK_SUCCESS, formatCount > 0 else {
            throw RHIError.swapchainAcquireFailed("Vulkan surface has no color formats")
        }
        var formats: [VkSurfaceFormatKHR] = Array(repeating: VkSurfaceFormatKHR(), count: Int(formatCount))
        guard context.instanceCommands.getSurfaceFormats(context.physicalDevice, surface, &formatCount, &formats) == VK_SUCCESS else {
            throw RHIError.swapchainAcquireFailed("Vulkan surface format enumeration failed")
        }
        let desired = VulkanFormats.vkFormat(colorFormat)
        var chosen = formats.prefix(Int(formatCount)).first { $0.format == desired }
        if chosen == nil, formatCount == 1, formats[0].format == VK_FORMAT_UNDEFINED {
            chosen = VkSurfaceFormatKHR(format: desired, colorSpace: formats[0].colorSpace)
        }
        guard let chosen else {
            throw RHIError.unsupportedFeature("Vulkan surface cannot present the requested color format")
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
        guard caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue != 0 else {
            throw RHIError.unsupportedFeature("Vulkan surface images do not support color rendering")
        }
        info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue
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
        var committed = false
        var textureIDs: [UInt32] = []
        defer {
            if !committed {
                for id in textureIDs {
                    if let record = registries.textures.removeValue(forKey: id) { context.core.destroyImageView(context.device, record.view, nil) }
                }
                context.sync.destroySwapchain(context.device, swapchain, nil)
            }
        }

        var actualCount: UInt32 = 0
        guard context.sync.getSwapchainImages(context.device, swapchain, &actualCount, nil) == VK_SUCCESS, actualCount > 0 else {
            throw RHIError.swapchainAcquireFailed("Vulkan swapchain has no images")
        }
        var images: [VkImage] = Array(repeating: vkNull(), count: Int(actualCount))
        guard context.sync.getSwapchainImages(context.device, swapchain, &actualCount, &images) == VK_SUCCESS else {
            throw RHIError.swapchainAcquireFailed("Vulkan swapchain image enumeration failed")
        }

        // Wrap each swapchain image as a Texture record in the fixed pool.
        for image in images.prefix(Int(actualCount)) {
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
                usage: [.present, .colorTarget],
                isSwapchain: true,
                layout: VK_IMAGE_LAYOUT_UNDEFINED
            )
            textureIDs.append(id)
        }

        committed = true
        return VulkanSwapchain(
            context: context,
            surface: surface,
            handle: swapchain,
            format: chosen.format,
            extent: extent,
            images: images,
            textureIDs: textureIDs,
            vsync: vsync, requestedColorFormat: colorFormat
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
