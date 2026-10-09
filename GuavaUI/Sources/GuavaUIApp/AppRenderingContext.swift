import GuavaUIRuntime
import GuavaUIDevTools
import NativeRHI
import RHIWGPU

/// Inject the same device used by the scene renderer to compose its viewport
/// without copying pixels. Omitting this option retains the WGPU default.
public enum AppRendererDevice {
    case wgpu(WGPUBackend)
    case native(Device)
}

struct AppWindowRenderSettings {
    let samples: UInt32
    let clearColor: GPUColor
    let preferredPresentMode: GPUPresentMode

    init(config: AppConfig) {
        samples = config.msaaSampleCount
        clearColor = config.clearColor
        preferredPresentMode = config.vsyncPresentMode
    }
}

/// Shares UI bindings, fonts and image residency across the application's
/// windows. Each window owns its own presentation and attachment resources.
@MainActor
final class AppRenderingContext {
    private enum Renderer {
        case wgpu(WGPUBackend, DrawListRenderer)
        case native(Device, NativeDrawListRenderer)
    }
    private let renderer: Renderer
    let viewportTextures: ViewportTextureRegistry

    init(device: AppRendererDevice?, config: AppConfig) throws {
        switch device ?? .wgpu(WGPUBackend(config: config.backendConfig)) {
        case .wgpu(let backend):
            let ui = DrawListRenderer(backend: backend)
            renderer = .wgpu(backend, ui)
            viewportTextures = ViewportTextureRegistry(renderer: ui)
        case .native(let device):
            let ui = try device.withFrameSession { try NativeDrawListRenderer(device: device) }
            renderer = .native(device, ui)
            viewportTextures = ViewportTextureRegistry(renderer: ui)
        }
    }

    func initialize() throws {
        if case .wgpu(let backend, _) = renderer { try backend.initialize() }
    }

    func makeWindow(settings: AppWindowRenderSettings) throws -> any AppWindowRenderer {
        switch renderer {
        case .wgpu(let backend, let ui):
            try ui.configure(format: .bgra8UnormSrgb, sampleCount: settings.samples)
            return WGPUAppWindowRenderer(backend: backend, renderer: ui, settings: settings)
        case .native(let device, let ui):
            try device.withFrameSession { try ui.configure(format: .bgra8UnormSRGB, sampleCount: Int(settings.samples)) }
            return NativeAppWindowRenderer(device: device, renderer: ui, settings: settings)
        }
    }

    func uploadFontAtlas(_ atlas: FontAtlas, textureID: TextureID) throws {
        switch renderer {
        case .wgpu(_, let ui): try ui.uploadFontAtlas(atlas, textureID: textureID)
        case .native(let device, let ui): try device.withFrameSession { try ui.uploadFontAtlas(atlas, textureID: textureID) }
        }
    }

    func attachFrameTap(to devTools: DevTools) throws {
        switch renderer {
        case .wgpu(let backend, let ui): devTools.attachFrameTap(backend: backend, renderer: ui)
        case .native(let device, let ui):
            let capture = try NativeAppFrameCapture(device: device, renderer: ui)
            devTools.attachFrameTap(capture: { list, width, height, logical in
                try capture.capture(list: list, size: SIMD2(Int(width), Int(height)),
                    logical: SIMD2(logical.width, logical.height))
            }, reset: { capture.reset() })
        }
    }
}
