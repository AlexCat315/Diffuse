#if os(macOS)
import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Shadow alpha quantization", .serialized)
struct ShadowQuantizationTests {
    private let rect = UIRect(x: 16, y: 16, width: 96, height: 64)
    private let color = Color(red: 42, green: 20, blue: 11, alpha: 20)

    @Test("Positive shadow alpha that packs to zero emits no geometry")
    func transparentStepsAreOmitted() {
        for opacity: Float in [0, 0.001, 1] {
            let list = DrawList()
            list.pixelScale = 2
            list.addShadow(SurfaceShadow(color: Color(r: 0.2, g: 0.1, b: 0.05, a: 0.001),
                                         offsetY: 2, blur: 8),
                           rect: rect, cornerRadius: 16, opacity: opacity)
            #expect(list.vertices.isEmpty && list.indices.isEmpty && list.batches.isEmpty)
        }
    }

    @Test("Visible shadow steps retain compositing when zero-alpha meshes are removed")
    func compositingIsPreserved() throws {
        let context = try NativeUIDrawTestContext()
        let viewport = NativeUIViewport(pixels: SIMD2(256, 192), logical: SIMD2(128, 96))
        for frosted in [false, true] {
            for backgroundAlpha: Float in [1, 0.6] {
                let original = scene(optimized: false, frosted: frosted, backgroundAlpha: backgroundAlpha)
                let optimized = scene(optimized: true, frosted: frosted, backgroundAlpha: backgroundAlpha)
                // The dashboard's faint 8pt shadow previously spent most of its
                // geometry on invisible steps, despite their positive Float alpha.
                #expect(optimized.vertices < original.vertices / 3)
                #expect(optimized.indices < original.indices / 3)
                #expect(transparentTriangleCount(original.list) > 0)
                #expect(transparentTriangleCount(optimized.list) == 0)
                for samples in [1, 4] {
                    let format = NativeUITestFormat.cases[3]
                    let expected = try context.nativeImage(list: original.list, format: format, samples: samples, viewport: viewport).0
                    let actual = try context.nativeImage(list: optimized.list, format: format, samples: samples, viewport: viewport).0
                    #expect(actual == expected)
                }
            }
        }
    }

    private func scene(optimized: Bool, frosted: Bool, backgroundAlpha: Float) -> (list: DrawList, vertices: Int, indices: Int) {
        let list = DrawList()
        list.pixelScale = 2
        list.addRect(UIRect(x: 0, y: 0, width: 128, height: 96), color: Color(r: 0.7, g: 0.9, b: 0.8, a: backgroundAlpha))
        list.addRect(UIRect(x: 0, y: 32, width: 128, height: 32), color: Color(r: 0.9, g: 0.4, b: 0.2, a: 0.5))
        let firstVertex = list.vertices.count, firstIndex = list.indices.count
        if optimized {
            list.addShadow(SurfaceShadow(color: color, offsetY: 2, blur: 8),
                           rect: rect, cornerRadius: 16, frostedRect: frosted ? rect : nil)
        } else {
            // Preserve the original 33-step blur algorithm as an independent
            // image reference, including every step that packs to alpha zero.
            for step in 0..<33 {
                let t = Float(step) / 32
                let expansion = 8 * (1 - t)
                let weight = (t + 0.15) * (t + 0.15)
                let stepColor = Color(r: color.r, g: color.g, b: color.b, a: color.a * weight / 33)
                let stepRect = UIRect(x: rect.x - expansion, y: rect.y + 2 - expansion,
                                      width: rect.width + 2 * expansion, height: rect.height + 2 * expansion)
                if frosted {
                    // Independently clip full original quads to the four
                    // nonoverlapping regions outside the panel's hole.
                    for clip in [UIRect(x: 0, y: 0, width: 128, height: 16),
                                 UIRect(x: 0, y: 80, width: 128, height: 16),
                                 UIRect(x: 0, y: 16, width: 16, height: 64),
                                 UIRect(x: 112, y: 16, width: 16, height: 64)] {
                        list.pushClip(clip); list.addRect(stepRect, color: stepColor); list.popClip()
                    }
                } else {
                    list.addRoundedRect(stepRect, radius: 16 + expansion, color: stepColor)
                }
            }
        }
        let shadowVertices = list.vertices.count - firstVertex, shadowIndices = list.indices.count - firstIndex
        // A translucent surface leaves both the exterior and interior shadow
        // visible, exercising RGB and alpha compositing over the background.
        list.addRoundedRect(rect, radius: 16, color: Color(r: 0.9, g: 0.8, b: 0.65, a: 0.65))
        return (list, shadowVertices, shadowIndices)
    }

    @Test("A shadow hidden under an opaque surface keeps its rounded corners")
    func occludedShadowKeepsRoundedCorners() throws {
        let context = try NativeUIDrawTestContext()
        let viewport = NativeUIViewport(pixels: SIMD2(256, 192), logical: SIMD2(128, 96))
        let whole = DrawList()
        whole.pixelScale = 2
        whole.addShadow(SurfaceShadow(color: color, offsetY: 2, blur: 8),
                        rect: rect, cornerRadius: 16)
        // Same shadow, but the surface that is painted over it is declared, so
        // the covered interior is skipped instead of drawn and hidden.
        let clipped = DrawList()
        clipped.pixelScale = 2
        clipped.addShadow(SurfaceShadow(color: color, offsetY: 2, blur: 8),
                          rect: rect, cornerRadius: 16, occludedRect: rect)
        // The guarantee is the fringe: everything the surface does not later cover
        // has to render identically, corners included.
        let format = NativeUITestFormat.cases[3]
        let expected = try context.nativeImage(list: whole, format: format, samples: 4,
                                               viewport: viewport, backdropSource: false).0
        let actual = try context.nativeImage(list: clipped, format: format, samples: 4,
                                              viewport: viewport, backdropSource: false).0
        #expect(Self.matchesOutside(rect, expected: expected, actual: actual,
                                    viewport: viewport))
    }

    /// Clipping the shadow must not change what the viewer sees.
    ///
    /// Both scenes paint the same opaque surface *after* the shadow, which is what
    /// production does, and the two renders are compared over the whole frame.
    /// Skipping the covered interior is an optimisation, so any visible difference
    /// — a squared corner, a missing arc, a fringe in the wrong place — shows up
    /// here. Comparing with the surface omitted cannot work: the only difference
    /// would then be underneath it, which is exactly the part nobody sees.
    @Test("A shadow under an opaque surface renders the same as an unclipped one")
    func occludedShadowRendersIdentically() throws {
        let context = try NativeUIDrawTestContext()
        let viewport = NativeUIViewport(pixels: SIMD2(256, 192), logical: SIMD2(128, 96))
        let format = NativeUITestFormat.cases[3]
        let whole = try context.nativeImage(list: Self.cardScene(clip: false), format: format,
                                            samples: 4, viewport: viewport, backdropSource: false).0
        let clipped = try context.nativeImage(list: Self.cardScene(clip: true), format: format,
                                              samples: 4, viewport: viewport, backdropSource: false).0
        var worst = 0
        var worstAt = (x: 0, y: 0)
        var beyondEdge = 0
        for y in 0..<viewport.pixels.y {
            for x in 0..<viewport.pixels.x {
                let offset = (y * viewport.pixels.x + x) * 4
                var shift = 0
                for channel in 0..<3 {
                    shift = max(shift, abs(Int(whole[offset + channel]) - Int(clipped[offset + channel])))
                }
                if shift > worst { worst = shift; worstAt = (x, y) }
                if shift > Self.edgeTolerance { beyondEdge += 1 }
            }
        }
        #expect(beyondEdge == 0,
                """
                \(beyondEdge) pixels shifted by more than \(Self.edgeTolerance) \
                (worst \(worst) at \(worstAt.x),\(worstAt.y)); the clip changed the shape, \
                not just edge coverage
                """)
    }

    /// How far a pixel may move before it counts as a shape change.
    ///
    /// Clipping the shadow is not bit-exact and cannot be: along the fringe the
    /// unclipped draw overlaps several faint steps on one partially covered pixel,
    /// and the clipped draw sums a different subset of them there. The same applies
    /// to the surface's own antialiased edge, where the shadow behind it legitimately
    /// shows through. Both land within a couple of 8-bit steps.
    ///
    /// A squared corner is a different kind of error — it moves a whole region, not
    /// a boundary — so the count above is what actually catches one, while this
    /// bound keeps the edge noise from masking it.
    private static let edgeTolerance = 4

    /// Shadow plus the opaque surface that covers it, as the painters emit them.
    private static func cardScene(clip: Bool) -> DrawList {
        let list = DrawList()
        list.pixelScale = 2
        let card = UIRect(x: 16, y: 16, width: 96, height: 64)
        list.addShadow(SurfaceShadow(color: Color(r: 0, g: 0, b: 0, a: 0.5), offsetY: 2, blur: 8),
                       rect: card, cornerRadius: 16, occludedRect: clip ? card : nil)
        list.addRoundedRect(card, radius: 16, color: Color(r: 0.9, g: 0.8, b: 0.65, a: 1))
        return list
    }

    /// Compares two renders only where `keep` is empty, so a region that a later
    /// opaque surface covers is allowed to differ.
    private static func matchesOutside(_ keep: UIRect, expected: Data, actual: Data,
                                       viewport: NativeUIViewport) -> Bool {
        let scaleX = Float(viewport.pixels.x) / max(viewport.logical.x, 0.0001)
        let scaleY = Float(viewport.pixels.y) / max(viewport.logical.y, 0.0001)
        let x0 = max(0, Int(keep.minX * scaleX)), x1 = min(viewport.pixels.x, Int(keep.maxX * scaleX))
        let y0 = max(0, Int(keep.minY * scaleY)), y1 = min(viewport.pixels.y, Int(keep.maxY * scaleY))
        let bytesPerPixel = 4
        let stride = viewport.pixels.x * bytesPerPixel
        for y in 0..<viewport.pixels.y {
            for x in 0..<viewport.pixels.x where x < x0 || x >= x1 || y < y0 || y >= y1 {
                let offset = y * stride + x * bytesPerPixel
                if expected[offset] != actual[offset]
                    || expected[offset + 1] != actual[offset + 1]
                    || expected[offset + 2] != actual[offset + 2] {
                    return false
                }
            }
        }
        return true
    }

    private func transparentTriangleCount(_ list: DrawList) -> Int {
        var count = 0
        var index = 0
        while index < list.indices.count {
            let a = list.vertices[Int(list.indices[index])].color >> 24
            let b = list.vertices[Int(list.indices[index + 1])].color >> 24
            let c = list.vertices[Int(list.indices[index + 2])].color >> 24
            if a == 0 && b == 0 && c == 0 { count += 1 }
            index += 3
        }
        return count
    }
}
#endif
