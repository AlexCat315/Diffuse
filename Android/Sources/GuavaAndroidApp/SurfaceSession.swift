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
    var scene: DemoScene { application.scene }
    var scale: Float { application.scale }
    let pixels: SIMD2<Int>
    private var previousTime: UInt64 = 0
    private var framebuffer: TextureResource?

    init(application: AndroidApplication, window: UnsafeMutableRawPointer, width: Int, height: Int) throws {
        self.application = application
        pixels = SIMD2(width, height)
        swapchain = try application.device.withFrameSession {
            try application.device.makeSwapchain(SurfaceDescriptor(nativeHandle: window, width: width, height: height))
        }
        scene.invalidate()
        guava_android_log("OPEN \(device.deviceName) \(width)x\(height)")
    }

    func frame() throws -> Bool {
        guard scene.needsFrame else { return false }
        let time = DispatchTime.now().uptimeNanoseconds
        let dt = previousTime == 0 ? 1.0 / 60 : min(0.1, Double(time - previousTime) / 1_000_000_000)
        previousTime = time
        scene.prepare(pixels: pixels, scale: scale, deltaTime: dt)
        return try device.withFrameSession { try presentFrame() }
    }

    private func presentFrame() throws -> Bool {
        try device.beginFrame()
        defer { device.endFrame() }
        let image = try device.acquireSwapchainImage(swapchain)
        if let resource = scene.game?.surface.image?.resource { try renderer.registerExternalColorTexture(id: 2, resource: resource) }
        let atlas = scene.launch.mode == .counter ? scene.typography.fonts.atlas : scene.environment.text!.atlas
        try renderer.uploadFontAtlas(atlas, textureID: 1)
        if renderer.supportsBackdrop && framebuffer == nil {
            framebuffer = try TextureResource(device: device, descriptor: TextureDescriptor(width: image.width,
                height: image.height, format: .rgba8Unorm, usage: [.colorTarget, .sampled], label: "android-ui-framebuffer"))
        }
        let commands = CommandBuffer()
        let frame = try renderer.record(list: scene.list, into: commands,
            target: RenderColorTarget(texture: framebuffer?.texture ?? image.texture, loadAction: .clear(SIMD4(0.025, 0.035, 0.06, 1))),
            viewport: NativeUIViewport(pixels: SIMD2(image.width, image.height), logical: scene.size), backdropSource: framebuffer?.texture)
        if let framebuffer {
            try renderer.recordBlit(source: framebuffer.texture, into: commands,
                target: RenderColorTarget(texture: image.texture, loadAction: .dontCare), size: SIMD2(image.width, image.height))
        }
        try device.submit(commands)
        frame.didSubmit()
        atlas.markClean()
        try device.present(image)
        scene.didPresent()
        if scene.game == nil { guava_android_log("PRESENT \(scene.launch.mode.rawValue)") }
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
