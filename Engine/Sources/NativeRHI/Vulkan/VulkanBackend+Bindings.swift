#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

extension VulkanBackend {
    func registerBindingLayout(_ handle: BindingLayout, descriptor: BindingLayoutDescriptor) throws {
        let bindings = descriptor.entries.map {
            VkDescriptorSetLayoutBinding(binding: $0.slot, descriptorType: VulkanLayoutFormats.descriptorType($0.type),
                descriptorCount: $0.arraySize, stageFlags: VulkanLayoutFormats.stageFlags($0.visibility), pImmutableSamplers: nil)
        }
        let native: VkDescriptorSetLayout? = bindings.withUnsafeBufferPointer { pointer in
            var info = VkDescriptorSetLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            info.bindingCount = UInt32(bindings.count)
            info.pBindings = pointer.baseAddress
            return vkWithOutHandle { _ = context.resources.createDescriptorSetLayout(context.device, &info, nil, $0) }
        }
        guard let native else { throw RHIError.outOfMemory }
        registries.bindingLayouts[handle.id] = native
    }

    func registerPipelineLayout(_ handle: PipelineLayout, descriptor: PipelineLayoutDescriptor) throws {
        let sets: [VkDescriptorSetLayout?] = try descriptor.setLayouts.map {
            guard let native = registries.bindingLayouts[$0.id] else { throw RHIError.invalidArgument("unknown binding layout") }
            return native
        }
        // Each shader stage's one SPIR-V push block begins at byte zero.
        // Overlapping ranges with disjoint stage masks are legal in Vulkan.
        let ranges = descriptor.pushConstants.map { VulkanPushRange(declaration: $0, offset: 0) }
        let nativeRanges = ranges.map {
            VkPushConstantRange(stageFlags: VulkanLayoutFormats.stageFlags($0.declaration.stage),
                                offset: $0.offset, size: UInt32($0.declaration.byteCount))
        }
        let native: VkPipelineLayout? = sets.withUnsafeBufferPointer { setPointer in
            nativeRanges.withUnsafeBufferPointer { constantPointer in
                var info = VkPipelineLayoutCreateInfo()
                info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
                info.setLayoutCount = UInt32(sets.count)
                info.pSetLayouts = setPointer.baseAddress
                info.pushConstantRangeCount = UInt32(nativeRanges.count)
                info.pPushConstantRanges = constantPointer.baseAddress
                return vkWithOutHandle { _ = context.resources.createPipelineLayout(context.device, &info, nil, $0) }
            }
        }
        guard let native else { throw RHIError.outOfMemory }
        registries.pipelineLayouts[handle.id] = VulkanPipelineLayoutRecord(native: native, descriptor: descriptor, pushRanges: ranges)
    }

    func registerBindingSet(_ handle: BindingSet, layout: BindingLayout,
                            layoutEntries: [BindingLayoutEntry], setEntries: [BindingSetEntry]) throws {
        guard let nativeLayout = registries.bindingLayouts[layout.id] else {
            throw RHIError.invalidArgument("unknown binding layout")
        }
        var layoutSlot: VkDescriptorSetLayout? = nativeLayout
        let set: VkDescriptorSet? = withUnsafePointer(to: &layoutSlot) { pointer in
            var info = VkDescriptorSetAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool = descriptorPool
            info.descriptorSetCount = 1
            info.pSetLayouts = pointer
            return vkWithOutHandle { _ = context.resources.allocateDescriptorSets(context.device, &info, $0) }
        }
        guard let set else { throw RHIError.outOfMemory }
        do {
            for entry in setEntries {
                guard let declaration = layoutEntries.first(where: { $0.slot == entry.slot }) else {
                    throw RHIError.layoutMismatch("binding has no declaration")
                }
                try writeDescriptor(set: set, entry: entry, declaration: declaration)
            }
        } catch {
            var native: VkDescriptorSet? = set
            _ = context.auxiliary.freeDescriptorSets(context.device, descriptorPool, 1, &native)
            throw error
        }
        registries.bindingSets[handle.id] = VulkanBindingSetRecord(descriptorSet: set, layoutID: layout.id)
    }

    func unregisterBindingSet(_ handle: BindingSet) {
        guard let record = registries.bindingSets.removeValue(forKey: handle.id) else { return }
        var native: VkDescriptorSet? = record.descriptorSet
        _ = context.auxiliary.freeDescriptorSets(context.device, descriptorPool, 1, &native)
    }

    private func writeDescriptor(set: VkDescriptorSet, entry: BindingSetEntry, declaration: BindingLayoutEntry) throws {
        var write = VkWriteDescriptorSet()
        write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
        write.dstSet = set
        write.dstBinding = entry.slot
        write.descriptorCount = 1
        write.descriptorType = VulkanLayoutFormats.descriptorType(declaration.type)
        switch entry.resource {
        case .uniformBuffer(let buffer, let offset, _), .storageBuffer(let buffer, let offset):
            guard let record = registries.buffers[buffer.id], offset >= 0, offset < record.size else {
                throw RHIError.invalidArgument("unknown buffer or invalid binding offset")
            }
            let alignment = declaration.type == .uniformBuffer ? context.limits.minUniformBufferOffsetAlignment : context.limits.minStorageBufferOffsetAlignment
            try rhiRequire(UInt64(offset) % max(1, alignment) == 0, "buffer binding offset violates Vulkan alignment")
            let length: Int
            if case .uniformBuffer(_, _, let size) = entry.resource { length = size ?? (record.size - offset) }
            else { length = record.size - offset }
            try rhiRequire(length > 0, "buffer binding size must be positive")
            try rhiByteRange(offset: offset, size: length, capacity: record.size)
            let limit = declaration.type == .uniformBuffer ? context.limits.maxUniformBufferRange : context.limits.maxStorageBufferRange
            try rhiRequire(UInt64(length) <= UInt64(limit), "buffer binding exceeds Vulkan descriptor range limit")
            var info = VkDescriptorBufferInfo(buffer: record.buffer, offset: VkDeviceSize(offset), range: VkDeviceSize(length))
            withUnsafePointer(to: &info) { pointer in
                write.pBufferInfo = pointer
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)
            }
        case .texture(let texture), .storageTexture(let texture):
            guard let record = registries.textures[texture.id] else { throw RHIError.invalidArgument("unknown texture") }
            var info = VkDescriptorImageInfo()
            info.imageView = record.view
            info.imageLayout = declaration.type == .storageTexture ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            withUnsafePointer(to: &info) { pointer in
                write.pImageInfo = pointer
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)
            }
        case .sampler(let sampler):
            guard let record = registries.samplers[sampler.id] else { throw RHIError.invalidArgument("unknown sampler") }
            var info = VkDescriptorImageInfo()
            info.sampler = record.sampler
            withUnsafePointer(to: &info) { pointer in
                write.pImageInfo = pointer
                context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)
            }
        case .accelerationStructure(let structure):
            guard let record = registries.accelerationStructures[structure.id] else { throw RHIError.invalidArgument("unknown acceleration structure binding") }
            var handle: VkAccelerationStructureKHR? = record.native
            withUnsafePointer(to: &handle) { pointer in
                var info = VkWriteDescriptorSetAccelerationStructureKHR()
                info.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR
                info.accelerationStructureCount = 1; info.pAccelerationStructures = pointer
                withUnsafePointer(to: &info) { extensionPointer in
                    write.pNext = UnsafeRawPointer(extensionPointer)
                    context.resources.updateDescriptorSets(context.device, 1, &write, 0, nil)
                }
            }
        }
    }
}
#endif
