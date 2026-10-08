// NativeRHI Vulkan — block/pock suballocator for device memory.
//
// Instead of one vkAllocateMemory per resource, we carve suballocations out of a
// small number of large blocks. Host-visible blocks are persistently mapped;
// device-local blocks back vertex/index buffers (staged via the upload ring).

#if (os(Windows) || os(Linux)) && canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

/// One suballocation out of a memory block.
struct VulkanMemoryAllocation {
    let blockIndex: Int
    let offset: VkDeviceSize
    let size: VkDeviceSize
    let memory: VkDeviceMemory
    /// Persistently mapped base for host-visible blocks; nil otherwise.
    let mappedBase: UnsafeMutableRawPointer?
}

final class VulkanMemoryBlock {
    let memory: VkDeviceMemory
    let size: VkDeviceSize
    let memoryTypeIndex: UInt32
    let mappedBase: UnsafeMutableRawPointer?
    var freeRegions: [(offset: VkDeviceSize, size: VkDeviceSize)]

    init(memory: VkDeviceMemory, size: VkDeviceSize, memoryTypeIndex: UInt32,
         mappedBase: UnsafeMutableRawPointer?) {
        self.memory = memory
        self.size = size
        self.memoryTypeIndex = memoryTypeIndex
        self.mappedBase = mappedBase
        self.freeRegions = [(0, size)]
    }
}

final class VulkanMemoryAllocator {
    private let context: VulkanContext
    private let memoryProperties: VkPhysicalDeviceMemoryProperties
    private var blocks: [VulkanMemoryBlock] = []
    private let blockSize: VkDeviceSize = 64 * 1024 * 1024

    init(context: VulkanContext,
         memoryProperties: VkPhysicalDeviceMemoryProperties) {
        self.context = context
        self.memoryProperties = memoryProperties
    }

    /// Resolves a memory type index satisfying `memoryTypeBits` and all required
    /// `VkMemoryPropertyFlagBits`, or nil.
    func findMemoryType(memoryTypeBits: UInt32, requiredFlags: VkMemoryPropertyFlags) -> UInt32? {
        var props = memoryProperties
        return withUnsafePointer(to: &props.memoryTypes) { raw in
            let types = UnsafeRawPointer(raw).assumingMemoryBound(to: VkMemoryType.self)
            for index in 0..<Int(props.memoryTypeCount) {
                let type = types[index]
                guard (memoryTypeBits & (1 << UInt32(index))) != 0 else { continue }
                if (type.propertyFlags & requiredFlags) == requiredFlags {
                    return UInt32(index)
                }
            }
            return nil
        }
    }

    func allocate(size: VkDeviceSize,
                  alignment: VkDeviceSize,
                  memoryTypeBits: UInt32,
                  requiredFlags: VkMemoryPropertyFlags) throws -> VulkanMemoryAllocation {
        // Buffer/image granularity is an allocation boundary invariant when
        // linear buffers and optimal images share one VkDeviceMemory block.
        let granularity = max(1, context.limits.bufferImageGranularity)
        let alignment = max(alignment, granularity)
        let size = align(offset: size, alignment: granularity)
        guard let typeIndex = findMemoryType(memoryTypeBits: memoryTypeBits,
                                             requiredFlags: requiredFlags) else {
            throw RHIError.outOfMemory
        }
        // Best-fit over existing blocks of this type.
        for (blockIndex, block) in blocks.enumerated() where block.memoryTypeIndex == typeIndex {
            if let region = findFreeRegion(block: block, size: size, alignment: alignment) {
                return commit(blockIndex: blockIndex, block: block, region: region, size: size)
            }
        }
        // Otherwise grow a fresh block.
        let blockSize = max(self.blockSize, align(offset: size, alignment: alignment))
        var properties = memoryProperties
        let coherent = withUnsafePointer(to: &properties.memoryTypes) { raw in
            let flags = UnsafeRawPointer(raw).assumingMemoryBound(to: VkMemoryType.self)[Int(typeIndex)].propertyFlags
            let required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
            return flags & required == required
        }
        let block = try createBlock(size: blockSize, typeIndex: typeIndex, hostVisible: coherent)
        blocks.append(block)
        let blockIndex = blocks.count - 1
        guard let region = findFreeRegion(block: block, size: size, alignment: alignment) else {
            throw RHIError.outOfMemory
        }
        return commit(blockIndex: blockIndex, block: block, region: region, size: size)
    }

    func free(_ allocation: VulkanMemoryAllocation) {
        guard allocation.blockIndex < blocks.count else { return }
        let block = blocks[allocation.blockIndex]
        block.freeRegions.append((allocation.offset, allocation.size))
        block.freeRegions.sort { $0.offset < $1.offset }
        var merged: [(offset: VkDeviceSize, size: VkDeviceSize)] = []
        for region in block.freeRegions {
            if let previous = merged.last, previous.offset + previous.size == region.offset { merged[merged.count - 1].size += region.size }
            else { merged.append(region) }
        }
        block.freeRegions = merged
    }

    /// Unmaps and frees every block. Call only after the device is idle.
    func destroyAll() {
        for block in blocks {
            if block.mappedBase != nil {
                context.core.unmapMemory(context.device, block.memory)
            }
            context.core.freeMemory(context.device, block.memory, nil)
        }
        blocks.removeAll()
    }

    // MARK: Private

    private func findFreeRegion(block: VulkanMemoryBlock,
                                size: VkDeviceSize,
                                alignment: VkDeviceSize) -> (offset: VkDeviceSize, size: VkDeviceSize)? {
        for index in block.freeRegions.indices {
            var region = block.freeRegions[index]
            let aligned = align(offset: region.offset, alignment: alignment)
            let padding = aligned - region.offset
            guard aligned + size <= region.offset + region.size else { continue }
            let remaining = region.size - padding - size
            block.freeRegions.remove(at: index)
            if padding > 0 { block.freeRegions.append((region.offset, padding)) }
            if remaining > 0 { block.freeRegions.append((aligned + size, remaining)) }
            block.freeRegions.sort { $0.offset < $1.offset }
            return (aligned, size)
        }
        return nil
    }

    private func commit(blockIndex: Int, block: VulkanMemoryBlock,
                        region: (offset: VkDeviceSize, size: VkDeviceSize),
                        size: VkDeviceSize) -> VulkanMemoryAllocation {
        VulkanMemoryAllocation(
            blockIndex: blockIndex,
            offset: region.offset,
            size: size,
            memory: block.memory,
            mappedBase: block.mappedBase
        )
    }

    private func createBlock(size: VkDeviceSize, typeIndex: UInt32,
                             hostVisible: Bool) throws -> VulkanMemoryBlock {
        var allocInfo = VkMemoryAllocateInfo()
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        allocInfo.allocationSize = size
        allocInfo.memoryTypeIndex = typeIndex

        let arena = VulkanScratch()
        if context.features.accelerationStructures {
            var flags = VkMemoryAllocateFlagsInfo()
            flags.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO
            flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT.rawValue
            allocInfo.pNext = UnsafeRawPointer(arena.make(flags))
        }
        guard let memory: VkDeviceMemory = withExtendedLifetime(arena, { vkWithOutHandle({
            context.core.allocateMemory(context.device, &allocInfo, nil, $0)
        }) }) else {
            throw RHIError.outOfMemory
        }

        var mappedBase: UnsafeMutableRawPointer?
        if hostVisible {
            guard context.core.mapMemory(context.device, memory, 0, size, 0, &mappedBase) == VK_SUCCESS else {
                context.core.freeMemory(context.device, memory, nil)
                throw RHIError.outOfMemory
            }
        }
        return VulkanMemoryBlock(memory: memory, size: size,
                                 memoryTypeIndex: typeIndex, mappedBase: mappedBase)
    }

    private func align(offset: VkDeviceSize, alignment: VkDeviceSize) -> VkDeviceSize {
        let alignment = max(1, alignment)
        return (offset + alignment - 1) / alignment * alignment
    }
}

#endif // canImport(CVulkanHeaders)
