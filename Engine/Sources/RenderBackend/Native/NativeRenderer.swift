import AssetPipeline
import Foundation
import Logging
import NativeRHI
import SIMDCompat

/// Scene renderer recorded entirely through NativeRHI. The initial migration
/// supports static opaque/masked meshes, material inspection modes and the grid.
/// RenderThread owns all mutable renderer state.
public final class NativeRenderer: RenderPacketConsumer, @unchecked Sendable {
    public let device: Device
    private let meshes: NativeMeshStore
    private let opaque: NativeOpaquePass
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
        opaque = try NativeOpaquePass(device: device)
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
        let matrices = try validate(packet)
        try meshes.synchronize()
        try ensureTargets(size: packet.drawableSize)
        guard let targets else { throw RHIError.outOfMemory }
        try device.beginFrame()
        defer { device.endFrame() }
        let hasDepth = packet.renderSettings.stage.rawValue >= RenderSettings.ReplacementStage.r2MultiObjectDepth.rawValue
        let prepared = try opaque.prepare(packet: packet, store: meshes,
            matrices: matrices, depthPrepass: hasDepth)
        let image = surface == nil ? nil : try device.acquireSwapchainImage()
        guard let color = image?.texture ?? targets.color else { throw RHIError.swapchainAcquireFailed("no scene color target") }
        let prepareEnd = DispatchTime.now().uptimeNanoseconds
        let commands = CommandBuffer()
        var passTimes: [RenderPassKind: UInt64] = [:]
        var passDraws: [RenderPassKind: Int] = [:]
        var active: [RenderPassKind] = []
        if hasDepth {
            let before = DispatchTime.now().uptimeNanoseconds
            opaque.encode(draws: prepared.draws, size: packet.drawableSize, color: nil,
                depth: RenderDepthTarget(texture: targets.depth, loadAction: .clear(1)), depthOnly: true, into: commands)
            passTimes[.depthPrepass] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.depthPrepass] = prepared.draws.count; active.append(.depthPrepass)
        }
        let beforeBase = DispatchTime.now().uptimeNanoseconds
        opaque.encode(draws: prepared.draws, size: packet.drawableSize,
            color: RenderColorTarget(texture: color, loadAction: .clear(SIMD4(0.05,0.06,0.08,1))),
            depth: RenderDepthTarget(texture: targets.depth, loadAction: hasDepth ? .load : .clear(1)), depthOnly: false, into: commands)
        passTimes[.basePass] = DispatchTime.now().uptimeNanoseconds - beforeBase
        passDraws[.basePass] = prepared.draws.count; active.append(.basePass)
        if packet.renderSettings.enableEditorGrid {
            let before = DispatchTime.now().uptimeNanoseconds
            try grid.encode(packet: packet, color: RenderColorTarget(texture: color, loadAction: .load),
                depth: RenderDepthTarget(texture: targets.depth, loadAction: .load), into: commands)
            passTimes[.editorGrid] = DispatchTime.now().uptimeNanoseconds - before
            passDraws[.editorGrid] = 1; active.append(.editorGrid)
        }
        let encoded = DispatchTime.now().uptimeNanoseconds
        try device.submit(commands); if let image { try device.present(image) }
        let end = DispatchTime.now().uptimeNanoseconds
        var stats = RenderFrameStats()
        stats.frameIndex = packet.frameIndex; stats.passCount = active.count; stats.activePasses = active
        stats.drawCallCount = passDraws.values.reduce(0,+); stats.passDrawCallCounts = passDraws; stats.passEncodeNS = passTimes
        stats.cpuPrepareNS = prepareEnd - start; stats.cpuEncodeNS = encoded - prepareEnd
        stats.cpuSubmitNS = end - encoded; stats.cpuFrameTotalNS = end - start
        stats.culledMeshInstanceCount = prepared.visibility.culledCount; stats.lodMeshInstanceCount = prepared.visibility.lodCount
        stats.meshBatchCount = prepared.draws.count; stats.instancedMeshBatchCount = prepared.draws.count { $0.instanceCount > 1 }
        stats.submittedMeshTriangleCount = prepared.draws.reduce(0) { $0 + $1.key.indexCount / 3 * $1.instanceCount }
        lastFrameStats = stats; lastError = nil
    }

    private func validate(_ packet: RenderPacket) throws -> RenderCameraMatrices {
        guard packet.drawableSize.width > 0, packet.drawableSize.height > 0,
              !packet.renderSettings.enableEditorGrid || packet.renderSettings.editorGridSpacing.isFinite else { throw RHIError.invalidArgument("native viewport must be nonempty") }
        guard [.r1MeshCamera,.r2MultiObjectDepth,.r3ViewportInterop].contains(packet.renderSettings.stage),
              packet.renderSettings.debugViewMode != .shaded,
              !packet.renderSettings.enableStylizedCharacterShading,
              packet.jointPaletteMap.palettes.isEmpty, packet.scene.deformableMeshes.isEmpty,
              packet.scene.particles.isEmpty, packet.scene.particleSimulationBatches.isEmpty else {
            throw RHIError.unsupportedFeature("native lighting, post, animation and particle migration is pending; use static geometry with a material inspection mode")
        }
        let matrices = RenderCameraMatrices.make(scene: packet.scene, drawableSize: packet.drawableSize)
        guard Self.finite(matrices.viewProjection), packet.scene.environment.exposure.isFinite,
              packet.scene.instances.allSatisfy({ Self.finite($0.transform) }) else {
            throw RHIError.invalidArgument("non-finite camera or instance transform")
        }
        for instance in packet.scene.instances {
            guard instance.colorTint.x.isFinite, instance.colorTint.y.isFinite, instance.colorTint.z.isFinite,
                  instance.material.baseColorFactor.x.isFinite, instance.material.baseColorFactor.y.isFinite,
                  instance.material.baseColorFactor.z.isFinite, instance.material.baseColorFactor.w.isFinite else {
                throw RHIError.invalidArgument("non-finite material color")
            }
        }
        return matrices
    }
    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }
    private func ensureTargets(size: RenderDrawableSize) throws {
        if targets?.size == size { return }
        if let surface { try NativeRenderTargets.configure(device: device, surface: surface, size: size) }
        let replacement = try NativeRenderTargets.make(device: device, size: size, offscreen: surface == nil)
        targets?.destroy(device: device); targets = replacement
    }
}
