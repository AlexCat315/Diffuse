import CWGPUBridge

public enum GPUSurfaceError: Error {
    case createFailed(String)
    case configureFailed(String)
    case acquireTextureFailed(String)
}

public final class GPUSurface {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    deinit {
        wgpu_bridge_release_surface(handle)
    }

    public func configure(device: UnsafeMutableRawPointer,
                          format: GPUTextureFormat = .bgra8Unorm,
                          width: UInt32,
                          height: UInt32,
                          presentMode: GPUPresentMode = .fifo) throws {
        let ok = wgpu_bridge_configure_surface(
            handle, device,
            format.bridgeValue,
            width, height,
            presentMode.bridgeValue
        )
        guard ok == 1 else {
            throw GPUSurfaceError.configureFailed(WGPUBackend.lastError())
        }
    }

    public func getCurrentTextureView() throws -> (texture: GPUTexture, view: GPUTextureView) {
        var texPtr: UnsafeMutableRawPointer?
        var viewPtr: UnsafeMutableRawPointer?
        let ok = wgpu_bridge_surface_get_current_texture_view(handle, &texPtr, &viewPtr)
        guard ok == 1, let texPtr, let viewPtr else {
            throw GPUSurfaceError.acquireTextureFailed(WGPUBackend.lastError())
        }
        return (
            GPUTexture(handle: texPtr, owned: false),
            GPUTextureView(handle: viewPtr)
        )
    }

    public func present() {
        wgpu_bridge_surface_present(handle)
    }
}
