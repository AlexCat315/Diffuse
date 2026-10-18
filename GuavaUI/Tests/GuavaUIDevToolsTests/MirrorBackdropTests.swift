#if os(macOS)
import Foundation
import Testing
import NativeRHI
import GuavaUIRuntime
import GuavaUIDevTools

@Suite("Native DevTools mirror pixels", .serialized)
@MainActor
struct MirrorBackdropTests {
    private func stripes(frosted: Bool) -> DrawList {
        let list = DrawList()
        for x in stride(from: 0, to: 64, by: 16) {
            list.addRect(UIRect(x: Float(x), y: 0, width: 8, height: 64), color: .white)
        }
        let panel = UIRect(x: 16, y: 16, width: 32, height: 32)
        if frosted { list.beginBackdrop(UIBackdrop(rect: panel, cornerRadius: 4, blurRadius: 8)) }
        list.addRoundedRect(panel, radius: 4, color: Color(r: 1, g: 1, b: 1, a: 0.02))
        return list
    }

    private func contrast(_ pixels: FrameTap.Pixels, row: Int, columns: Range<Int>) -> Float {
        let values = columns.map { Float(pixels.data[row * pixels.bytesPerRow + $0 * 4]) / 255 }
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    @Test("Mirror capture preserves real backdrop blur, including resized captures")
    func frostedPixels() throws {
        let device = try Device.make(.init(preferredBackends: [.metal], enableValidation: true, framesInFlight: 3))
        let renderer = try NativeDrawListRenderer(device: device)
        try renderer.configure(format: .bgra8Unorm)
        #expect(renderer.supportsBackdrop)
        let capture = try NativeAppFrameCapture(device: device, renderer: renderer)
        defer { capture.reset() }
        let sharp = try capture.capture(list: stripes(frosted: false), size: SIMD2(64, 64), logical: SIMD2(64, 64))
        let frosted = try capture.capture(list: stripes(frosted: true), size: SIMD2(64, 64), logical: SIMD2(64, 64))
        let outside = contrast(frosted, row: 8, columns: 0..<64)
        #expect(outside > 0.8)
        #expect(contrast(sharp, row: 32, columns: 27..<37) > 0.8)
        #expect(contrast(frosted, row: 32, columns: 27..<37) < outside * 0.5)
        let resized = try capture.capture(list: stripes(frosted: true), size: SIMD2(128, 128), logical: SIMD2(64, 64))
        #expect(resized.bytesPerRow == 512 && resized.data.count == 65_536)
        #expect(contrast(resized, row: 16, columns: 0..<128) > 0.8)
        #expect(contrast(resized, row: 64, columns: 54..<74) < 0.4)
    }
}
#endif
