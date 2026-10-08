#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws {
        guard let module = registries.shaderModules[descriptor.shader.id], module.stage == .compute,
              let layout = registries.pipelineLayouts[descriptor.layout.id] else {
            throw RHIError.invalidArgument("unknown compute shader or pipeline layout")
        }
        let arena = VulkanScratch()
        var stage = VkPipelineShaderStageCreateInfo()
        stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
        stage.module = module.module
        stage.pName = arena.string(module.entryPoint)
        var info = VkComputePipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
        info.stage = stage
        info.layout = layout.native
        var pipeline: VkPipeline = vkNull()
        let result = withExtendedLifetime(arena) {
            context.resources.createComputePipelines(context.device, vkNull(), 1, &info, nil, &pipeline)
        }
        guard result == VK_SUCCESS else { throw RHIError.invalidArgument("Vulkan compute pipeline failed: \(result)") }
        registries.computePipelines[handle.id] = VulkanComputePipelineRecord(pipeline: pipeline, descriptor: descriptor)
    }

    func destroyComputePipeline(_ handle: ComputePipeline) {
        guard let record = registries.computePipelines.removeValue(forKey: handle.id) else { return }
        context.resources.destroyPipeline(context.device, record.pipeline, nil)
    }

    func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws {
        guard let layout = registries.pipelineLayouts[descriptor.layout.id],
              let vertex = registries.shaderModules[descriptor.vertex.id], vertex.stage == .vertex else {
            throw RHIError.invalidArgument("unknown graphics shader or pipeline layout")
        }
        try rhiRequire(descriptor.colorAttachments.count <= 8, "at most eight color attachments are supported")
        if descriptor.rasterization.fillMode == .lines && !context.features.nonSolidFill {
            throw RHIError.unsupportedFeature("Vulkan non-solid fill is unsupported")
        }
        let arena = VulkanScratch()
        var stages = [try shaderStage(vertex, arena: arena)]
        if let fragment = descriptor.fragment {
            guard let shader = registries.shaderModules[fragment.id], shader.stage == .fragment else {
                throw RHIError.invalidArgument("unknown fragment shader")
            }
            stages.append(try shaderStage(shader, arena: arena))
        }
        let pipeline = try graphicsPipeline(descriptor, nativeLayout: layout.native, stages: stages, arena: arena)
        registries.graphicsPipelines[handle.id] = VulkanGraphicsPipelineRecord(pipeline: pipeline, descriptor: descriptor)
    }

    func destroyGraphicsPipeline(_ handle: GraphicsPipeline) {
        guard let record = registries.graphicsPipelines.removeValue(forKey: handle.id) else { return }
        context.resources.destroyPipeline(context.device, record.pipeline, nil)
    }

    func shaderStage(_ module: VulkanShaderModuleRecord, arena: VulkanScratch) throws -> VkPipelineShaderStageCreateInfo {
        var stage = VkPipelineShaderStageCreateInfo()
        stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stage.stage = VkShaderStageFlagBits(rawValue: VulkanLayoutFormats.stageFlags(module.stage))
        stage.module = module.module
        stage.pName = arena.string(module.entryPoint)
        return stage
    }

    func graphicsPipeline(_ descriptor: GraphicsPipelineDescriptor, nativeLayout: VkPipelineLayout,
                          stages: [VkPipelineShaderStageCreateInfo], arena: VulkanScratch) throws -> VkPipeline {
        var vertexInput = VkPipelineVertexInputStateCreateInfo()
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        if let layout = descriptor.vertexLayout {
            try rhiRequire(layout.attributes.count <= 32 && layout.bufferLayouts.count <= 8, "vertex input capacity exceeded")
            try rhiRequire(layout.bufferLayouts.allSatisfy { $0.stride > 0 }, "vertex strides must be positive")
            try rhiRequire(layout.attributes.allSatisfy { $0.offset >= 0 && Int($0.bufferIndex) < layout.bufferLayouts.count },
                           "vertex attribute references an invalid buffer or offset")
            let bindings = layout.bufferLayouts.enumerated().map {
                VkVertexInputBindingDescription(binding: UInt32($0.offset), stride: UInt32($0.element.stride),
                    inputRate: $0.element.stepRate == .perInstance ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX)
            }
            let attributes = layout.attributes.map {
                VkVertexInputAttributeDescription(location: $0.location, binding: $0.bufferIndex,
                    format: VulkanFormats.vkVertexFormat($0.format), offset: UInt32($0.offset))
            }
            vertexInput.vertexBindingDescriptionCount = UInt32(bindings.count)
            vertexInput.pVertexBindingDescriptions = arena.store(bindings)
            vertexInput.vertexAttributeDescriptionCount = UInt32(attributes.count)
            vertexInput.pVertexAttributeDescriptions = arena.store(attributes)
        }
        var assembly = VkPipelineInputAssemblyStateCreateInfo()
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        assembly.topology = VulkanFormats.vkPrimitiveTopology(descriptor.primitive)
        var raster = VkPipelineRasterizationStateCreateInfo()
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        raster.polygonMode = descriptor.rasterization.fillMode == .lines ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL
        raster.cullMode = VulkanFormats.vkCullMode(descriptor.rasterization.cullMode)
        raster.frontFace = VulkanFormats.vkFrontFace(descriptor.rasterization.frontWinding)
        raster.lineWidth = 1
        var viewport = VkPipelineViewportStateCreateInfo()
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewport.viewportCount = 1
        viewport.scissorCount = 1
        var samples = VkPipelineMultisampleStateCreateInfo()
        samples.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        samples.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
        var depth = VkPipelineDepthStencilStateCreateInfo()
        depth.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        if let state = descriptor.depthStencil, descriptor.depthFormat != nil {
            depth.depthTestEnable = VK_TRUE
            depth.depthWriteEnable = state.depthWriteEnabled ? VK_TRUE : VK_FALSE
            depth.depthCompareOp = VulkanFormats.vkCompareOp(state.depthCompare)
        }
        let blends = descriptor.colorAttachments.map { attachment in
            VkPipelineColorBlendAttachmentState(blendEnable: attachment.blend.enabled ? VK_TRUE : VK_FALSE,
                srcColorBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.sourceColorBlendFactor),
                dstColorBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.destinationColorBlendFactor),
                colorBlendOp: VulkanFormats.vkBlendOp(attachment.blend.colorBlendOperation),
                srcAlphaBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.sourceAlphaBlendFactor),
                dstAlphaBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.destinationAlphaBlendFactor),
                alphaBlendOp: VulkanFormats.vkBlendOp(attachment.blend.alphaBlendOperation), colorWriteMask: 15)
        }
        var blend = VkPipelineColorBlendStateCreateInfo()
        blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        blend.attachmentCount = UInt32(blends.count)
        blend.pAttachments = arena.store(blends)
        var dynamic = VkPipelineDynamicStateCreateInfo()
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamic.dynamicStateCount = 2
        dynamic.pDynamicStates = arena.store([VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR])
        var rendering = VkPipelineRenderingCreateInfo()
        rendering.sType = VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO
        rendering.colorAttachmentCount = UInt32(descriptor.colorAttachments.count)
        rendering.pColorAttachmentFormats = arena.store(descriptor.colorAttachments.map { VulkanFormats.vkFormat($0.format) })
        rendering.depthAttachmentFormat = descriptor.depthFormat.map(VulkanFormats.vkFormat) ?? VK_FORMAT_UNDEFINED
        rendering.stencilAttachmentFormat = descriptor.stencilFormat.map(VulkanFormats.vkFormat) ?? VK_FORMAT_UNDEFINED
        var info = VkGraphicsPipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        info.pNext = UnsafeRawPointer(arena.make(rendering))
        info.stageCount = UInt32(stages.count)
        info.pStages = arena.store(stages)
        let isMesh = stages.contains { $0.stage == VK_SHADER_STAGE_MESH_BIT_EXT }
        if !isMesh {
            info.pVertexInputState = UnsafePointer(arena.make(vertexInput))
            info.pInputAssemblyState = UnsafePointer(arena.make(assembly))
        }
        info.pRasterizationState = UnsafePointer(arena.make(raster))
        info.pViewportState = UnsafePointer(arena.make(viewport))
        info.pMultisampleState = UnsafePointer(arena.make(samples))
        info.pDepthStencilState = UnsafePointer(arena.make(depth))
        info.pColorBlendState = UnsafePointer(arena.make(blend))
        info.pDynamicState = UnsafePointer(arena.make(dynamic))
        info.layout = nativeLayout
        var pipeline: VkPipeline = vkNull()
        let result = withExtendedLifetime(arena) {
            context.resources.createGraphicsPipelines(context.device, vkNull(), 1, &info, nil, &pipeline)
        }
        guard result == VK_SUCCESS else { throw RHIError.invalidArgument("Vulkan graphics pipeline failed: \(result)") }
        return pipeline
    }
}
#endif
