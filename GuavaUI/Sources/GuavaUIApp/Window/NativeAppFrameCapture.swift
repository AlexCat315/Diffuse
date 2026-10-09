import Foundation
import GuavaUIRuntime
import GuavaUIDevTools
import NativeRHI

/// DevTools capture uses the same owned bindings as window presentation and
/// performs its synchronous readback after the window's frame has ended.
@MainActor
final class NativeAppFrameCapture {
    private let device: Device
    private let source: NativeDrawListRenderer
    private let renderer: NativeDrawListRenderer
    private var target: TextureResource?

    init(device: Device, renderer: NativeDrawListRenderer) throws {
        self.device = device; source = renderer
        self.renderer = try device.withFrameSession { try renderer.makeSibling(format: .bgra8Unorm) }
    }

    func reset() { device.withFrameSession { target = nil } }

    func capture(list: DrawList, size: SIMD2<Int>, logical: SIMD2<Float>) throws -> FrameTap.Pixels {
        try device.withFrameSession {
            guard size.x > 0 && size.y > 0 && size.x <= 1_920 && size.y <= 1_080 else {
                throw RHIError.invalidArgument("mirror capture extent exceeds 1920x1080")
            }
            if target?.descriptor.width != size.x || target?.descriptor.height != size.y {
                target = try TextureResource(device: device, descriptor: TextureDescriptor(width: size.x,
                    height: size.y, format: .bgra8Unorm, usage: [.colorTarget, .transferSource]))
            }
            guard let target else { throw RHIError.outOfMemory }
            try renderer.synchronizeTextures(from: source)
            try device.beginFrame()
            do {
                defer { device.endFrame() }
                let commands = CommandBuffer()
                let frame = try renderer.record(list: list, into: commands,
                    target: RenderColorTarget(texture: target.texture, loadAction: .clear(SIMD4(0, 0, 0, 1))),
                    viewport: NativeUIViewport(pixels: size, logical: logical))
                try device.submit(commands)
                frame.didSubmit()
            }
            try device.waitUntilIdle()
            let stride = size.x * 4
            var pixels = Data(count: stride * size.y)
            try pixels.withUnsafeMutableBytes {
                try device.readTextureData(target.texture, width: size.x, height: size.y, bytesPerRow: stride, into: $0)
            }
            return FrameTap.Pixels(data: pixels, bytesPerRow: stride)
        }
    }
}
