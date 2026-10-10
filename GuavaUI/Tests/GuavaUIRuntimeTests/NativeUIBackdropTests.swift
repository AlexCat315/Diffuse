#if os(macOS)
import Foundation
import NativeRHI
import Testing
@testable import GuavaUIRuntime

/// Frost is a rendering decision, so these tests read pixels: a hard striped
/// background must come out soft inside a frosted panel and stay sharp
/// everywhere else, including when the renderer has nothing to sample.
@Suite("Native frosted backdrops", .serialized)
struct NativeUIBackdropTests {
    private let viewport = NativeUIViewport(pixels: SIMD2(64, 64), logical: SIMD2(64, 64))
    private let panel = UIRect(x: 16, y: 16, width: 32, height: 32)

    /// 8px bars: wide enough that simply reading the frame at a lower
    /// resolution still leaves a ripple, so only a real blur can flatten it.
    private func stripedList(frosted: Bool) -> DrawList {
        let list = DrawList()
        for x in stride(from: 0, to: 64, by: 16) {
            list.addRect(UIRect(x: Float(x), y: 0, width: 8, height: 64),
                         color: Color(r: 1, g: 1, b: 1, a: 1))
        }
        if frosted {
            list.beginBackdrop(UIBackdrop(rect: panel, cornerRadius: 4, blurRadius: 8))
        }
        // Almost no fill: the test measures the backdrop, not the tint.
        list.addRoundedRect(panel, radius: 4, color: Color(r: 1, g: 1, b: 1, a: 0.02))
        return list
    }

    /// Peak-to-peak luma across one scanline: 1.0 for the stripes, near 0 once
    /// they have been blurred into each other.
    private func contrast(_ pixels: Data, row: Int, from: Int, to: Int) throws -> Float {
        var minimum: Float = 1, maximum: Float = 0
        for x in from..<to {
            let offset = (row * 64 + x) * 4
            guard offset + 2 < pixels.count else { continue }
            let luma = Float(pixels[offset]) / 255
            minimum = min(minimum, luma); maximum = max(maximum, luma)
        }
        return maximum - minimum
    }

    @Test("a frosted panel softens what sits behind it")
    func frostedPanelBlursBackdrop() throws {
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: stripedList(frosted: true),
            format: NativeUITestFormat.cases[0], samples: 1, viewport: viewport, backdropSource: true)
        let outside = try contrast(pixels, row: 8, from: 0, to: 64)
        let inside = try contrast(pixels, row: 32, from: 20, to: 44)
        #expect(outside > 0.8)
        #expect(inside < outside * 0.5)
    }

    @Test("the same panel stays sharp when there is nothing to sample")
    func withoutSourceFrameStaysSharp() throws {
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: stripedList(frosted: true),
            format: NativeUITestFormat.cases[0], samples: 1, viewport: viewport, backdropSource: false)
        // No source means no blur: the stripes the panel covers are still the
        // stripes the frame drew, which is why the fill alone must stay legible.
        let inside = try contrast(pixels, row: 32, from: 20, to: 44)
        #expect(inside > 0.8)
    }

    @Test("a panel that never asked for a backdrop is left alone")
    func unfrostedPanelStaysSharp() throws {
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: stripedList(frosted: false),
            format: NativeUITestFormat.cases[0], samples: 1, viewport: viewport, backdropSource: true)
        let inside = try contrast(pixels, row: 32, from: 20, to: 44)
        #expect(inside > 0.8)
    }

    @Test("frost survives MSAA, where the panel samples the resolved frame")
    func frostedPanelBlursUnderMSAA() throws {
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: stripedList(frosted: true),
            format: NativeUITestFormat.cases[0], samples: 4, viewport: viewport, backdropSource: true)
        let outside = try contrast(pixels, row: 8, from: 0, to: 64)
        let inside = try contrast(pixels, row: 32, from: 20, to: 44)
        #expect(outside > 0.8)
        #expect(inside < outside * 0.5)
    }
}
#endif
