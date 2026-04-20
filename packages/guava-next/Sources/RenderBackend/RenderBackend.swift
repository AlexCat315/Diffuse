import Foundation
import RHIWGPU
import PlatformShell

@MainActor
public protocol Renderer {
    func initialize()
    func renderFrame(frameIndex: Int)
}

@MainActor
public struct MetalPlaceholderRenderer: Renderer {
    public init() {}

    public func initialize() {
        print("[RenderBackend] initialize Metal placeholder")
    }

    public func renderFrame(frameIndex: Int) {
        print("[RenderBackend] render frame \(frameIndex)")
    }
}

/// Real RHIWGPU-backed renderer that draws an animated clear color into the shell's CAMetalLayer.
@MainActor
public final class WGPURenderer: Renderer {
    private let backend: WGPUBackend
    private let shell: any Shell
    private var surface: GPUSurface?
    private var configuredSize: (width: UInt32, height: UInt32) = (0, 0)
    private let format: GPUTextureFormat = .bgra8Unorm

    public init(backend: WGPUBackend, shell: any Shell) {
        self.backend = backend
        self.shell = shell
    }

    public func initialize() {
        guard let layer = shell.metalLayer else {
            print("[WGPURenderer] no CAMetalLayer; skipping surface creation")
            return
        }
        do {
            let layerPtr = Unmanaged.passUnretained(layer).toOpaque()
            surface = try backend.createSurfaceMetal(layer: layerPtr)
            try ensureConfigured()
            print("[WGPURenderer] surface ready, format=\(format), size=\(configuredSize)")
        } catch {
            print("[WGPURenderer] initialize failed: \(error)")
        }
    }

    public func renderFrame(frameIndex: Int) {
        guard let surface, let device = backend.rawDevice else { return }
        do {
            try ensureConfigured()
            guard let acquired = try surface.getCurrentTextureView() else {
                return
            }

            let t = Double(frameIndex) * 0.03
            let r = 0.5 + 0.5 * sin(t)
            let g = 0.5 + 0.5 * sin(t + 2.094)
            let b = 0.5 + 0.5 * sin(t + 4.188)
            let clear = GPUColor(r: r, g: g, b: b, a: 1.0)

            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: acquired.view,
                loadOp: .clear,
                storeOp: .store,
                clearColor: clear
            )
            pass.end()
            let cmd = try encoder.finish()
            backend.submit(cmd)
            surface.present()
            _ = device // silence unused warning
        } catch {
            print("[WGPURenderer] frame \(frameIndex) failed: \(error)")
        }
    }

    private func ensureConfigured() throws {
        guard let surface, let device = backend.rawDevice else { return }
        let size = shell.drawableSize
        if size.width == configuredSize.width && size.height == configuredSize.height && configuredSize.width > 0 {
            return
        }
        try surface.configure(
            device: device,
            format: format,
            width: size.width,
            height: size.height,
            presentMode: .fifo
        )
        configuredSize = size
    }
}
