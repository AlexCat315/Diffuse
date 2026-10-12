import Foundation
import NativeRHI
import GuavaUICore
import GuavaUIRendering
import CAndroidHost

/// A minimal event-driven Android host for the shared UI renderer. The Java
/// Surface lifecycle owns one session; JNI serializes calls on the UI thread.
final class SurfaceSession {
    let device: Device
    let renderer: NativeDrawListRenderer
    let swapchain: Swapchain
    private var draws = 0

    init(window: UnsafeMutableRawPointer, width: Int, height: Int) throws {
        device = try Device.make(DeviceConfig(enableValidation: false))
        renderer = try NativeDrawListRenderer(device: device)
        try renderer.configure(format: .rgba8Unorm)
        var surface = SurfaceDescriptor(nativeHandle: window, width: width, height: height, colorFormat: .rgba8Unorm)
        surface.kind = .androidWindow
        swapchain = try device.makeSwapchain(surface)
        guava_android_log("OPEN \(device.deviceName) \(width)x\(height)")
    }

    func draw(touch: SIMD2<Float>) throws {
        try device.beginFrame()
        defer { device.endFrame() }
        let image = try device.acquireSwapchainImage(swapchain)
        let size = SIMD2<Float>(640, 640 * Float(image.height) / Float(image.width))
        let list = DrawList()
        list.pixelScale = Float(image.width) / size.x
        let origin = SIMD2<Float>((size.x - 280) / 2, 64)
        list.addRoundedRect(UIRect(x: origin.x, y: origin.y, width: 280, height: 112), radius: 20,
                            color: Color(r: 0.08, g: 0.3, b: 0.6))
        // Render native GuavaUI geometry; each touch changes the accent and
        // moves a marker. No platform canvas participates in these pixels.
        let accent = draws % 2 == 0 ? Color(r: 0.1, g: 0.85, b: 0.6) : Color(r: 1, g: 0.5, b: 0.15)
        list.addRoundedRect(UIRect(x: origin.x + 20, y: origin.y + 28, width: 240, height: 24), radius: 8, color: accent)
        list.addRect(UIRect(x: origin.x + 20, y: origin.y + 72, width: 168, height: 8), color: .white)
        list.pushClip(UIRect(x: origin.x, y: origin.y + 140, width: 280, height: 120))
        for i in 0..<8 {
            list.addRoundedRect(UIRect(x: origin.x + 10 + Float(i % 4) * 68, y: origin.y + 148 + Float(i / 4) * 54,
                width: 56, height: 42), radius: 10, color: accent.multipliedAlpha(0.6))
        }
        list.popClip()
        if touch.x >= 0 {
            let point = touch * size / SIMD2(Float(image.width), Float(image.height))
            list.addRoundedRect(UIRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20), radius: 10, color: .white)
        }
        let commands = CommandBuffer()
        let frame = try renderer.record(list: list, into: commands,
            target: RenderColorTarget(texture: image.texture, loadAction: .clear(SIMD4(0.025, 0.035, 0.06, 1))),
            viewport: NativeUIViewport(pixels: SIMD2(image.width, image.height), logical: size))
        try device.submit(commands)
        frame.didSubmit()
        try device.present(image)
        draws += 1
        guava_android_log("PRESENT \(draws) touch=\(touch)")
    }

    deinit {
        try? device.waitUntilIdle()
        device.destroy(swapchain)
        guava_android_log("CLOSE")
    }
}

@_cdecl("guava_android_open")
func openSurface(_ window: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer? {
    guard let window, width > 0, height > 0 else { return nil }
    do { return Unmanaged.passRetained(try SurfaceSession(window: window, width: Int(width), height: Int(height))).toOpaque() }
    catch { guava_android_log("FAIL open: \(error)"); return nil }
}

@_cdecl("guava_android_draw")
func drawSurface(_ session: UnsafeMutableRawPointer?, _ x: Float, _ y: Float) {
    guard let session else { return }
    do { try Unmanaged<SurfaceSession>.fromOpaque(session).takeUnretainedValue().draw(touch: SIMD2(x, y)) }
    catch { guava_android_log("FAIL draw: \(error)") }
}

@_cdecl("guava_android_close")
func closeSurface(_ session: UnsafeMutableRawPointer?) {
    guard let session else { return }
    Unmanaged<SurfaceSession>.fromOpaque(session).release()
}
