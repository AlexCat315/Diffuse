import CWGPUBridge

public final class GPUTexture {
    let handle: UnsafeMutableRawPointer
    private let owned: Bool

    init(handle: UnsafeMutableRawPointer, owned: Bool = true) {
        self.handle = handle
        self.owned = owned
    }

    deinit {
        if owned {
            wgpu_bridge_release_texture(handle)
        }
    }

    public func createView() throws -> GPUTextureView {
        var viewPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_texture_view_default(handle, &viewPtr)
        guard ok == 1, let viewPtr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPUTextureView(handle: viewPtr)
    }

    public func createView(format: GPUTextureFormat,
                           dimension: GPUTextureViewDimension,
                           baseMipLevel: UInt32 = 0,
                           mipLevelCount: UInt32 = 1,
                           baseArrayLayer: UInt32 = 0,
                           arrayLayerCount: UInt32 = 1) throws -> GPUTextureView {
        var desc = WGPUBridgeTextureViewDesc(
            format: format.bridgeValue,
            dimension: dimension.bridgeValue,
            base_mip_level: baseMipLevel,
            mip_level_count: mipLevelCount,
            base_array_layer: baseArrayLayer,
            array_layer_count: arrayLayerCount
        )
        var viewPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_create_texture_view(handle, &desc, &viewPtr)
        guard ok == 1, let viewPtr else {
            throw WGPUBackendError.initFailed(WGPUBackend.lastError())
        }
        return GPUTextureView(handle: viewPtr)
    }
}

public final class GPUTextureView {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_texture_view(handle)
    }
}
