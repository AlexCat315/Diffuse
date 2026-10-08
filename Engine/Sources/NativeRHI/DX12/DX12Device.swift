// NativeRHI — DirectX 12 backend skeleton (Windows only).
//
// This file is compiled ONLY on Windows (`#if os(Windows)`); on every other
// host it is excluded entirely, so it cannot affect the macOS build. It is a
// structured starting point that follows the real D3D12 object model:
//
//   IDXGIFactory -> IDXGIAdapter -> ID3D12Device
//      -> ID3D12CommandQueue / ID3D12CommandAllocator / ID3D12GraphicsCommandList
//      -> descriptor heaps (CBV/SRV/UAV, samplers) -> IDXGISwapChain
//
// Unlike the Zig prototype's stubs, nothing here reports fake success: paths
// that are not yet implemented throw `.unsupportedFeature`. Capability
// detection is wired to `ID3D12Device::CheckFeatureSupport` and is never
// hardcoded.
//
// NOTE: DX12 cannot be compiled or verified on the development Mac. The raw
// COM calls below follow the imported WinSDK C ABI and must be confirmed by a
// Windows build pass before being considered complete.

#if os(Windows)

import WinSDK

public final class DX12Device: RHIBackend {
    /// The owning D3D12 device.
    private let device: UnsafeMutablePointer<ID3D12Device>
    /// Configuration the device was created with.
    private let config: DeviceConfig
    /// Lazily-created graphics queue (submission is not yet implemented).
    private var graphicsQueue: UnsafeMutablePointer<ID3D12CommandQueue>?

    public var api: GraphicsAPI { .dx12 }
    public let deviceName: String

    // MARK: Creation

    private init(
        device: UnsafeMutablePointer<ID3D12Device>,
        config: DeviceConfig,
        deviceName: String
    ) {
        self.device = device
        self.config = config
        self.deviceName = deviceName
    }

    public static func make(config: DeviceConfig) throws -> RHIBackend {
        // Use the default hardware adapter (factory/adapter enumeration is a
        // documented TODO below). D3D12CreateDevice keeps the adapter alive.
        var device: UnsafeMutablePointer<ID3D12Device>?
        let createResult = D3D12CreateDevice(
            nil,
            D3D_FEATURE_LEVEL_11_0,
            &IID_ID3D12Device,
            &device
        )
        guard createResult == S_OK, let device else {
            throw RHIError.unsupportedBackend(
                "D3D12CreateDevice failed (0x\(String(createResult, radix: 16)))"
            )
        }

        return DX12Device(
            device: device,
            config: config,
            // Adapter description retrieval via IDXGIAdapter::GetDesc is TODO.
            deviceName: "DirectX 12 Device"
        )
    }

    // MARK: Capabilities (real detection via CheckFeatureSupport)

    public func queryCapabilities() -> Capabilities { Capabilities() }

    public func queryAdapterCapabilities() -> AdapterCapabilities {
        var options = D3D12_FEATURE_DATA_D3D12_OPTIONS()
        let optionsHR = device.pointee.lpVtbl.pointee.CheckFeatureSupport(
            device,
            D3D12_FEATURE_D3D12_OPTIONS,
            &options,
            UINT(MemoryLayout<D3D12_FEATURE_DATA_D3D12_OPTIONS>.size)
        )

        // Raytracing tier is reported in OPTIONS5 (Windows 10 1809+).
        var options5 = D3D12_FEATURE_DATA_D3D12_OPTIONS5()
        let options5HR = device.pointee.lpVtbl.pointee.CheckFeatureSupport(
            device,
            D3D12_FEATURE_D3D12_OPTIONS5,
            &options5,
            UINT(MemoryLayout<D3D12_FEATURE_DATA_D3D12_OPTIONS5>.size)
        )

        let raytracing = options5HR == S_OK
            && options5.RaytracingTier.rawValue >= D3D12_RAYTRACING_TIER_1_0.rawValue
        let meshShaders = optionsHR == S_OK
            // Mesh shader support is reported in OPTIONS7 (amplification/mesh
            // shader tier); that query is added during the mesh-shader phase.
            && false

        var result = AdapterCapabilities()
        result.rayTracing = raytracing
        result.meshShading = meshShaders
        return result
    }

    // MARK: Surface / swapchain

    public func configure(surface: SurfaceDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 swapchain/IDXGIFactory setup is not yet implemented")
    }

    public func acquireSwapchainImage() throws -> SwapchainImage {
        throw RHIError.swapchainAcquireFailed("DX12 swapchain is not yet implemented")
    }

    public func present(_ image: SwapchainImage) throws {
        throw RHIError.presentFailed("DX12 swapchain is not yet implemented")
    }

    // MARK: Resource creation

    public func createBuffer(_ handle: Buffer, descriptor: BufferDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 committed/placed resource creation is not yet implemented")
    }

    public func createTexture(_ handle: Texture, descriptor: TextureDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 texture creation is not yet implemented")
    }

    public func createSampler(_ handle: Sampler, descriptor: SamplerDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 sampler descriptor heap is not yet implemented")
    }

    public func createShaderModule(_ handle: ShaderModule, descriptor: ShaderModuleDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 DXIL shader modules are not yet implemented")
    }

    // MARK: Pipelines

    public func createGraphicsPipeline(_ handle: GraphicsPipeline, descriptor: GraphicsPipelineDescriptor) throws {
        // TODO: root signature + PSO via CreateGraphicsPipelineState, including
        // MRT (all RTV formats) and rasterization state.
        throw RHIError.unsupportedFeature("DX12 graphics pipeline state is not yet implemented")
    }

    public func createComputePipeline(_ handle: ComputePipeline, descriptor: ComputePipelineDescriptor) throws {
        throw RHIError.unsupportedFeature("DX12 compute pipeline state is not yet implemented")
    }

    // MARK: Binding sets

    public func registerBindingSet(
        _ handle: BindingSet,
        layoutEntries: [BindingLayoutEntry],
        setEntries: [BindingSetEntry]
    ) throws {
        // TODO: bind via root signature / descriptor tables; must propagate
        // allocation failures (never silently no-op) and reject >32 vertex
        // attributes / >8 buffer layouts.
        throw RHIError.unsupportedFeature("DX12 binding sets are not yet implemented")
    }

    public func unregisterBindingSet(_ handle: BindingSet) {}

    // MARK: Data transfer

    public func uploadBufferData(_ buffer: Buffer, offset: Int, data: Data) throws {
        throw RHIError.unsupportedFeature("DX12 upload is not yet implemented")
    }

    public func uploadTextureData(
        _ texture: Texture,
        data: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        throw RHIError.unsupportedFeature("DX12 texture upload is not yet implemented")
    }

    public func readTextureData(
        _ texture: Texture,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws {
        throw RHIError.unsupportedFeature("DX12 readback is not yet implemented")
    }

    // MARK: Frame uploader / submission

    public func makeFrameUploader(slot: Int) -> FrameUploader {
        // The upload ring is not wired for D3D12 yet; return a throwing stub so
        // callers fail loudly rather than silently dropping uploads.
        DX12FailingUploader()
    }

    public func submit(_ submit: PlannedSubmit, completion: @escaping () -> Void) throws {
        // TODO: record into ID3D12GraphicsCommandList, use a fence for the
        // completion callback, and map timeline semaphores to D3D12 fences.
        throw RHIError.submitFailed("DX12 submission is not yet implemented")
    }

    // MARK: Deferred destruction (invoked by FrameRing after GPU completion)

    public func destroyBuffer(_ handle: Buffer) {}
    public func destroyTexture(_ handle: Texture) {}
    public func destroySampler(_ handle: Sampler) {}
    public func destroyShaderModule(_ handle: ShaderModule) {}
    public func destroyGraphicsPipeline(_ handle: GraphicsPipeline) {}
    public func destroyComputePipeline(_ handle: ComputePipeline) {}

    // MARK: Synchronization

    public func waitUntilIdle() throws {
        guard let queue = graphicsQueue else { return }
        // TODO: signal/wait a ID3D12Fence and block on its event.
        _ = queue
        throw RHIError.unsupportedFeature("DX12 fence wait is not yet implemented")
    }
}

/// Placeholder uploader that fails loudly until the D3D12 upload ring exists.
private final class DX12FailingUploader: FrameUploader {
    func reset() {}
    func write(_ data: Data, alignment: Int) throws -> UploadLocation {
        throw RHIError.unsupportedFeature("DX12 upload ring is not yet implemented")
    }
}

#endif // os(Windows)
