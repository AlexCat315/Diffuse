// NativeRHI Vulkan — graphics/compute pipelines and descriptor binding sets.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    // MARK: Binding sets

    func registerBindingSet(_ handle: BindingSet,
                            layoutEntries: [BindingLayoutEntry],
                            setEntries: [BindingSetEntry]) throws {
        // Build the descriptor set layout from the layout entries.
        var bindings: [VkDescriptorSetLayoutBinding] = layoutEntries.map { entry in
            VkDescriptorSetLayoutBinding(
                binding: entry.slot,
                descriptorType: Self.descriptorType(entry.type),
                descriptorCount: max(1, entry.arraySize),
                stageFlags: Self.stageFlags(entry.stage),
                pImmutableSamplers: nil)
        }
        var layoutInfo = VkDescriptorSetLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
        bindings.withUnsafeMutableBufferPointer { layoutInfo.pBindings = UnsafePointer($0.baseAddress) }
        layoutInfo.bindingCount = UInt32(bindings.count)
        guard let setLayout = vkWithOutHandle({
            context.resources.createDescriptorSetLayout(context.device, &layoutInfo, nil, $0)
        }) else {
            throw RHIError.outOfMemory
        }

        var layouts: [VkDescriptorSetLayout?] = [setLayout]
        var allocInfo = VkDescriptorSetAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
        allocInfo.descriptorPool = descriptorPool
        allocInfo.descriptorSetCount = 1
        layouts.withUnsafeMutableBufferPointer { allocInfo.pSetLayouts = UnsafePointer($0.baseAddress) }
        var descriptorSet: VkDescriptorSet = vkNull()
        guard context.resources.allocateDescriptorSets(context.device, &allocInfo, &descriptorSet) == VK_SUCCESS else {
            context.resources.destroyDescriptorSetLayout(context.device, setLayout, nil)
            throw RHIError.outOfMemory
        }
        let set = descriptorSet

        try writeDescriptors(set: set, layoutEntries: layoutEntries, setEntries: setEntries)
        registries.bindingSets[handle.id] = VulkanBindingSetRecord(
            descriptorSet: set, setLayout: setLayout)
    }

    func unregisterBindingSet(_ handle: BindingSet) {
        guard let record = registries.bindingSets.removeValue(forKey: handle.id) else { return }
        context.resources.destroyDescriptorSetLayout(context.device, record.setLayout, nil)
    }

    private func writeDescriptors(set: VkDescriptorSet,
                                   layoutEntries: [BindingLayoutEntry],
                                   setEntries: [BindingSetEntry]) throws {
        for entry in setEntries {
            let layout = layoutEntries.first { $0.slot == entry.slot }
            guard let layout else {
                throw RHIError.layoutMismatch("binding entry at slot \(entry.slot) has no layout")
            }
            switch entry.resource {
            case .sampler(let sampler):
                guard let record = registries.samplers[sampler.id] else {
                    throw RHIError.invalidArgument("unknown sampler")
                }
                var imageInfo = VkDescriptorImageInfo()
                imageInfo.sampler = record.sampler
                var write = VkWriteDescriptorSet()
                write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                write.dstSet = set
                write.dstBinding = entry.slot
                write.descriptorCount = 1
                write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
                withUnsafeMutablePointer(to: &imageInfo) { write.pImageInfo = UnsafePointer($0) }
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)

            case .texture(let texture), .storageTexture(let texture):
                guard let record = registries.textures[texture.id] else {
                    throw RHIError.invalidArgument("unknown texture")
                }
                var imageInfo = VkDescriptorImageInfo()
                imageInfo.imageView = record.view
                imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                var write = VkWriteDescriptorSet()
                write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                write.dstSet = set
                write.dstBinding = entry.slot
                write.descriptorCount = 1
                write.descriptorType = layout.type == .storageTexture
                    ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE : VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
                withUnsafeMutablePointer(to: &imageInfo) { write.pImageInfo = UnsafePointer($0) }
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)

            case .uniformBuffer(let buffer, let offset), .storageBuffer(let buffer, let offset):
                guard let record = registries.buffers[buffer.id] else {
                    throw RHIError.invalidArgument("unknown buffer")
                }
                var bufferInfo = VkDescriptorBufferInfo()
                bufferInfo.buffer = record.buffer
                bufferInfo.offset = VkDeviceSize(offset)
                bufferInfo.range = VkDeviceSize(record.size)
                var write = VkWriteDescriptorSet()
                write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                write.dstSet = set
                write.dstBinding = entry.slot
                write.descriptorCount = 1
                write.descriptorType = layout.type == .storageBuffer
                    ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER : VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                withUnsafeMutablePointer(to: &bufferInfo) { write.pBufferInfo = UnsafePointer($0) }
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)

            case .accelerationStructure:
                throw RHIError.unsupportedFeature("ray tracing acceleration structures are not available")
            }
        }
    }

    // MARK: Graphics pipeline

    func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws {
        if let vertexLayout = descriptor.vertexLayout {
            guard vertexLayout.attributes.count <= 32 else {
                throw RHIError.invalidArgument("more than 32 vertex attributes")
            }
            guard vertexLayout.bufferLayouts.count <= 8 else {
                throw RHIError.invalidArgument("more than 8 vertex buffer layouts")
            }
        }
        guard let vs = registries.shaderModules[descriptor.vertex.id] else {
            throw RHIError.invalidArgument("unknown vertex shader")
        }

        var setLayouts: [VkDescriptorSetLayout?] = registries.bindingSets.values.map(\.setLayout)
        var pipelineLayoutInfo = VkPipelineLayoutCreateInfo()
        pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        pipelineLayoutInfo.setLayoutCount = UInt32(setLayouts.count)
        setLayouts.withUnsafeMutableBufferPointer { pipelineLayoutInfo.pSetLayouts = $0.baseAddress.map { UnsafePointer($0) } }
        guard let pipelineLayout = vkWithOutHandle({
            context.resources.createPipelineLayout(context.device, &pipelineLayoutInfo, nil, $0)
        }) else { throw RHIError.outOfMemory }

        let renderPass = try renderPass(for: descriptor)

        var stages: [VkPipelineShaderStageCreateInfo] = []
        var vertexStage = VkPipelineShaderStageCreateInfo()
        vertexStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        vertexStage.stage = VK_SHADER_STAGE_VERTEX_BIT
        vertexStage.module = vs.module
        vertexStage.pName = vkExtName("main")
        stages.append(vertexStage)
        if let fragment = descriptor.fragment, let fs = registries.shaderModules[fragment.id] {
            var fragmentStage = VkPipelineShaderStageCreateInfo()
            fragmentStage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            fragmentStage.stage = VK_SHADER_STAGE_FRAGMENT_BIT
            fragmentStage.module = fs.module
            fragmentStage.pName = vkExtName("main")
            stages.append(fragmentStage)
        }

        var vertexInput = VkPipelineVertexInputStateCreateInfo()
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        var vertexBindings: [VkVertexInputBindingDescription] = []
        var vertexAttribs: [VkVertexInputAttributeDescription] = []
        if let layout = descriptor.vertexLayout {
            vertexBindings = layout.bufferLayouts.enumerated().map { index, entry in
                VkVertexInputBindingDescription(
                    binding: UInt32(index), stride: UInt32(entry.stride),
                    inputRate: entry.stepRate == .perInstance
                        ? VK_VERTEX_INPUT_RATE_INSTANCE : VK_VERTEX_INPUT_RATE_VERTEX)
            }
            vertexAttribs = layout.attributes.map { attr in
                VkVertexInputAttributeDescription(
                    location: attr.location, binding: attr.bufferIndex,
                    format: VulkanFormats.vkVertexFormat(attr.format), offset: UInt32(attr.offset))
            }
        }
        vertexInput.vertexBindingDescriptionCount = UInt32(vertexBindings.count)
        vertexBindings.withUnsafeBufferPointer { vertexInput.pVertexBindingDescriptions = $0.baseAddress }
        vertexInput.vertexAttributeDescriptionCount = UInt32(vertexAttribs.count)
        vertexAttribs.withUnsafeBufferPointer { vertexInput.pVertexAttributeDescriptions = $0.baseAddress }

        var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        inputAssembly.topology = VulkanFormats.vkPrimitiveTopology(descriptor.primitive)

        var raster = VkPipelineRasterizationStateCreateInfo()
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        raster.polygonMode = descriptor.rasterization.fillMode == .lines
            ? VK_POLYGON_MODE_LINE : VK_POLYGON_MODE_FILL
        raster.cullMode = VulkanFormats.vkCullMode(descriptor.rasterization.cullMode)
        raster.frontFace = VulkanFormats.vkFrontFace(descriptor.rasterization.frontWinding)
        raster.lineWidth = 1

        var viewportState = VkPipelineViewportStateCreateInfo()
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewportState.viewportCount = 1
        viewportState.scissorCount = 1

        var multisample = VkPipelineMultisampleStateCreateInfo()
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

        var depthStencil = VkPipelineDepthStencilStateCreateInfo()
        depthStencil.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        if let ds = descriptor.depthStencil {
            depthStencil.depthTestEnable = VK_TRUE
            depthStencil.depthWriteEnable = ds.depthWriteEnabled ? VK_TRUE : VK_FALSE
            depthStencil.depthCompareOp = VulkanFormats.vkCompareOp(ds.depthCompare)
        }

        var colorBlendAttachments: [VkPipelineColorBlendAttachmentState] =
            descriptor.colorAttachments.map { attachment in
                VkPipelineColorBlendAttachmentState(
                    blendEnable: attachment.blend.enabled ? VK_TRUE : VK_FALSE,
                    srcColorBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.sourceColorBlendFactor),
                    dstColorBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.destinationColorBlendFactor),
                    colorBlendOp: VulkanFormats.vkBlendOp(attachment.blend.colorBlendOperation),
                    srcAlphaBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.sourceAlphaBlendFactor),
                    dstAlphaBlendFactor: VulkanFormats.vkBlendFactor(attachment.blend.destinationAlphaBlendFactor),
                    alphaBlendOp: VulkanFormats.vkBlendOp(attachment.blend.alphaBlendOperation),
                    colorWriteMask: VkColorComponentFlags(VK_COLOR_COMPONENT_R_BIT.rawValue
                        | VK_COLOR_COMPONENT_G_BIT.rawValue
                        | VK_COLOR_COMPONENT_B_BIT.rawValue
                        | VK_COLOR_COMPONENT_A_BIT.rawValue))
            }
        var colorBlend = VkPipelineColorBlendStateCreateInfo()
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        colorBlend.logicOpEnable = VK_FALSE
        colorBlendAttachments.withUnsafeBufferPointer { colorBlend.pAttachments = $0.baseAddress }
        colorBlend.attachmentCount = UInt32(colorBlendAttachments.count)

        var info = VkGraphicsPipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        stages.withUnsafeBufferPointer { info.pStages = $0.baseAddress }
        info.stageCount = UInt32(stages.count)
        info.pVertexInputState = withUnsafeMutablePointer(to: &vertexInput) { UnsafePointer($0) }
        info.pInputAssemblyState = withUnsafeMutablePointer(to: &inputAssembly) { UnsafePointer($0) }
        info.pRasterizationState = withUnsafeMutablePointer(to: &raster) { UnsafePointer($0) }
        info.pViewportState = withUnsafeMutablePointer(to: &viewportState) { UnsafePointer($0) }
        info.pMultisampleState = withUnsafeMutablePointer(to: &multisample) { UnsafePointer($0) }
        info.pDepthStencilState = withUnsafeMutablePointer(to: &depthStencil) { UnsafePointer($0) }
        info.pColorBlendState = withUnsafeMutablePointer(to: &colorBlend) { UnsafePointer($0) }
        info.layout = pipelineLayout
        info.renderPass = renderPass
        info.subpass = 0

        guard let pipeline = vkWithOutHandle({
            context.resources.createGraphicsPipelines(context.device, vkNull(), 1, &info, nil, $0)
        }) else {
            throw RHIError.outOfMemory
        }
        registries.graphicsPipelines[handle.id] = VulkanGraphicsPipelineRecord(
            pipeline: pipeline, layout: pipelineLayout, renderPass: renderPass)
    }

    func destroyGraphicsPipeline(_ handle: GraphicsPipeline) {
        guard let record = registries.graphicsPipelines.removeValue(forKey: handle.id) else { return }
        context.resources.destroyPipeline(context.device, record.pipeline, nil)
        context.resources.destroyPipelineLayout(context.device, record.layout, nil)
    }

    // MARK: Compute pipeline

    func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws {
        guard let module = registries.shaderModules[descriptor.shader.id] else {
            throw RHIError.invalidArgument("unknown compute shader")
        }
        var setLayouts: [VkDescriptorSetLayout?] = registries.bindingSets.values.map(\.setLayout)
        var layoutInfo = VkPipelineLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        layoutInfo.setLayoutCount = UInt32(setLayouts.count)
        setLayouts.withUnsafeMutableBufferPointer { layoutInfo.pSetLayouts = $0.baseAddress.map { UnsafePointer($0) } }
        guard let pipelineLayout = vkWithOutHandle({
            context.resources.createPipelineLayout(context.device, &layoutInfo, nil, $0)
        }) else { throw RHIError.outOfMemory }

        var stage = VkPipelineShaderStageCreateInfo()
        stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
        stage.module = module.module
        stage.pName = vkExtName("main")

        var info = VkComputePipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
        info.stage = stage
        info.layout = pipelineLayout

        guard let pipeline = vkWithOutHandle({
            context.resources.createComputePipelines(context.device, vkNull(), 1, &info, nil, $0)
        }) else {
            throw RHIError.outOfMemory
        }
        registries.computePipelines[handle.id] = VulkanComputePipelineRecord(
            pipeline: pipeline, layout: pipelineLayout)
    }

    func destroyComputePipeline(_ handle: ComputePipeline) {
        guard let record = registries.computePipelines.removeValue(forKey: handle.id) else { return }
        context.resources.destroyPipeline(context.device, record.pipeline, nil)
        context.resources.destroyPipelineLayout(context.device, record.layout, nil)
    }

    // MARK: Helpers

    private static func descriptorType(_ type: BindingType) -> VkDescriptorType {
        switch type {
        case .sampler: return VK_DESCRIPTOR_TYPE_SAMPLER
        case .texture: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
        case .storageTexture: return VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
        case .uniformBuffer: return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        case .storageBuffer: return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
        case .accelerationStructure: return VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR
        }
    }

    private static func stageFlags(_ stage: ShaderStage) -> VkShaderStageFlags {
        switch stage {
        case .vertex: return VkShaderStageFlags(VK_SHADER_STAGE_VERTEX_BIT.rawValue)
        case .fragment: return VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
        case .compute: return VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)
        case .task: return VkShaderStageFlags(VK_SHADER_STAGE_TASK_BIT_EXT.rawValue)
        case .mesh: return VkShaderStageFlags(VK_SHADER_STAGE_MESH_BIT_EXT.rawValue)
        }
    }

    private func renderPass(for descriptor: GraphicsPipelineDescriptor) throws -> VkRenderPass {
        var key = "color:"
        for attachment in descriptor.colorAttachments { key += "\(attachment.format);" }
        if let depth = descriptor.depthFormat { key += "depth:\(depth);" }
        if let cached = registries.renderPasses[key] { return cached }

        var attachments: [VkAttachmentDescription] = []
        var colorRefs: [VkAttachmentReference] = []
        for attachment in descriptor.colorAttachments {
            attachments.append(VkAttachmentDescription(
                flags: 0, format: VulkanFormats.vkFormat(attachment.format),
                samples: VK_SAMPLE_COUNT_1_BIT,
                loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
                storeOp: VK_ATTACHMENT_STORE_OP_STORE,
                stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                finalLayout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
            colorRefs.append(VkAttachmentReference(
                attachment: UInt32(colorRefs.count), layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL))
        }

        var depthAttachmentIndex: UInt32?
        if let depthFormat = descriptor.depthFormat {
            depthAttachmentIndex = UInt32(attachments.count)
            attachments.append(VkAttachmentDescription(
                flags: 0, format: VulkanFormats.vkFormat(depthFormat),
                samples: VK_SAMPLE_COUNT_1_BIT,
                loadOp: VK_ATTACHMENT_LOAD_OP_CLEAR,
                storeOp: VK_ATTACHMENT_STORE_OP_STORE,
                stencilLoadOp: VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                stencilStoreOp: VK_ATTACHMENT_STORE_OP_DONT_CARE,
                initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
                finalLayout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL))
        }

        var subpass = VkSubpassDescription()
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
        subpass.colorAttachmentCount = UInt32(colorRefs.count)
        colorRefs.withUnsafeBufferPointer { subpass.pColorAttachments = $0.baseAddress }
        if let depthIndex = depthAttachmentIndex {
            var depthValue = VkAttachmentReference(attachment: depthIndex,
                                                   layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
            subpass.pDepthStencilAttachment = withUnsafeMutablePointer(to: &depthValue) {
                UnsafePointer($0)
            }
        }

        var info = VkRenderPassCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
        attachments.withUnsafeBufferPointer { info.pAttachments = $0.baseAddress }
        info.attachmentCount = UInt32(attachments.count)
        info.subpassCount = 1
        withUnsafeMutablePointer(to: &subpass) { info.pSubpasses = UnsafePointer($0) }

        guard let renderPass = vkWithOutHandle({
            context.resources.createRenderPass(context.device, &info, nil, $0)
        }) else { throw RHIError.outOfMemory }
        registries.renderPasses[key] = renderPass
        return renderPass
    }
}

#endif // canImport(CVulkanHeaders)
