import GuavaUIRuntime
import Logging
import PlatformShell
import RHIWGPU

@MainActor
final class WGPUAppWindowRenderer: AppWindowRenderer {
    private struct Multisample {
        let texture: GPUTexture
        let view: GPUTextureView
        let size: SIMD2<UInt32>
    }
    private let backend: WGPUBackend
    private let renderer: DrawListRenderer
    private let settings: AppWindowRenderSettings
    private var surface: GPUSurface?
    private var size = SIMD2<UInt32>(repeating: 0)
    private var multisample: Multisample?

    var isConfigured: Bool { surface != nil }

    init(backend: WGPUBackend, renderer: DrawListRenderer, settings: AppWindowRenderSettings) {
        self.backend = backend; self.renderer = renderer; self.settings = settings
    }

    func configure(native: NativeRenderSurface, size: SIMD2<UInt32>, vsync: Bool) throws {
        let surface = try SurfaceFactory.make(backend: backend, native: native)
        try configure(surface: surface, size: size, vsync: vsync)
        self.surface = surface
        if !vsync { native.disableDisplaySync() }
    }

    func resize(size: SIMD2<UInt32>, vsync: Bool) throws {
        guard let surface else { return }
        guard size.x > 0 && size.y > 0 else { self.size = size; return }
        try configure(surface: surface, size: size, vsync: vsync)
    }

    private func configure(surface: GPUSurface, size: SIMD2<UInt32>, vsync: Bool) throws {
        guard let device = backend.rawDevice else { throw WGPUBackendError.initFailed("UI device is not initialized") }
        try surface.configure(device: device, format: .bgra8UnormSrgb, width: size.x, height: size.y,
            presentMode: resolvePresentMode(surface: surface, vsync: vsync))
        if settings.samples > 1, multisample?.size != size {
            let texture = try backend.createTexture(width: size.x, height: size.y, format: .bgra8UnormSrgb,
                usage: [.renderAttachment], sampleCount: settings.samples)
            multisample = Multisample(texture: texture, view: try texture.createView(), size: size)
        }
        self.size = size
    }

    func draw(list: DrawList, logical: SIMD2<Float>) throws -> Bool {
        guard let surface, size.x > 0 && size.y > 0,
              let image = try surface.getCurrentTextureView() else { return false }
        let encoder = try backend.createCommandEncoder()
        let pass = try encoder.beginRenderPass(colorView: multisample?.view ?? image.view,
            resolveTargetView: multisample == nil ? nil : image.view, loadOp: .clear, storeOp: .store,
            clearColor: settings.clearColor)
        try renderer.render(list: list, pass: pass, viewportPx: (size.x, size.y), coordinateSpace: (logical.x, logical.y))
        pass.end()
        backend.submit(try encoder.finish())
        surface.present()
        return true
    }

    func close() throws { multisample = nil; surface = nil; size = .zero }

    private func resolvePresentMode(surface: GPUSurface, vsync: Bool) -> GPUPresentMode {
        guard let adapter = backend.rawAdapter else { return .fifo }
        do {
            let supported = try surface.supportedPresentModes(adapter: adapter)
            let candidates = Self.presentModeCandidates(vsyncEnabled: vsync, preferred: settings.preferredPresentMode)
            return candidates.first { supported.contains($0) } ?? supported.first ?? .fifo
        } catch {
            Logger(label: "com.guava.ui.app").warning("Present mode query failed: \(error); using FIFO")
            return .fifo
        }
    }

    static func presentModeCandidates(vsyncEnabled: Bool, preferred: GPUPresentMode) -> [GPUPresentMode] {
        let desired: [GPUPresentMode]
        if vsyncEnabled { desired = preferred == .fifo || preferred == .immediate ? [preferred, .fifo] : [preferred, .immediate, .fifo] }
        else { desired = [.immediate, .fifo] }
        var result: [GPUPresentMode] = []
        for mode in desired where !result.contains(mode) { result.append(mode) }
        return result
    }
}
