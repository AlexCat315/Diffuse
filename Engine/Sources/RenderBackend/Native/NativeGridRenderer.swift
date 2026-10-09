import Foundation
import Logging
import NativeRHI

/// An isolated RenderPacketConsumer for validating the migrated editor-grid
/// pass. Full scene meshes and post processing belong to NativeRenderer.
/// This consumer supports native windows and offscreen NativeRHI textures;
/// offscreen output is published as an owned NativeRHI image for UI sampling.
public final class NativeGridRenderer: RenderPacketConsumer, @unchecked Sendable {
    public let device: Device
    private let grid: NativeEditorGridPass
    private let windowTarget: NativeWindowTarget?
    private var targets: NativeRenderTargets?
    private var viewportPublication = ViewportSurfacePublication()
    public private(set) var lastFrameStats = RenderFrameStats()
    public private(set) var lastError: String?
    /// Borrowed handle; a viewport surface owns the output across replacement.
    public var colorTexture: Texture? { targets?.color?.texture }

    public init(device: Device, surface: RenderSurfaceDescriptor? = nil) throws {
        self.device = device; windowTarget = surface.map { NativeWindowTarget(device: device, surface: $0) }
        grid = try NativeEditorGridPass(device: device)
    }

    public func initialize() { Logger.renderer.info("NativeRHI editor-grid renderer ready (\(device.deviceName))") }
    public func render(packet: RenderPacket) {
        do { try renderChecked(packet: packet) }
        catch { lastError = String(describing: error); Logger.renderer.error("native grid render failed: \(error)") }
    }
    public func currentFrameStats() -> RenderFrameStats { lastFrameStats }
    public func currentViewportSurfaceState() -> ViewportSurfaceState { viewportPublication.state }

    /// Throwing entry point used by tools/tests so a failed render cannot be
    /// mistaken for a successful frame or a performance sample.
    public func renderChecked(packet: RenderPacket) throws {
        try device.withFrameSession { try renderFrame(packet: packet) }
    }

    private func renderFrame(packet: RenderPacket) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        guard packet.drawableSize.width > 0, packet.drawableSize.height > 0,
              !packet.renderSettings.enableEditorGrid || packet.renderSettings.editorGridSpacing.isFinite else {
            throw RHIError.invalidArgument("native grid viewport must be nonempty")
        }
        try ensureTargets(size: packet.drawableSize)
        guard let targets else { throw RHIError.outOfMemory }
        try device.beginFrame()
        defer { device.endFrame() }
        let image = try windowTarget?.acquire()
        guard let color = image?.texture ?? targets.color?.texture else { throw RHIError.swapchainAcquireFailed("no grid color target") }
        let prepared = DispatchTime.now().uptimeNanoseconds
        let commands = CommandBuffer()
        let colorTarget = RenderColorTarget(texture: color, loadAction: .clear(SIMD4(0.08, 0.10, 0.14, 1)))
        let depthTarget = RenderDepthTarget(texture: targets.depth.texture, loadAction: .clear(1))
        if packet.renderSettings.enableEditorGrid {
            try grid.encode(packet: packet, color: colorTarget, depth: depthTarget, into: commands)
        } else {
            commands.renderPass(descriptor: RenderPassDescriptor(colorTargets: [colorTarget], depthTarget: depthTarget)) { _ in }
        }
        let encoded = DispatchTime.now().uptimeNanoseconds
        try device.submit(commands)
        if let output = targets.color {
            viewportPublication.publish(storage: .native(output),
                region: ViewportSamplingRegion(size: packet.drawableSize, capacity: targets.size))
        } else { viewportPublication.clear() }
        if let image { try device.present(image) }
        let submitted = DispatchTime.now().uptimeNanoseconds
        var stats = RenderFrameStats()
        stats.frameIndex = packet.frameIndex; stats.passCount = 1
        stats.drawCallCount = packet.renderSettings.enableEditorGrid ? 1 : 0
        stats.activePasses = packet.renderSettings.enableEditorGrid ? [.editorGrid] : []
        stats.passDrawCallCounts = [.editorGrid: stats.drawCallCount]
        stats.cpuPrepareNS = prepared - start; stats.cpuEncodeNS = encoded - prepared
        stats.cpuSubmitNS = submitted - encoded; stats.cpuFrameTotalNS = submitted - start
        stats.passEncodeNS = [.editorGrid: stats.cpuEncodeNS]
        lastFrameStats = stats; lastError = nil
    }

    private func ensureTargets(size: RenderDrawableSize) throws {
        if targets?.size == size { return }
        try windowTarget?.configure(size: size)
        let replacement = try NativeRenderTargets.make(device: device, size: size, offscreen: windowTarget == nil)
        targets = replacement
    }
}
