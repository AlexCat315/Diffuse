import AssetPipeline
import Foundation
import PlatformShell
import RHIWGPU
import simd

@MainActor
public protocol Renderer {
    func initialize()
    func renderFrame(frameIndex: Int)
    func queueRenderSettings(_ settings: RenderSettings)
    func forceRenderSettings(_ settings: RenderSettings)
    func currentFrameStats() -> RenderFrameStats
    func currentViewportSurfaceState() -> ViewportSurfaceState
}

public extension Renderer {
    func queueRenderSettings(_ settings: RenderSettings) {
        _ = settings
    }

    func forceRenderSettings(_ settings: RenderSettings) {
        _ = settings
    }

    func currentFrameStats() -> RenderFrameStats {
        .init()
    }

    func currentViewportSurfaceState() -> ViewportSurfaceState {
        .init()
    }
}

@MainActor
public struct MetalPlaceholderRenderer: Renderer {
    public init() {}
    public func initialize() { print("[RenderBackend] initialize Metal placeholder") }
    public func renderFrame(frameIndex: Int) { print("[RenderBackend] render frame \(frameIndex)") }
}

/// One mesh resident on the GPU.
private struct GPUMesh {
    let vertexBuffer: GPUBuffer
    let indexBuffer: GPUBuffer
    let indexCount: UInt32
    let name: String
}

/// Per-instance GPU resources (uniform buffer + bind group). One slot per draw call.
private struct InstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
}

/// Shared uniform-buffer path using dynamic bind offsets.
private struct DynamicInstanceResources {
    let uniformBuffer: GPUBuffer
    let bindGroup: GPUBindGroup
    let stride: UInt64
}

///  RHIWGPU renderer: scene of multiple instances drawn through one shared pipeline.
@MainActor
public final class WGPURenderer: Renderer {
    private let backend: WGPUBackend
    private let shell: any Shell
    private var surface: GPUSurface?
    private var configuredSize: (width: UInt32, height: UInt32) = (0, 0)
    private let format: GPUTextureFormat = .bgra8Unorm
    private let depthFormat: GPUTextureFormat = .depth32Float

    private var meshPipeline: GPURenderPipeline?
    private var depthTexture: GPUTexture?
    private var depthView: GPUTextureView?

    private var meshes: [GPUMesh] = []
    private var instanceResources: [InstanceResources] = []
    private var dynamicInstanceResources: DynamicInstanceResources?
    private var scene: RenderScene = RenderScene(
        camera: RenderCamera(eye: SIMD3<Float>(0, 1.4, 3.0)))

    private let dynamicOffsetThreshold = 64
    private let dynamicUniformStride: UInt64 = 256

    private var activeRenderSettings: RenderSettings = .init()
    private var pendingRenderSettings: RenderSettings?
    private var settingsGeneration: UInt64 = 0
    private var viewportSurfaceState: ViewportSurfaceState = .init()

    public private(set) var lastFrameStats: RenderFrameStats = .init()

    public init(backend: WGPUBackend, shell: any Shell) {
        self.backend = backend
        self.shell = shell
    }

    public func initialize() {
        guard let renderSurface = shell.renderSurface else {
            print("[WGPURenderer] no render surface; skipping surface creation")
            return
        }
        do {
            switch renderSurface {
                case let .metalLayer(layerPointer):
                    surface = try backend.createSurfaceMetal(layer: layerPointer)
            }
            try ensureConfigured()
            try ensureMeshPipelineAndScene()
            print(
                "[WGPURenderer] surface ready, size=\(configuredSize), pipeline=\(meshPipeline != nil), depth=\(depthView != nil), meshes=\(meshes.count), instances=\(scene.instances.count), dynamic=\(dynamicInstanceResources != nil)"
            )
        } catch {
            print("[WGPURenderer] initialize failed: \(error)")
        }
    }

    public func queueRenderSettings(_ settings: RenderSettings) {
        pendingRenderSettings = settings
    }

    public func forceRenderSettings(_ settings: RenderSettings) {
        pendingRenderSettings = nil
        activeRenderSettings = settings
        settingsGeneration &+= 1
    }

    public func currentFrameStats() -> RenderFrameStats {
        lastFrameStats
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        viewportSurfaceState
    }

    public func renderFrame(frameIndex: Int) {
        guard let surface else { return }
        do {
            applyPendingRenderSettingsIfNeeded(frameIndex: frameIndex)
            try ensureConfigured()
            try ensureMeshPipelineAndScene()
            guard let acquired = try surface.getCurrentTextureView(),
                let depthView,
                let pipeline = meshPipeline
            else {
                return
            }

            // Animate scene + upload per-instance MVPs.
            updateSceneTransforms(frameIndex: frameIndex)
            let viewProj = computeViewProj()
            writeInstanceUniforms(viewProj: viewProj)

            let framePlan = RenderFramePlanner.makePlan(settings: activeRenderSettings)
            var drawCallCount = 0
            var viewportResolved = false
            let encoder = try backend.createCommandEncoder()
            for passKind in framePlan.passes {
                switch passKind {
                    case .basePass:
                        drawCallCount += try encodeBasePass(
                            encoder: encoder,
                            colorView: acquired.view,
                            depthView: depthView,
                            pipeline: pipeline
                        )

                    case .depthPrepass,
                         .shadowPass,
                         .ssao,
                         .bloom,
                         .fxaa,
                         .tonemap:
                        emitPlannedPassLog(passKind, frameIndex: frameIndex)

                    case .viewportResolve:
                        registerViewportSurface(texture: acquired.texture)
                        viewportResolved = true
                        emitPlannedPassLog(passKind, frameIndex: frameIndex)
                }
            }

            if !viewportResolved {
                viewportSurfaceState = .init()
            }

            let cmd = try encoder.finish()
            backend.submit(cmd)
            surface.present()

            lastFrameStats = RenderFrameStats(
                frameIndex: frameIndex,
                passCount: framePlan.passes.count,
                drawCallCount: drawCallCount,
                activePasses: framePlan.passes,
                settingsGeneration: settingsGeneration
            )
        } catch {
            print("[WGPURenderer] frame \(frameIndex) failed: \(error)")
        }
    }

    private func applyPendingRenderSettingsIfNeeded(frameIndex: Int) {
        guard let pending = pendingRenderSettings else { return }
        pendingRenderSettings = nil
        activeRenderSettings = pending
        settingsGeneration &+= 1

        if shouldEmitPlannerLog(frameIndex: frameIndex) {
            print(
                "[WGPURenderer] applied render settings in-frame generation=\(settingsGeneration) stage=\(pending.stage.rawValue) fxaa=\(pending.enableFXAA) ssao=\(pending.enableSSAO) bloom=\(pending.enableBloom)"
            )
        }
    }

    private func writeInstanceUniforms(viewProj: simd_float4x4) {
        if let dyn = dynamicInstanceResources {
            for (i, instance) in scene.instances.enumerated() {
                var mvp = viewProj * instance.transform
                let offset = UInt64(i) * dyn.stride
                withUnsafeBytes(of: &mvp) { raw in
                    if let base = raw.baseAddress {
                        backend.writeBuffer(
                            dyn.uniformBuffer, data: base, size: raw.count, offset: offset)
                    }
                }
            }
            return
        }

        for (i, instance) in scene.instances.enumerated() where i < instanceResources.count {
            var mvp = viewProj * instance.transform
            withUnsafeBytes(of: &mvp) { raw in
                if let base = raw.baseAddress {
                    backend.writeBuffer(instanceResources[i].uniformBuffer, data: base, size: raw.count)
                }
            }
        }
    }

    private func encodeBasePass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline
    ) throws -> Int {
        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: .clear,
            storeOp: .store,
            clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1.0),
            depthView: depthView,
            depthLoadOp: .clear,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )

        pass.setPipeline(pipeline)
        var drawCallCount = 0
        if let dyn = dynamicInstanceResources {
            for (i, instance) in scene.instances.enumerated() {
                guard meshes.indices.contains(instance.meshIndex) else { continue }
                let mesh = meshes[instance.meshIndex]
                let drawOffset = UInt64(i) * dyn.stride
                guard drawOffset <= UInt64(UInt32.max) else { continue }
                pass.setBindGroup(dyn.bindGroup, index: 0, dynamicOffsets: [UInt32(drawOffset)])
                pass.setVertexBuffer(mesh.vertexBuffer, slot: 0)
                pass.setIndexBuffer(mesh.indexBuffer, format: .uint32)
                pass.drawIndexed(indexCount: mesh.indexCount)
                drawCallCount += 1
            }
        } else {
            for (i, instance) in scene.instances.enumerated() where i < instanceResources.count {
                guard meshes.indices.contains(instance.meshIndex) else { continue }
                let mesh = meshes[instance.meshIndex]
                pass.setBindGroup(instanceResources[i].bindGroup, index: 0)
                pass.setVertexBuffer(mesh.vertexBuffer, slot: 0)
                pass.setIndexBuffer(mesh.indexBuffer, format: .uint32)
                pass.drawIndexed(indexCount: mesh.indexCount)
                drawCallCount += 1
            }
        }
        pass.end()

        return drawCallCount
    }

    private func emitPlannedPassLog(_ passKind: RenderPassKind, frameIndex: Int) {
        guard shouldEmitPlannerLog(frameIndex: frameIndex) else { return }
        print("[WGPURenderer][plan] executing placeholder pass=\(passKind.rawValue)")
    }

    private func shouldEmitPlannerLog(frameIndex: Int) -> Bool {
        frameIndex == 0 || frameIndex % 120 == 0
    }

    private func registerViewportSurface(texture: GPUTexture) {
        let pointerValue = UInt64(UInt(bitPattern: Unmanaged.passUnretained(texture).toOpaque()))
        viewportSurfaceState = ViewportSurfaceState(
            surfaceID: pointerValue,
            width: configuredSize.width,
            height: configuredSize.height,
            zeroCopy: true
        )
    }

    // MARK: - Pipeline + scene construction

    private func ensureMeshPipelineAndScene() throws {
        if meshPipeline != nil { return }
        guard backend.rawDevice != nil else { return }

        let module = try backend.createShaderModule(wgsl: Self.wgsl, label: "mesh_lit")

        let vbLayout = GPUVertexBufferLayout(
            arrayStride: UInt64(MeshAsset.vertexStride),
            attributes: [
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.positionOffset), shaderLocation: 0),
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.normalOffset), shaderLocation: 1),
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.colorOffset), shaderLocation: 2),
            ]
        )

        // 1. Build mesh table.
        let cube = BuiltinMesh.cube()
        let cubeMesh = try uploadMesh(cube)
        var objMesh: GPUMesh?
        if let url = Bundle.module.url(forResource: "FinalBaseMesh", withExtension: "obj") {
            do {
                var obj = try OBJLoader.load(path: url.path)
                obj.normalizeToUnitBounds(targetSize: 2.0)
                objMesh = try uploadMesh(obj)
            } catch {
                print("[WGPURenderer] OBJ load failed (\(error)); skipping fixture mesh")
            }
        }
        meshes.append(cubeMesh)
        if let objMesh { meshes.append(objMesh) }

        let cubeIndex = 0
        let objIndex = meshes.count > 1 ? 1 : 0

        // 2. Build scene: 1 fixture mesh in center + 4 cubes orbiting.
        var instances: [RenderInstance] = []
        instances.append(RenderInstance(meshIndex: objIndex, transform: matrix_identity_float4x4))
        for k in 0..<4 {
            let angle = Float(k) * (.pi / 2)
            let r: Float = 2.5
            let pos = SIMD3<Float>(cos(angle) * r, 0, sin(angle) * r)
            let m = translation(pos) * uniformScale(0.4)
            instances.append(RenderInstance(meshIndex: cubeIndex, transform: m))
        }
        scene = RenderScene(
            camera: RenderCamera(eye: SIMD3<Float>(0, 2.0, 5.5), target: .zero),
            instances: instances
        )

        let useDynamicOffsets = instances.count > dynamicOffsetThreshold

        let pipeline: GPURenderPipeline
        let bindGroupLayout: GPUBindGroupLayout
        if useDynamicOffsets {
            bindGroupLayout = try backend.createBindGroupLayout(entries: [
                GPUBindGroupLayoutEntry(
                    binding: 0,
                    visibility: .vertex,
                    type: .uniformBuffer,
                    hasDynamicOffset: true)
            ])
            let pipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [bindGroupLayout])
            pipeline = try backend.createRenderPipeline(
                desc: GPURenderPipelineDescriptor(
                    shaderModule: module,
                    pipelineLayout: pipelineLayout,
                    colorFormat: format,
                    cullMode: .back,
                    vertexBuffers: [vbLayout],
                    depthStencil: GPUDepthStencilPipelineState(
                        format: depthFormat,
                        depthWriteEnabled: true,
                        depthCompare: .less
                    )
                ))
        } else {
            pipeline = try backend.createRenderPipeline(
                desc: GPURenderPipelineDescriptor(
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
            bindGroupLayout = try pipeline.getBindGroupLayout(group: 0)
        }
        meshPipeline = pipeline

        // 3. Allocate per-instance uniform buffer + bind group.
        instanceResources.removeAll(keepingCapacity: true)
        dynamicInstanceResources = nil
        if useDynamicOffsets {
            let totalSize = UInt64(instances.count) * dynamicUniformStride
            let ub = try backend.createBuffer(size: totalSize, usage: [.uniform, .copyDst])
            let bg = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: [GPUBindGroupEntry(binding: 0, buffer: ub, offset: 0, size: 64)]
            )
            dynamicInstanceResources = DynamicInstanceResources(
                uniformBuffer: ub,
                bindGroup: bg,
                stride: dynamicUniformStride
            )
        } else {
            for _ in instances {
                let ub = try backend.createBuffer(size: 64, usage: [.uniform, .copyDst])
                let bg = try backend.createBindGroup(
                    layout: bindGroupLayout,
                    entries: [GPUBindGroupEntry(binding: 0, buffer: ub, offset: 0, size: 64)]
                )
                instanceResources.append(InstanceResources(uniformBuffer: ub, bindGroup: bg))
            }
        }

        print(
            "[WGPURenderer] scene built: meshes=\(meshes.map(\.name)) instances=\(instances.count) dynamic=\(useDynamicOffsets)")
    }

    private func uploadMesh(_ mesh: MeshAsset) throws -> GPUMesh {
        let vb = try backend.createBuffer(
            size: UInt64(mesh.vertexBufferSize), usage: [.vertex, .copyDst])
        mesh.vertices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(vb, data: base, size: raw.count)
            }
        }
        let ib = try backend.createBuffer(
            size: UInt64(mesh.indexBufferSize), usage: [.index, .copyDst])
        mesh.indices.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(ib, data: base, size: raw.count)
            }
        }
        return GPUMesh(
            vertexBuffer: vb, indexBuffer: ib, indexCount: mesh.indexCount, name: mesh.name)
    }

    private func ensureConfigured() throws {
        guard let surface, let device = backend.rawDevice else { return }
        let size = shell.drawableSize
        if size.width == configuredSize.width && size.height == configuredSize.height
            && configuredSize.width > 0
        {
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

    // MARK: - Per-frame animation

    private func updateSceneTransforms(frameIndex: Int) {
        let t = Float(frameIndex) * 0.015
        // Center fixture rotates around Y.
        if !scene.instances.isEmpty {
            scene.instances[0].transform = rotationY(t)
        }
        // Orbiting cubes rotate around the central axis and spin individually.
        for k in 0..<4 {
            let idx = 1 + k
            guard idx < scene.instances.count else { break }
            let baseAngle = Float(k) * (.pi / 2) + t * 0.5
            let r: Float = 2.5
            let pos = SIMD3<Float>(
                cos(baseAngle) * r, sin(t * 0.4 + Float(k)) * 0.4, sin(baseAngle) * r)
            let m = translation(pos) * rotationY(t * 1.5 + Float(k)) * uniformScale(0.4)
            scene.instances[idx].transform = m
        }
    }

    private func computeViewProj() -> simd_float4x4 {
        let aspect = Float(max(configuredSize.width, 1)) / Float(max(configuredSize.height, 1))
        let cam = scene.camera
        let proj = perspective(
            fovYRadians: cam.fovYRadians, aspect: aspect, near: cam.near, far: cam.far)
        let view = lookAt(eye: cam.eye, target: cam.target, up: cam.up)
        return proj * view
    }

    // MARK: - Shader

    private static let wgsl: String = """
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
}

// MARK: - Math helpers (right-handed, depth 0..1)

private func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float)
    -> simd_float4x4
{
    let f = 1.0 / tan(fovYRadians * 0.5)
    let nf = 1.0 / (near - far)
    return simd_float4x4(rows: [
        SIMD4<Float>(f / aspect, 0, 0, 0),
        SIMD4<Float>(0, f, 0, 0),
        SIMD4<Float>(0, 0, far * nf, near * far * nf),
        SIMD4<Float>(0, 0, -1, 0),
    ])
}

private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(rows: [
        SIMD4<Float>(s.x, s.y, s.z, -simd_dot(s, eye)),
        SIMD4<Float>(u.x, u.y, u.z, -simd_dot(u, eye)),
        SIMD4<Float>(-f.x, -f.y, -f.z, simd_dot(f, eye)),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, t.x),
        SIMD4<Float>(0, 1, 0, t.y),
        SIMD4<Float>(0, 0, 1, t.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func uniformScale(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
}

private func rotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle)
    let s = sin(angle)
    return simd_float4x4(rows: [
        SIMD4<Float>(c, 0, s, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(-s, 0, c, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}
