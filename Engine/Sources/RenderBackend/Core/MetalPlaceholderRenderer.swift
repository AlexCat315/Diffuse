import Logging

public final class MetalPlaceholderRenderer: RenderPacketConsumer, @unchecked Sendable {
    public init() {}
    public func initialize() { Logger.renderer.debug("initialize Metal placeholder") }
    public func render(packet: RenderPacket) {
        Logger.renderer.debug("render frame \(packet.frameIndex)")
    }

    public func currentFrameStats() -> RenderFrameStats { .init() }
    public func currentViewportSurfaceState() -> ViewportSurfaceState { .init() }
}
