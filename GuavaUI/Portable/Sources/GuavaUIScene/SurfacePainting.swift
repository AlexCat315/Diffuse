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
    public func addShadow(_ layer: SurfaceShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1, frostedRect: UIRect? = nil) {
        guard !layer.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let hole = frostedRect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        paintSteps(layer, rect: rect, cornerRadius: cornerRadius,
                   opacity: opacity, count: Self.stepCount(for: layer), hole: hole)
    }

    /// Paint a layered shadow: ambient halo first, key shadow over it.
    public func addShadow(_ layers: LayeredShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1, frostedRect: UIRect? = nil) {
        addShadow(layers.ambient, rect: rect, cornerRadius: cornerRadius,
                  opacity: opacity, frostedRect: frostedRect)
        addShadow(layers.key, rect: rect, cornerRadius: cornerRadius,
                  opacity: opacity, frostedRect: frostedRect)
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
                            opacity: Float, count: Int, hole: UIRect?) {
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
            if let hole {
                // Rect bands, not rounded ones: the hole is the panel the frost
                // samples, and four quads per step cost less than clipping a
                // rounded rect into four pieces.
                for band in Self.bands(around: hole, in: stepRect) {
                    addRect(band, color: stepColor)
                }
            } else {
                let stepRadius = radius + max(0, -inset)
                if stepRadius > 0 {
                    addRoundedRect(stepRect, radius: stepRadius, color: stepColor)
                } else {
                    addRect(stepRect, color: stepColor)
                }
            }
        }
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
