import CWGPUBridge

public struct GPUBindGroupLayoutEntry: Sendable {
    public var binding: UInt32
    public var visibility: GPUShaderStage
    public var type: GPUBindingType

    public init(binding: UInt32, visibility: GPUShaderStage, type: GPUBindingType) {
        self.binding = binding
        self.visibility = visibility
        self.type = type
    }
}

public final class GPUBindGroupLayout {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_bind_group_layout(handle)
    }
}

public struct GPUBindGroupEntry {
    public var binding: UInt32
    public var buffer: GPUBuffer?
    public var offset: UInt64
    public var size: UInt64
    public var sampler: GPUSampler?
    public var textureView: GPUTextureView?

    public init(binding: UInt32,
                buffer: GPUBuffer? = nil,
                offset: UInt64 = 0,
                size: UInt64 = 0,
                sampler: GPUSampler? = nil,
                textureView: GPUTextureView? = nil) {
        self.binding = binding
        self.buffer = buffer
        self.offset = offset
        self.size = size
        self.sampler = sampler
        self.textureView = textureView
    }
}

public final class GPUBindGroup {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_bind_group(handle)
    }
}

public final class GPUPipelineLayout {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_pipeline_layout(handle)
    }
}
