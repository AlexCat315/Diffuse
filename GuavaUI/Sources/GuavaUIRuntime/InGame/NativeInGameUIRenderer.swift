import Foundation
import NativeRHI
import RenderBackend

/// Render-thread consumer of HUD snapshots. Scene and UI commands are submitted
/// together, preserving scene color and sampling only the packet's used extent.
public final class NativeInGameUIRenderer: InGameUIProviding, @unchecked Sendable {
    private let device: Device
    private let renderer: NativeDrawListRenderer
    private let source: InGameDrawListSource
    private let list = DrawList()
    private var atlasDelivery = InGameUIAtlasDelivery()

    public init(device: Device, source: InGameDrawListSource) throws {
        self.device = device; self.source = source
        renderer = try NativeDrawListRenderer(device: device)
    }

    public func recordInGameUI(packet: RenderPacket, target: InGameUIRenderTarget) throws -> InGameUIRecording? {
        guard case .native(let target) = target, target.device === device else {
            throw RHIError.invalidArgument("native HUD requires the scene's NativeRHI device")
        }
        guard let snapshot = source.consume() else { list.reset(); return nil }
        atlasDelivery.collect(snapshot)
        try renderer.configure(format: target.format, sampleCount: target.sampleCount)
        try atlasDelivery.stage { update in
            var region = TextureUploadRegion(width: Int(update.regionWidth), height: Int(update.regionHeight))
            region.origin = SIMD2(Int(update.regionX), Int(update.regionY))
            try renderer.registerTexture(id: update.textureID, pixels: Data(update.pixels),
                size: SIMD2(Int(update.textureWidth), Int(update.textureHeight)), region: region,
                format: update.format == .alpha ? .r8Unorm : .rgba8Unorm)
        }
        list.load(vertices: snapshot.vertices, indices: snapshot.indices, batches: snapshot.batches, resources: snapshot.resources)
        guard !snapshot.isEmpty else { return nil }
        let frame = try renderer.record(list: list, into: target.commands, target: target.color,
            viewport: NativeUIViewport(pixels: SIMD2(Int(packet.drawableSize.width), Int(packet.drawableSize.height)), logical: snapshot.logicalSize))
        return InGameUIRecording(drawCallCount: frame.statistics.drawCalls) { frame.didSubmit() }
    }
}
