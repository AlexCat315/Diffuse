import Foundation
import NativeRHI
import GuavaUICore
import GuavaUIRuntime
import CAndroidHost

/// JNI serializes this surface's GPU and scene operations on the UI thread.
final class SurfaceSession {
    let application: AndroidApplication
    var device: Device { application.device }
    var renderer: NativeDrawListRenderer { application.renderer }
    let swapchain: Swapchain
    var scene: HostedScene { application.scene }
    var scale: Float { application.scale }
    let pixels: SIMD2<Int>
    private var clock = DisplayFrameClock()
    private let timings: FrameTimings
    private var gpuTimings: GPUTimingReporter
    private var framebuffer: TextureResource?

    init(application: AndroidApplication, window: UnsafeMutableRawPointer, width: Int, height: Int) throws {
        self.application = application
        timings = FrameTimings(enabled: application.runtime.timings)
        gpuTimings = GPUTimingReporter(device: application.device, enabled: application.runtime.timings)
        pixels = SIMD2(width, height)
        swapchain = try application.device.withFrameSession {
            try application.device.makeSwapchain(SurfaceDescriptor(nativeHandle: window, width: width, height: height,
                                                                    vsyncEnabled: application.runtime.vsync))
        }
        scene.invalidate()
        let presentation = try? application.device.presentationMode(for: swapchain)
        guava_android_log("OPEN \(device.deviceName) \(width)x\(height) vsyncRequested=\(application.runtime.vsync) presentMode=\(presentation?.rawValue ?? "unavailable") displaySynchronized=\(presentation.map { String($0.synchronizesToDisplay) } ?? "unavailable") benchmark=\(application.runtime.benchmark) gpuTimings=\(gpuTimings.isRecording)")
    }

    func frame(timestamp: UInt64) throws -> Bool {
        let dt = clock.advance(to: timestamp)
        guard application.runtime.benchmark || scene.needsFrame else { return false }
        timings.begin()
        timings.measure(.scenePrepare) { scene.prepare(pixels: pixels, scale: scale, deltaTime: dt) }
        let result = try device.withFrameSession { try presentFrame() }
        timings.finish(timestamp: timestamp, vertices: scene.list.vertices.count, indices: scene.list.indices.count)
        gpuTimings.tick(timestamp: timestamp)
        return result
    }

    private func presentFrame() throws -> Bool {
        try timings.measure(.frameSlot) { try device.beginFrame() }
        defer { device.endFrame() }
        let image = try timings.measure(.drawableAcquire) { try device.acquireSwapchainImage(swapchain) }
        if let resource = scene.game?.surface.image?.resource { try renderer.registerExternalColorTexture(id: 2, resource: resource) }
        let atlas = scene.fontAtlas
        try timings.measure(.atlasUpload) { try renderer.uploadFontAtlas(atlas, textureID: 1) }
        // A frosted panel samples what is already behind it, and a swapchain image
        // is a render target that cannot be sampled. Only pay for the owned texture
        // — and the blit that follows — on frames that really have a panel doing
        // the sampling; the rest render straight into the drawable.
        let frosted = renderer.supportsBackdrop && scene.list.batches.contains(where: { $0.backdrop != nil })
        if !frosted {
            framebuffer = nil
        } else if framebuffer?.descriptor.width != image.width || framebuffer?.descriptor.height != image.height {
            framebuffer = try TextureResource(device: device, descriptor: TextureDescriptor(width: image.width,
                height: image.height, format: .rgba8Unorm, usage: [.colorTarget, .sampled], label: "android-ui-framebuffer"))
        }
        let commands = CommandBuffer()
        let frame = try timings.measure(.commandRecord) {
            let frame = try renderer.record(list: scene.list, into: commands,
                target: RenderColorTarget(texture: framebuffer?.texture ?? image.texture, loadAction: .clear(SIMD4(0.025, 0.035, 0.06, 1))),
                viewport: NativeUIViewport(pixels: SIMD2(image.width, image.height), logical: scene.size), backdropSource: framebuffer?.texture)
            if let framebuffer {
                try renderer.recordBlit(source: framebuffer.texture, into: commands,
                    target: RenderColorTarget(texture: image.texture, loadAction: .dontCare), size: SIMD2(image.width, image.height))
            }
            return frame
        }
        try timings.measure(.queueSubmit) { try device.submit(commands) }
        frame.didSubmit()
        atlas.markClean()
        try timings.measure(.present) { try device.present(image) }
        scene.didPresent()
        return true
    }

    deinit {
        device.withFrameSession {
            try? device.waitUntilIdle()
            device.destroy(swapchain)
        }
        guava_android_log("CLOSE")
    }
}
