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
    private var rainbowPipeline: GPURenderPipeline?

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
            try ensureRainbowPipeline()
            print("[WGPURenderer] surface ready, format=\(format), size=\(configuredSize), pipeline=\(rainbowPipeline != nil)")
        } catch {
            print("[WGPURenderer] initialize failed: \(error)")
        }
    }

    public func renderFrame(frameIndex: Int) {
        guard let surface else { return }
        do {
            try ensureConfigured()
            try ensureRainbowPipeline()
            guard let acquired = try surface.getCurrentTextureView() else {
                return
            }

            let t = Double(frameIndex) * 0.03
            let r = 0.15 + 0.10 * sin(t)
            let g = 0.15 + 0.10 * sin(t + 2.094)
            let b = 0.15 + 0.10 * sin(t + 4.188)
            let clear = GPUColor(r: r, g: g, b: b, a: 1.0)

            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: acquired.view,
                loadOp: .clear,
                storeOp: .store,
                clearColor: clear
            )
            if let pipeline = rainbowPipeline {
                pass.setPipeline(pipeline)
                pass.draw(vertexCount: 3)
            }
            pass.end()
            let cmd = try encoder.finish()
            backend.submit(cmd)
            surface.present()
        } catch {
            print("[WGPURenderer] frame \(frameIndex) failed: \(error)")
        }
    }

    private func ensureRainbowPipeline() throws {
        if rainbowPipeline != nil { return }
        guard backend.rawDevice != nil else { return }
        let wgsl = """
        struct VsOut {
            @builtin(position) pos : vec4<f32>,
            @location(0) color    : vec3<f32>,
        };

        @vertex
        fn vs_main(@builtin(vertex_index) vid : u32) -> VsOut {
            var positions = array<vec2<f32>, 3>(
                vec2<f32>( 0.0,  0.6),
                vec2<f32>(-0.6, -0.5),
                vec2<f32>( 0.6, -0.5),
            );
            var colors = array<vec3<f32>, 3>(
                vec3<f32>(1.0, 0.0, 0.0),
                vec3<f32>(0.0, 1.0, 0.0),
                vec3<f32>(0.0, 0.0, 1.0),
            );
            var out : VsOut;
            out.pos = vec4<f32>(positions[vid], 0.0, 1.0);
            out.color = colors[vid];
            return out;
        }

        @fragment
        fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
            return vec4<f32>(in.color, 1.0);
        }
        """
        let module = try backend.createShaderModule(wgsl: wgsl, label: "rainbow")
        let desc = GPURenderPipelineDescriptor(
            shaderModule: module,
            colorFormat: format
        )
        rainbowPipeline = try backend.createRenderPipeline(desc: desc)
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
