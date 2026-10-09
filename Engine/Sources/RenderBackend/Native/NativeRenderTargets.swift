import NativeRHI

struct NativeRenderTargets {
    /// Allocated capacity; scene passes render only the packet's used extent.
    let size: RenderDrawableSize
    let color: TextureResource?
    let hdr: TextureResource?
    let depth: TextureResource
    static func surfaceDescriptor(surface: RenderSurfaceDescriptor, size: RenderDrawableSize) -> SurfaceDescriptor {
        var descriptor = SurfaceDescriptor(nativeHandle: nil, width: Int(size.width), height: Int(size.height), colorFormat: .bgra8Unorm)
        switch surface {
        case .metalLayer(let layer): descriptor.kind = .metalLayer; descriptor.nativeHandle = layer
        case .win32Window(let window, _): descriptor.kind = .win32Window; descriptor.nativeHandle = window
        case .xlibWindow(let display, let window):
            descriptor.kind = .xlibWindow; descriptor.display = display
            descriptor.nativeHandle = UnsafeMutableRawPointer(bitPattern: UInt(window))
        case .waylandSurface(let display, let surface):
            descriptor.kind = .waylandSurface; descriptor.display = display; descriptor.nativeHandle = surface
        }
        return descriptor
    }
    static func make(device: Device, size: RenderDrawableSize, offscreen: Bool, hdr: Bool = false) throws -> NativeRenderTargets {
        let depth = try TextureResource(device: device, descriptor: TextureDescriptor(width: Int(size.width), height: Int(size.height),
            format: .depth32Float, usage: [.depthStencilTarget,.sampled], label: "native-render-depth"))
        let color = offscreen ? try TextureResource(device: device, descriptor: TextureDescriptor(width: Int(size.width), height: Int(size.height),
            format: .bgra8Unorm, usage: [.colorTarget, .sampled, .transferSource], label: "native-render-color")) : nil
        let sceneHDR = hdr ? try TextureResource(device: device, descriptor: TextureDescriptor(width: Int(size.width), height: Int(size.height),
            format: .rgba16Float, usage: [.colorTarget,.sampled,.transferSource,.transferDestination], label: "native-scene-hdr")) : nil
        return NativeRenderTargets(size: size, color: color, hdr: sceneHDR, depth: depth)
    }
}
