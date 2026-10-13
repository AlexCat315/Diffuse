#if os(Android)
import Android
#endif
import Foundation
import GuavaUICore

/// How a `SurfaceShadow` / `SurfaceHighlight` becomes geometry.
///
/// Both node painters share this so the cheap-blur approximation and the rim
/// geometry have exactly one implementation.
extension DrawList {

    /// Paint one shadow layer as a stack of expanded translucent rounded rects.
    ///
    /// The renderer has no blurred primitive, so the gradient is built from
    /// concentric rects: the outermost is the faint fringe, and each one on top
    /// is smaller and denser, which accumulates into a falloff near the
    /// surface.
    ///
    /// `frostedRect` is the panel a backdrop blur will sample, when it has one.
    /// The shadow is then clipped to the band outside it: a panel's own shadow
    /// falls on what is *behind* the panel, so letting the frost sample it
    /// greys the panel from the inside — measured at −17% luma on white.
    ///
    /// `occludedRect` is a surface that will be painted opaquely over this node
    /// straight after, so the shadow's interior can never be seen. Skipping it
    /// keeps a `blur: 8` shadow from costing 33 full-surface fills, which
    /// dominated GPU time on card-dense layouts. Corners stay rounded there;
    /// clipping to plain bands would square the card's outline.
    public func addShadow(_ layer: SurfaceShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1, frostedRect: UIRect? = nil,
                          occludedRect: UIRect? = nil) {
        guard !layer.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let frost = frostedRect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        // A frosted panel samples what is behind it, so its shadow has to stay
        // outside even when nothing opaque covers it — that clip wins.
        let occluded = frost == nil ? occludedRect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } : nil
        paintSteps(layer, rect: rect, cornerRadius: cornerRadius, opacity: opacity,
                   count: Self.stepCount(for: layer), frost: frost, occluded: occluded)
    }

    /// Paint a layered shadow: ambient halo first, key shadow over it.
    public func addShadow(_ layers: LayeredShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1, frostedRect: UIRect? = nil,
                          occludedRect: UIRect? = nil) {
        addShadow(layers.ambient, rect: rect, cornerRadius: cornerRadius,
                  opacity: opacity, frostedRect: frostedRect, occludedRect: occludedRect)
        addShadow(layers.key, rect: rect, cornerRadius: cornerRadius,
                  opacity: opacity, frostedRect: frostedRect, occludedRect: occludedRect)
    }
    // MARK: - Cheap blur

    /// Steps spaced evenly in *space*, one every `stepSpacing` points.
    ///
    /// What shows as banding is where consecutive rects land, not how much
    /// alpha a single one adds. Spacing them by equal alpha instead bunches `t`
    /// towards the surface and stretches the faint outer fringe into ridges a
    /// few pixels apart — measurably worse than the even spacing it replaced,
    /// because the gradient's curvature is in space and its steps have to be
    /// too. Space is also what bounds the count: a 24pt halo wants ~96 rects,
    /// a 2pt one wants 8, and neither pays for the other's resolution.
    private static func stepCount(for layer: SurfaceShadow) -> Int {
        let blur = max(0, layer.blur)
        guard (layer.color?.a ?? 0) > 0, blur > 0 else { return 1 }
        return max(2, min(128, Int((blur / Self.stepSpacing).rounded(.up)) + 1))
    }

    /// Distance between neighbouring rects in the stack. A quarter of a point
    /// is half a pixel on a 2x display, so the edges blend into each other
    /// instead of stacking up into ridges.
    private static let stepSpacing: Float = 0.25

    private func paintSteps(_ layer: SurfaceShadow, rect: UIRect, cornerRadius: Float,
                            opacity: Float, count: Int, frost: UIRect?, occluded: UIRect?) {
        let blur = max(0, layer.blur)
        let radius = max(cornerRadius, 0)
        for i in 0..<count {
            let t = Float(i) / Float(max(1, count - 1))
            let inset = -blur * (1 - t)
            // Largest rect is the faint outer edge; smaller rects build density
            // towards the surface, not the other way around.
            let weight = blur > 0 ? (t + 0.15) * (t + 0.15) : 1
            let alpha = layer.color!.a * weight / Float(count)
            let stepColor = Color(r: layer.color!.r, g: layer.color!.g, b: layer.color!.b,
                                  a: min(1, alpha) * opacity)
            // Vertices store 8-bit alpha. Many faint blur steps round to zero;
            // they cannot affect compositing but still cost a full rounded
            // mesh, its upload and validation if recorded.
            guard stepColor.rgba8 >> 24 != 0 else { continue }
            let stepRect = UIRect(x: rect.minX + layer.offsetX + inset,
                                  y: rect.minY + layer.offsetY + inset,
                                  width: rect.width - 2 * inset,
                                  height: rect.height - 2 * inset)
            let stepRadius = radius + max(0, -inset)
            if let frost {
                for band in Self.bands(around: frost, in: stepRect) {
                    addRect(band, color: stepColor)
                }
            } else if let occluded {
                if stepRadius > 0 {
                    // Only the fringe outside the surface can be seen; a `blur: 8`
                    // shadow is 33 nested rects, and repainting the covered
                    // interior each time dominated GPU time on card layouts.
                    for edge in Self.fringeEdges(around: occluded, in: stepRect, radius: stepRadius) {
                        addRect(edge, color: stepColor)
                    }
                    addCornerFringe(step: stepRect, stepRadius: stepRadius, color: stepColor)
                } else {
                    for band in Self.bands(around: occluded, in: stepRect) {
                        addRect(band, color: stepColor)
                    }
                }
            } else if stepRadius > 0 {
                addRoundedRect(stepRect, radius: stepRadius, color: stepColor)
            } else {
                addRect(stepRect, color: stepColor)
            }
        }
    }

    /// Straight parts of `outer` outside `hole`, shortened so the corner arcs —
    /// not these quads — own the corners.
    ///
    /// The corners are shortened by exactly one `radius`, because that is where a
    /// step's corner arc reaches: `outer.minY + radius` is the arc's centre, and
    /// the arc sweeps from there back to the step's edge. Shortening by more
    /// leaves a gap along the straight edges, and by less leaves the band painting
    /// square corners where the arc has already curved in.
    private static func fringeEdges(around hole: UIRect, in outer: UIRect,
                                    radius: Float) -> [UIRect] {
        let reach = radius
        let top = max(outer.minY, hole.minY)
        let bottom = min(outer.maxY, hole.maxY)
        let left = max(outer.minX, hole.minX)
        let right = min(outer.maxX, hole.maxX)
        guard top < bottom || left < right else { return [] }
        let midX0 = min(outer.minX + reach, outer.maxX)
        let midX1 = max(midX0, outer.maxX - reach)
        let midY0 = min(outer.minY + reach, outer.maxY)
        let midY1 = max(midY0, outer.maxY - reach)
        var edges: [UIRect] = []
        if top < bottom {
            edges.append(UIRect(x: midX0, y: outer.minY, width: midX1 - midX0, height: top - outer.minY))
            edges.append(UIRect(x: midX0, y: bottom, width: midX1 - midX0, height: outer.maxY - bottom))
        }
        if left < right {
            edges.append(UIRect(x: outer.minX, y: midY0, width: left - outer.minX, height: midY1 - midY0))
            edges.append(UIRect(x: right, y: midY0, width: outer.maxX - right, height: midY1 - midY0))
        }
        return edges.filter { $0.width > 0 && $0.height > 0 }
    }

    /// The visible part of each corner: the step's own quarter disc.
    ///
    /// The surface is painted opaque over this shadow, so anything drawn inside it
    /// is never seen. That makes the inner bound free — the corner only has to
    /// reach as far as the step's arc, and the part that spills under the surface
    /// costs nothing visually. Fanning from the step's own arc centre therefore
    /// lands the outer edge exactly on the rounded-rect boundary, whatever the
    /// shadow's offset is. An earlier version clipped the disc down to a strip
    /// between two arcs, which had to assume the step's and the surface's arc were
    /// concentric; a shadow offset makes them differ, and the corners came out
    /// wrong.
    private func addCornerFringe(step: UIRect, stepRadius: Float, color: Color) {
        // Corner arc centres, paired with the two bounding edges their arc sweeps
        // between, as unit vectors.
        let corners: [(x: Float, y: Float, quadrant: (Float, Float, Float, Float))] = [
            (step.minX + stepRadius, step.minY + stepRadius, (-1, 0, 0, -1)),
            (step.maxX - stepRadius, step.minY + stepRadius, (0, -1, 1, 0)),
            (step.minX + stepRadius, step.maxY - stepRadius, (-1, 0, 0, 1)),
            (step.maxX - stepRadius, step.maxY - stepRadius, (0, 1, 1, 0))
        ]
        let segments = fanSegments(for: stepRadius)
        for corner in corners {
            let (cx, cy) = (corner.x, corner.y)
            let (ax, ay, bx, by) = corner.quadrant
            var previous = (x: cx + ax * stepRadius, y: cy + ay * stepRadius)
            for index in 1...segments {
                let angle = Float(index) / Float(segments) * (.pi / 2)
                let (sine, cosine) = (sin(angle), cos(angle))
                let point = (x: cx + (ax * cosine + bx * sine) * stepRadius,
                             y: cy + (ay * cosine + by * sine) * stepRadius)
                addTriangle(cx, cy, previous.x, previous.y, point.x, point.y, color: color)
                previous = point
            }
        }
    }

    /// Triangles per corner fan.
    ///
    /// A chord cuts inside the arc by `r * (1 - cos(step / 2))`, which for a small
    /// step is `r * step^2 / 8`. Holding that under `tolerance` bounds the step at
    /// `sqrt(8 * tolerance / r)`, so a quarter arc needs
    /// `(pi / 2) / sqrt(8 * tolerance / r)` segments.
    private func fanSegments(for radius: Float) -> Int {
        guard radius > 0 else { return 1 }
        let tolerance: Float = 0.05 / max(1, pixelScale)
        let count = (.pi / (4 * Float(2).squareRoot())) * (radius / tolerance).squareRoot()
        return max(2, min(32, Int(count.rounded(.up))))
    }

    /// The four bands of `outer` that lie outside `hole`.
    private static func bands(around hole: UIRect, in outer: UIRect) -> [UIRect] {
        let top = max(outer.minY, min(outer.maxY, hole.minY))
        let bottom = max(top, min(outer.maxY, hole.maxY))
        let bands = [
            UIRect(x: outer.minX, y: outer.minY,
                   width: outer.width, height: max(0, top - outer.minY)),
            UIRect(x: outer.minX, y: bottom,
                   width: outer.width, height: max(0, outer.maxY - bottom)),
            UIRect(x: outer.minX, y: top,
                   width: max(0, hole.minX - outer.minX), height: max(0, bottom - top)),
            UIRect(x: hole.maxX, y: top,
                   width: max(0, outer.maxX - hole.maxX), height: max(0, bottom - top))
        ]
        return bands.filter { $0.width > 0 && $0.height > 0 }
    }

    /// Paint the top-edge rim light, inset past the border ring so the two do
    /// not fight over the same pixel row.
    ///
    /// It spans only between the corner arcs — a full-width line would square
    /// off the rounded corners it sits between.
    public func addHighlight(_ highlight: SurfaceHighlight, rect: UIRect, cornerRadius: Float,
                             borderWidth: Float = 0, opacity: Float = 1) {
        guard !highlight.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let inset = max(0, borderWidth) + max(0, cornerRadius)
        let width = rect.width - 2 * inset
        guard width > 0 else { return }
        let color = Color(r: highlight.color!.r, g: highlight.color!.g, b: highlight.color!.b,
                          a: highlight.color!.a * opacity)
        addRect(UIRect(x: rect.minX + inset,
                       y: rect.minY + max(0, borderWidth),
                       width: width,
                       height: min(highlight.width, rect.height)),
                color: color)
    }
}
