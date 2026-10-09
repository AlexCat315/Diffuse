// NativeRHI — opaque resource handles.
//
// Handles are frontend IDs (matching the Zig design). The backend resolves
// them through its own registries. ID 0 is always invalid.

public protocol RHIHandle: Hashable, Sendable {
    var id: UInt32 { get }
    init(id: UInt32)
}

public struct Buffer: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct Texture: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct Sampler: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct ShaderModule: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct BindingLayout: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct BindingSet: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct PipelineLayout: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct GraphicsPipeline: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
public struct ComputePipeline: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }

/// Handle to a BLAS or TLAS. Creation and build support are capability-gated.
public struct AccelerationStructure: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }

/// One native window swapchain on a device.
public struct Swapchain: RHIHandle { public let id: UInt32; public init(id: UInt32) { self.id = id } }
