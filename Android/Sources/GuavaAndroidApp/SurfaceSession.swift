import Foundation
import NativeRHI
import GuavaUICore
import GuavaUIRendering
import CAndroidHost

/// JNI serializes this surface's GPU and scene operations on the UI thread.
final class SurfaceSession {
    let device: Device
    let renderer: NativeDrawListRenderer
    let swapchain: Swapchain
    let scene: DemoScene
    let scale: Float

    init(window: UnsafeMutableRawPointer, width: Int, height: Int, scale: Float, checkpoint: String) throws {
        self.scale = scale.isFinite ? min(4, max(1, scale)) : 1
        scene = try DemoScene(checkpoint: checkpoint)
        device = try Device.make(DeviceConfig(enableValidation: false))
        renderer = try NativeDrawListRenderer(device: device)
        try renderer.configure(format: .rgba8Unorm)
        swapchain = try device.makeSwapchain(SurfaceDescriptor(nativeHandle: window, width: width, height: height))
        guava_android_log("OPEN \(device.deviceName) \(width)x\(height)")
    }

    func frame() throws -> Bool {
        guard scene.needsFrame else { return false }
        try device.beginFrame()
        defer { device.endFrame() }
        let image = try device.acquireSwapchainImage(swapchain)
        scene.prepare(pixels: SIMD2(image.width, image.height), scale: scale)
        let atlas = scene.typography.fonts.atlas
        if let payload = atlas.dirtyUploadPayload() {
            var region = TextureUploadRegion(width: payload.region.width, height: payload.region.height)
            region.origin = SIMD2(payload.region.x, payload.region.y)
            try renderer.registerTexture(id: 1, pixels: Data(payload.pixels),
                size: SIMD2(atlas.atlasWidth, atlas.atlasHeight), region: region, format: .r8Unorm)
        }
        let commands = CommandBuffer()
        let frame = try renderer.record(list: scene.list, into: commands,
            target: RenderColorTarget(texture: image.texture, loadAction: .clear(SIMD4(0.025, 0.035, 0.06, 1))),
            viewport: NativeUIViewport(pixels: SIMD2(image.width, image.height), logical: scene.size))
        try device.submit(commands)
        frame.didSubmit()
        atlas.markClean()
        try device.present(image)
        scene.didPresent()
        guava_android_log("PRESENT \(scene.snapshot())")
        return true
    }

    deinit {
        try? device.waitUntilIdle()
        device.destroy(swapchain)
        guava_android_log("CLOSE")
    }
}
