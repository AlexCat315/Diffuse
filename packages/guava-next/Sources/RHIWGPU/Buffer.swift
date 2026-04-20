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
}
