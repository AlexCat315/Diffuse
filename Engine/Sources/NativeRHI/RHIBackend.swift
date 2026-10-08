// NativeRHI — backend protocol (the vtable equivalent).
//
// A concrete `RHIBackend` (Metal / Vulkan / DX12) owns the GPU device and the
// concrete resource objects. The frontend `Device` owns handle allocation,
// binding/pipeline-layout caches, and the submission planner; it hands each
// newly allocated handle to the backend, which stores the concrete object under
// that handle. All backend failures are thrown — nothing is silently truncated.
//
// Destruction methods are invoked by the FrameRing *after* the frame in which
// the resource was released has completed on the GPU, so they never free an
// object that is still in use.

import Foundation

public protocol RHIBackend: AnyObject {
    /// The graphics API this backend implements.
    var api: GraphicsAPI { get }
    /// Human-readable physical device / adapter name.
    var deviceName: String { get }

    /// Implemented features intersected with device support. An advertised
    /// extension alone must never enable an unimplemented RHI operation.
    func queryCapabilities() -> Capabilities
    func queryAdapterCapabilities() -> AdapterCapabilities

    /// Provides the native surface (CAMetalLayer / HWND / Xlib window) used by
    /// the swapchain. May be called again on resize.
    func configure(surface: SurfaceDescriptor) throws

    // MARK: Resource creation

    func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws
    func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws
    func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws
    func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws

    func createAccelerationStructure(_ handle: AccelerationStructure, descriptor: AccelerationStructureDescriptor) throws
    func destroyAccelerationStructure(_ handle: AccelerationStructure)

    // MARK: Pipelines

    func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws
    func createMeshPipeline(_ handle: MeshPipeline, descriptor: MeshPipelineDescriptor) throws
    func destroyMeshPipeline(_ handle: MeshPipeline)
    func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws

    // MARK: Binding sets

    func registerBindingLayout(_ handle: BindingLayout, descriptor: BindingLayoutDescriptor) throws
    func registerPipelineLayout(_ handle: PipelineLayout, descriptor: PipelineLayoutDescriptor) throws

    /// Maps a binding-set handle to the concrete GPU resources it references.
    /// Must throw (never silently no-op) if backend allocation fails.
    func registerBindingSet(
        _ handle: BindingSet,
        layout: BindingLayout,
        layoutEntries: [BindingLayoutEntry],
        setEntries: [BindingSetEntry]
    ) throws
    func unregisterBindingSet(_ handle: BindingSet)

    // MARK: Immediate data transfer (host-visible / shared storage)

    func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws
    /// Synchronous readback of previously submitted buffer contents.
    func readBufferData(_ buffer: Buffer, offset: Int, into destination: UnsafeMutableRawBufferPointer) throws
    func uploadTextureData(
        _ texture: Texture,
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        subresource: TextureSubresource
    ) throws
    func readTextureData(
        _ texture: Texture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        subresource: TextureSubresource,
        into destination: UnsafeMutableRawBufferPointer
    ) throws

    // MARK: Swapchain

    func acquireSwapchainImage() throws -> SwapchainImage
    func present(_ image: SwapchainImage) throws

    // MARK: Submission

    /// Vends (and resets) the per-slot transient uploader for an upcoming frame.
    func makeFrameUploader(slot: Int) throws -> FrameUploader

    /// Executes one planned submission. Must be asynchronous: it returns once
    /// the work is queued and invokes `completion` when the GPU finishes. No
    /// `waitUntilCompleted` / `vkQueueWaitIdle` on the hot path.
    func submit(_ submit: PlannedSubmit, completion: @escaping () -> Void) throws

    // MARK: Deferred destruction (called by FrameRing)

    func destroyBuffer(_ handle: Buffer)
    func destroyTexture(_ handle: Texture)
    func destroySampler(_ handle: Sampler)
    func destroyShaderModule(_ handle: ShaderModule)
    func destroyGraphicsPipeline(_ handle: GraphicsPipeline)
    func destroyComputePipeline(_ handle: ComputePipeline)

    // MARK: Synchronization

    /// Blocks until all previously queued GPU work has completed.
    func waitUntilIdle() throws
}

public extension RHIBackend {
    func readBufferData(_ buffer: Buffer, offset: Int, into destination: UnsafeMutableRawBufferPointer) throws {
        throw RHIError.unsupportedFeature("buffer readback is not implemented by this backend")
    }
    func registerBindingLayout(_ handle: BindingLayout, descriptor: BindingLayoutDescriptor) throws {}
    func registerPipelineLayout(_ handle: PipelineLayout, descriptor: PipelineLayoutDescriptor) throws {}
    func createAccelerationStructure(_ handle: AccelerationStructure, descriptor: AccelerationStructureDescriptor) throws {
        throw RHIError.unsupportedFeature("acceleration structures are not implemented by this backend")
    }
    func destroyAccelerationStructure(_ handle: AccelerationStructure) {}
    func createMeshPipeline(_ handle: MeshPipeline, descriptor: MeshPipelineDescriptor) throws {
        throw RHIError.unsupportedFeature("mesh pipelines are not implemented by this backend")
    }
    func destroyMeshPipeline(_ handle: MeshPipeline) {}
    func queryAdapterCapabilities() -> AdapterCapabilities { AdapterCapabilities() }
}
