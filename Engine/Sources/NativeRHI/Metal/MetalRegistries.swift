// NativeRHI Metal backend — concrete resource registry.
//
// The backend keeps every concrete Metal object here, keyed by the opaque RHI
// handle. This is the backend's own namespace: frontend handles come from the
// frontend IdentifierPool, while resources the backend creates internally
// (upload-ring chunks, swapchain drawable textures) use a high-offset ID space
// so they can never collide with frontend handles.

#if os(macOS)
import Metal

/// One resolved binding set: the recorded set entries (handles) plus the
/// layout stage/type needed to bind correctly.
struct MetalBoundEntry {
    let slot: UInt32
    let type: BindingType
    let visibility: ShaderVisibility
    let resource: BindingResource
}

final class MetalBindingSet {
    var entries: [MetalBoundEntry]
    init(entries: [MetalBoundEntry]) { self.entries = entries }
}

/// All concrete Metal objects the backend owns. Grouped on its own so the
/// device type stays small (one responsibility per type).
final class MetalRegistries {
    var accelerationStructures: [UInt32: MetalAccelerationStructure] = [:]
    var buffers: [UInt32: MTLBuffer] = [:]
    var textures: [UInt32: MTLTexture] = [:]
    var samplers: [UInt32: MTLSamplerState] = [:]
    /// Compiled function per shader-module handle.
    var shaderFunctions: [UInt32: MTLFunction] = [:]
    /// Library per shader-module handle (keeps the compiled module alive).
    var shaderLibraries: [UInt32: MTLLibrary] = [:]
    var shaderStages: [UInt32: ShaderStage] = [:]
    var shaderThreadgroupSizes: [UInt32: ThreadgroupSize] = [:]
    var computeThreadgroupSizes: [UInt32: ThreadgroupSize] = [:]
    var meshPipelines: [UInt32: MetalMeshPipeline] = [:]
    var renderPipelines: [UInt32: MTLRenderPipelineState] = [:]
    var computePipelines: [UInt32: MTLComputePipelineState] = [:]
    var depthStates: [UInt32: MTLDepthStencilState] = [:]
    var pipelinePrimitives: [UInt32: MTLPrimitiveType] = [:]
    /// Cull/winding/fill are encoder state in Metal; stash per pipeline so the
    /// encoder can re-apply them when the pipeline is bound.
    var pipelineRasterStates: [UInt32: RasterizationState] = [:]
    var bindingSets: [UInt32: MetalBindingSet] = [:]
    var sharedEvents: [UInt32: MTLSharedEvent] = [:]

    /// Internal-handle counter for backend-owned resources (upload chunks,
    /// swapchain drawables). Starts above the frontend's low IDs.
    private var internalID: UInt32 = 0x8000_0000

    init() {}

    func nextInternalID() -> UInt32 {
        let id = internalID
        internalID += 1
        return id
    }
}

#endif
