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
