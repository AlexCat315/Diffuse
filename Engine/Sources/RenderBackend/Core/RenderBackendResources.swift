import RHIWGPU

/// One mesh resident on the GPU.
struct GPUMesh {
    let vertexBuffer: GPUBuffer
    let indexBuffer: GPUBuffer
    let indexCount: UInt32
    let name: String
}

extension GPUMesh: @unchecked Sendable {}

/// Per-instance GPU resources (uniform buffer + bind group). One slot per draw call.
struct InstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
}

extension InstanceResources: @unchecked Sendable {}

/// Shared uniform-buffer path using dynamic bind offsets.
struct DynamicInstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
    let stride: UInt64
    let capacity: Int
}

extension DynamicInstanceResources: @unchecked Sendable {}

struct RenderTextureTarget {
    let texture: GPUTexture
    let view: GPUTextureView
}

struct GPUMeshTextureResource {
    let texture: GPUTexture
    let view: GPUTextureView
    let width: UInt32
    let height: UInt32
    let sourcePath: String
}

struct BasePassEncodingReport {
    let drawCallCount: Int
    let renderBundleCount: Int
    let parallelJobCount: Int
    let bundleRecordNS: UInt64
}
