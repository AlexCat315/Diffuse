import AssetPipeline
import Foundation
import Logging
import RHIWGPU
import SceneRuntime
import simd

public final class MetalPlaceholderRenderer: RenderPacketConsumer, @unchecked Sendable {
    public init() {}
    public func initialize() { Logger.renderer.debug("initialize Metal placeholder") }
    public func render(packet: RenderPacket) {
        Logger.renderer.debug("render frame \(packet.frameIndex)")
    }

    public func currentFrameStats() -> RenderFrameStats { .init() }
    public func currentViewportSurfaceState() -> ViewportSurfaceState { .init() }
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
    let capacity: Int
}

///  RHIWGPU renderer: scene of multiple instances drawn through one shared pipeline.
public final class WGPURenderer: RenderPacketConsumer, @unchecked Sendable {
    private let backend: WGPUBackend
    private let renderSurface: RenderSurfaceDescriptor?
    private var surface: GPUSurface?
    private var configuredSize: RenderDrawableSize = .init(width: 0, height: 0)
    private let format: GPUTextureFormat = .bgra8Unorm
    private let depthFormat: GPUTextureFormat = .depth32Float

    private var meshPipeline: GPURenderPipeline?
    private var offscreenColorTexture: GPUTexture?
    private var offscreenColorView: GPUTextureView?
    private var depthTexture: GPUTexture?
    private var depthView: GPUTextureView?

    private var meshes: [GPUMesh] = []
    private var instanceResources: [InstanceResources] = []
    private var dynamicInstanceResources: DynamicInstanceResources?

    private let dynamicOffsetThreshold = 64
    private let dynamicUniformStride: UInt64 = 256

    private var activeRenderSettings: RenderSettings = .init()
    private var settingsGeneration: UInt64 = 0
    private var viewportSurfaceState: ViewportSurfaceState = .init()

    public private(set) var lastFrameStats: RenderFrameStats = .init()

    public init(backend: WGPUBackend, renderSurface: RenderSurfaceDescriptor? = nil) {
        self.backend = backend
        self.renderSurface = renderSurface
    }

    public func initialize() {
        do {
            if let renderSurface {
                switch renderSurface {
                    case let .metalLayer(layerPointer):
                        surface = try backend.createSurfaceMetal(layer: layerPointer)

                    case let .win32Window(hwnd, hinstance):
                        surface = try backend.createSurfaceWin32(hwnd: hwnd, hinstance: hinstance)

                    case let .xlibWindow(display, window):
                        surface = try backend.createSurfaceXlib(display: display, window: window)

                    case let .waylandSurface(display, wlSurface):
                        surface = try backend.createSurfaceWayland(display: display, surface: wlSurface)
                }
                Logger.renderer.info("surface ready, waiting for first render packet")
            } else {
                Logger.renderer.info("offscreen viewport renderer ready, waiting for first render packet")
            }
        } catch {
            Logger.renderer.error("initialize failed: \(error)")
        }
    }

    public func currentFrameStats() -> RenderFrameStats {
        lastFrameStats
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        viewportSurfaceState
    }

    public func render(packet: RenderPacket) {
        do {
            applyPacketRenderSettingsIfNeeded(packet.renderSettings, frameIndex: packet.frameIndex)
            try ensureConfigured(size: packet.drawableSize)
            try ensureMeshPipeline()
            try ensureInstanceResources(instanceCount: packet.scene.instances.count)
            guard let colorTarget = try acquireColorTarget(),
                let depthView,
                let pipeline = meshPipeline
            else {
                return
            }

            let viewProj = computeViewProj(scene: packet.scene, drawableSize: packet.drawableSize)
            writeInstanceUniforms(scene: packet.scene, viewProj: viewProj)

            let framePlan = RenderFramePlanner.makePlan(settings: activeRenderSettings)
            var drawCallCount = 0
            var viewportResolved = false
            let encoder = try backend.createCommandEncoder()
            for passKind in framePlan.passes {
                switch passKind {
                    case .basePass:
                        drawCallCount += try encodeBasePass(
                            encoder: encoder,
                            colorView: colorTarget.view,
                            depthView: depthView,
                            pipeline: pipeline,
                            scene: packet.scene
                        )

                    case .depthPrepass,
                         .shadowPass,
                         .ssao,
                         .bloom,
                         .fxaa,
                         .tonemap:
                        emitPlannedPassLog(passKind, frameIndex: packet.frameIndex)

                    case .viewportResolve:
                        registerViewportSurface(texture: colorTarget.texture, size: packet.drawableSize)
                        viewportResolved = true
                        emitPlannedPassLog(passKind, frameIndex: packet.frameIndex)
                }
            }

            if !viewportResolved {
                viewportSurfaceState = .init()
            }

            let cmd = try encoder.finish()
            backend.submit(cmd)
            if colorTarget.presentAfterSubmit {
                surface?.present()
            }

            lastFrameStats = RenderFrameStats(
                frameIndex: packet.frameIndex,
                passCount: framePlan.passes.count,
                drawCallCount: drawCallCount,
                activePasses: framePlan.passes,
                settingsGeneration: settingsGeneration
            )
        } catch {
            Logger.renderer.error("frame \(packet.frameIndex) failed: \(error)")
        }
    }

    private struct FrameColorTarget {
        let texture: GPUTexture
        let view: GPUTextureView
        let presentAfterSubmit: Bool
    }

    private func acquireColorTarget() throws -> FrameColorTarget? {
        if let surface {
            guard let acquired = try surface.getCurrentTextureView() else {
                return nil
            }
            return FrameColorTarget(
                texture: acquired.texture,
                view: acquired.view,
                presentAfterSubmit: true
            )
        }

        guard let offscreenColorTexture, let offscreenColorView else {
            return nil
        }
        return FrameColorTarget(
            texture: offscreenColorTexture,
            view: offscreenColorView,
            presentAfterSubmit: false
        )
    }

    private func applyPacketRenderSettingsIfNeeded(_ settings: RenderSettings, frameIndex: Int) {
        guard settings != activeRenderSettings else { return }
        activeRenderSettings = settings
        settingsGeneration &+= 1

        if shouldEmitPlannerLog(frameIndex: frameIndex) {
            let gen = settingsGeneration
            Logger.renderer.debug(
                "applied render settings generation=\(gen) stage=\(settings.stage.rawValue) fxaa=\(settings.enableFXAA) ssao=\(settings.enableSSAO) bloom=\(settings.enableBloom)"
            )
        }
    }

    private func writeInstanceUniforms(scene: RenderScene, viewProj: simd_float4x4) {
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
        pipeline: GPURenderPipeline,
        scene: RenderScene
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
        Logger.renderer.debug("executing placeholder pass=\(passKind.rawValue)")
    }

    private func shouldEmitPlannerLog(frameIndex: Int) -> Bool {
        frameIndex == 0 || frameIndex % 120 == 0
    }

    private func registerViewportSurface(texture: GPUTexture, size: RenderDrawableSize) {
        let pointerValue = UInt64(UInt(bitPattern: Unmanaged.passUnretained(texture).toOpaque()))
        viewportSurfaceState = ViewportSurfaceState(
            surfaceID: pointerValue,
            width: size.width,
            height: size.height,
            zeroCopy: true
        )
    }

    // MARK: - Pipeline + mesh construction

    private func ensureMeshPipeline() throws {
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
                Logger.renderer.error("OBJ load failed (\(error)); skipping fixture mesh")
            }
        }
        meshes.append(cubeMesh)
        if let objMesh { meshes.append(objMesh) }

        let pipeline: GPURenderPipeline
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
        meshPipeline = pipeline

        let _meshNames = meshes.map(\.name)
        Logger.renderer.info(
            "mesh table built: meshes=\(_meshNames)"
        )
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

    private func ensureInstanceResources(instanceCount: Int) throws {
        guard let pipeline = meshPipeline else { return }

        let useDynamicOffsets = instanceCount > dynamicOffsetThreshold
        let bindGroupLayout = try pipeline.getBindGroupLayout(group: 0)

        if useDynamicOffsets {
            if let dyn = dynamicInstanceResources, dyn.capacity >= instanceCount {
                return
            }
            instanceResources.removeAll(keepingCapacity: false)

            let totalSize = UInt64(max(instanceCount, 1)) * dynamicUniformStride
            let uniformBuffer = try backend.createBuffer(size: totalSize, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: [GPUBindGroupEntry(binding: 0, buffer: uniformBuffer, offset: 0, size: 64)]
            )
            dynamicInstanceResources = DynamicInstanceResources(
                uniformBuffer: uniformBuffer,
                bindGroup: bindGroup,
                stride: dynamicUniformStride,
                capacity: instanceCount
            )
            return
        }

        if dynamicInstanceResources == nil && instanceResources.count == instanceCount {
            return
        }

        dynamicInstanceResources = nil
        instanceResources.removeAll(keepingCapacity: false)
        for _ in 0..<instanceCount {
            let uniformBuffer = try backend.createBuffer(size: 64, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: [GPUBindGroupEntry(binding: 0, buffer: uniformBuffer, offset: 0, size: 64)]
            )
            instanceResources.append(
                InstanceResources(uniformBuffer: uniformBuffer, bindGroup: bindGroup))
        }
    }

    private func ensureConfigured(size: RenderDrawableSize) throws {
        guard backend.rawDevice != nil else { return }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        if width == configuredSize.width && height == configuredSize.height
            && configuredSize.width > 0
        {
            return
        }
        if let surface, let device = backend.rawDevice {
            try surface.configure(
                device: device,
                format: format,
                width: width,
                height: height,
                presentMode: .fifo
            )
            offscreenColorView = nil
            offscreenColorTexture = nil
        } else {
            let color = try backend.createTexture(
                width: width,
                height: height,
                format: format,
                usage: [.renderAttachment, .textureBinding]
            )
            offscreenColorView = try color.createView()
            offscreenColorTexture = color
        }
        configuredSize = .init(width: width, height: height)

        depthView = nil
        depthTexture = nil
        let depth = try backend.createTexture(
            width: width,
            height: height,
            format: depthFormat,
            usage: .renderAttachment
        )
        depthView = try depth.createView()
        depthTexture = depth
    }

    private func computeViewProj(scene: RenderScene, drawableSize: RenderDrawableSize) -> simd_float4x4 {
        let aspect = Float(max(drawableSize.width, 1)) / Float(max(drawableSize.height, 1))
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
