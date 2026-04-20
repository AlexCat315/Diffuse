import CWGPUBridge

public final class GPUComputePipeline {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_compute_pipeline(handle)
    }
}

public final class GPUComputePassEncoder {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_compute_pass_encoder(handle)
    }

    public func setPipeline(_ pipeline: GPUComputePipeline) {
        wgpu_bridge_compute_pass_set_pipeline(handle, pipeline.handle)
    }

    public func setBindGroup(_ bindGroup: GPUBindGroup, index: UInt32 = 0) {
        wgpu_bridge_compute_pass_set_bind_group(handle, index, bindGroup.handle)
    }

    public func dispatch(x: UInt32, y: UInt32 = 1, z: UInt32 = 1) {
        wgpu_bridge_compute_pass_dispatch(handle, x, y, z)
    }

    public func end() {
        wgpu_bridge_compute_pass_end(handle)
    }
}
