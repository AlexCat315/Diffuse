import NativeRHI

struct NativeRenderTargets {
    let size: RenderDrawableSize
    let color: Texture?
    let depth: Texture
    static func configure(device: Device, surface: RenderSurfaceDescriptor, size: RenderDrawableSize) throws {
        try device.waitUntilIdle()
        var descriptor = SurfaceDescriptor(nativeHandle: nil, width: Int(size.width), height: Int(size.height), colorFormat: .bgra8Unorm)
        switch surface {
        case .metalLayer(let layer): descriptor.nativeHandle = layer
        case .win32Window(let window, _): descriptor.nativeHandle = window
        case .xlibWindow(let display, let window):
            descriptor.display = display; descriptor.nativeHandle = UnsafeMutableRawPointer(bitPattern: UInt(window))
        case .waylandSurface: throw RHIError.unsupportedFeature("NativeRHI Wayland surface is not implemented")
        }
        try device.configureSurface(descriptor)
    }
    static func make(device: Device, size: RenderDrawableSize, offscreen: Bool) throws -> NativeRenderTargets {
        let depth = try device.makeTexture(TextureDescriptor(width: Int(size.width), height: Int(size.height),
            format: .depth32Float, usage: .depthStencilTarget, label: "native-render-depth"))
        do {
            let color = offscreen ? try device.makeTexture(TextureDescriptor(width: Int(size.width), height: Int(size.height),
                format: .bgra8Unorm, usage: [.colorTarget, .transferSource], label: "native-render-color")) : nil
            return NativeRenderTargets(size: size, color: color, depth: depth)
        } catch { device.destroy(depth); throw error }
    }
    func destroy(device: Device) { if let color { device.destroy(color) }; device.destroy(depth) }
}
