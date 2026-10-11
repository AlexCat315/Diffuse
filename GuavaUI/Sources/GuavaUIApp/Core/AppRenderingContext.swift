import GuavaUIRuntime
import GuavaUIDevTools
import NativeRHI

struct AppWindowRenderSettings {
    let samples: UInt32
    let clearColor: SIMD4<Float>
    init(config: AppConfig) {
        samples = config.msaaSampleCount
        clearColor = config.clearColor
    }
}

/// Shares UI bindings, fonts and image residency across application windows.
@MainActor
final class AppRenderingContext {
    private let device: Device
    private let renderer: NativeDrawListRenderer
    let viewportTextures: ViewportTextureRegistry

    init(device: Device?, config: AppConfig) throws {
        let device = try device ?? Device.make(config.backendConfig)
        self.device = device
        renderer = try device.withFrameSession { try NativeDrawListRenderer(device: device) }
        viewportTextures = ViewportTextureRegistry(renderer: renderer)
    }

    func makeWindow(settings: AppWindowRenderSettings) throws -> any AppWindowRenderer {
        try device.withFrameSession { try renderer.configure(format: .bgra8UnormSRGB, sampleCount: Int(settings.samples)) }
        return NativeAppWindowRenderer(device: device, renderer: renderer, settings: settings)
    }

    func uploadFontAtlas(_ atlas: FontAtlas, textureID: TextureID) throws {
        try device.withFrameSession { try renderer.uploadFontAtlas(atlas, textureID: textureID) }
    }

    func attachFrameTap(to devTools: DevTools) throws {
        let capture = try NativeAppFrameCapture(device: device, renderer: renderer)
        devTools.attachFrameTap(capture: { list, width, height, logical in
            try capture.capture(list: list, size: SIMD2(Int(width), Int(height)),
                logical: SIMD2(logical.width, logical.height))
        }, reset: { capture.reset() })
    }
}
