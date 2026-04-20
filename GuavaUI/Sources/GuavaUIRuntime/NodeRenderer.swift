import CoreGraphics

/// Walks a `Node` tree post-layout and emits draw commands into a `DrawList`.
///
/// Convention: `Node.frame` is interpreted as parent-local; the renderer
/// accumulates an absolute origin while descending. Background fills and the
/// `Node.draw` hook (used by Text/Image) are emitted in that order so custom
/// content paints over its own background. `clipsToBounds` pushes a scissor
/// for the duration of the subtree.
public struct NodeRenderer {

    public init() {}

    /// Render `root` into `list`. Coordinates are produced in viewport pixels.
    public func render(root: Node, into list: DrawList) {
        renderNode(root, list: list, originX: 0, originY: 0)
    }

    private func renderNode(_ node: Node, list: DrawList,
                            originX: Float, originY: Float) {
        let f = node.frame
        let absX = originX + Float(f.origin.x)
        let absY = originY + Float(f.origin.y)
        let width  = Float(f.size.width)
        let height = Float(f.size.height)

        // 1. Clip stack push (covers background, content, and children).
        let clipped = node.clipsToBounds && width > 0 && height > 0
        if clipped {
            list.pushClip(UIRect(x: absX, y: absY, width: width, height: height))
        }

        // 2. Background fill.
        if let bg = node.backgroundColor, width > 0, height > 0 {
            list.addRect(
                UIRect(x: absX, y: absY, width: width, height: height),
                color: applyOpacity(bg, node.opacity)
            )
        }

        // 3. Custom content (Text/Image/etc).
        if let draw = node.draw {
            draw(list, CGPoint(x: Double(absX), y: Double(absY)))
        }

        // 4. Children.
        for child in node.children {
            renderNode(child, list: list, originX: absX, originY: absY)
        }

        // 5. Pop clip.
        if clipped {
            list.popClip()
        }
    }

    private func applyOpacity(_ color: Color, _ opacity: Float) -> Color {
        guard opacity < 1 else { return color }
        return Color(r: color.r, g: color.g, b: color.b, a: color.a * opacity)
    }
}
