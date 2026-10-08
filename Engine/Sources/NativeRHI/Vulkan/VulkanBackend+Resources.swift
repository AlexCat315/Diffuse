// NativeRHI Vulkan — resource creation, immediate transfers, surface configure.

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func configure(surface descriptor: SurfaceDescriptor) throws {
        try lock.withLock {
            try waitUntilIdle()
            swapchain?.destroy(registries: registries); swapchain = nil; surface = nil
            for semaphore in presentation.ready.values { sync.destroySemaphore(context.device, semaphore, nil) }
            presentation = VulkanPresentationState()
            guard let native = descriptor.nativeHandle else {
                throw RHIError.invalidArgument("Vulkan requires a native surface handle")
            }
            let kind: GRHIVulkanSurfaceKind
            switch descriptor.kind {
            case .win32Window: kind = GRHI_VULKAN_WIN32
            case .xlibWindow: kind = GRHI_VULKAN_XLIB
            case .waylandSurface: kind = GRHI_VULKAN_WAYLAND
            case .metalLayer: throw RHIError.unsupportedBackend("Vulkan requires a native Windows/Linux surface")
            }
            var created: VkSurfaceKHR?
            let result = grhi_vulkan_create_native_surface(context.instance, kind, native, descriptor.display, &created)
            guard result == VK_SUCCESS, let newSurface = created else {
                throw RHIError.unsupportedBackend("native Vulkan surface creation failed: \(result)")
            }
            var committed = false
            defer { if !committed { context.instanceCommands.destroySurfaceKHR(context.instance, newSurface, nil); self.surface = nil } }
            var supported: VkBool32 = VK_FALSE
            guard context.extensions.contains("VK_KHR_swapchain"),
                  context.instanceCommands.getSurfaceSupport(context.physicalDevice, context.queues.graphics.family,
                    newSurface, &supported) == VK_SUCCESS, supported == VK_TRUE else {
                throw RHIError.unsupportedBackend("selected Vulkan graphics queue cannot present this surface")
            }
            self.surface = newSurface
            let vulkanSurface = VulkanSurface(
                surface: newSurface,
                width: descriptor.width,
                height: descriptor.height,
                colorFormat: descriptor.colorFormat,
                vsync: descriptor.vsyncEnabled
            )
            self.swapchain = try VulkanSwapchain.create(
                context: context, surface: vulkanSurface, registries: registries)
            committed = true

        }
    }

    // MARK: Buffers

    func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws {
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(max(1, descriptor.size))
        info.usage = Self.bufferUsageFlags(descriptor.usage)
        if context.features.accelerationStructures {
            info.usage |= VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue
                | VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR.rawValue
                | VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR.rawValue
        }
        let arena = VulkanScratch()
        let families = Array(Set([context.queues.graphics.family, context.queues.compute.family, context.queues.transfer.family]))
        info.sharingMode = families.count > 1 ? VK_SHARING_MODE_CONCURRENT : VK_SHARING_MODE_EXCLUSIVE
        if families.count > 1 {
            info.queueFamilyIndexCount = UInt32(families.count)
            info.pQueueFamilyIndices = arena.store(families)
        }
        guard let buffer: VkBuffer = withExtendedLifetime(arena, {
            vkWithOutHandle { _ = context.core.createBuffer(context.device, &info, nil, $0) }
        }) else { throw RHIError.outOfMemory }

        var stored = false
        defer { if !stored { context.core.destroyBuffer(context.device, buffer, nil) } }
        var req = VkMemoryRequirements()
        context.core.getBufferMemoryRequirements(context.device, buffer, &req)

        let isGpuResource = descriptor.usage.contains(.vertex)
            || descriptor.usage.contains(.index)
            || descriptor.usage.contains(.indirect)
            || descriptor.usage.contains(.uniform)
            || descriptor.usage.contains(.storageRead)
            || descriptor.usage.contains(.storageWrite)
        let flags: VkMemoryPropertyFlags = isGpuResource
            ? UInt32(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
            : UInt32(VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)

        let allocation = try allocator.allocate(
            size: req.size, alignment: req.alignment,
            memoryTypeBits: req.memoryTypeBits, requiredFlags: flags)
        defer { if !stored { allocator.free(allocation) } }
        if context.core.bindBufferMemory(context.device, buffer, allocation.memory, allocation.offset) != VK_SUCCESS {
            throw RHIError.outOfMemory
        }
        registries.buffers[handle.id] = VulkanBufferRecord(
            buffer: buffer, allocation: allocation, size: descriptor.size, usage: descriptor.usage)
        stored = true
    }

    func destroyBuffer(_ handle: Buffer) {
        guard let record = registries.buffers.removeValue(forKey: handle.id) else { return }
        context.core.destroyBuffer(context.device, record.buffer, nil)
        allocator.free(record.allocation)
    }

    // MARK: Textures

    func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws {
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = descriptor.dimension == .texture3D ? VK_IMAGE_TYPE_3D : VK_IMAGE_TYPE_2D
        info.format = VulkanFormats.vkFormat(descriptor.format)
        info.extent = VkExtent3D(width: UInt32(max(1, descriptor.width)),
                                 height: UInt32(max(1, descriptor.height)),
                                 depth: UInt32(max(1, descriptor.depth)))
        info.mipLevels = UInt32(max(1, descriptor.mipLevels))
        info.arrayLayers = descriptor.dimension == .cube ? 6 : UInt32(descriptor.layers)
        if descriptor.dimension == .cube { info.flags = UInt32(VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT.rawValue) }
        try rhiValidateTextureSamples(descriptor)
        info.samples = try VulkanFormats.vkSampleCount(descriptor.sampleCount)
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = Self.textureUsageFlags(descriptor.usage)
        let arena = VulkanScratch()
        let families = Array(Set([context.queues.graphics.family, context.queues.compute.family, context.queues.transfer.family]))
        info.sharingMode = families.count > 1 ? VK_SHARING_MODE_CONCURRENT : VK_SHARING_MODE_EXCLUSIVE
        if families.count > 1 {
            info.queueFamilyIndexCount = UInt32(families.count)
            info.pQueueFamilyIndices = arena.store(families)
        }
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var support = VkImageFormatProperties()
        let supported = context.instanceCommands.getImageFormatProperties(context.physicalDevice, info.format,
            info.imageType, info.tiling, info.usage, info.flags, &support)
        guard supported == VK_SUCCESS && support.sampleCounts & UInt32(descriptor.sampleCount) != 0 else {
            throw RHIError.unsupportedFeature("Vulkan adapter does not support the requested texture format, usage and samples")
        }
        try rhiRequire(info.extent.width <= support.maxExtent.width && info.extent.height <= support.maxExtent.height
            && info.extent.depth <= support.maxExtent.depth && info.mipLevels <= support.maxMipLevels
            && info.arrayLayers <= support.maxArrayLayers, "texture exceeds Vulkan format limits")

        guard let image: VkImage = withExtendedLifetime(arena, {
            vkWithOutHandle { _ = context.core.createImage(context.device, &info, nil, $0) }
        }) else { throw RHIError.outOfMemory }

        var stored = false
        defer { if !stored { context.core.destroyImage(context.device, image, nil) } }
        var req = VkMemoryRequirements()
        context.core.getImageMemoryRequirements(context.device, image, &req)
        let allocation = try allocator.allocate(
            size: req.size, alignment: req.alignment,
            memoryTypeBits: req.memoryTypeBits,
            requiredFlags: UInt32(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue))
        defer { if !stored { allocator.free(allocation) } }
        if context.core.bindImageMemory(context.device, image, allocation.memory, allocation.offset) != VK_SUCCESS {
            throw RHIError.outOfMemory
        }

        let aspect: VkImageAspectFlags = VulkanFormats.isDepth(descriptor.format)
            ? UInt32(VK_IMAGE_ASPECT_DEPTH_BIT.rawValue) : UInt32(VK_IMAGE_ASPECT_COLOR_BIT.rawValue)
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        switch descriptor.dimension {
        case .texture2D: viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        case .texture2DArray: viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D_ARRAY
        case .texture3D: viewInfo.viewType = VK_IMAGE_VIEW_TYPE_3D
        case .cube: viewInfo.viewType = VK_IMAGE_VIEW_TYPE_CUBE
        }
        viewInfo.format = VulkanFormats.vkFormat(descriptor.format)
        viewInfo.subresourceRange = VkImageSubresourceRange(aspectMask: aspect, baseMipLevel: 0,
                                                           levelCount: VK_REMAINING_MIP_LEVELS,
                                                           baseArrayLayer: 0,
                                                           layerCount: VK_REMAINING_ARRAY_LAYERS)
        guard let view = vkWithOutHandle({
            context.core.createImageView(context.device, &viewInfo, nil, $0)
        }) else { throw RHIError.outOfMemory }
        defer { if !stored { context.core.destroyImageView(context.device, view, nil) } }
        var attachmentView: VkImageView?
        if descriptor.mipLevels > 1 && (descriptor.usage.contains(.colorTarget) || descriptor.usage.contains(.depthStencilTarget)) {
            viewInfo.subresourceRange.levelCount = 1
            attachmentView = vkWithOutHandle { context.core.createImageView(context.device, &viewInfo, nil, $0) }
            guard attachmentView != nil else { throw RHIError.outOfMemory }
        }

        var record = VulkanTextureRecord(
            image: image, allocation: allocation, view: view,
            format: descriptor.format, width: descriptor.width, height: descriptor.height,
            depth: descriptor.depth, dimension: descriptor.dimension, mipLevels: UInt32(max(1, descriptor.mipLevels)),
            usage: descriptor.usage, isSwapchain: false, layout: VK_IMAGE_LAYOUT_UNDEFINED)
        record.layers = info.arrayLayers
        record.sampleCount = descriptor.sampleCount
        record.attachmentView = attachmentView
        registries.textures[handle.id] = record
        stored = true
    }

    func destroyTexture(_ handle: Texture) {
        guard let record = registries.textures.removeValue(forKey: handle.id) else { return }
        guard !record.isSwapchain else { return }
        if let attachment = record.attachmentView { context.core.destroyImageView(context.device, attachment, nil) }
        context.core.destroyImageView(context.device, record.view, nil)
        context.core.destroyImage(context.device, record.image, nil)
        if let allocation = record.allocation { allocator.free(allocation) }
    }

    // MARK: Samplers / shaders

    func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws {
        var info = VkSamplerCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        info.magFilter = VulkanFormats.vkFilter(descriptor.magFilter)
        info.minFilter = VulkanFormats.vkFilter(descriptor.minFilter)
        info.mipmapMode = VulkanFormats.vkSamplerMipmapMode(descriptor.mipFilter)
        info.addressModeU = VulkanFormats.vkSamplerAddressMode(descriptor.addressModeU)
        info.addressModeV = VulkanFormats.vkSamplerAddressMode(descriptor.addressModeV)
        info.addressModeW = VulkanFormats.vkSamplerAddressMode(descriptor.addressModeW)
        info.compareEnable = descriptor.compareEnabled ? VK_TRUE : VK_FALSE
        info.compareOp = VulkanFormats.vkCompareOp(descriptor.compareOp)
        info.maxLod = VK_LOD_CLAMP_NONE
        info.borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK
        info.unnormalizedCoordinates = VK_FALSE
        guard let sampler = vkWithOutHandle({
            context.resources.createSampler(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }
        registries.samplers[handle.id] = VulkanSamplerRecord(sampler: sampler)
    }

    func destroySampler(_ handle: Sampler) {
        guard let record = registries.samplers.removeValue(forKey: handle.id) else { return }
        context.resources.destroySampler(context.device, record.sampler, nil)
    }

    func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws {
        guard descriptor.format == .spirv else {
            throw RHIError.unsupportedFeature("Vulkan backend requires SPIR-V shader modules")
        }
        var info = VkShaderModuleCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        info.codeSize = descriptor.code.count
        try rhiRequire(descriptor.code.count >= 20 && descriptor.code.count % 4 == 0, "invalid SPIR-V byte count")
        let words = stride(from: 0, to: descriptor.code.count, by: 4).map { index in
            descriptor.code.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index, as: UInt32.self) }
        }
        let arena = VulkanScratch()
        info.pCode = arena.store(words)
        guard let module: VkShaderModule = withExtendedLifetime(arena, {
            vkWithOutHandle { _ = context.core.createShaderModule(context.device, &info, nil, $0) }
        }) else { throw RHIError.outOfMemory }
        registries.shaderModules[handle.id] = VulkanShaderModuleRecord(module: module, stage: descriptor.stage,
            entryPoint: descriptor.entryPoint,specializationConstants: descriptor.specializationConstants)
    }

    func destroyShaderModule(_ handle: ShaderModule) {
        guard let record = registries.shaderModules.removeValue(forKey: handle.id) else { return }
        context.core.destroyShaderModule(context.device, record.module, nil)
    }

    // MARK: Usage flag mapping

    private static func bufferUsageFlags(_ usage: BufferUsage) -> VkBufferUsageFlags {
        var flags: VkBufferUsageFlags = UInt32(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)
        if usage.contains(.vertex) { flags |= UInt32(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT.rawValue) }
        if usage.contains(.index) { flags |= UInt32(VK_BUFFER_USAGE_INDEX_BUFFER_BIT.rawValue) }
        if usage.contains(.indirect) { flags |= UInt32(VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue) }
        if usage.contains(.uniform) { flags |= UInt32(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue) }
        if usage.contains(.storageRead) || usage.contains(.storageWrite) {
            flags |= UInt32(VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue)
        }
        if usage.contains(.transferSource) { flags |= UInt32(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue) }
        if usage.contains(.transferDestination) { flags |= UInt32(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue) }
        return flags
    }

    private static func textureUsageFlags(_ usage: TextureUsage) -> VkImageUsageFlags {
        var flags: VkImageUsageFlags = UInt32(VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
        if usage.contains(.sampled) { flags |= UInt32(VK_IMAGE_USAGE_SAMPLED_BIT.rawValue) }
        if usage.contains(.colorTarget) { flags |= UInt32(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue) }
        if usage.contains(.depthStencilTarget) { flags |= UInt32(VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue) }
        if usage.contains(.storageRead) || usage.contains(.storageWrite) {
            flags |= UInt32(VK_IMAGE_USAGE_STORAGE_BIT.rawValue)
        }
        if usage.contains(.transferSource) { flags |= UInt32(VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue) }
        if usage.contains(.transferDestination) { flags |= UInt32(VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue) }
        return flags
    }
}

#endif // canImport(CVulkanHeaders)
