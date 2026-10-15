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
    private func stripedList(frosted: Bool,
                             fill: Color = Color(r: 1, g: 1, b: 1, a: 0.02)) -> DrawList {
        let list = DrawList()
        for x in stride(from: 0, to: 64, by: 16) {
            list.addRect(UIRect(x: Float(x), y: 0, width: 8, height: 64),
                         color: Color(r: 1, g: 1, b: 1, a: 1))
        }
        if frosted {
            list.beginBackdrop(UIBackdrop(rect: panel, cornerRadius: 4, blurRadius: 8))
        }
        // Almost no fill by default: those tests measure the backdrop, not the
        // tint. A real panel passes its own material instead.
        list.addRoundedRect(panel, radius: 4, color: fill)
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
        // Measured in the middle of the panel, clear of the rounded corners.
        let inside = try contrast(pixels, row: 32, from: 27, to: 37)
        #expect(outside > 0.8)
        #expect(inside < outside * 0.5)
    }

    @Test("a material panel over content still shows it, softened")
    func materialPanelTransmitsBlurredBackdrop() throws {
        let context = try NativeUIDrawTestContext()
        // The material's own colour, so the stripes behind it are not lifted by
        // a white tint on the way through.
        let material = Color(r: 0x2B / 255, g: 0x2D / 255, b: 0x33 / 255, a: 0.5)
        func measure(frosted: Bool, fill: Color) throws -> Float {
            let (pixels, _) = try context.nativeImage(list: stripedList(frosted: frosted, fill: fill),
                format: NativeUITestFormat.cases[0], samples: 1, viewport: viewport, backdropSource: true)
            // The panel's middle, same as the plain-frost test.
            return try contrast(pixels, row: 32, from: 27, to: 37)
        }
        let frosted = try measure(frosted: true, fill: material)
        let plain = try measure(frosted: false, fill: material)
        let clear = try measure(frosted: true, fill: Color(r: 1, g: 1, b: 1, a: 0.02))
        print("frost-transmit frosted=\(frosted) plain=\(plain) clear=\(clear)")
        #expect(frosted < plain * 0.5)
    }

    /// A flat backdrop is the case that exposed the frost as missing: a blurred
    /// plain window is *identical* to a solid fill, so a menu over one reads as
    /// paint rather than glass. Frost has to change what the panel looks like
    /// even when there is no structure behind it to blur away.
    @Test("frost is visible over a flat backdrop too")
    func frostShowsOverAFlatBackdrop() throws {
        let context = try NativeUIDrawTestContext()
        let material = Color(r: 0x2B / 255, g: 0x2D / 255, b: 0x33 / 255, a: 0.5)
        /// A plain window at `level`: nothing to blur into anything else.
        func delta(over level: Float) throws -> Float {
            func centre(frosted: Bool) throws -> (Float, Float, Float) {
                let list = DrawList()
                list.addRect(UIRect(x: 0, y: 0, width: 64, height: 64),
                             color: Color(r: level, g: level, b: level, a: 1))
                if frosted { list.beginBackdrop(UIBackdrop(rect: panel, cornerRadius: 4, blurRadius: 8)) }
                list.addRoundedRect(panel, radius: 4, color: material)
                let (pixels, _) = try context.nativeImage(list: list, format: NativeUITestFormat.cases[0],
                                                          samples: 1, viewport: viewport, backdropSource: true)
                let offset = (32 * 64 + 32) * 4
                return (Float(pixels[offset]) / 255, Float(pixels[offset + 1]) / 255,
                        Float(pixels[offset + 2]) / 255)
            }
            let frosted = try centre(frosted: true)
            let plain = try centre(frosted: false)
            return abs(frosted.0 - plain.0) + abs(frosted.1 - plain.1) + abs(frosted.2 - plain.2)
        }
        // Light and dark are the two a demo actually shows, and they are the
        // two a one-way lift can only ever get right on one of. Mid-grey is
        // where a directional push is weakest, so it is not the bar here.
        let onLight = try delta(over: 0.94)
        let onDark = try delta(over: 0.12)
        print("frost-flat onLight=\(onLight) onDark=\(onDark)")
        #expect(onLight > 0.02)
        #expect(onDark > 0.02)
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
        let inside = try contrast(pixels, row: 32, from: 27, to: 37)
        #expect(outside > 0.8)
        #expect(inside < outside * 0.5)
    }

    // MARK: - A floating panel: shadow and frost together

    private let panelViewport = NativeUIViewport(pixels: SIMD2(128, 128), logical: SIMD2(128, 128))

    /// The panel every measurement below shares: frosted, and carrying the
    /// layered shadow a floating surface gets.
    private func floatingPanel(shadow: Bool, backdrop: Color) throws -> Data {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 128, height: 128)
        root.backgroundColor = backdrop
        let panel = Node()
        panel.frame = CGRect(x: 48, y: 40, width: 32, height: 32)
        panel.cornerRadius = 6
        panel.backdropBlur = 8
        panel.backgroundColor = Color(r: 0x2B / 255, g: 0x2D / 255, b: 0x33 / 255, a: 0.5)
        if shadow {
            panel.ambientShadow = SurfaceShadow(color: Color(r: 0, g: 0, b: 0, a: 0.3), offsetY: 3, blur: 16)
            panel.shadow = SurfaceShadow(color: Color(r: 0, g: 0, b: 0, a: 0.6), offsetY: 6, blur: 6)
        }
        root.addChild(panel)
        let list = DrawList()
        NodeRenderer().render(root: root, into: list)
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: list, format: NativeUITestFormat.cases[0],
                                                 samples: 1, viewport: panelViewport, backdropSource: true)
        return pixels
    }

    private func luma(_ pixels: Data, x: Int, y: Int, width: Int = 128) -> Float {
        let offset = (y * width + x) * 4
        guard offset + 2 < pixels.count else { return 0 }
        return Float(pixels[offset]) / 255
    }

    private func panelLuma(_ pixels: Data) -> Float {
        var total: Float = 0, count = 0
        for y in 44..<68 { for x in 52..<76 { total += luma(pixels, x: x, y: y); count += 1 } }
        return total / Float(count)
    }

    @Test("a panel's own shadow stays out of the frost it samples")
    func shadowDoesNotGreyTheFrost() throws {
        let clean = try panelLuma(floatingPanel(shadow: false, backdrop: Color(r: 1, g: 1, b: 1, a: 1)))
        let shadowed = try panelLuma(floatingPanel(shadow: true, backdrop: Color(r: 1, g: 1, b: 1, a: 1)))
        // The shadow falls behind the panel, so the frost must not eat it:
        // sampling it greys the panel by 17%, which reads as dirt.
        //
        // What is measured is not the leak itself but the leak scaled by how
        // much of the frost the fill lets through, so the bound moves with the
        // fill's alpha. Clipping keeps the shadow off the panel rect, but the
        // capture reaches a margin beyond it and the blur pulls the clipped
        // ring back inward — inherent, and a few percent of luma. 0.04 at
        // alpha 0.5 is 0.013 at the old 0.76; the 17% this test was written
        // against would read 0.085.
        #expect(clean - shadowed < 0.04)
    }

    @Test("the shadow falloff has no ridges")
    func shadowFalloffIsSmooth() throws {
        let pixels = try floatingPanel(shadow: true, backdrop: Color(r: 1, g: 1, b: 1, a: 1))
        // Down the middle, just under the panel's bottom edge: every rect in
        // the cheap-blur stack ends somewhere along here, and a stack that is
        // too coarse leaves a step at each one.
        var deltas: [Float] = []
        for y in 75..<92 {
            deltas.append(luma(pixels, x: 64, y: y) - luma(pixels, x: 64, y: y - 1))
        }
        // A coarse stack puts a hard edge every few pixels and the falloff
        // stutters: its second difference peaks at 0.11 with six steps, against
        // 0.055 now. The rest is the falloff's own curvature, which is the
        // shape of the shadow and not a defect.
        var ridge: Float = 0
        for i in 1..<deltas.count { ridge = max(ridge, abs(deltas[i] - deltas[i - 1])) }
        #expect(ridge < 0.07)
    }

    @Test("frost answers to what is behind it")
    func frostFollowsTheBackdrop() throws {
        let onWhite = try panelLuma(floatingPanel(shadow: false, backdrop: Color(r: 1, g: 1, b: 1, a: 1)))
        let onBlack = try panelLuma(floatingPanel(shadow: false, backdrop: Color(r: 0, g: 0, b: 0, a: 1)))
        // What makes a panel read as glass rather than paint is this swing.
        // An 0.84 fill leaves only 0.12 of it, which looked like a solid that
        // happened to be translucent.
        #expect(onWhite - onBlack > 0.15)
    }

    /// A dark field with one bright bar ending right at the panel's left edge.
    /// How far that bar reaches into the panel is the capture margin's doing:
    /// the blur has to carry it across the boundary, and stop carrying it
    /// before it crosses the whole panel.
    private func edgeContentList(blurRadius: Float = 4) -> DrawList {
        let list = DrawList()
        list.addRect(UIRect(x: 0, y: 0, width: 64, height: 64),
                     color: Color(r: 0.1, g: 0.1, b: 0.1, a: 1))
        list.addRect(UIRect(x: 10, y: 0, width: 6, height: 64),
                     color: Color(r: 1, g: 1, b: 1, a: 1))
        list.beginBackdrop(UIBackdrop(rect: panel, cornerRadius: 4, blurRadius: blurRadius))
        list.addRoundedRect(panel, radius: 4, color: Color(r: 1, g: 1, b: 1, a: 0.02))
        return list
    }

    private func bandLuma(_ pixels: Data, from: Int, to: Int) throws -> Float {
        var total: Float = 0, count = 0
        for x in from..<to {
            total += luma(pixels, x: x, y: 32, width: 64); count += 1
        }
        return total / Float(count)
    }

    /// The capture has to reach past the panel on every axis by the blur's own
    /// two-sigma spread, or the taps clamp on the panel's own edge pixels and
    /// drag them inward — a bright halo along the rim.
    @Test("the capture margin is the blur's own reach, scaled per axis")
    func captureMarginCoversTheBlur() {
        #expect(NativeUIBackdropPass.captureMargin(blurRadius: 14, scale: 1) == 28)
        #expect(NativeUIBackdropPass.captureMargin(blurRadius: 14, scale: 2) == 56)
        // Physical pixels per logical point, so a radius in points scales the
        // margin the same way it scales the sigma.
        #expect(NativeUIBackdropPass.captureMargin(blurRadius: 4, scale: 1.5) == 12)
        // Nothing to reach for, and still never negative — a negative radius
        // would march the capture inwards over the panel itself.
        #expect(NativeUIBackdropPass.captureMargin(blurRadius: 0, scale: 2) == 0)
        #expect(NativeUIBackdropPass.captureMargin(blurRadius: -3, scale: 2) == 0)
    }

    /// The capture margin's whole job: content sitting just *outside* the panel
    /// has to reach into it. Without the margin the taps clamp on the panel's
    /// own edge pixels and drag them inward instead, which reads as a halo
    /// hugging the rim rather than the backdrop diffusing through it.
    @Test("content just outside the panel still diffuses into it")
    func marginLetsTheBackdropReachIn() throws {
        let context = try NativeUIDrawTestContext()
        let (pixels, _) = try context.nativeImage(list: edgeContentList(blurRadius: 12),
            format: NativeUITestFormat.cases[0], samples: 1, viewport: viewport, backdropSource: true)
        let near = try bandLuma(pixels, from: 18, to: 24)
        let body = try bandLuma(pixels, from: 27, to: 37)
        let far = try bandLuma(pixels, from: 40, to: 46)
        print("frost-reach near=\(near) body=\(body) far=\(far)")
        // The bright bar ends at the panel's left edge, so the near band can
        // only be brighter if the capture carried it across the boundary.
        #expect(near > body + 0.02)
        // And it stays a diffusion: the bar must fade out well before the far
        // side, or the capture reached further than a gaussian of this radius
        // can carry and something is sampling the sharp frame.
        #expect(body > far + 0.02)
    }
}
#endif
