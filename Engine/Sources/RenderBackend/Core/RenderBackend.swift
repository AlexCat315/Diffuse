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

///  RHIWGPU renderer: scene of multiple instances drawn through one shared pipeline.
public final class WGPURenderer: RenderPacketConsumer, @unchecked Sendable {
    private let backend: WGPUBackend
    private let renderSurface: RenderSurfaceDescriptor?
    var surface: GPUSurface?
    private var configuredSize: RenderDrawableSize = .init(width: 0, height: 0)
    private let format: GPUTextureFormat = .bgra8Unorm
    private let hdrFormat: GPUTextureFormat = .rgba16Float
    private let depthFormat: GPUTextureFormat = .depth32Float

    private var meshPipelineLDR: GPURenderPipeline?
    private var meshPipelineHDR: GPURenderPipeline?
    private var stylizedMeshPipelineLDR: GPURenderPipeline?
    private var stylizedMeshPipelineHDR: GPURenderPipeline?
    private var outlinePipelineLDR: GPURenderPipeline?
    private var outlinePipelineHDR: GPURenderPipeline?
    private var meshBindGroupLayout: GPUBindGroupLayout?
    private var meshPipelineLayout: GPUPipelineLayout?
    private var skyboxPipeline: GPURenderPipeline?
    private var tonemapPipeline: GPURenderPipeline?
    private var bloomPipeline: GPURenderPipeline?
    private var inkPaperPostPipeline: GPURenderPipeline?
    private var fxaaPipeline: GPURenderPipeline?
    private var ssrPipeline: GPURenderPipeline?
    private var taaPipeline: GPURenderPipeline?
    private var ssaoPipeline: GPURenderPipeline?
    var offscreenColorTexture: GPUTexture?
    var offscreenColorView: GPUTextureView?
    private var depthTexture: GPUTexture?
    private var depthView: GPUTextureView?
    var publishedTextureRetainer: Unmanaged<GPUTexture>?
    var stalePublishedTextureRetainers: [Unmanaged<GPUTexture>] = []
    let publishedTextureRetainerHistoryLimit = 32
    var publishedSurfaceID: UInt64 = 0
    var publishedSurfaceHandle: UInt64 = 0
    var nextSurfaceID: UInt64 = 0
    private var sceneColorTarget: RenderTextureTarget?
    private var postProcessTargetA: RenderTextureTarget?
    private var postProcessTargetB: RenderTextureTarget?
    private var ldrPostProcessTarget: RenderTextureTarget?
    private var historyTarget: RenderTextureTarget?

    private var meshes: [GPUMesh] = []
    private var meshTextureResources: [Int: [Int: GPUMeshTextureResource]] = [:]
    private var instanceResources: [InstanceResources] = []
    private var instanceResourceMeshIndices: [Int] = []
    private var dynamicInstanceResources: DynamicInstanceResources?
    private var linearSampler: GPUSampler?
    private var nearestSampler: GPUSampler?
    private var fallbackMeshTexture: GPUTexture?
    private var fallbackMeshTextureView: GPUTextureView?
    private var skyboxUniformBuffer: GPUBuffer?
    private var tonemapUniformBuffer: GPUBuffer?
    private var bloomUniformBuffer: GPUBuffer?
    private var ssrUniformBuffer: GPUBuffer?
    private var taaUniformBuffer: GPUBuffer?
    private var ssaoUniformBuffer: GPUBuffer?
    private var stylizedCharacterUniformBuffer: GPUBuffer?
    var historyValid = false

    private let dynamicOffsetThreshold = 64
    private let dynamicUniformStride: UInt64 = 256

    var activeRenderSettings: RenderSettings = .init()
    var settingsGeneration: UInt64 = 0
    var viewportSurfaceState: ViewportSurfaceState = .init()

    public private(set) var lastFrameStats: RenderFrameStats = .init()

    public init(backend: WGPUBackend, renderSurface: RenderSurfaceDescriptor? = nil) {
        self.backend = backend
        self.renderSurface = renderSurface
    }

    deinit {
        publishedTextureRetainer?.release()
        publishedTextureRetainer = nil
        for retained in stalePublishedTextureRetainers {
            retained.release()
        }
        stalePublishedTextureRetainers.removeAll(keepingCapacity: false)
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
            let frameStartNS = DispatchTime.now().uptimeNanoseconds
            applyPacketRenderSettingsIfNeeded(packet.renderSettings, frameIndex: packet.frameIndex)
            let framePlan = RenderFramePlanner.makePlan(settings: activeRenderSettings)
            let usesHDRFrameGraph = framePlan.passes.contains(.tonemap)
            try ensureConfigured(size: packet.drawableSize)
            guard let colorTarget = try acquireColorTarget(),
                let depthView
            else {
                return
            }

            if usesHDRFrameGraph {
                try ensureFrameGraphResources(size: packet.drawableSize)
            }

            let cameraMatrices = RenderCameraMatrices.make(
                scene: packet.scene,
                drawableSize: packet.drawableSize
            )
            let meshPipeline = try ensureMeshPipeline(hdr: usesHDRFrameGraph)
            try ensureStylizedCharacterUniformBuffer()
            writeStylizedCharacterUniforms()
            try ensureInstanceResources(scene: packet.scene, pipeline: meshPipeline)
            writeInstanceUniforms(scene: packet.scene, viewProj: cameraMatrices.viewProjection)

            if framePlan.passes.contains(.skybox) {
                try ensureSkyboxPipeline()
            }
            if framePlan.passes.contains(.tonemap) {
                try ensureTonemapPipeline()
            }
            if framePlan.passes.contains(.bloom) {
                try ensureBloomPipeline()
            }
            if framePlan.passes.contains(.inkPaperPost) {
                try ensureInkPaperPostPipeline()
            }
            if framePlan.passes.contains(.fxaa) {
                try ensureFXAAPipeline()
            }
            if framePlan.passes.contains(.ssr) {
                try ensureSSRPipeline()
            }
            if framePlan.passes.contains(.taa) {
                try ensureTAAPipeline()
            }
            if framePlan.passes.contains(.ssao) {
                try ensureSSAOPipeline()
            }
            if framePlan.passes.contains(.outline) {
                _ = try ensureOutlinePipeline(hdr: usesHDRFrameGraph)
            }
            try ensureFullscreenResources()

            let prepareDoneNS = DispatchTime.now().uptimeNanoseconds

            var drawCallCount = 0
            var renderBundleCount = 0
            var renderBundleParallelJobs = 0
            var bundleRecordNS: UInt64 = 0
            var passEncodeNS: [RenderPassKind: UInt64] = [:]
            var cpuSkyboxEncodeNS: UInt64 = 0
            var cpuBaseEncodeNS: UInt64 = 0
            var cpuPostProcessEncodeNS: UInt64 = 0
            var viewportResolved = false
            var skyboxEncoded = false
            var hdrCurrent = sceneColorTarget
            var bloomTarget = sceneColorTarget
            let encoder = try backend.createCommandEncoder()

            for passKind in framePlan.passes {
                let passStartNS = DispatchTime.now().uptimeNanoseconds
                switch passKind {
                    case .skybox:
                        guard let target = sceneColorTarget,
                              let skyboxPipeline
                        else { break }
                        try encodeSkyboxPass(
                            encoder: encoder,
                            colorView: target.view,
                            depthView: depthView,
                            pipeline: skyboxPipeline,
                            viewProj: cameraMatrices.viewProjection
                        )
                        skyboxEncoded = true

                    case .basePass:
                        let report = try encodeBasePass(
                            encoder: encoder,
                            colorView: usesHDRFrameGraph ? sceneColorTarget?.view ?? colorTarget.view : colorTarget.view,
                            depthView: depthView,
                            pipeline: meshPipeline,
                            scene: packet.scene,
                            colorFormat: usesHDRFrameGraph ? hdrFormat : format,
                            colorLoadOp: skyboxEncoded ? .load : .clear,
                            depthLoadOp: skyboxEncoded ? .load : .clear
                        )
                        drawCallCount += report.drawCallCount
                        renderBundleCount += report.renderBundleCount
                        renderBundleParallelJobs += report.parallelJobCount
                        bundleRecordNS &+= report.bundleRecordNS

                    case .outline:
                        let outlinePipeline = try ensureOutlinePipeline(hdr: usesHDRFrameGraph)
                        drawCallCount += try encodeOutlinePass(
                            encoder: encoder,
                            colorView: usesHDRFrameGraph ? sceneColorTarget?.view ?? colorTarget.view : colorTarget.view,
                            depthView: depthView,
                            pipeline: outlinePipeline,
                            scene: packet.scene
                        )

                    case .inkPaperPost:
                        guard usesHDRFrameGraph,
                              let input = hdrCurrent,
                              let output = nextPingPongTarget(after: input),
                              let inkPaperPostPipeline
                        else {
                            emitPlannedPassLog(passKind, frameIndex: packet.frameIndex)
                            break
                        }
                        try encodeInkPaperPostPass(
                            encoder: encoder,
                            input: input,
                            output: output,
                            pipeline: inkPaperPostPipeline
                        )
                        hdrCurrent = output

                    case .ssao:
                        guard let input = hdrCurrent,
                              let output = nextPingPongTarget(after: input),
                              let depthTexture,
                              let ssaoPipeline
                        else { break }
                        try encodeSSAOPass(
                            encoder: encoder,
                            input: input,
                            output: output,
                            depthTexture: depthTexture,
                            pipeline: ssaoPipeline,
                            projection: cameraMatrices.projection
                        )
                        hdrCurrent = output

                    case .ssr:
                        guard let input = hdrCurrent,
                              let output = nextPingPongTarget(after: input),
                              let depthTexture,
                              let ssrPipeline
                        else { break }
                        try encodeSSRPass(
                            encoder: encoder,
                            input: input,
                            output: output,
                            depthTexture: depthTexture,
                            pipeline: ssrPipeline,
                            projection: cameraMatrices.projection
                        )
                        hdrCurrent = output

                    case .taa:
                        guard let input = hdrCurrent,
                              let output = nextPingPongTarget(after: input),
                              let taaPipeline
                        else { break }
                        try encodeTAAPass(
                            encoder: encoder,
                            input: input,
                            history: historyTarget ?? input,
                            output: output,
                            pipeline: taaPipeline
                        )
                        hdrCurrent = output

                    case .bloom:
                        guard let input = hdrCurrent,
                              let output = nextPingPongTarget(after: input),
                              let bloomPipeline
                        else { break }
                        try encodeBloomPass(
                            encoder: encoder,
                            input: input,
                            output: output,
                            pipeline: bloomPipeline
                        )
                        bloomTarget = output

                    case .tonemap:
                        guard let input = hdrCurrent,
                              let tonemapPipeline
                        else { break }
                        try encodeTonemapPass(
                            encoder: encoder,
                            input: input,
                            bloom: bloomTarget ?? input,
                            outputView: activeRenderSettings.enableFXAA ? ldrPostProcessTarget?.view ?? colorTarget.view : colorTarget.view,
                            pipeline: tonemapPipeline
                        )
                        if activeRenderSettings.enableTAA,
                           let historyTarget {
                            encoder.copyTextureToTexture(
                                source: input.texture,
                                destination: historyTarget.texture,
                                width: packet.drawableSize.width,
                                height: packet.drawableSize.height
                            )
                            historyValid = true
                        } else {
                            historyValid = false
                        }

                    case .fxaa:
                        guard let fxaaPipeline,
                              let input = ldrPostProcessTarget
                        else { break }
                        try encodeFXAAPass(
                            encoder: encoder,
                            input: input,
                            output: colorTarget,
                            pipeline: fxaaPipeline
                        )

                    case .depthPrepass,
                         .shadowPass:
                        emitPlannedPassLog(passKind, frameIndex: packet.frameIndex)

                    case .viewportResolve:
                        registerViewportSurface(texture: colorTarget.texture, size: packet.drawableSize)
                        viewportResolved = true
                }

                let passElapsedNS = DispatchTime.now().uptimeNanoseconds - passStartNS
                passEncodeNS[passKind, default: 0] &+= passElapsedNS
                switch passKind {
                case .skybox:
                    cpuSkyboxEncodeNS &+= passElapsedNS
                case .basePass:
                    cpuBaseEncodeNS &+= passElapsedNS
                case .inkPaperPost, .ssao, .ssr, .taa, .bloom, .tonemap, .fxaa:
                    cpuPostProcessEncodeNS &+= passElapsedNS
                case .outline, .depthPrepass, .shadowPass, .viewportResolve:
                    break
                }
            }

            let encodeDoneNS = DispatchTime.now().uptimeNanoseconds

            if !viewportResolved {
                viewportSurfaceState = .init()
            }

            let cmd = try encoder.finish()
            backend.submit(cmd)
            if colorTarget.presentAfterSubmit {
                surface?.present()
            }
            let submitDoneNS = DispatchTime.now().uptimeNanoseconds

            let cpuPrepareNS = prepareDoneNS - frameStartNS
            let cpuEncodeNS = encodeDoneNS - prepareDoneNS
            let cpuSubmitNS = submitDoneNS - encodeDoneNS
            let cpuFrameTotalNS = submitDoneNS - frameStartNS

            lastFrameStats = RenderFrameStats(
                frameIndex: packet.frameIndex,
                passCount: framePlan.passes.count,
                drawCallCount: drawCallCount,
                renderBundleCount: renderBundleCount,
                renderBundleParallelJobs: renderBundleParallelJobs,
                activePasses: framePlan.passes,
                settingsGeneration: settingsGeneration,
                cpuPrepareNS: cpuPrepareNS,
                cpuEncodeNS: cpuEncodeNS,
                cpuSubmitNS: cpuSubmitNS,
                cpuFrameTotalNS: cpuFrameTotalNS,
                cpuSkyboxEncodeNS: cpuSkyboxEncodeNS,
                cpuBaseEncodeNS: cpuBaseEncodeNS,
                cpuPostProcessEncodeNS: cpuPostProcessEncodeNS,
                passEncodeNS: passEncodeNS
            )

            if shouldEmitPlannerLog(frameIndex: packet.frameIndex) {
                var seenPasses = Set<RenderPassKind>()
                let orderedPassStats = framePlan.passes.compactMap { passKind -> String? in
                    if seenPasses.contains(passKind) {
                        return nil
                    }
                    seenPasses.insert(passKind)
                    return "\(passKind.rawValue):\(passEncodeNS[passKind, default: 0])"
                }.joined(separator: ",")
                Logger.renderer.debug(
                    "frame_cpu_timing frame=\(packet.frameIndex) prepare_ns=\(cpuPrepareNS) encode_ns=\(cpuEncodeNS) submit_ns=\(cpuSubmitNS) total_ns=\(cpuFrameTotalNS) bundle_record_ns=\(bundleRecordNS) bundles=\(renderBundleCount) bundle_jobs=\(renderBundleParallelJobs) pass_encode_ns=[\(orderedPassStats)]"
                )
            }
        } catch {
            Logger.renderer.error("frame \(packet.frameIndex) failed: \(error)")
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

    // MARK: - Pipeline + mesh construction

    private func ensureMeshAssetsUploaded() throws {
        guard backend.rawDevice != nil else { return }
        if meshes.isEmpty {
            try uploadBuiltinMeshes()
        }
        try syncImportedMeshes()
    }

    private func uploadBuiltinMeshes() throws {
        let cube = BuiltinMesh.cube()
        let cubeMesh = try uploadMesh(cube)
        let cubeBounds = cube.localBounds
        var objAsset: MeshAsset?
        var objMesh: GPUMesh?
        if let url = Bundle.module.url(forResource: "FinalBaseMesh", withExtension: "obj") {
            do {
                var obj = try OBJLoader.load(path: url.path)
                obj.normalizeToUnitBounds(targetSize: 2.0)
                objMesh = try uploadMesh(obj)
                objAsset = obj
            } catch {
                Logger.renderer.error("OBJ load failed (\(error)); skipping fixture mesh")
            }
        }

        meshes.append(cubeMesh)
        MeshBoundsRegistry.shared.register(meshIndex: 0,
                                           min: cubeBounds.min,
                                           max: cubeBounds.max)
        MeshWireframeRegistry.shared.register(meshIndex: 0, mesh: cube)
        MeshMaterialRegistry.shared.register(meshIndex: 0, mesh: cube)
        MeshTextureRegistry.shared.register(meshIndex: 0, mesh: cube, sourceDirectory: nil)
        if let objMesh, let objAsset {
            meshes.append(objMesh)
            let b = objAsset.localBounds
            MeshBoundsRegistry.shared.register(meshIndex: 1,
                                               min: b.min,
                                               max: b.max)
            MeshWireframeRegistry.shared.register(meshIndex: 1, mesh: objAsset)
            MeshMaterialRegistry.shared.register(meshIndex: 1, mesh: objAsset)
            MeshTextureRegistry.shared.register(meshIndex: 1, mesh: objAsset, sourceDirectory: nil)
        } else {
            let fallbackFixture = GPUMesh(vertexBuffer: cubeMesh.vertexBuffer,
                                          indexBuffer: cubeMesh.indexBuffer,
                                          indexCount: cubeMesh.indexCount,
                                          name: "builtin.fixtureFallback")
            meshes.append(fallbackFixture)
            MeshBoundsRegistry.shared.register(meshIndex: 1,
                                               min: cubeBounds.min,
                                               max: cubeBounds.max)
            MeshWireframeRegistry.shared.register(meshIndex: 1, mesh: cube)
            MeshMaterialRegistry.shared.register(meshIndex: 1, mesh: cube)
            MeshTextureRegistry.shared.register(meshIndex: 1, mesh: cube, sourceDirectory: nil)
        }

        let meshNames = meshes.map(\ .name)
        Logger.renderer.info("mesh table built: meshes=\(meshNames)")
    }

    private func makeMeshVertexLayout() -> GPUVertexBufferLayout {
        GPUVertexBufferLayout(
            arrayStride: UInt64(MeshAsset.vertexStride),
            attributes: [
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.positionOffset), shaderLocation: 0),
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.normalOffset), shaderLocation: 1),
                GPUVertexAttribute(
                    format: .float32x3, offset: UInt64(MeshAsset.colorOffset), shaderLocation: 2),
                GPUVertexAttribute(
                    format: .float32x2, offset: UInt64(MeshAsset.uvOffset), shaderLocation: 3),
                GPUVertexAttribute(
                    format: .float32x4, offset: UInt64(MeshAsset.tangentOffset), shaderLocation: 4),
                GPUVertexAttribute(
                    format: .float32, offset: UInt64(MeshAsset.materialIndexOffset), shaderLocation: 5),
                GPUVertexAttribute(
                    format: .float32x4, offset: UInt64(MeshAsset.jointsOffset), shaderLocation: 6),
                GPUVertexAttribute(
                    format: .float32x4, offset: UInt64(MeshAsset.weightsOffset), shaderLocation: 7),
            ]
        )
    }

    private func ensureMeshPipeline(hdr: Bool) throws -> GPURenderPipeline {
        try ensureMeshAssetsUploaded()
        let stylized = activeRenderSettings.enableStylizedCharacterShading
        if stylized {
            if hdr, let stylizedMeshPipelineHDR { return stylizedMeshPipelineHDR }
            if !hdr, let stylizedMeshPipelineLDR { return stylizedMeshPipelineLDR }
        } else {
            if hdr, let meshPipelineHDR { return meshPipelineHDR }
            if !hdr, let meshPipelineLDR { return meshPipelineLDR }
        }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        let module = try backend.createShaderModule(
            wgsl: try Self.loadShaderSource(named: stylized ? "stylized_character" : "mesh"),
            label: stylized ? "stylized_character" : "mesh"
        )

        if meshBindGroupLayout == nil {
            meshBindGroupLayout = try backend.createBindGroupLayout(
                entries: [
                    GPUBindGroupLayoutEntry(
                        binding: 0,
                        visibility: .vertex,
                        type: .uniformBuffer,
                        hasDynamicOffset: true
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 1,
                        visibility: [.vertex, .fragment],
                        type: .uniformBuffer
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 2,
                        visibility: .fragment,
                        type: .sampler
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 3,
                        visibility: .fragment,
                        type: .sampledTexture
                    )
                ]
            )
        }
        if meshPipelineLayout == nil, let meshBindGroupLayout {
            meshPipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [meshBindGroupLayout])
        }

        let pipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                pipelineLayout: meshPipelineLayout,
                colorFormat: hdr ? hdrFormat : format,
                cullMode: .back,
                vertexBuffers: [makeMeshVertexLayout()],
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: true,
                    depthCompare: .less
                )
            )
        )

        if hdr {
            if stylized {
                stylizedMeshPipelineHDR = pipeline
            } else {
                meshPipelineHDR = pipeline
            }
        } else {
            if stylized {
                stylizedMeshPipelineLDR = pipeline
            } else {
                meshPipelineLDR = pipeline
            }
        }
        return pipeline
    }

    private func ensureOutlinePipeline(hdr: Bool) throws -> GPURenderPipeline {
        try ensureMeshAssetsUploaded()
        if hdr, let outlinePipelineHDR { return outlinePipelineHDR }
        if !hdr, let outlinePipelineLDR { return outlinePipelineLDR }
        guard backend.rawDevice != nil else {
            throw WGPUBackendError.initFailed("device not ready")
        }

        let module = try backend.createShaderModule(
            wgsl: try Self.loadShaderSource(named: "outline"),
            label: "outline"
        )

        if meshBindGroupLayout == nil {
            meshBindGroupLayout = try backend.createBindGroupLayout(
                entries: [
                    GPUBindGroupLayoutEntry(
                        binding: 0,
                        visibility: .vertex,
                        type: .uniformBuffer,
                        hasDynamicOffset: true
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 1,
                        visibility: [.vertex, .fragment],
                        type: .uniformBuffer
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 2,
                        visibility: .fragment,
                        type: .sampler
                    ),
                    GPUBindGroupLayoutEntry(
                        binding: 3,
                        visibility: .fragment,
                        type: .sampledTexture
                    )
                ]
            )
        }
        if meshPipelineLayout == nil, let meshBindGroupLayout {
            meshPipelineLayout = try backend.createPipelineLayout(bindGroupLayouts: [meshBindGroupLayout])
        }

        let pipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                pipelineLayout: meshPipelineLayout,
                colorFormat: hdr ? hdrFormat : format,
                cullMode: .front,
                vertexBuffers: [makeMeshVertexLayout()],
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: false,
                    depthCompare: .lessEqual
                )
            )
        )

        if hdr {
            outlinePipelineHDR = pipeline
        } else {
            outlinePipelineLDR = pipeline
        }
        return pipeline
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

    private func syncImportedMeshes() throws {
        for registered in AssetRegistry.shared.registeredMeshes() {
            if registered.meshIndex < meshes.count {
                continue
            }
            guard registered.meshIndex == meshes.count else {
                Logger.renderer.warning(
                    "skipping imported mesh out of sequence: meshIndex=\(registered.meshIndex) currentCount=\(meshes.count) id=\(registered.assetID)"
                )
                continue
            }
            let mesh = try uploadMesh(registered.mesh)
            meshes.append(mesh)
            let bounds = registered.mesh.localBounds
            MeshBoundsRegistry.shared.register(meshIndex: registered.meshIndex,
                                               min: bounds.min,
                                               max: bounds.max)
            MeshMaterialRegistry.shared.register(meshIndex: registered.meshIndex,
                                                 mesh: registered.mesh)
            let textureReport = MeshTextureRegistry.shared.register(
                meshIndex: registered.meshIndex,
                mesh: registered.mesh,
                sourceDirectory: registered.sourceDirectory
            )
            try uploadMeshTextures(meshIndex: registered.meshIndex, report: textureReport)
            for failure in textureReport.failures {
                Logger.renderer.warning(
                    "mesh texture decode failed: meshIndex=\(registered.meshIndex) textureIndex=\(failure.textureIndex) uri=\(failure.sourceURI ?? "<nil>") reason=\(failure.reason)"
                )
            }
            if let slices = registered.topologySlices, !slices.isEmpty {
                let submeshes = slices.map {
                    MeshWireframeTopology(positions: $0.positions,
                                          triangleIndices: $0.triangleIndices,
                                          indexRemap: $0.indexRemap)
                }
                MeshWireframeRegistry.shared.register(meshIndex: registered.meshIndex,
                                                      submeshes: submeshes)
            } else {
                MeshWireframeRegistry.shared.register(meshIndex: registered.meshIndex,
                                                      mesh: registered.mesh)
            }
        }
    }

    private func uploadMeshTextures(meshIndex: Int, report: MeshTextureRegistrationReport) throws {
        guard !report.decodedTextures.isEmpty else { return }
        var resources = meshTextureResources[meshIndex] ?? [:]
        for decoded in report.decodedTextures where resources[decoded.textureIndex] == nil {
            let textureWidth = UInt32(decoded.texture.width)
            let textureHeight = UInt32(decoded.texture.height)
            let gpuTexture = try backend.createTexture(
                width: textureWidth,
                height: textureHeight,
                format: .rgba8Unorm,
                usage: [.textureBinding, .copyDst]
            )
            decoded.texture.pixels.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    backend.writeTexture(
                        gpuTexture,
                        data: base,
                        dataSize: raw.count,
                        bytesPerRow: textureWidth * 4,
                        rowsPerImage: textureHeight,
                        width: textureWidth,
                        height: textureHeight
                    )
                }
            }
            resources[decoded.textureIndex] = GPUMeshTextureResource(
                texture: gpuTexture,
                view: try gpuTexture.createView(),
                width: textureWidth,
                height: textureHeight,
                sourcePath: decoded.sourcePath
            )
            Logger.renderer.debug(
                "uploaded mesh texture: meshIndex=\(meshIndex) textureIndex=\(decoded.textureIndex) size=\(textureWidth)x\(textureHeight) source=\(decoded.sourcePath)"
            )
        }
        meshTextureResources[meshIndex] = resources
    }

    private func ensureInstanceResources(scene: RenderScene, pipeline: GPURenderPipeline) throws {
        let instanceCount = scene.instances.count
        let meshIndices = scene.instances.map(\.meshIndex)

        let useDynamicOffsets = instanceCount > dynamicOffsetThreshold
        let bindGroupLayout: GPUBindGroupLayout
        if let meshBindGroupLayout {
            bindGroupLayout = meshBindGroupLayout
        } else {
            bindGroupLayout = try pipeline.getBindGroupLayout(group: 0)
        }

        if useDynamicOffsets {
            if let dyn = dynamicInstanceResources, dyn.capacity >= instanceCount {
                instanceResourceMeshIndices = meshIndices
                return
            }
            instanceResources.removeAll(keepingCapacity: false)
            instanceResourceMeshIndices = meshIndices

            let totalSize = UInt64(max(instanceCount, 1)) * dynamicUniformStride
            let uniformBuffer = try backend.createBuffer(size: totalSize, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: try meshBindGroupEntries(instanceUniformBuffer: uniformBuffer)
            )
            dynamicInstanceResources = DynamicInstanceResources(
                uniformBuffer: uniformBuffer,
                bindGroup: bindGroup,
                stride: dynamicUniformStride,
                capacity: instanceCount
            )
            return
        }

        if dynamicInstanceResources == nil
            && instanceResources.count == instanceCount
            && instanceResourceMeshIndices == meshIndices {
            return
        }

        dynamicInstanceResources = nil
        instanceResources.removeAll(keepingCapacity: false)
        instanceResourceMeshIndices = meshIndices
        for meshIndex in meshIndices {
            let uniformBuffer = try backend.createBuffer(size: 64, usage: [.uniform, .copyDst])
            let bindGroup = try backend.createBindGroup(
                layout: bindGroupLayout,
                entries: try meshBindGroupEntries(
                    instanceUniformBuffer: uniformBuffer,
                    baseColorTextureView: baseColorTextureView(for: meshIndex)
                )
            )
            instanceResources.append(
                InstanceResources(uniformBuffer: uniformBuffer, bindGroup: bindGroup))
        }
    }

    private func meshBindGroupEntries(instanceUniformBuffer: GPUBuffer,
                                      baseColorTextureView: GPUTextureView? = nil) throws -> [GPUBindGroupEntry] {
        try ensureStylizedCharacterUniformBuffer()
        try ensureMeshSamplingFallbackResources()
        guard let stylizedCharacterUniformBuffer,
              let linearSampler,
              let fallbackMeshTextureView
        else {
            throw WGPUBackendError.initFailed("mesh bind group resources missing")
        }
        let textureView = baseColorTextureView ?? fallbackMeshTextureView
        return [
            GPUBindGroupEntry(binding: 0, buffer: instanceUniformBuffer, offset: 0, size: 64),
            GPUBindGroupEntry(
                binding: 1,
                buffer: stylizedCharacterUniformBuffer,
                offset: 0,
                size: UInt64(MemoryLayout<StylizedCharacterUniforms>.stride)
            ),
            GPUBindGroupEntry(binding: 2, sampler: linearSampler),
            GPUBindGroupEntry(binding: 3, textureView: textureView),
        ]
    }

    private func baseColorTextureView(for meshIndex: Int) -> GPUTextureView? {
        guard let materialSet = MeshMaterialRegistry.shared.materials(for: meshIndex),
              let textureIndex = materialSet.materials.first?.baseColorTextureIndex
        else {
            return nil
        }
        return meshTextureResources[meshIndex]?[textureIndex]?.view
    }

    private func ensureStylizedCharacterUniformBuffer() throws {
        guard backend.rawDevice != nil else { return }
        if stylizedCharacterUniformBuffer != nil { return }
        stylizedCharacterUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
    }

    private func writeStylizedCharacterUniforms() {
        guard let stylizedCharacterUniformBuffer else { return }
        let style = activeRenderSettings.stylizedCharacterStyle
        var uniforms = StylizedCharacterUniforms(
            toonThresholds: style.toonThresholds,
            toonLevels: style.toonLevels,
            inkWashColor: style.inkWashColor,
            params: SIMD4<Float>(
                style.paperGrainStrength,
                style.rimStrength,
                style.materialBiasStrength,
                style.outlineWidth
            )
        )
        withUnsafeBytes(of: &uniforms) { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(stylizedCharacterUniformBuffer,
                                    data: base,
                                    size: raw.count)
            }
        }
    }

    private func ensureMeshSamplingFallbackResources() throws {
        guard backend.rawDevice != nil else { return }
        if linearSampler == nil {
            linearSampler = try backend.createSampler(
                desc: GPUSamplerDescriptor(
                    addressModeU: .clampToEdge,
                    addressModeV: .clampToEdge,
                    magFilter: .linear,
                    minFilter: .linear,
                    mipmapFilter: .linear
                )
            )
        }
        if fallbackMeshTextureView != nil { return }
        let texture = try backend.createTexture(
            width: 1,
            height: 1,
            format: .rgba8Unorm,
            usage: [.textureBinding, .copyDst]
        )
        let whitePixel: [UInt8] = [255, 255, 255, 255]
        whitePixel.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                backend.writeTexture(
                    texture,
                    data: base,
                    dataSize: raw.count,
                    bytesPerRow: 4,
                    rowsPerImage: 1,
                    width: 1,
                    height: 1
                )
            }
        }
        fallbackMeshTexture = texture
        fallbackMeshTextureView = try texture.createView()
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
        sceneColorTarget = nil
        postProcessTargetA = nil
        postProcessTargetB = nil
        ldrPostProcessTarget = nil
        historyTarget = nil
        historyValid = false

        depthView = nil
        depthTexture = nil
        let depth = try backend.createTexture(
            width: width,
            height: height,
            format: depthFormat,
            usage: [.renderAttachment, .textureBinding]
        )
        depthView = try depth.createView()
        depthTexture = depth
    }

    private func ensureFrameGraphResources(size: RenderDrawableSize) throws {
        guard sceneColorTarget == nil || postProcessTargetA == nil || postProcessTargetB == nil || historyTarget == nil else {
            return
        }
        sceneColorTarget = try makeRenderTarget(width: size.width, height: size.height, format: hdrFormat)
        postProcessTargetA = try makeRenderTarget(width: size.width, height: size.height, format: hdrFormat)
        postProcessTargetB = try makeRenderTarget(width: size.width, height: size.height, format: hdrFormat)
        ldrPostProcessTarget = try makeRenderTarget(width: size.width, height: size.height, format: format)
        historyTarget = try makeRenderTarget(width: size.width, height: size.height, format: hdrFormat)
    }

    private func ensureFullscreenResources() throws {
        if linearSampler == nil {
            linearSampler = try backend.createSampler(
                desc: GPUSamplerDescriptor(
                    addressModeU: .clampToEdge,
                    addressModeV: .clampToEdge,
                    magFilter: .linear,
                    minFilter: .linear,
                    mipmapFilter: .linear
                )
            )
        }
        if nearestSampler == nil {
            nearestSampler = try backend.createSampler(
                desc: GPUSamplerDescriptor(
                    addressModeU: .clampToEdge,
                    addressModeV: .clampToEdge,
                    magFilter: .nearest,
                    minFilter: .nearest,
                    mipmapFilter: .nearest
                )
            )
        }
        if skyboxUniformBuffer == nil {
            skyboxUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        if tonemapUniformBuffer == nil {
            tonemapUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        if bloomUniformBuffer == nil {
            bloomUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        if ssrUniformBuffer == nil {
            ssrUniformBuffer = try backend.createBuffer(size: 512, usage: [.uniform, .copyDst])
        }
        if taaUniformBuffer == nil {
            taaUniformBuffer = try backend.createBuffer(size: 256, usage: [.uniform, .copyDst])
        }
        if ssaoUniformBuffer == nil {
            ssaoUniformBuffer = try backend.createBuffer(size: 512, usage: [.uniform, .copyDst])
        }
    }

    private func ensureSkyboxPipeline() throws {
        guard skyboxPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "skybox"), label: "skybox")
        skyboxPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none,
                depthStencil: GPUDepthStencilPipelineState(
                    format: depthFormat,
                    depthWriteEnabled: false,
                    depthCompare: .lessEqual
                )
            )
        )
    }

    private func ensureTonemapPipeline() throws {
        guard tonemapPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "tonemap"), label: "tonemap")
        tonemapPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: format,
                cullMode: .none
            )
        )
    }

    private func ensureBloomPipeline() throws {
        guard bloomPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "bloom"), label: "bloom")
        bloomPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    private func ensureInkPaperPostPipeline() throws {
        guard inkPaperPostPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ink_paper_post"), label: "ink_paper_post")
        inkPaperPostPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    private func ensureFXAAPipeline() throws {
        guard fxaaPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "fxaa"), label: "fxaa")
        fxaaPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: format,
                cullMode: .none
            )
        )
    }

    private func ensureSSRPipeline() throws {
        guard ssrPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ssr"), label: "ssr")
        ssrPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    private func ensureTAAPipeline() throws {
        guard taaPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "taa"), label: "taa")
        taaPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    private func ensureSSAOPipeline() throws {
        guard ssaoPipeline == nil else { return }
        let module = try backend.createShaderModule(wgsl: try Self.loadShaderSource(named: "ssao"), label: "ssao")
        ssaoPipeline = try backend.createRenderPipeline(
            desc: GPURenderPipelineDescriptor(
                shaderModule: module,
                colorFormat: hdrFormat,
                cullMode: .none
            )
        )
    }

    private func makeRenderTarget(width: UInt32, height: UInt32, format: GPUTextureFormat) throws -> RenderTextureTarget {
        let texture = try backend.createTexture(
            width: width,
            height: height,
            format: format,
            usage: [.renderAttachment, .textureBinding, .copySrc, .copyDst]
        )
        let view = try texture.createView()
        return RenderTextureTarget(texture: texture, view: view)
    }

    private func nextPingPongTarget(after current: RenderTextureTarget) -> RenderTextureTarget? {
        guard let postProcessTargetA, let postProcessTargetB else { return nil }
        return current.texture === postProcessTargetA.texture ? postProcessTargetB : postProcessTargetA
    }

    private func writeUniform<T>(_ value: inout T, buffer: GPUBuffer) {
        withUnsafeBytes(of: &value) { raw in
            if let base = raw.baseAddress {
                backend.writeBuffer(buffer, data: base, size: raw.count)
            }
        }
    }

    private func makeBindGroup(pipeline: GPURenderPipeline, entries: [GPUBindGroupEntry]) throws -> GPUBindGroup {
        let layout = try pipeline.getBindGroupLayout(group: 0)
        return try backend.createBindGroup(layout: layout, entries: entries)
    }

    private func encodeSkyboxPass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        viewProj: simd_float4x4
    ) throws {
        guard let skyboxUniformBuffer else { return }
        var uniforms = SkyboxUniforms(
            invViewProj: simd_inverse(viewProj),
            skyTint: SIMD4<Float>(0.10, 0.20, 0.42, 1.0),
            horizonTint: SIMD4<Float>(0.95, 0.48, 0.18, 1.0),
            groundTint: SIMD4<Float>(0.03, 0.04, 0.05, 1.0)
        )
        writeUniform(&uniforms, buffer: skyboxUniformBuffer)
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [GPUBindGroupEntry(binding: 0, buffer: skyboxUniformBuffer, offset: 0, size: UInt64(MemoryLayout<SkyboxUniforms>.stride))]
        )

        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: .clear,
            storeOp: .store,
            clearColor: GPUColor(r: 0.01, g: 0.01, b: 0.02, a: 1.0),
            depthView: depthView,
            depthLoadOp: .clear,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeBasePass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        scene: RenderScene,
        colorFormat: GPUTextureFormat,
        colorLoadOp: GPULoadOp,
        depthLoadOp: GPULoadOp
    ) throws -> BasePassEncodingReport {
        let drawOrder = makeBasePassDrawOrder(scene: scene)

        if activeRenderSettings.enableRenderBundles {
            let bundleReport = try encodeBasePassWithRenderBundles(
                encoder: encoder,
                colorView: colorView,
                depthView: depthView,
                pipeline: pipeline,
                scene: scene,
                drawOrder: drawOrder,
                colorFormat: colorFormat,
                colorLoadOp: colorLoadOp,
                depthLoadOp: depthLoadOp
            )
            if bundleReport.renderBundleCount > 0 {
                return bundleReport
            }
        }

        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: colorLoadOp,
            storeOp: .store,
            clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1.0),
            depthView: depthView,
            depthLoadOp: depthLoadOp,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )

        pass.setPipeline(pipeline)
        var drawCallCount = 0
        if let dyn = dynamicInstanceResources {
            for i in drawOrder {
                let instance = scene.instances[i]
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
            for i in drawOrder where i < instanceResources.count {
                let instance = scene.instances[i]
                guard meshes.indices.contains(instance.meshIndex) else { continue }
                let mesh = meshes[instance.meshIndex]
                pass.setBindGroup(instanceResources[i].bindGroup, index: 0, dynamicOffsets: [0])
                pass.setVertexBuffer(mesh.vertexBuffer, slot: 0)
                pass.setIndexBuffer(mesh.indexBuffer, format: .uint32)
                pass.drawIndexed(indexCount: mesh.indexCount)
                drawCallCount += 1
            }
        }
        pass.end()

        return BasePassEncodingReport(
            drawCallCount: drawCallCount,
            renderBundleCount: 0,
            parallelJobCount: 0,
            bundleRecordNS: 0
        )
    }

    private func encodeOutlinePass(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        scene: RenderScene
    ) throws -> Int {
        let drawOrder = makeBasePassDrawOrder(scene: scene)
        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: .load,
            storeOp: .store,
            clearColor: GPUColor(r: 0.0, g: 0.0, b: 0.0, a: 1.0),
            depthView: depthView,
            depthLoadOp: .load,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )
        pass.setPipeline(pipeline)
        var drawCallCount = 0
        if let dyn = dynamicInstanceResources {
            for i in drawOrder {
                let instance = scene.instances[i]
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
            for i in drawOrder where i < instanceResources.count {
                let instance = scene.instances[i]
                guard meshes.indices.contains(instance.meshIndex) else { continue }
                let mesh = meshes[instance.meshIndex]
                pass.setBindGroup(instanceResources[i].bindGroup, index: 0, dynamicOffsets: [0])
                pass.setVertexBuffer(mesh.vertexBuffer, slot: 0)
                pass.setIndexBuffer(mesh.indexBuffer, format: .uint32)
                pass.drawIndexed(indexCount: mesh.indexCount)
                drawCallCount += 1
            }
        }
        pass.end()
        return drawCallCount
    }

    private func encodeBasePassWithRenderBundles(
        encoder: GPUCommandEncoder,
        colorView: GPUTextureView,
        depthView: GPUTextureView,
        pipeline: GPURenderPipeline,
        scene: RenderScene,
        drawOrder: [Int],
        colorFormat: GPUTextureFormat,
        colorLoadOp: GPULoadOp,
        depthLoadOp: GPULoadOp
    ) throws -> BasePassEncodingReport {
        guard !scene.instances.isEmpty else {
            return BasePassEncodingReport(
                drawCallCount: 0,
                renderBundleCount: 0,
                parallelJobCount: 0,
                bundleRecordNS: 0
            )
        }

        let instanceCount = scene.instances.count
        let chunkTarget: Int
        if activeRenderSettings.renderBundleChunkSize > 0 {
            chunkTarget = max(1, activeRenderSettings.renderBundleChunkSize)
        } else {
            let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            chunkTarget = max(64, (instanceCount + (workerCount * 2) - 1) / (workerCount * 2))
        }

        var ranges: [Range<Int>] = []
        ranges.reserveCapacity((instanceCount + chunkTarget - 1) / chunkTarget)
        var chunkStart = 0
        while chunkStart < instanceCount {
            let chunkEnd = min(chunkStart + chunkTarget, instanceCount)
            ranges.append(chunkStart..<chunkEnd)
            chunkStart = chunkEnd
        }
        let finalRanges = ranges

        let descriptor = GPURenderBundleEncoderDescriptor(
            colorFormats: [colorFormat],
            depthStencilFormat: depthFormat,
            sampleCount: 1,
            depthReadOnly: false,
            stencilReadOnly: true
        )

        final class BundleRecordState: @unchecked Sendable {
            private let lock = NSLock()
            private var firstError: Error?
            private var bundles: [GPURenderBundle?]
            private var drawCounts: [Int]

            init(count: Int) {
                self.bundles = Array(repeating: nil, count: count)
                self.drawCounts = Array(repeating: 0, count: count)
            }

            func hasError() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return firstError != nil
            }

            func setResult(index: Int, bundle: GPURenderBundle, drawCount: Int) {
                lock.lock()
                bundles[index] = bundle
                drawCounts[index] = drawCount
                lock.unlock()
            }

            func setErrorIfNeeded(_ error: Error) {
                lock.lock()
                if firstError == nil {
                    firstError = error
                }
                lock.unlock()
            }

            func snapshot() -> (firstError: Error?, bundles: [GPURenderBundle], drawCounts: [Int]) {
                lock.lock()
                defer { lock.unlock() }
                return (firstError, bundles.compactMap { $0 }, drawCounts)
            }
        }

        let bundleRecordStartNS = DispatchTime.now().uptimeNanoseconds
        let state = BundleRecordState(count: finalRanges.count)
        let localInstanceResources = instanceResources
        let localDynamicResources = dynamicInstanceResources
        let localMeshes = meshes
        let localSceneInstances = scene.instances
        let localPipeline = pipeline
        let localDescriptor = descriptor

        DispatchQueue.concurrentPerform(iterations: finalRanges.count) { rangeIndex in
            if state.hasError() {
                return
            }

            do {
                let bundleEncoder = try backend.createRenderBundleEncoder(localDescriptor)
                bundleEncoder.setPipeline(localPipeline)

                var localDrawCount = 0
                for i in finalRanges[rangeIndex] {
                    let drawIndex = drawOrder[i]
                    let instance = localSceneInstances[drawIndex]
                    guard localMeshes.indices.contains(instance.meshIndex) else { continue }
                    let mesh = localMeshes[instance.meshIndex]
                    if let dyn = localDynamicResources {
                        let drawOffset = UInt64(drawIndex) * dyn.stride
                        guard drawOffset <= UInt64(UInt32.max) else { continue }
                        bundleEncoder.setBindGroup(dyn.bindGroup, index: 0, dynamicOffsets: [UInt32(drawOffset)])
                    } else {
                        guard drawIndex < localInstanceResources.count else { continue }
                        bundleEncoder.setBindGroup(localInstanceResources[drawIndex].bindGroup, index: 0, dynamicOffsets: [0])
                    }
                    bundleEncoder.setVertexBuffer(mesh.vertexBuffer, slot: 0)
                    bundleEncoder.setIndexBuffer(mesh.indexBuffer, format: .uint32)
                    bundleEncoder.drawIndexed(indexCount: mesh.indexCount)
                    localDrawCount += 1
                }

                let bundle = try bundleEncoder.finish()
                state.setResult(index: rangeIndex, bundle: bundle, drawCount: localDrawCount)
            } catch {
                state.setErrorIfNeeded(error)
            }
        }

        let snapshot = state.snapshot()
        if let firstError = snapshot.firstError {
            throw firstError
        }

        let compactBundles = snapshot.bundles
        guard !compactBundles.isEmpty else {
            return BasePassEncodingReport(
                drawCallCount: 0,
                renderBundleCount: 0,
                parallelJobCount: finalRanges.count,
                bundleRecordNS: DispatchTime.now().uptimeNanoseconds - bundleRecordStartNS
            )
        }

        let pass = try encoder.beginRenderPass(
            colorView: colorView,
            loadOp: colorLoadOp,
            storeOp: .store,
            clearColor: GPUColor(r: 0.05, g: 0.06, b: 0.08, a: 1.0),
            depthView: depthView,
            depthLoadOp: depthLoadOp,
            depthStoreOp: .store,
            depthClearValue: 1.0
        )
        pass.executeBundles(compactBundles)
        pass.end()

        return BasePassEncodingReport(
            drawCallCount: snapshot.drawCounts.reduce(0, +),
            renderBundleCount: compactBundles.count,
            parallelJobCount: finalRanges.count,
            bundleRecordNS: DispatchTime.now().uptimeNanoseconds - bundleRecordStartNS
        )
    }

    private func makeBasePassDrawOrder(scene: RenderScene) -> [Int] {
        let instances = scene.instances
        guard activeRenderSettings.enableGroupedDrawByMesh else {
            return Array(instances.indices)
        }

        var buckets: [Int: [Int]] = [:]
        buckets.reserveCapacity(max(2, meshes.count))
        for index in instances.indices {
            buckets[instances[index].meshIndex, default: []].append(index)
        }

        var order: [Int] = []
        order.reserveCapacity(instances.count)
        for meshIndex in buckets.keys.sorted() {
            order.append(contentsOf: buckets[meshIndex] ?? [])
        }
        return order
    }

    private func encodeBloomPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        output: RenderTextureTarget,
        pipeline: GPURenderPipeline
    ) throws {
        guard let linearSampler, let bloomUniformBuffer else { return }
        var uniforms = BloomUniforms(
            params: SIMD4<Float>(1.05, 0.75, 1.0 / Float(configuredSize.width), 1.0 / Float(configuredSize.height))
        )
        writeUniform(&uniforms, buffer: bloomUniformBuffer)
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, buffer: bloomUniformBuffer, offset: 0, size: UInt64(MemoryLayout<BloomUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .clear)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeInkPaperPostPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        output: RenderTextureTarget,
        pipeline: GPURenderPipeline
    ) throws {
        guard let linearSampler, let stylizedCharacterUniformBuffer else { return }
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, buffer: stylizedCharacterUniformBuffer, offset: 0, size: UInt64(MemoryLayout<StylizedCharacterUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .clear)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeSSRPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        output: RenderTextureTarget,
        depthTexture: GPUTexture,
        pipeline: GPURenderPipeline,
        projection: simd_float4x4
    ) throws {
        guard let linearSampler, let ssrUniformBuffer else { return }
        var uniforms = SSRUniforms(
            projection: projection,
            invProjection: simd_inverse(projection),
            resolutionIntensity: SIMD4<Float>(Float(configuredSize.width), Float(configuredSize.height), 0.22, 0),
            tracing: SIMD4<Float>(14.0, 32.0, 0.18, 0.08)
        )
        writeUniform(&uniforms, buffer: ssrUniformBuffer)
        let depthView = try depthTexture.createView()
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, textureView: depthView),
                GPUBindGroupEntry(binding: 3, buffer: ssrUniformBuffer, offset: 0, size: UInt64(MemoryLayout<SSRUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .clear)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeTAAPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        history: RenderTextureTarget,
        output: RenderTextureTarget,
        pipeline: GPURenderPipeline
    ) throws {
        guard let linearSampler, let taaUniformBuffer else { return }
        var uniforms = TAAUniforms(
            params: SIMD4<Float>(0.12, 1.0 / Float(configuredSize.width), 1.0 / Float(configuredSize.height), historyValid ? 1.0 : 0.0)
        )
        writeUniform(&uniforms, buffer: taaUniformBuffer)
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, textureView: history.view),
                GPUBindGroupEntry(binding: 3, buffer: taaUniformBuffer, offset: 0, size: UInt64(MemoryLayout<TAAUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .clear)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeSSAOPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        output: RenderTextureTarget,
        depthTexture: GPUTexture,
        pipeline: GPURenderPipeline,
        projection: simd_float4x4
    ) throws {
        guard let linearSampler, let ssaoUniformBuffer else { return }
        var uniforms = SSAOUniforms(
            projection: projection,
            invProjection: simd_inverse(projection),
            resolutionRadius: SIMD4<Float>(Float(configuredSize.width), Float(configuredSize.height), 0.45, 0),
            tuning: SIMD4<Float>(0.025, 0.7, 1.35, 0)
        )
        writeUniform(&uniforms, buffer: ssaoUniformBuffer)
        let depthView = try depthTexture.createView()
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, textureView: depthView),
                GPUBindGroupEntry(binding: 3, buffer: ssaoUniformBuffer, offset: 0, size: UInt64(MemoryLayout<SSAOUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .clear)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeTonemapPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        bloom: RenderTextureTarget,
        outputView: GPUTextureView,
        pipeline: GPURenderPipeline
    ) throws {
        guard let linearSampler, let tonemapUniformBuffer else { return }
        var uniforms = TonemapUniforms(
            params: SIMD4<Float>(1.0, 0.85, activeRenderSettings.enableBloom ? 1.0 : 0.0, 1.0)
        )
        writeUniform(&uniforms, buffer: tonemapUniformBuffer)
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
                GPUBindGroupEntry(binding: 2, textureView: bloom.view),
                GPUBindGroupEntry(binding: 3, buffer: tonemapUniformBuffer, offset: 0, size: UInt64(MemoryLayout<TonemapUniforms>.stride)),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: outputView, loadOp: .clear, storeOp: .store, clearColor: .black)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    private func encodeFXAAPass(
        encoder: GPUCommandEncoder,
        input: RenderTextureTarget,
        output: FrameColorTarget,
        pipeline: GPURenderPipeline
    ) throws {
        guard let linearSampler else { return }
        let bindGroup = try makeBindGroup(
            pipeline: pipeline,
            entries: [
                GPUBindGroupEntry(binding: 0, sampler: linearSampler),
                GPUBindGroupEntry(binding: 1, textureView: input.view),
            ]
        )
        let pass = try encoder.beginRenderPass(colorView: output.view, loadOp: .clear, storeOp: .store, clearColor: .black)
        pass.setPipeline(pipeline)
        pass.setBindGroup(bindGroup, index: 0)
        pass.draw(vertexCount: 3)
        pass.end()
    }

    // MARK: - Shader

    // MARK: - Shader

    private static func loadShaderSource(named name: String) throws -> String {
        try ShaderCatalog().loadWGSLRenderModule(named: name)
    }
}
