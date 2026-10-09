// Capabilities describe the operations implemented by this backend. Adapter
// support is reported separately; an extension name alone is not a promise.

public struct RayTracingCapabilities: Equatable, Sendable {
    public var accelerationStructures = false
    public var computeRayQuery = false
    public var pipelines = false
    public var update = false
    public var compaction = false
    public init() {}
}

public struct MeshShadingCapabilities: Equatable, Sendable {
    public var mesh = false
    public var task = false
    public var indirect = false
    public init() {}
}

public struct TextureCapabilities: Equatable, Sendable {
    public var texture3D = false
    public var cube = false
    public init() {}
}

public struct Capabilities: Equatable, Sendable {
    public var graphics = false
    public var compute = false
    public var indirectDraw = false
    public var rayTracing = RayTracingCapabilities()
    public var meshShading = MeshShadingCapabilities()
    public var textures = TextureCapabilities()
    public var maxQueues = QueueLimits(graphics: 0, compute: 0, transfer: 0)

    public init(_ configure: (inout Capabilities) -> Void = { _ in }) {
        configure(&self)
    }
}

/// Diagnostic information about the adapter, not the implemented RHI API.
public struct AdapterCapabilities: Equatable, Sendable {
    public var rayTracing = false
    public var meshShading = false
    public init() {}
}
