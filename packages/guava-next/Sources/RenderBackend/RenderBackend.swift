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
    private var vertexBuffer: GPUBuffer?
    private var indexBuffer: GPUBuffer?
    private var uniformBuffer: GPUBuffer?
    private var bindGroup: GPUBindGroup?

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
            print("[WGPURenderer] surface ready, format=\(format), size=\(configuredSize), pipeline=\(rainbowPipeline != nil), bindGroup=\(bindGroup != nil)")
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

            // Update uniform: rotation angle advances per frame.
            if let uniformBuffer {
                let uniforms: [Float] = [Float(frameIndex) * 0.02, 0, 0, 0]
                uniforms.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        backend.writeBuffer(uniformBuffer, data: base, size: raw.count)
                    }
                }
            }

            // Background sweeps a dim color so the rotating triangle stays the focus.
            let t = Double(frameIndex) * 0.03
            let r = 0.10 + 0.05 * sin(t)
            let g = 0.10 + 0.05 * sin(t + 2.094)
            let b = 0.10 + 0.05 * sin(t + 4.188)
            let clear = GPUColor(r: r, g: g, b: b, a: 1.0)

            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: acquired.view,
                loadOp: .clear,
                storeOp: .store,
                clearColor: clear
            )
            if let pipeline = rainbowPipeline,
               let vb = vertexBuffer,
               let ib = indexBuffer,
               let bg = bindGroup {
                pass.setPipeline(pipeline)
                pass.setBindGroup(bg, index: 0)
                pass.setVertexBuffer(vb, slot: 0)
                pass.setIndexBuffer(ib, format: .uint32)
                pass.drawIndexed(indexCount: 3)
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
        struct Uniforms {
            angle : f32,
            _pad0 : f32,
            _pad1 : f32,
            _pad2 : f32,
        };
        @group(0) @binding(0) var<uniform> u : Uniforms;

        struct VsIn {
            @location(0) pos   : vec2<f32>,
            @location(1) color : vec3<f32>,
        };
        struct VsOut {
            @builtin(position) pos : vec4<f32>,
            @location(0) color    : vec3<f32>,
        };

        @vertex
        fn vs_main(in : VsIn) -> VsOut {
            let c = cos(u.angle);
            let s = sin(u.angle);
            let rotated = vec2<f32>(in.pos.x * c - in.pos.y * s,
                                    in.pos.x * s + in.pos.y * c);
            var out : VsOut;
            out.pos = vec4<f32>(rotated, 0.0, 1.0);
            out.color = in.color;
            return out;
        }

        @fragment
        fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
            return vec4<f32>(in.color, 1.0);
        }
        """
        let module = try backend.createShaderModule(wgsl: wgsl, label: "rainbow")

        // Vertex layout: pos (vec2 f32) + color (vec3 f32), stride = 20 bytes.
        let vbLayout = GPUVertexBufferLayout(
            arrayStride: 20,
            attributes: [
                GPUVertexAttribute(format: .float32x2, offset: 0, shaderLocation: 0),
                GPUVertexAttribute(format: .float32x3, offset: 8, shaderLocation: 1),
            ]
        )

        let pipeline = try backend.createRenderPipeline(desc: GPURenderPipelineDescriptor(
            shaderModule: module,
            colorFormat: format,
            vertexBuffers: [vbLayout]
        ))
        rainbowPipeline = pipeline

        // Vertex/index/uniform buffers.
        let vertices: [Float] = [
             0.0,  0.6, 1.0, 0.0, 0.0,
            -0.6, -0.5, 0.0, 1.0, 0.0,
             0.6, -0.5, 0.0, 0.0, 1.0,
        ]
        let vbSize = UInt64(vertices.count * MemoryLayout<Float>.size)
        let vb = try backend.createBuffer(size: vbSize, usage: [.vertex, .copyDst])
        vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(vb, data: base, size: raw.count)
            }
        }
        vertexBuffer = vb

        let indices: [UInt32] = [0, 1, 2]
        let ibSize = UInt64(indices.count * MemoryLayout<UInt32>.size)
        let ib = try backend.createBuffer(size: ibSize, usage: [.index, .copyDst])
        indices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(ib, data: base, size: raw.count)
            }
        }
        indexBuffer = ib

        let ub = try backend.createBuffer(size: 16, usage: [.uniform, .copyDst])
        uniformBuffer = ub

        let layout = try pipeline.getBindGroupLayout(group: 0)
        bindGroup = try backend.createBindGroup(
            layout: layout,
            entries: [GPUBindGroupEntry(binding: 0, buffer: ub, offset: 0, size: 16)]
        )
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
