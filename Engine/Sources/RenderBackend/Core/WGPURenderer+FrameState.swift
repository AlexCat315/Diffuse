import Logging
import RHIWGPU

extension WGPURenderer {
    struct FrameColorTarget {
        let texture: GPUTexture
        let view: GPUTextureView
        let presentAfterSubmit: Bool
    }

    func acquireColorTarget() throws -> FrameColorTarget? {
        if let surface {
            guard let acquired = try surface.getCurrentTextureView() else {
                return nil
            }
            return FrameColorTarget(
                texture: acquired.texture,
                view: acquired.view,
                presentAfterSubmit: true
            )
        }

        guard let offscreenColorTexture, let offscreenColorView else {
            return nil
        }
        return FrameColorTarget(
            texture: offscreenColorTexture,
            view: offscreenColorView,
            presentAfterSubmit: false
        )
    }

    func applyPacketRenderSettingsIfNeeded(_ settings: RenderSettings, frameIndex: Int) {
        guard settings != activeRenderSettings else { return }
        activeRenderSettings = settings
        settingsGeneration &+= 1
        if !settings.enableTAA {
            historyValid = false
        }

        if shouldEmitPlannerLog(frameIndex: frameIndex) {
            let gen = settingsGeneration
            Logger.renderer.debug(
                "applied render settings generation=\(gen) stage=\(settings.stage.rawValue) fxaa=\(settings.enableFXAA) ssao=\(settings.enableSSAO) ssr=\(settings.enableSSR) taa=\(settings.enableTAA) bloom=\(settings.enableBloom) stylized=\(settings.enableStylizedCharacterShading) outlineWidth=\(settings.stylizedCharacterStyle.outlineWidth) bundles=\(settings.enableRenderBundles) grouped=\(settings.enableGroupedDrawByMesh) chunk=\(settings.renderBundleChunkSize)"
            )
        }
    }

    func emitPlannedPassLog(_ passKind: RenderPassKind, frameIndex: Int) {
        guard shouldEmitPlannerLog(frameIndex: frameIndex) else { return }
        Logger.renderer.debug("executing placeholder pass=\(passKind.rawValue)")
    }

    func shouldEmitPlannerLog(frameIndex: Int) -> Bool {
        frameIndex == 0 || frameIndex % 120 == 0
    }

    func registerViewportSurface(texture: GPUTexture, size: RenderDrawableSize) {
        // Keep old texture retainers briefly because UI snapshots can outlive
        // the frame that published them.
        if let publishedTextureRetainer,
           publishedTextureRetainer.takeUnretainedValue() === texture {
            viewportSurfaceState = ViewportSurfaceState(
                surfaceID: publishedSurfaceID,
                handle: publishedSurfaceHandle,
                width: size.width,
                height: size.height,
                zeroCopy: true
            )
            return
        }

        if let previous = publishedTextureRetainer {
            stalePublishedTextureRetainers.append(previous)
            if stalePublishedTextureRetainers.count > publishedTextureRetainerHistoryLimit {
                stalePublishedTextureRetainers.removeFirst().release()
            }
        }
        let retained = Unmanaged.passRetained(texture)
        publishedTextureRetainer = retained
        nextSurfaceID &+= 1
        publishedSurfaceID = nextSurfaceID
        publishedSurfaceHandle = UInt64(UInt(bitPattern: retained.toOpaque()))

        viewportSurfaceState = ViewportSurfaceState(
            surfaceID: publishedSurfaceID,
            handle: publishedSurfaceHandle,
            width: size.width,
            height: size.height,
            zeroCopy: true
        )
    }
}
