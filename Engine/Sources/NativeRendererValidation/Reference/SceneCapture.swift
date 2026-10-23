import Foundation
import NativeRHI
import RenderBackend

/// Independent device/session used to check deterministic rendering and resets.
/// This is not an independent shader oracle.
public final class SceneCapture {
    public let device: Device
    public let renderer: NativeRenderer
    public init(validation: Bool = false, api: GraphicsAPI? = nil, inGameUI: (any InGameUIProviding)? = nil) throws {
        device = try Device.make(DeviceConfig(preferredBackends: api.map { [$0] } ?? NativeRHI.platformDefaultBackends,
            enableValidation: validation))
        renderer = try NativeRenderer(device: device, inGameUI: inGameUI)
    }
    deinit { try? device.waitUntilIdle() }
    public func render(packet: RenderPacket) throws -> RenderFrameStats {
        try renderer.renderChecked(packet: packet)
        return renderer.lastFrameStats
    }
    public func finish() throws { try device.waitUntilIdle() }
    public func readback() throws -> Data {
        let surface = renderer.currentViewportSurfaceState()
        guard let image = surface.image, surface.isValid else {
            throw RHIError.invalidArgument("scene capture has no published frame")
        }
        return try GridImage.readback(device: device, texture: image.resource.texture, size: surface.region.size)
    }
}
