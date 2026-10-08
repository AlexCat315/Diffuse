// NativeRHI Vulkan — per-frame upload ring chunk.
//
// Each chunk is a host-visible + coherent VkBuffer that is persistently mapped
// for the lifetime of the chunk. The ChunkUploadAllocator bumps offsets within
// it, so no per-upload map/unmap/free happens on the hot path.

#if canImport(CVulkanHeaders)
import CVulkanHeaders
import Foundation

final class VulkanUploadChunk: UploadRingChunk {
    let buffer: VkBuffer
    let allocation: VulkanMemoryAllocation
    let capacity: Int
    private let mappedPointer: UnsafeMutableRawPointer

    init(buffer: VkBuffer, allocation: VulkanMemoryAllocation, capacity: Int) {
        self.buffer = buffer
        self.allocation = allocation
        self.capacity = capacity
        guard let base = allocation.mappedBase else {
            fatalError("VulkanUploadChunk requires a host-visible allocation")
        }
        self.mappedPointer = base.advanced(by: Int(allocation.offset))
    }

    func cpuPointer() -> UnsafeMutableRawPointer {
        mappedPointer
    }
}

#endif // canImport(CVulkanHeaders)
