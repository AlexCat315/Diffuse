import GuavaUICore

/// How a `SurfaceShadow` / `SurfaceHighlight` becomes geometry.
///
/// Both node painters share this so the cheap-blur approximation and the rim
/// geometry have exactly one implementation.
extension DrawList {

    /// Paint one shadow layer as a stack of expanded translucent rounded rects.
    ///
    /// The renderer has no blurred primitive, so the gradient is built from
    /// `steps` concentric rects: the outermost is the faint fringe, and each
    /// one on top is smaller and denser, which accumulates into a falloff near
    /// the surface. Cost is bounded (≤ 6 quads per layer).
    public func addShadow(_ layer: SurfaceShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1, steps: Int = 6) {
        guard !layer.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let blur = max(0, layer.blur)
        let radius = max(cornerRadius, 0)
        let count = blur > 0 ? max(1, min(steps, 6)) : 1
        for i in 0..<count {
            let t = Float(i) / Float(max(1, count - 1))
            let inset = -blur * (1 - t)
            // Largest rect is the faint outer edge; smaller rects build density
            // towards the surface, not the other way around.
            let weight = blur > 0 ? (t + 0.15) * (t + 0.15) : 1
            let alpha = layer.color!.a * weight / Float(count)
            let stepColor = Color(r: layer.color!.r, g: layer.color!.g, b: layer.color!.b,
                                  a: min(1, alpha) * opacity)
            let stepRect = UIRect(x: rect.minX + layer.offsetX + inset,
                                  y: rect.minY + layer.offsetY + inset,
                                  width: rect.width - 2 * inset,
                                  height: rect.height - 2 * inset)
            let stepRadius = radius + max(0, -inset)
            if stepRadius > 0 {
                addRoundedRect(stepRect, radius: stepRadius, color: stepColor)
            } else {
                addRect(stepRect, color: stepColor)
            }
        }
    }

    /// Paint a layered shadow: ambient halo first, key shadow over it.
    public func addShadow(_ layers: LayeredShadow, rect: UIRect, cornerRadius: Float,
                          opacity: Float = 1) {
        addShadow(layers.ambient, rect: rect, cornerRadius: cornerRadius, opacity: opacity)
        addShadow(layers.key, rect: rect, cornerRadius: cornerRadius, opacity: opacity)
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
