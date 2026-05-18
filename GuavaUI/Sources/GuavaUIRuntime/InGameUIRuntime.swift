import EngineKernel
import Foundation
import RHIWGPU

/// Render-thread implementation of `InGameUIProviding` that reads
/// `DrawListSnapshot` frames published by `InGameViewGraphBridge` on the
/// main thread and composites them onto the 3-D scene using `DrawListRenderer`.
///
/// Do not instantiate this directly — use `InGameUIHost` in `GuavaUIApp`,
/// which wires this together with the main-thread `InGameViewGraphBridge`.
public final class InGameUIRenderer: InGameUIProviding, @unchecked Sendable {

    private let renderer: DrawListRenderer
    private let source: InGameDrawListSource
    private var configuredFormat: GPUTextureFormat?
    private let renderThreadList = DrawList()

    public init(renderer: DrawListRenderer, source: InGameDrawListSource) {
        self.renderer = renderer
        self.source = source
    }

    // MARK: - InGameUIProviding

    public func renderInGameUI(
        canvas: InGameCanvas,
        commandEncoder: AnyObject,
        colorView: AnyObject,
        formatHint: String,
        width: Int,
        height: Int,
        deltaTime: Double
    ) {
        guard let snapshot = source.consume(),
              !snapshot.isEmpty,
              let encoder = commandEncoder as? GPUCommandEncoder,
              let view = colorView as? GPUTextureView,
              width > 0, height > 0
        else { return }

        let gpuFormat: GPUTextureFormat
        switch formatHint {
        case "rgba16Float": gpuFormat = .rgba16Float
        case "rgba8Unorm":  gpuFormat = .rgba8Unorm
        default:            gpuFormat = .bgra8Unorm
        }

        if configuredFormat != gpuFormat {
            try? renderer.configure(format: gpuFormat)
            configuredFormat = gpuFormat
        }
        guard configuredFormat != nil else { return }

        if let dirty = snapshot.atlasDirty {
            dirty.pixels.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                try? renderer.registerAlphaTexture(
                    id: dirty.textureID,
                    pixels: base,
                    width: dirty.regionWidth,
                    height: dirty.regionHeight,
                    originX: dirty.regionX,
                    originY: dirty.regionY,
                    textureWidth: dirty.textureWidth,
                    textureHeight: dirty.textureHeight
                )
            }
        }

        renderThreadList.load(
            vertices: snapshot.vertices,
            indices: snapshot.indices,
            batches: snapshot.batches
        )

        do {
            let pass = try encoder.beginRenderPass(
                colorView: view,
                loadOp: .load,
                storeOp: .store,
                clearColor: .clear
            )
            try renderer.render(
                list: renderThreadList,
                pass: pass,
                viewportPx: (snapshot.viewportWidth, snapshot.viewportHeight),
                coordinateSpace: (snapshot.logicalWidth, snapshot.logicalHeight)
            )
            pass.end()
        } catch {}
    }

    public func notifyResize(width: Int, height: Int) {}
}
