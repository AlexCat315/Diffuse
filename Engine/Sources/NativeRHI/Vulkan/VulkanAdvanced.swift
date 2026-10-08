#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders

struct VulkanAdvancedCommands {
    let bufferAddress: CVulkanHeaders.PFN_vkGetBufferDeviceAddress
    let createStructure: CVulkanHeaders.PFN_vkCreateAccelerationStructureKHR?
    let destroyStructure: CVulkanHeaders.PFN_vkDestroyAccelerationStructureKHR?
    let buildSizes: CVulkanHeaders.PFN_vkGetAccelerationStructureBuildSizesKHR?
    let structureAddress: CVulkanHeaders.PFN_vkGetAccelerationStructureDeviceAddressKHR?
    let build: CVulkanHeaders.PFN_vkCmdBuildAccelerationStructuresKHR?
    let drawMesh: CVulkanHeaders.PFN_vkCmdDrawMeshTasksEXT?
    let scratchAlignment: VkDeviceSize

    init(_ resolve: VulkanResolver, features: VulkanFeatureSupport, commands: VulkanInstanceCommands, physicalDevice: VkPhysicalDevice) {
        bufferAddress = vkFunction(resolve, "vkGetBufferDeviceAddress")
        func optional<Value>(_ name: String, enabled: Bool) -> Value? {
            guard enabled, let pointer = resolve(name) else { return nil }
            return unsafeBitCast(pointer, to: Value.self)
        }
        createStructure = optional("vkCreateAccelerationStructureKHR", enabled: features.accelerationStructures)
        destroyStructure = optional("vkDestroyAccelerationStructureKHR", enabled: features.accelerationStructures)
        buildSizes = optional("vkGetAccelerationStructureBuildSizesKHR", enabled: features.accelerationStructures)
        structureAddress = optional("vkGetAccelerationStructureDeviceAddressKHR", enabled: features.accelerationStructures)
        build = optional("vkCmdBuildAccelerationStructuresKHR", enabled: features.accelerationStructures)
        drawMesh = optional("vkCmdDrawMeshTasksEXT", enabled: features.mesh)
        var properties = VkPhysicalDeviceAccelerationStructurePropertiesKHR()
        properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR
        var info = VkPhysicalDeviceProperties2()
        info.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        withUnsafeMutablePointer(to: &properties) { pointer in
            info.pNext = UnsafeMutableRawPointer(pointer)
            commands.getPhysicalDeviceProperties2(physicalDevice, &info)
        }
        scratchAlignment = VkDeviceSize(max(256, properties.minAccelerationStructureScratchOffsetAlignment))
    }
}
#endif
