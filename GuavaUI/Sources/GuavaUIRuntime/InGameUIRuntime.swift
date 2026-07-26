import EngineKernel
import Foundation
import Logging
import RHIWGPU

private enum InGameUIRendererError: Error {
    case emptyAtlasPayload
}

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
    private var pendingAtlasDirty: DrawListAtlasDirty?
    private var reportedFailures: [String: String] = [:]

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
            do {
                try renderer.configure(format: gpuFormat)
                configuredFormat = gpuFormat
                clearFailure(context: "configure")
            } catch {
                configuredFormat = nil
                reportFailure(error, context: "configure")
                return
            }
        }
        guard configuredFormat != nil else { return }

        if let dirty = snapshot.atlasDirty { pendingAtlasDirty = dirty }
        if let dirty = pendingAtlasDirty {
            do {
                try dirty.pixels.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else {
                        throw InGameUIRendererError.emptyAtlasPayload
                    }
                    try renderer.registerAlphaTexture(
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
                pendingAtlasDirty = nil
                clearFailure(context: "atlas upload")
            } catch {
                reportFailure(error, context: "atlas upload")
                return
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
            defer { pass.end() }
            // The scene occupies the top-left `width`×`height` sub-region of a
            // grow-only allocated target; pin the HUD to the same region.
            pass.setViewport(x: 0, y: 0, width: Float(width), height: Float(height))
            pass.setScissorRect(x: 0, y: 0, width: UInt32(width), height: UInt32(height))
            try renderer.render(
                list: renderThreadList,
                pass: pass,
                viewportPx: (UInt32(width), UInt32(height)),
                coordinateSpace: (snapshot.logicalWidth, snapshot.logicalHeight)
            )
            clearFailure(context: "render")
        } catch {
            reportFailure(error, context: "render")
        }
    }

    public func notifyResize(width: Int, height: Int) {}

    private func reportFailure(_ error: Error, context: String) {
        let description = String(describing: error)
        guard reportedFailures[context] != description else { return }
        reportedFailures[context] = description
        Logger(label: "com.guava.ui.runtime")
            .error("in-game UI \(context) failed: \(description)")
    }

    private func clearFailure(context: String) {
        reportedFailures.removeValue(forKey: context)
    }
}
