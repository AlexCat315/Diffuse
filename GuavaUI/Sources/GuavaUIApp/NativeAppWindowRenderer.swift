import GuavaUIRuntime
import NativeRHI
import PlatformShell

@MainActor
final class NativeAppWindowRenderer: AppWindowRenderer {
    private let device: Device
    private let renderer: NativeDrawListRenderer
    private let settings: AppWindowRenderSettings
    private var native: NativeRenderSurface?
    private var swapchain: SwapchainResource?
    private var size = SIMD2<UInt32>(repeating: 0)
    private var multisample: TextureResource?

    var isConfigured: Bool { swapchain != nil }

    init(device: Device, renderer: NativeDrawListRenderer, settings: AppWindowRenderSettings) {
        self.device = device; self.renderer = renderer; self.settings = settings
    }

    func configure(native: NativeRenderSurface, size: SIMD2<UInt32>, vsync: Bool) throws {
        try device.withFrameSession {
            guard swapchain == nil else { throw RHIError.invalidArgument("window is already configured") }
            let resource = try SwapchainResource(device: device,
                descriptor: SurfaceFactory.nativeDescriptor(native: native, size: size, vsync: vsync))
            self.native = native; self.swapchain = resource; self.size = size
        }
    }

    func resize(size: SIMD2<UInt32>, vsync: Bool) throws {
        try device.withFrameSession {
            guard let native, let swapchain else { return }
            // Minimized windows may have no drawable extent; keep the last pool
            // alive and resume configuration when a positive size returns.
            guard size.x > 0 && size.y > 0 else { self.size = size; return }
            try device.configureSwapchain(swapchain.swapchain,
                descriptor: SurfaceFactory.nativeDescriptor(native: native, size: size, vsync: vsync))
            self.size = size
        }
    }

    func draw(list: DrawList, logical: SIMD2<Float>) throws -> Bool {
        try device.withFrameSession {
            guard let swapchain, size.x > 0 && size.y > 0 else { return false }
            try device.beginFrame()
            defer { device.endFrame() }
            let image = try device.acquireSwapchainImage(swapchain.swapchain)
            let pixels = SIMD2(image.width, image.height)
            if settings.samples > 1 && (multisample?.descriptor.width != pixels.x || multisample?.descriptor.height != pixels.y) {
                var descriptor = TextureDescriptor(width: pixels.x, height: pixels.y,
                    format: .bgra8UnormSRGB, usage: [.colorTarget])
                descriptor.sampleCount = Int(settings.samples)
                multisample = try TextureResource(device: device, descriptor: descriptor)
            }
            let clear = settings.clearColor
            var target = RenderColorTarget(texture: multisample?.texture ?? image.texture,
                loadAction: .clear(SIMD4(Float(clear.r), Float(clear.g), Float(clear.b), Float(clear.a))))
            target.resolveTexture = multisample == nil ? nil : image.texture
            let commands = CommandBuffer()
            let frame = try renderer.record(list: list, into: commands, target: target,
                viewport: NativeUIViewport(pixels: pixels, logical: logical))
            try device.submit(commands)
            frame.didSubmit()
            try device.present(image)
            return true
        }
    }

    func close() throws {
        try device.withFrameSession {
            defer { swapchain = nil; native = nil; multisample = nil; size = .zero }
            try swapchain?.close()
        }
    }
}
