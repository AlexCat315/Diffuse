// NativeRHI Vulkan — resource creation, immediate transfers, surface configure.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func configure(surface descriptor: SurfaceDescriptor) throws {
        try lock.withLock {
            #if os(macOS)
            guard let native = descriptor.nativeHandle else {
                throw RHIError.invalidArgument("Vulkan on macOS requires a CAMetalLayer native handle")
            }
            var info = VkMetalSurfaceCreateInfoEXTRepr()
            info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT
            info.flags = 0
            info.pLayer = native
            guard let newSurface = vkWithOutHandle({
                context.instanceCommands.createMetalSurfaceEXT(
                    context.instance, withUnsafePointer(to: &info) { UnsafeRawPointer($0) }, nil, $0)
            }) else {
                throw RHIError.unsupportedBackend("vkCreateMetalSurfaceEXT failed")
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
            #else
            throw RHIError.unsupportedBackend("Vulkan surface creation is only implemented on macOS")
            #endif
        }
    }

    // MARK: Buffers

    func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws {
        var info = VkBufferCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        info.size = VkDeviceSize(max(1, descriptor.size))
        info.usage = Self.bufferUsageFlags(descriptor.usage)
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        guard let buffer = vkWithOutHandle({
            context.core.createBuffer(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }

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
        if context.core.bindBufferMemory(context.device, buffer, allocation.memory, allocation.offset) != VK_SUCCESS {
            throw RHIError.outOfMemory
        }
        registries.buffers[handle.id] = VulkanBufferRecord(
            buffer: buffer, allocation: allocation, size: descriptor.size, usage: descriptor.usage)
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
        info.arrayLayers = UInt32(max(1, descriptor.layers))
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = Self.textureUsageFlags(descriptor.usage)
        info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED

        guard let image = vkWithOutHandle({
            context.core.createImage(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }

        var req = VkMemoryRequirements()
        context.core.getImageMemoryRequirements(context.device, image, &req)
        let allocation = try allocator.allocate(
            size: req.size, alignment: req.alignment,
            memoryTypeBits: req.memoryTypeBits,
            requiredFlags: UInt32(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue))
        if context.core.bindImageMemory(context.device, image, allocation.memory, allocation.offset) != VK_SUCCESS {
            throw RHIError.outOfMemory
        }

        let aspect: VkImageAspectFlags = VulkanFormats.isDepth(descriptor.format)
            ? UInt32(VK_IMAGE_ASPECT_DEPTH_BIT.rawValue) : UInt32(VK_IMAGE_ASPECT_COLOR_BIT.rawValue)
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = VulkanFormats.vkFormat(descriptor.format)
        viewInfo.subresourceRange = VkImageSubresourceRange(aspectMask: aspect, baseMipLevel: 0,
                                                           levelCount: VK_REMAINING_MIP_LEVELS,
                                                           baseArrayLayer: 0,
                                                           layerCount: VK_REMAINING_ARRAY_LAYERS)
        guard let view = vkWithOutHandle({
            context.core.createImageView(context.device, &viewInfo, nil, $0)
        }) else { throw RHIError.outOfMemory }

        registries.textures[handle.id] = VulkanTextureRecord(
            image: image, allocation: allocation, view: view,
            format: descriptor.format, width: descriptor.width, height: descriptor.height,
            depth: descriptor.depth, mipLevels: UInt32(max(1, descriptor.mipLevels)),
            usage: descriptor.usage, isSwapchain: false, layout: VK_IMAGE_LAYOUT_UNDEFINED)
    }

    func destroyTexture(_ handle: Texture) {
        guard var record = registries.textures.removeValue(forKey: handle.id) else { return }
        guard !record.isSwapchain else { return }
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
        descriptor.code.withUnsafeBytes { bytes in
            info.pCode = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self)
        }
        guard let module = vkWithOutHandle({
            context.core.createShaderModule(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }
        registries.shaderModules[handle.id] = VulkanShaderModuleRecord(module: module, stage: descriptor.stage)
    }

    func destroyShaderModule(_ handle: ShaderModule) {
        guard let record = registries.shaderModules.removeValue(forKey: handle.id) else { return }
        context.core.destroyShaderModule(context.device, record.module, nil)
    }

    // MARK: Usage flag mapping

    private static func bufferUsageFlags(_ usage: BufferUsage) -> VkBufferUsageFlags {
        var flags: VkBufferUsageFlags = 0
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
        var flags: VkImageUsageFlags = 0
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
