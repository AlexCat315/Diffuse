import NativeRHI

struct NativeRenderTargets {
    let size: RenderDrawableSize
    let color: Texture?
    let hdr: Texture?
    let depth: Texture
    static func configure(device: Device, surface: RenderSurfaceDescriptor, size: RenderDrawableSize) throws {
        try device.waitUntilIdle()
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
        try device.configureSurface(descriptor)
    }
    static func make(device: Device, size: RenderDrawableSize, offscreen: Bool, hdr: Bool = false) throws -> NativeRenderTargets {
        let depth = try device.makeTexture(TextureDescriptor(width: Int(size.width), height: Int(size.height),
            format: .depth32Float, usage: .depthStencilTarget, label: "native-render-depth"))
        var color: Texture?
        do {
            color = offscreen ? try device.makeTexture(TextureDescriptor(width: Int(size.width), height: Int(size.height),
                format: .bgra8Unorm, usage: [.colorTarget, .transferSource], label: "native-render-color")) : nil
            let sceneHDR = hdr ? try device.makeTexture(TextureDescriptor(width: Int(size.width), height: Int(size.height),
                format: .rgba16Float, usage: [.colorTarget,.sampled], label: "native-scene-hdr")) : nil
            return NativeRenderTargets(size: size, color: color, hdr: sceneHDR, depth: depth)
        } catch { if let color { device.destroy(color) }; device.destroy(depth); throw error }
    }
    func destroy(device: Device) { if let color { device.destroy(color) }; if let hdr { device.destroy(hdr) }; device.destroy(depth) }
}
