// NativeRHI Vulkan — concrete RHIBackend.
//
// Owns the Vulkan device, the block suballocator, resource registries, the
// per-frame command pools/fences, the timeline-semaphore map and the swapchain.
// All Vulkan work is driven off the frozen RHIBackend contract; this file wires
// that contract to the loaded function-pointer table.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

final class VulkanBackend: RHIBackend {
    let api: GraphicsAPI = .vulkan
    let deviceName: String

    let loader: VulkanLoader
    let context: VulkanContext
    let config: DeviceConfig
    let capabilitiesValue: Capabilities

    let allocator: VulkanMemoryAllocator
    let registries: VulkanRegistries
    let descriptorPool: VkDescriptorPool

    var presentation = VulkanPresentationState()
    var surface: VkSurfaceKHR?
    var swapchain: VulkanSwapchain?

    var frames: [VulkanFrame] = []
    var activeSlot: Int = 0
    let submissionStatus = VulkanSubmissionStatus()
    var timelineSemaphores: [UInt32: VkSemaphore] = [:]
    var chunkBufferIDs: [ObjectIdentifier: UInt32] = [:]

    /// One-shot command pool/fence for immediate (out-of-frame) transfers.
    var scratchCommandPool: VkCommandPool?
    var scratchFence: VkFence?

    let lock = NSLock()

    // Convenience aliases so transfer/render extensions can name command
    // groups directly instead of threading `context.` through every call.
    var draw: VulkanDeviceDrawCommands { context.draw }
    var sync: VulkanDeviceSyncCommands { context.sync }

    // MARK: Construction

    /// Real availability: the linked loader enumerates at least one physical
    /// device (ICD). Cached in `VulkanRuntime`.
    static var isAvailable: Bool { VulkanRuntime.isAvailable }

    static func make(config: DeviceConfig) throws -> VulkanBackend {
        guard let loader = VulkanLoader.open() else {
            throw RHIError.unsupportedBackend("The linked Vulkan loader entry point was not found")
        }
        let context: VulkanContext
        do {
            context = try VulkanDeviceSetup.make(loader: loader,
                                                 enableValidation: config.enableValidation)
        } catch let error as RHIError {
            throw error
        } catch {
            throw RHIError.unsupportedBackend("Vulkan device creation failed: \(error)")
        }

        var memProps = VkPhysicalDeviceMemoryProperties()
        context.instanceCommands.getPhysicalDeviceMemoryProperties(context.physicalDevice, &memProps)
        let allocator = VulkanMemoryAllocator(context: context, memoryProperties: memProps)

        let descriptorPool = try createDescriptorPool(context: context)

        return VulkanBackend(
            loader: loader,
            context: context,
            config: config,
            allocator: allocator,
            registries: VulkanRegistries(),
            descriptorPool: descriptorPool
        )
    }

    private init(
        loader: VulkanLoader,
        context: VulkanContext,
        config: DeviceConfig,
        allocator: VulkanMemoryAllocator,
        registries: VulkanRegistries,
        descriptorPool: VkDescriptorPool
    ) {
        self.loader = loader
        self.context = context
        self.config = config
        self.deviceName = context.deviceName
        self.allocator = allocator
        self.registries = registries
        self.descriptorPool = descriptorPool
        self.capabilitiesValue = Self.probeCapabilities(context: context)
    }

    deinit { releaseNativeObjects() }

    func queryCapabilities() -> Capabilities {
        capabilitiesValue
    }

    /// Exposes only completed RHI paths. Adapter extensions are diagnostic.
    private static func probeCapabilities(context: VulkanContext) -> Capabilities {
        return Capabilities {
            $0.graphics = true
            $0.compute = true
            $0.indirectDraw = true
            $0.textures.texture3D = true
            $0.textures.cube = true
            $0.maxQueues = QueueLimits()
            let advanced = context.advanced
            $0.rayTracing.accelerationStructures = context.features.accelerationStructures && advanced.createStructure != nil
                && advanced.destroyStructure != nil && advanced.buildSizes != nil && advanced.structureAddress != nil && advanced.build != nil
            $0.rayTracing.computeRayQuery = $0.rayTracing.accelerationStructures && context.features.rayQuery
            $0.meshShading.mesh = context.features.mesh && advanced.drawMesh != nil
            $0.meshShading.task = $0.meshShading.mesh && context.features.task
        }
    }

    func queryAdapterCapabilities() -> AdapterCapabilities {
        // Extension presence is diagnostic only. The logical device currently
        // does not enable the RT/mesh feature chains or encode these commands.
        var result = AdapterCapabilities()
        let ext = context.extensions
        result.rayTracing = ext.contains("VK_KHR_acceleration_structure")
            && (ext.contains("VK_KHR_ray_query") || ext.contains("VK_KHR_ray_tracing_pipeline"))
        result.meshShading = ext.contains("VK_EXT_mesh_shader")
        return result
    }

    private static func contextPhysicalDeviceMemoryProperties(_ context: VulkanContext)
        -> VkPhysicalDeviceMemoryProperties {
        var props = VkPhysicalDeviceMemoryProperties()
        context.instanceCommands.getPhysicalDeviceMemoryProperties(context.physicalDevice, &props)
        return props
    }

    private static func createDescriptorPool(context: VulkanContext) throws -> VkDescriptorPool {
        var poolSizes: [VkDescriptorPoolSize] = [
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 256),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, descriptorCount: 256),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: 256),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, descriptorCount: 256),
            VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: 64),
        ]
        if context.features.accelerationStructures { poolSizes.append(VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR, descriptorCount: 256)) }
        let arena = VulkanScratch()
        var info = VkDescriptorPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        info.maxSets = 256
        info.poolSizeCount = UInt32(poolSizes.count)
        info.pPoolSizes = arena.store(poolSizes)
        info.flags = UInt32(VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue)
        guard let pool: VkDescriptorPool = withExtendedLifetime(arena, { vkWithOutHandle({
            _ = context.core.createDescriptorPool(context.device, &info, nil, $0)
        }) }) else {
            throw RHIError.outOfMemory
        }
        return pool
    }
}

#endif // canImport(CVulkanHeaders)
