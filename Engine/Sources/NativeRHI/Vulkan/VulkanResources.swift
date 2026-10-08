// NativeRHI Vulkan — concrete resource records and the registry that maps
// frontend handles to Vulkan objects. Kept separate from the backend so the
// device type stays small (one responsibility per type).

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

struct VulkanBufferRecord {
    let buffer: VkBuffer
    let allocation: VulkanMemoryAllocation
    let size: Int
    let usage: BufferUsage
}

struct VulkanTextureRecord {
    let image: VkImage
    let allocation: VulkanMemoryAllocation?
    let view: VkImageView
    let format: TextureFormat
    let width: Int
    let height: Int
    let depth: Int
    var dimension: TextureDimension = .texture2D
    var layers: UInt32 = 1
    let mipLevels: UInt32
    let usage: TextureUsage
    /// True for images acquired from the swapchain (memory owned by Vulkan).
    let isSwapchain: Bool
    /// Current layout, tracked for barrier emission.
    var layout: VkImageLayout
}

struct VulkanSamplerRecord {
    let sampler: VkSampler
}

struct VulkanShaderModuleRecord {
    let module: VkShaderModule
    let stage: ShaderStage
    let entryPoint: String
    let specializationConstants: [ShaderSpecializationConstant]
}

struct VulkanGraphicsPipelineRecord {
    let pipeline: VkPipeline
    let descriptor: GraphicsPipelineDescriptor
}

struct VulkanComputePipelineRecord {
    let pipeline: VkPipeline
    let descriptor: ComputePipelineDescriptor
}

struct VulkanBindingSetRecord {
    let descriptorSet: VkDescriptorSet
    let layoutID: UInt32
}

struct VulkanPushRange {
    let declaration: PushConstantRange
    let offset: UInt32
}

struct VulkanPipelineLayoutRecord {
    let native: VkPipelineLayout
    let descriptor: PipelineLayoutDescriptor
    let pushRanges: [VulkanPushRange]
}

final class VulkanRegistries {
    var buffers: [UInt32: VulkanBufferRecord] = [:]
    var textures: [UInt32: VulkanTextureRecord] = [:]
    var samplers: [UInt32: VulkanSamplerRecord] = [:]
    var shaderModules: [UInt32: VulkanShaderModuleRecord] = [:]
    var graphicsPipelines: [UInt32: VulkanGraphicsPipelineRecord] = [:]
    var computePipelines: [UInt32: VulkanComputePipelineRecord] = [:]
    var bindingSets: [UInt32: VulkanBindingSetRecord] = [:]
    var bindingLayouts: [UInt32: VkDescriptorSetLayout] = [:]
    var pipelineLayouts: [UInt32: VulkanPipelineLayoutRecord] = [:]
    var meshPipelines: [UInt32: VulkanMeshPipelineRecord] = [:]
    var accelerationStructures: [UInt32: VulkanAccelerationRecord] = [:]
    /// Internal-handle counter for backend-owned resources (upload chunks,
    /// swapchain drawables); starts above the frontend's low IDs.
    private var internalID: UInt32 = 0x8000_0000

    init() {}

    func nextInternalID() -> UInt32 {
        let id = internalID
        internalID += 1
        return id
    }
}

#endif // canImport(CVulkanHeaders)
