import AssetPipeline
import Foundation
import Logging
import NativeRHI
import SIMDCompat

/// Scene renderer recorded entirely through NativeRHI. The initial migration
/// supports opaque/masked/transparent meshes and animation, PBR lighting, directional shadows,
/// HDR sky/tonemap, stylized materials/outline/paper, r5 post effects, temporal
/// history/cache, the grid, CPU-authored particle draws and resident GPU particle
/// physics/events, GPU sorting and simulated-particle instance conversion.
/// RenderThread owns all mutable renderer state.
public final class NativeRenderer: RenderPacketConsumer, @unchecked Sendable {
    public let device: Device
    private let meshes: NativeMeshStore
    private let meshPass: NativeMeshPass
    private let deformables: NativeDeformableMeshes
    private let lighting: NativeLightingResources
    private let shadows: NativeShadowPass
    private let hdrPasses: NativeHDRPasses
    private let grid: NativeEditorGridPass
    private let post: NativePostPasses
    private let particles: NativeParticlePass
    let particleSimulation: NativeParticleSimulation
    private var frameState = RenderTemporalState()
    public var lastFrameUsedOpaqueCache: Bool { frameState.cacheHit }
    private let surface: RenderSurfaceDescriptor?
    private var configuredSurfaceSize: RenderDrawableSize?
    private var targets: NativeRenderTargets?
    private var viewportPublication = ViewportSurfacePublication()
    public private(set) var lastFrameStats = RenderFrameStats()
    public private(set) var lastError: String?
    /// Borrowed handle for immediate recording/readback. Retain a viewport
    /// surface's owned image when the output must survive target replacement.
    public var colorTexture: Texture? { targets?.color?.texture }
    public var residentMeshCount: Int { meshes.residentCount }

    public init(device: Device, surface: RenderSurfaceDescriptor? = nil, assets: AssetRegistry = .shared) throws {
        self.device = device; self.surface = surface
        meshes = try NativeMeshStore(device: device, registry: assets)
        meshPass = try NativeMeshPass(device: device)
        deformables = NativeDeformableMeshes(device: device)
        lighting = try NativeLightingResources(device: device)
        shadows = try NativeShadowPass(device: device)
        hdrPasses = try NativeHDRPasses(device: device)
        grid = try NativeEditorGridPass(device: device)
        post = try NativePostPasses(device: device)
        particles = try NativeParticlePass(device: device)
        particleSimulation = NativeParticleSimulation(device: device)
    }
    public func initialize() { Logger.renderer.info("NativeRenderer ready (\(device.deviceName))") }
    public func currentFrameStats() -> RenderFrameStats { lastFrameStats }
    public func currentViewportSurfaceState() -> ViewportSurfaceState { viewportPublication.state }
    public func drainGPUParticleSimulationEventSnapshots(maxSnapshots: Int = Int.max) throws -> [GPUParticleSimulationEventSnapshot] {
        try particleSimulation.drain(maxSnapshots: maxSnapshots)
    }
    public func render(packet: RenderPacket) {
        do { try renderChecked(packet: packet) }
        catch { lastError = String(describing: error); Logger.renderer.error("native scene render failed: \(error)") }
    }

    public func renderChecked(packet: RenderPacket) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let matrices = try NativePacketValidation.validate(packet)
        try meshes.synchronize()
        let hdr = packet.renderSettings.stage.rawValue >= RenderSettings.ReplacementStage.r4LightingPBRShadow.rawValue
        if hdr || packet.renderSettings.debugViewMode == .shaded { try lighting.ensureEnvironment() }
        let shadowPlan = ShadowAtlasPlanner.makeShadowAtlasPlan(scene: packet.scene, drawableSize: packet.drawableSize,
            enabled: hdr, settings: packet.renderSettings.shadowSettings, palettes: packet.jointPaletteMap, meshBounds: { meshes[$0]?.geometry.bounds })
        try shadows.ensureTargets(plan: shadowPlan)
        try ensureTargets(size: packet.drawableSize, hdr: hdr)
        guard let targets else { throw RHIError.outOfMemory }
        if hdr { try post.ensureTargets(size: targets.size) }
        var nextFrame = frameState
        nextFrame.prepare(packet: packet,resources: RenderFrameResourceVersion(meshRevision: meshes.revision,postRevision: post.revision,
            usedSize: packet.drawableSize),hdr: hdr)
        try device.beginFrame()
        defer { device.endFrame() }
        let hasDepth = packet.renderSettings.stage.rawValue >= RenderSettings.ReplacementStage.r2MultiObjectDepth.rawValue
        let commands = CommandBuffer()
        let simulationStart = DispatchTime.now().uptimeNanoseconds
        let simulation = try particleSimulation.prepare(scene: packet.scene,deltaTime: Float(packet.deltaTime),
            elapsedTime: Float(packet.simulationTimeSeconds),into: commands)
        let simulationTime = DispatchTime.now().uptimeNanoseconds - simulationStart
        let deformableStart = DispatchTime.now().uptimeNanoseconds
        let dynamic = try deformables.prepare(packet.scene.deformableMeshes, into: commands)
        let deformableTime = DispatchTime.now().uptimeNanoseconds - deformableStart
        let skin = try NativeSkinBindings(packet: packet, device: device)
        let lightBindings = try lighting.prepare(packet: packet, plan: shadowPlan, atlas: shadows.atlas, fallback: meshes.fallbacks[0])
        let shadowTiles = try shadows.prepare(packet: packet, store: meshes, plan: shadowPlan, skin: skin, deformables: dynamic.geometries)
        let prepared = try meshPass.prepare(packet: packet, store: meshes,
            matrices: matrices, depthPrepass: hasDepth, hdr: hdr, lighting: lightBindings, skin: skin, deformables: dynamic.geometries)
        let particleFrame = try particles.prepare(scene: packet.scene,matrices: matrices,hdr: hdr,simulated: simulation.render,into: commands)
        let opaqueDraws = prepared.draws.filter { $0.batch.key.mode != .blend }
        let transparentDraws = prepared.draws.filter { $0.batch.key.mode == .blend }.sorted { $0.batch.distance > $1.batch.distance }
        let image = surface == nil ? nil : try device.acquireSwapchainImage()
        guard let color = image?.texture ?? targets.color?.texture else { throw RHIError.swapchainAcquireFailed("no scene color target") }
        let prepareEnd = DispatchTime.now().uptimeNanoseconds
        var passTimes: [RenderPassKind: UInt64] = [:]
        var passDraws: [RenderPassKind: Int] = [:]
        var active: [RenderPassKind] = []
        var current = targets.hdr?.texture ?? color
        var bloom: Texture?
        let planned = RenderFramePlanner.makePlan(settings: packet.renderSettings).passes
        let passes = RenderFramePlanner.motionRefinedPasses(planned,opaqueMoving: nextFrame.moving)
        for kind in passes {
            if nextFrame.cacheHit && RenderPassKind.opaquePasses.contains(kind) { continue }
            let before = DispatchTime.now().uptimeNanoseconds
            var draws = 1
            switch kind {
            case .depthPrepass:
                meshPass.encode(draws: opaqueDraws,size: packet.drawableSize,color: nil,
                    depth: RenderDepthTarget(texture: targets.depth.texture,loadAction: .clear(1)),kind: .depth,into: commands)
                draws = opaqueDraws.count
            case .shadowPass:
                guard !shadowTiles.isEmpty else { continue }
                shadows.encode(tiles: shadowTiles,plan: shadowPlan,into: commands)
                draws = shadowTiles.reduce(0) { $0 + $1.draws.count }
            case .skybox:
                try hdrPasses.encodeSky(packet: packet,matrices: matrices,hdr: current,depth: targets.depth.texture,into: commands)
            case .basePass:
                meshPass.encode(draws: opaqueDraws,size: packet.drawableSize,
                    color: RenderColorTarget(texture: current,loadAction: hdr ? .load : .clear(SIMD4(0.05,0.06,0.08,1))),
                    depth: RenderDepthTarget(texture: targets.depth.texture,loadAction: hasDepth ? .load : .clear(1)),into: commands)
                draws = opaqueDraws.count
            case .ssao, .ssr:
                guard let resources = post.targets else { throw RHIError.outOfMemory }
                let output = resources.next(after: current)
                if kind == .ssao {
                    try post.encode(kind: kind,input: current,secondary: targets.depth.texture,output: output,
                        uniforms: PostEffectUniforms.ssao(projection: matrices.projection,size: packet.drawableSize),size: packet.drawableSize,into: commands)
                } else {
                    try post.encode(kind: kind,input: current,secondary: targets.depth.texture,output: output,
                        uniforms: PostEffectUniforms.ssr(projection: matrices.projection,size: packet.drawableSize),size: packet.drawableSize,into: commands)
                }
                current = output
            case .editorGrid:
                if hdr { try hdrPasses.encodeGrid(packet: packet,hdr: current,depth: targets.depth.texture,into: commands) }
                else {
                    try grid.encode(packet: packet,color: RenderColorTarget(texture: current,loadAction: .load),
                        depth: RenderDepthTarget(texture: targets.depth.texture,loadAction: .load),into: commands)
                }
            case .taa:
                guard let resources = post.targets else { throw RHIError.outOfMemory }
                let output = resources.next(after: current)
                try post.encode(kind: kind,input: current,secondary: resources.history,output: output,
                    uniforms: PostEffectUniforms.taa(size: resources.size,historyValid: nextFrame.historyValid),size: packet.drawableSize,into: commands)
                commands.copyPass { $0.copyTexture(src: output,dst: resources.history,width: Int(packet.drawableSize.width),height: Int(packet.drawableSize.height)) }
                nextFrame.historyValid = true; current = output
            case .transparentMeshes:
                if hdr, let resources = post.targets, let scene = targets.hdr?.texture {
                    if nextFrame.cacheHit {
                        commands.copyPass { $0.copyTexture(src: resources.snapshot,dst: scene,width: Int(packet.drawableSize.width),height: Int(packet.drawableSize.height)) }
                        current = scene
                    } else if nextFrame.canCapture(settings: packet.renderSettings) {
                        commands.copyPass { $0.copyTexture(src: current,dst: resources.snapshot,width: Int(packet.drawableSize.width),height: Int(packet.drawableSize.height)) }
                        nextFrame.snapshotValid = true
                    }
                }
                guard !transparentDraws.isEmpty else { continue }
                meshPass.encode(draws: transparentDraws,size: packet.drawableSize,
                    color: RenderColorTarget(texture: current,loadAction: .load),
                    depth: RenderDepthTarget(texture: targets.depth.texture,loadAction: .load),into: commands)
                draws = transparentDraws.count
            case .bloom:
                guard let resources = post.targets else { throw RHIError.outOfMemory }
                let output = resources.next(after: current)
                try post.encode(kind: kind,input: current,secondary: current,output: output,
                    uniforms: PostEffectUniforms.bloom(size: resources.size),size: packet.drawableSize,into: commands)
                bloom = output
            case .tonemap:
                let output = packet.renderSettings.enableFXAA ? post.targets?.ldr ?? color : color
                try hdrPasses.encodeTonemap(size: packet.drawableSize,capacity: targets.size,hdr: current,output: output,bloom: bloom,into: commands)
            case .fxaa:
                guard let input = post.targets?.ldr else { throw RHIError.outOfMemory }
                try post.encode(kind: kind,input: input,secondary: input,output: color,
                    uniforms: SIMD4<Float>(1/Float(targets.size.width),1/Float(targets.size.height),0,0),size: packet.drawableSize,into: commands)
            case .particles:
                guard let particleFrame else { continue }
                particles.encode(particleFrame,size: packet.drawableSize,color: current,depth: targets.depth.texture,into: commands)
                draws = particleFrame.draws.count
            case .viewportResolve: continue
            case .outline:
                let outlines = opaqueDraws.filter { $0.outlinePipeline != nil }
                meshPass.encode(draws: outlines,size: packet.drawableSize,color: RenderColorTarget(texture: current,loadAction: .load),
                    depth: RenderDepthTarget(texture: targets.depth.texture,loadAction: .load),kind: .outline,into: commands)
                draws = outlines.count
            case .inkPaperPost:
                guard hdr, let resources = post.targets else { continue }
                let output = resources.next(after: current)
                try post.encode(kind: kind,input: current,secondary: current,output: output,
                    uniforms: StylizedCharacterUniforms(style: packet.renderSettings.stylizedCharacterStyle),size: packet.drawableSize,into: commands)
                current = output
            }
            passTimes[kind] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[kind] = draws; active.append(kind)
        }
        let encoded = DispatchTime.now().uptimeNanoseconds
        try device.submit(commands); deformables.commit(dynamic); particleSimulation.commit(simulation); frameState = nextFrame
        if let output = targets.color {
            viewportPublication.publish(storage: .native(output),
                region: ViewportSamplingRegion(size: packet.drawableSize, capacity: targets.size))
        } else { viewportPublication.clear() }
        if let image { try device.present(image) }
        let end = DispatchTime.now().uptimeNanoseconds
        var stats = RenderFrameStats()
        stats.frameIndex = packet.frameIndex; stats.passCount = active.count; stats.activePasses = active
        stats.drawCallCount = passDraws.values.reduce(0,+); stats.passDrawCallCounts = passDraws; stats.passEncodeNS = passTimes
        stats.cpuPrepareNS = prepareEnd - start; stats.cpuEncodeNS = encoded - prepareEnd
        stats.cpuPostProcessEncodeNS = [.inkPaperPost,.ssao,.ssr,.taa,.bloom,.tonemap,.fxaa].reduce(0) { $0 + (passTimes[$1] ?? 0) }
        stats.cpuSubmitNS = end - encoded; stats.cpuFrameTotalNS = end - start
        stats.culledMeshInstanceCount = prepared.visibility.culledCount; stats.lodMeshInstanceCount = prepared.visibility.lodCount
        stats.shadowedLightCount = shadowPlan.shadowedLightCount
        stats.shadowTileCount = shadowPlan.shadowTileCount
        stats.shadowCascadeCount = shadowPlan.cascadeCount
        stats.shadowMapResolution = shadowPlan.tileSize
        stats.shadowAtlasResolution = shadowPlan.atlasSize
        stats.meshBatchCount = prepared.draws.count; stats.instancedMeshBatchCount = prepared.draws.count { $0.batch.uniforms.count > 1 }
        stats.submittedMeshTriangleCount = prepared.draws.reduce(0) { $0 + $1.batch.key.indexCount / 3 * $1.batch.uniforms.count }
        stats.deformableMeshCount = dynamic.report.meshCount
        stats.deformableVertexCount = dynamic.report.vertexCount
        stats.deformableTriangleCount = dynamic.report.triangleCount
        stats.deformableRejectedMeshCount = dynamic.report.rejectedMeshCount
        stats.deformableUploadedBytes = dynamic.report.uploadedBytes
        stats.deformableUploadNS = deformableTime
        stats.gpuParticleCullBatchCount = particleFrame?.draws.count ?? 0
        stats.gpuParticleCullCandidateCount = particleFrame?.candidates ?? 0
        stats.gpuParticleCullDispatchWorkgroups = particleFrame?.draws.count ?? 0
        stats.gpuParticleIndirectDrawCount = particleFrame?.draws.count ?? 0
        stats.gpuParticleSimulationBatchCount = simulation.report.batchCount
        stats.gpuParticleSimulationParticleCount = simulation.report.particleCount
        stats.gpuParticleSimulationDispatchWorkgroups = simulation.report.dispatchWorkgroups
        stats.gpuParticleSimulationEventCapacity = simulation.report.eventCapacity
        stats.gpuParticleSimulationEventBufferBytes = simulation.report.eventBufferBytes
        stats.gpuParticleSimulationEncodeNS = simulationTime
        stats.gpuParticleRenderInstanceCount = simulation.report.renderInstanceCount
        stats.gpuParticleInstanceDispatchWorkgroups = simulation.report.instanceDispatchWorkgroups
        stats.gpuParticleSortPassCount = simulation.report.sortPassCount
        stats.gpuParticleSortItemCount = simulation.report.sortItemCount
        stats.gpuParticleSortPaddedItemCount = simulation.report.sortPaddedItemCount
        stats.gpuParticleSortDispatchWorkgroups = simulation.report.sortDispatchWorkgroups
        lastFrameStats = stats; lastError = nil
    }

    private func ensureTargets(size: RenderDrawableSize, hdr: Bool) throws {
        if let surface, configuredSurfaceSize != size {
            try NativeRenderTargets.configure(device: device, surface: surface, size: size)
            configuredSurfaceSize = size
        }
        // Direct swapchain rendering needs matching depth dimensions. HDR and
        // offscreen targets share the production grow-only viewport policy.
        let previous = targets?.size ?? RenderDrawableSize(width: 0,height: 0)
        let postSize = hdr ? post.targets?.size : nil
        let current = RenderDrawableSize(width: max(previous.width,postSize?.width ?? 0),height: max(previous.height,postSize?.height ?? 0))
        let capacity = surface != nil && !hdr ? size : ViewportTargetAllocation.grownCapacity(current: current,used: size)
        if targets?.size == capacity && (targets?.hdr != nil) == hdr { return }
        let replacement = try NativeRenderTargets.make(device: device, size: capacity, offscreen: surface == nil, hdr: hdr)
        targets = replacement
    }
}
