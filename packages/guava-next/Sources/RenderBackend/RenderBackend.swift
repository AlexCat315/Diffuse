import Foundation
import simd
import RHIWGPU
import PlatformShell
import AssetPipeline

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

/// R1-stage RHIWGPU renderer: lit cube mesh through a perspective camera with depth buffer.
@MainActor
public final class WGPURenderer: Renderer {
    private let backend: WGPUBackend
    private let shell: any Shell
    private var surface: GPUSurface?
    private var configuredSize: (width: UInt32, height: UInt32) = (0, 0)
    private let format: GPUTextureFormat = .bgra8Unorm
    private let depthFormat: GPUTextureFormat = .depth32Float

    private var meshPipeline: GPURenderPipeline?
    private var vertexBuffer: GPUBuffer?
    private var indexBuffer: GPUBuffer?
    private var indexCount: UInt32 = 0
    private var uniformBuffer: GPUBuffer?
    private var bindGroup: GPUBindGroup?
    private var depthTexture: GPUTexture?
    private var depthView: GPUTextureView?

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
            try ensureMeshPipeline()
            print("[WGPURenderer] surface ready, format=\(format), size=\(configuredSize), pipeline=\(meshPipeline != nil), depth=\(depthView != nil)")
        } catch {
            print("[WGPURenderer] initialize failed: \(error)")
        }
    }

    public func renderFrame(frameIndex: Int) {
        guard let surface else { return }
        do {
            try ensureConfigured()
            try ensureMeshPipeline()
            guard let acquired = try surface.getCurrentTextureView(),
                  let depthView else {
                return
            }

            if let uniformBuffer {
                var matrix = computeMVP(frameIndex: frameIndex)
                withUnsafeBytes(of: &matrix) { raw in
                    if let base = raw.baseAddress {
                        backend.writeBuffer(uniformBuffer, data: base, size: raw.count)
                    }
                }
            }

            let encoder = try backend.createCommandEncoder()
            let pass = try encoder.beginRenderPass(
                colorView: acquired.view,
                loadOp: .clear,
                storeOp: .store,
                clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1.0),
                depthView: depthView,
                depthLoadOp: .clear,
                depthStoreOp: .store,
                depthClearValue: 1.0
            )
            if let pipeline = meshPipeline,
               let vb = vertexBuffer,
               let ib = indexBuffer,
               let bg = bindGroup {
                pass.setPipeline(pipeline)
                pass.setBindGroup(bg, index: 0)
                pass.setVertexBuffer(vb, slot: 0)
                pass.setIndexBuffer(ib, format: .uint32)
                pass.drawIndexed(indexCount: indexCount)
            }
            pass.end()
            let cmd = try encoder.finish()
            backend.submit(cmd)
            surface.present()
        } catch {
            print("[WGPURenderer] frame \(frameIndex) failed: \(error)")
        }
    }

    private func ensureMeshPipeline() throws {
        if meshPipeline != nil { return }
        guard backend.rawDevice != nil else { return }

        let wgsl = """
        struct Uniforms {
            mvp : mat4x4<f32>,
        };
        @group(0) @binding(0) var<uniform> u : Uniforms;

        struct VsIn {
            @location(0) pos    : vec3<f32>,
            @location(1) normal : vec3<f32>,
            @location(2) color  : vec3<f32>,
        };
        struct VsOut {
            @builtin(position) pos : vec4<f32>,
            @location(0) color    : vec3<f32>,
            @location(1) normal   : vec3<f32>,
        };

        @vertex
        fn vs_main(in : VsIn) -> VsOut {
            var out : VsOut;
            out.pos = u.mvp * vec4<f32>(in.pos, 1.0);
            out.color = in.color;
            out.normal = in.normal;
            return out;
        }

        @fragment
        fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
            let lightDir = normalize(vec3<f32>(0.4, 0.8, 0.6));
            let n = normalize(in.normal);
            let lambert = max(dot(n, lightDir), 0.0);
            let lit = in.color * (0.25 + lambert * 0.85);
            return vec4<f32>(lit, 1.0);
        }
        """
        let module = try backend.createShaderModule(wgsl: wgsl, label: "mesh_lit")

        let vbLayout = GPUVertexBufferLayout(
            arrayStride: UInt64(MeshAsset.vertexStride),
            attributes: [
                GPUVertexAttribute(format: .float32x3, offset: UInt64(MeshAsset.positionOffset), shaderLocation: 0),
                GPUVertexAttribute(format: .float32x3, offset: UInt64(MeshAsset.normalOffset),   shaderLocation: 1),
                GPUVertexAttribute(format: .float32x3, offset: UInt64(MeshAsset.colorOffset),    shaderLocation: 2),
            ]
        )

        let pipeline = try backend.createRenderPipeline(desc: GPURenderPipelineDescriptor(
            shaderModule: module,
            colorFormat: format,
            cullMode: .back,
            vertexBuffers: [vbLayout],
            depthStencil: GPUDepthStencilPipelineState(
                format: depthFormat,
                depthWriteEnabled: true,
                depthCompare: .less
            )
        ))
        meshPipeline = pipeline

        let mesh = BuiltinMesh.cube()
        indexCount = mesh.indexCount

        let vb = try backend.createBuffer(size: UInt64(mesh.vertexBufferSize), usage: [.vertex, .copyDst])
        mesh.vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(vb, data: base, size: raw.count)
            }
        }
        vertexBuffer = vb

        let ib = try backend.createBuffer(size: UInt64(mesh.indexBufferSize), usage: [.index, .copyDst])
        mesh.indices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(ib, data: base, size: raw.count)
            }
        }
        indexBuffer = ib

        let ub = try backend.createBuffer(size: 64, usage: [.uniform, .copyDst])
        uniformBuffer = ub

        let layout = try pipeline.getBindGroupLayout(group: 0)
        bindGroup = try backend.createBindGroup(
            layout: layout,
            entries: [GPUBindGroupEntry(binding: 0, buffer: ub, offset: 0, size: 64)]
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

        depthView = nil
        depthTexture = nil
        let depth = try backend.createTexture(
            width: size.width,
            height: size.height,
            format: depthFormat,
            usage: .renderAttachment
        )
        depthView = try depth.createView()
        depthTexture = depth
    }

    private func computeMVP(frameIndex: Int) -> simd_float4x4 {
        let aspect = Float(max(configuredSize.width, 1)) / Float(max(configuredSize.height, 1))
        let proj = perspective(fovYRadians: .pi / 4, aspect: aspect, near: 0.1, far: 100)
        let eye = SIMD3<Float>(0, 1.4, 3.0)
        let view = lookAt(eye: eye, target: SIMD3<Float>(0, 0, 0), up: SIMD3<Float>(0, 1, 0))
        let angle = Float(frameIndex) * 0.015
        let modelY = rotationY(angle)
        let modelX = rotationX(angle * 0.6)
        let model = modelY * modelX
        return proj * view * model
    }
}

// MARK: - Math helpers (right-handed, depth 0..1)

private func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let f = 1.0 / tan(fovYRadians * 0.5)
    let nf = 1.0 / (near - far)
    return simd_float4x4(rows: [
        SIMD4<Float>(f / aspect, 0,  0,                      0),
        SIMD4<Float>(0,          f,  0,                      0),
        SIMD4<Float>(0,          0,  far * nf,               near * far * nf),
        SIMD4<Float>(0,          0, -1,                      0),
    ])
}

private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(rows: [
        SIMD4<Float>(s.x,  s.y,  s.z, -simd_dot(s, eye)),
        SIMD4<Float>(u.x,  u.y,  u.z, -simd_dot(u, eye)),
        SIMD4<Float>(-f.x, -f.y, -f.z, simd_dot(f, eye)),
        SIMD4<Float>(0,    0,    0,   1),
    ])
}

private func rotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle); let s = sin(angle)
    return simd_float4x4(rows: [
        SIMD4<Float>(c,  0, s, 0),
        SIMD4<Float>(0,  1, 0, 0),
        SIMD4<Float>(-s, 0, c, 0),
        SIMD4<Float>(0,  0, 0, 1),
    ])
}

private func rotationX(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle); let s = sin(angle)
    return simd_float4x4(rows: [
        SIMD4<Float>(1, 0,  0, 0),
        SIMD4<Float>(0, c, -s, 0),
        SIMD4<Float>(0, s,  c, 0),
        SIMD4<Float>(0, 0,  0, 1),
    ])
}
