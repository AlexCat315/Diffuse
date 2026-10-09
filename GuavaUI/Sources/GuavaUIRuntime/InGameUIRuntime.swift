import Foundation
import RenderBackend
import RHIWGPU

/// WGPU consumer of the same HUD snapshots used by NativeRHI during migration.
/// The scene owns the frame and submits scene and UI commands together.
public final class WGPUInGameUIRenderer: InGameUIProviding, @unchecked Sendable {
    private let renderer: DrawListRenderer
    private let source: InGameDrawListSource
    private let list = DrawList()
    private var atlasDelivery = InGameUIAtlasDelivery()

    public init(renderer: DrawListRenderer, source: InGameDrawListSource) {
        self.renderer = renderer; self.source = source
    }

    public func recordInGameUI(packet: RenderPacket, target: InGameUIRenderTarget) throws -> InGameUIRecording? {
        guard case .wgpu(let target) = target, target.backend === renderer.backend else {
            throw WGPUBackendError.initFailed("WGPU HUD requires the scene's WGPU backend")
        }
        guard let snapshot = source.consume() else { list.reset(); return nil }
        atlasDelivery.collect(snapshot)
        try renderer.configure(format: target.format)
        try atlasDelivery.stage { update in
            try update.pixels.withUnsafeBufferPointer { pixels in
                guard let base = pixels.baseAddress else {
                    throw WGPUBackendError.initFailed("empty HUD atlas payload")
                }
                if update.format == .alpha {
                    try renderer.registerAlphaTexture(id: update.textureID, pixels: base,
                        width: update.regionWidth, height: update.regionHeight,
                        originX: update.regionX, originY: update.regionY,
                        textureWidth: update.textureWidth, textureHeight: update.textureHeight)
                } else {
                    try renderer.registerColorTexture(id: update.textureID, pixels: base,
                        width: update.regionWidth, height: update.regionHeight,
                        originX: update.regionX, originY: update.regionY,
                        textureWidth: update.textureWidth, textureHeight: update.textureHeight)
                }
            }
        }
        list.load(vertices: snapshot.vertices, indices: snapshot.indices, batches: snapshot.batches, resources: snapshot.resources)
        guard !snapshot.isEmpty else { return nil }
        let viewport = NativeUIViewport(pixels: SIMD2(Int(packet.drawableSize.width), Int(packet.drawableSize.height)), logical: snapshot.logicalSize)
        try viewport.validate()
        let pass = try target.encoder.beginRenderPass(colorView: target.color, loadOp: .load, storeOp: .store, clearColor: .clear)
        defer { pass.end() }
        pass.setViewport(x: 0, y: 0, width: Float(viewport.pixels.x), height: Float(viewport.pixels.y))
        pass.setScissorRect(x: 0, y: 0, width: packet.drawableSize.width, height: packet.drawableSize.height)
        let draws = try renderer.render(list: list, pass: pass,
            viewportPx: (packet.drawableSize.width, packet.drawableSize.height),
            coordinateSpace: (snapshot.logicalSize.x, snapshot.logicalSize.y))
        return InGameUIRecording(drawCallCount: draws) { withExtendedLifetime(snapshot.resources) {} }
    }
}
