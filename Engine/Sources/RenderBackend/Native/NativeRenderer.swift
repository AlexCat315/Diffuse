import AssetPipeline
import Foundation
import Logging
import NativeRHI
import SIMDCompat

/// Scene renderer recorded entirely through NativeRHI. The initial migration
/// supports opaque/masked/transparent meshes and animation, PBR lighting, directional shadows,
/// HDR sky/tonemap, material inspection modes and the grid.
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
    private let surface: RenderSurfaceDescriptor?
    private var targets: NativeRenderTargets?
    public private(set) var lastFrameStats = RenderFrameStats()
    public private(set) var lastError: String?
    public var colorTexture: Texture? { targets?.color }
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
    }
    deinit { targets?.destroy(device: device) }
    public func initialize() { Logger.renderer.info("NativeRenderer ready (\(device.deviceName))") }
    public func currentFrameStats() -> RenderFrameStats { lastFrameStats }
    public func currentViewportSurfaceState() -> ViewportSurfaceState { .init() }
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
        try device.beginFrame()
        defer { device.endFrame() }
        let hasDepth = packet.renderSettings.stage.rawValue >= RenderSettings.ReplacementStage.r2MultiObjectDepth.rawValue
        let commands = CommandBuffer()
        let deformableStart = DispatchTime.now().uptimeNanoseconds
        let dynamic = try deformables.prepare(packet.scene.deformableMeshes, into: commands)
        let deformableTime = DispatchTime.now().uptimeNanoseconds - deformableStart
        let skin = try NativeSkinBindings(packet: packet, device: device)
        let lightBindings = try lighting.prepare(packet: packet, plan: shadowPlan, atlas: shadows.atlas, fallback: meshes.fallbacks[0])
        let shadowTiles = try shadows.prepare(packet: packet, store: meshes, plan: shadowPlan, skin: skin, deformables: dynamic.geometries)
        let prepared = try meshPass.prepare(packet: packet, store: meshes,
            matrices: matrices, depthPrepass: hasDepth, hdr: hdr, lighting: lightBindings, skin: skin, deformables: dynamic.geometries)
        let opaqueDraws = prepared.draws.filter { $0.batch.key.mode != .blend }
        let transparentDraws = prepared.draws.filter { $0.batch.key.mode == .blend }.sorted { $0.batch.distance > $1.batch.distance }
        let image = surface == nil ? nil : try device.acquireSwapchainImage()
        guard let color = image?.texture ?? targets.color else { throw RHIError.swapchainAcquireFailed("no scene color target") }
        let prepareEnd = DispatchTime.now().uptimeNanoseconds
        var passTimes: [RenderPassKind: UInt64] = [:]
        var passDraws: [RenderPassKind: Int] = [:]
        var active: [RenderPassKind] = []
        if hasDepth {
            let before = DispatchTime.now().uptimeNanoseconds
            meshPass.encode(draws: opaqueDraws, size: packet.drawableSize, color: nil,
                depth: RenderDepthTarget(texture: targets.depth, loadAction: .clear(1)), depthOnly: true, into: commands)
            passTimes[.depthPrepass] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.depthPrepass] = opaqueDraws.count; active.append(.depthPrepass)
        }
        if !shadowTiles.isEmpty {
            let before = DispatchTime.now().uptimeNanoseconds
            shadows.encode(tiles: shadowTiles, plan: shadowPlan, into: commands)
            passTimes[.shadowPass] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.shadowPass] = shadowTiles.reduce(0) { $0 + $1.draws.count }; active.append(.shadowPass)
        }
        let sceneColor = targets.hdr ?? color
        if hdr {
            let before = DispatchTime.now().uptimeNanoseconds
            try hdrPasses.encodeSky(packet: packet, matrices: matrices, hdr: sceneColor, depth: targets.depth, into: commands)
            passTimes[.skybox] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.skybox] = 1; active.append(.skybox)
        }
        let beforeBase = DispatchTime.now().uptimeNanoseconds
        meshPass.encode(draws: opaqueDraws, size: packet.drawableSize,
            color: RenderColorTarget(texture: sceneColor, loadAction: hdr ? .load : .clear(SIMD4(0.05,0.06,0.08,1))),
            depth: RenderDepthTarget(texture: targets.depth, loadAction: hasDepth ? .load : .clear(1)), depthOnly: false, into: commands)
        passTimes[.basePass] = DispatchTime.now().uptimeNanoseconds - beforeBase
        passDraws[.basePass] = opaqueDraws.count; active.append(.basePass)
        if packet.renderSettings.enableEditorGrid {
            let before = DispatchTime.now().uptimeNanoseconds
            if hdr {
                try hdrPasses.encodeGrid(packet: packet, hdr: sceneColor, depth: targets.depth, into: commands)
            } else {
                try grid.encode(packet: packet, color: RenderColorTarget(texture: color, loadAction: .load),
                    depth: RenderDepthTarget(texture: targets.depth, loadAction: .load), into: commands)
            }
            passTimes[.editorGrid] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.editorGrid] = 1; active.append(.editorGrid)
        }
        if !transparentDraws.isEmpty {
            let before = DispatchTime.now().uptimeNanoseconds
            meshPass.encode(draws: transparentDraws, size: packet.drawableSize,
                color: RenderColorTarget(texture: sceneColor, loadAction: .load),
                depth: RenderDepthTarget(texture: targets.depth, loadAction: .load), depthOnly: false, into: commands)
            passTimes[.transparentMeshes] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.transparentMeshes] = transparentDraws.count; active.append(.transparentMeshes)
        }
        if hdr {
            let before = DispatchTime.now().uptimeNanoseconds
            try hdrPasses.encodeTonemap(size: packet.drawableSize, hdr: sceneColor, output: color, into: commands)
            passTimes[.tonemap] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.tonemap] = 1; active.append(.tonemap)
        }
        let encoded = DispatchTime.now().uptimeNanoseconds
        try device.submit(commands); deformables.commit(dynamic)
        if let image { try device.present(image) }
        let end = DispatchTime.now().uptimeNanoseconds
        var stats = RenderFrameStats()
        stats.frameIndex = packet.frameIndex; stats.passCount = active.count; stats.activePasses = active
        stats.drawCallCount = passDraws.values.reduce(0,+); stats.passDrawCallCounts = passDraws; stats.passEncodeNS = passTimes
        stats.cpuPrepareNS = prepareEnd - start; stats.cpuEncodeNS = encoded - prepareEnd
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
        lastFrameStats = stats; lastError = nil
    }

    private func ensureTargets(size: RenderDrawableSize, hdr: Bool) throws {
        if targets?.size == size && (targets?.hdr != nil) == hdr { return }
        if let surface { try NativeRenderTargets.configure(device: device, surface: surface, size: size) }
        let replacement = try NativeRenderTargets.make(device: device, size: size, offscreen: surface == nil, hdr: hdr)
        targets?.destroy(device: device); targets = replacement
    }
}
