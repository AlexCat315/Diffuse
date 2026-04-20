import CWGPUBridge

public final class GPUBuffer {
    let handle: UnsafeMutableRawPointer
    public let size: UInt64

    init(handle: UnsafeMutableRawPointer, size: UInt64) {
        self.handle = handle
        self.size = size
    }

    deinit {
        wgpu_bridge_release_buffer(handle)
    }

    public func getMappedRange(offset: UInt64 = 0, size: UInt64 = 0) -> UnsafeRawPointer? {
        let sz = size > 0 ? size : self.size
        return wgpu_bridge_buffer_get_mapped_range(handle, offset, sz)
    }

    public func unmap() {
        wgpu_bridge_buffer_unmap(handle)
    }
}
