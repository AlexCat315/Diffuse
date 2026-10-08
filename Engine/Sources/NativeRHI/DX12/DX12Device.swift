// The C ABI isolates COM and D3D12 GPU layouts. This adapter is compiled on all
// hosts; the native Windows implementation still needs a Windows GPU build.
import CDX12Bridge
import Foundation

public final class DX12Device: RHIBackend {
    let native: OpaquePointer
    let config: DeviceConfig
    var resources = DX12ResourceMetadata()
    var uploaders: [Int: DX12FrameUploader] = [:]
    var nextInternalID: UInt32 = 0xf000_0000
    public let deviceName: String
    public var api: GraphicsAPI { .dx12 }

    private init(native: OpaquePointer, config: DeviceConfig) {
        self.native = native
        self.config = config
        deviceName = String(cString: grhi_dx12_name(native))
    }
    deinit { grhi_dx12_release(native) }

    public static func make(config: DeviceConfig) throws -> RHIBackend {
        guard let native = grhi_dx12_create(config.enableValidation ? 1 : 0, config.preferLowPower ? 1 : 0) else {
            throw RHIError.unsupportedBackend(String(cString: grhi_dx12_error(nil)))
        }
        return DX12Device(native: native, config: config)
    }
    func check(_ result: Int32) throws {
        guard result != 0 else { throw RHIError.submitFailed(String(cString: grhi_dx12_error(native))) }
    }
    public func queryCapabilities() -> Capabilities {
        let features = grhi_dx12_capabilities(native)
        return Capabilities {
            $0.graphics = true; $0.compute = true; $0.indirectDraw = true
            $0.textures.texture3D = true; $0.textures.cube = true
            $0.rayTracing.accelerationStructures = features.ray_tier >= 10
            $0.rayTracing.computeRayQuery = features.ray_tier >= 11
            $0.meshShading.mesh = features.mesh != 0; $0.meshShading.task = features.task != 0
            $0.maxQueues = QueueLimits()
        }
    }
    public func queryAdapterCapabilities() -> AdapterCapabilities {
        let features = grhi_dx12_capabilities(native)
        var result = AdapterCapabilities()
        result.rayTracing = features.ray_tier > 0; result.meshShading = features.mesh != 0
        return result
    }
    public func configure(surface: SurfaceDescriptor) throws {
        try check(grhi_dx12_surface(native, surface.nativeHandle, rhiCount(surface.width), rhiCount(surface.height), surface.colorFormat.dx12, surface.vsyncEnabled ? 1 : 0))
    }
    public func acquireSwapchainImage() throws -> SwapchainImage {
        var width: UInt32 = 0, height: UInt32 = 0
        let id = grhi_dx12_acquire(native, &width, &height)
        try check(id == 0 ? 0 : 1)
        return SwapchainImage(texture: Texture(id: id), width: Int(width), height: Int(height))
    }
    public func present(_ image: SwapchainImage) throws { try check(grhi_dx12_present(native, image.texture.id)) }
    public func waitUntilIdle() throws { try check(grhi_dx12_wait_idle(native)) }
    public func makeFrameUploader(slot: Int) -> FrameUploader {
        let uploader = uploaders[slot] ?? DX12FrameUploader(backend: self)
        uploaders[slot] = uploader; uploader.reset(); return uploader
    }
    public func destroyBuffer(_ handle: Buffer) { grhi_dx12_destroy(native, 0, handle.id); resources.buffers.removeValue(forKey: handle.id) }
    public func destroyTexture(_ handle: Texture) { grhi_dx12_destroy(native, 1, handle.id); resources.textures.removeValue(forKey: handle.id) }
    public func destroySampler(_ handle: Sampler) { grhi_dx12_destroy(native, 2, handle.id) }
    public func destroyShaderModule(_ handle: ShaderModule) { grhi_dx12_destroy(native, 3, handle.id) }
    public func destroyGraphicsPipeline(_ handle: GraphicsPipeline) { grhi_dx12_destroy(native, 4, handle.id) }
    public func destroyComputePipeline(_ handle: ComputePipeline) { grhi_dx12_destroy(native, 5, handle.id) }
    public func destroyMeshPipeline(_ handle: MeshPipeline) { grhi_dx12_destroy(native, 6, handle.id) }
    public func destroyAccelerationStructure(_ handle: AccelerationStructure) { grhi_dx12_destroy(native, 7, handle.id) }
    public func unregisterBindingSet(_ handle: BindingSet) { grhi_dx12_destroy(native, 8, handle.id) }
}

struct DX12ResourceMetadata {
    var buffers: [UInt32: BufferDescriptor] = [:]
    var textures: [UInt32: TextureDescriptor] = [:]
}
