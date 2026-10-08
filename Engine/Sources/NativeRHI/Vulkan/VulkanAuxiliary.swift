#if canImport(CVulkanHeaders)
import CVulkanHeaders

/// Commands with separate lifetimes from the primary draw encoder table.
struct VulkanAuxiliaryCommands {
    let freeDescriptorSets: CVulkanHeaders.PFN_vkFreeDescriptorSets
    let drawIndirect: CVulkanHeaders.PFN_vkCmdDrawIndirect
    let dispatchIndirect: CVulkanHeaders.PFN_vkCmdDispatchIndirect
    let destroyCommandPool: CVulkanHeaders.PFN_vkDestroyCommandPool

    init(_ resolve: VulkanResolver) {
        freeDescriptorSets = vkFunction(resolve, "vkFreeDescriptorSets")
        drawIndirect = vkFunction(resolve, "vkCmdDrawIndirect")
        dispatchIndirect = vkFunction(resolve, "vkCmdDispatchIndirect")
        destroyCommandPool = vkFunction(resolve, "vkDestroyCommandPool")
    }
}

func vkFunction<Function>(_ resolve: VulkanResolver, _ name: String) -> Function {
    guard let pointer = resolve(name) else { preconditionFailure("Required Vulkan command \(name) is unavailable") }
    return unsafeBitCast(pointer, to: Function.self)
}

enum VulkanLayoutFormats {
    static func stageFlags(_ visibility: ShaderVisibility) -> VkShaderStageFlags {
        visibility.stages.reduce(0) { $0 | stageFlags($1) }
    }

    static func descriptorType(_ type: BindingType) -> VkDescriptorType {
        switch type {
        case .sampler: return VK_DESCRIPTOR_TYPE_SAMPLER
        case .texture: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
        case .storageTexture: return VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
        case .uniformBuffer: return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        case .storageBuffer: return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        case .accelerationStructure: return VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR
        }
    }

    static func stageFlags(_ stage: ShaderStage) -> VkShaderStageFlags {
        switch stage {
        case .vertex: return VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue)
        case .fragment: return VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
        case .compute: return VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)
        case .task: return VkShaderStageFlags(VK_SHADER_STAGE_TASK_BIT_EXT.rawValue)
        case .mesh: return VkShaderStageFlags(VK_SHADER_STAGE_MESH_BIT_EXT.rawValue)
        }
    }
}
#endif
