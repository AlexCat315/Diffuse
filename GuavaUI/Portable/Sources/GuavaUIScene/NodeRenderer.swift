import GuavaUICore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

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
        list.setViewportBounds(UIRect(x: Float(root.frame.origin.x),
                                      y: Float(root.frame.origin.y),
                                      width: Float(root.frame.width),
                                      height: Float(root.frame.height)))
        renderNode(root, list: list, originX: 0, originY: 0)
    }

    private func renderNode(_ node: Node, list: DrawList,
                            originX: Float, originY: Float) {
        let firstVertex = list.vertices.count
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

        // 2. Drop shadow (painted before background so it sits behind). The
        //    ambient halo goes down first; the tighter key shadow lands on it.
        let rect = UIRect(x: absX, y: absY, width: width, height: height)
        // A frosted panel samples the frame behind it, so keep its own shadow
        // out of the band it samples — otherwise the frost eats the shadow.
        let frosted: UIRect? = node.backdropBlur > 0 ? rect : nil
        list.addShadow(LayeredShadow(ambient: node.ambientShadow, key: node.shadow),
                       rect: rect, cornerRadius: node.cornerRadius, opacity: node.opacity,
                       frostedRect: frosted)

        // 3. Border ring, including when the background is transparent.
        if let bc = node.borderColor, node.borderWidth > 0,
           width > 0, height > 0 {
            let color = applyOpacity(bc, node.opacity)
            list.addRoundedRectStroke(rect, radius: node.cornerRadius,
                                      width: node.borderWidth, color: color)
        }

        // 4. Background fill (inset by border width so it does not overdraw
        //    the border ring).
        if let bg = node.backgroundColor, width > 0, height > 0 {
            let inset = (node.borderColor != nil && node.borderWidth > 0) ? node.borderWidth : 0
            let bgWidth  = max(0, width  - 2 * inset)
            let bgHeight = max(0, height - 2 * inset)
            if bgWidth > 0 && bgHeight > 0 {
                let rect = UIRect(x: absX + inset, y: absY + inset,
                                  width: bgWidth, height: bgHeight)
                let color = applyOpacity(bg, node.opacity)
                let bgRadius = max(0, node.cornerRadius - inset)
                // The backdrop covers the whole node, not just the fill: the
                // border ring is drawn on top of it and must stay crisp.
                if node.backdropBlur > 0 {
                    list.beginBackdrop(UIBackdrop(
                        rect: UIRect(x: absX, y: absY, width: width, height: height),
                        cornerRadius: node.cornerRadius,
                        blurRadius: node.backdropBlur))
                }
                if bgRadius > 0 {
                    list.addRoundedRect(rect, radius: bgRadius, color: color)
                } else {
                    list.addRect(rect, color: color)
                }
            }
        }

        // 5. Custom content (Text/Image/etc).
        if let draw = node.draw {
            draw(list, CGPoint(x: Double(absX), y: Double(absY)))
        }

        // 6. Children — translated by -contentOffset for scrollable containers.
        // The offset stays fractional while content moves — see
        // `ScrollAnimator.restOnWholePoints`, which aligns it once at rest.
        let childOriginX = absX - Float(node.contentOffset.x)
        let childOriginY = absY - Float(node.contentOffset.y)
        let descendantStart = list.vertices.count
        if node.childrenMayNeedZSort {
            for child in renderOrderedChildren(of: node) {
                renderNode(child, list: list, originX: childOriginX, originY: childOriginY)
            }
        } else {
            for child in node.children {
                renderNode(child, list: list, originX: childOriginX, originY: childOriginY)
            }
        }

        // 7. Overlay (scrollbars, focus rings drawn above content), then the
        //    rim light: the edge belongs to the surface, so it goes on last.
        list.multiplyOpacity(fromVertexIndex: descendantStart, by: node.opacity)
        if let overlay = node.overlayDraw {
            overlay(list, CGPoint(x: Double(absX), y: Double(absY)))
        }
        let borderInset = (node.borderColor != nil && node.borderWidth > 0) ? node.borderWidth : 0
        list.addHighlight(node.highlight, rect: rect, cornerRadius: node.cornerRadius,
                          borderWidth: borderInset, opacity: node.opacity)

        list.multiplyOpacity(node.subtreeOpacity, fromVertex: firstVertex)
        // 8. Pop clip.
        if clipped {
            list.popClip()
        }
    }

    private func applyOpacity(_ color: Color, _ opacity: Float) -> Color {
        guard opacity < 1 else { return color }
        return Color(r: color.r, g: color.g, b: color.b, a: color.a * opacity)
    }

    private func renderOrderedChildren(of node: Node) -> [Node] {
        node.children.enumerated()
            .sorted { lhs, rhs in
                let lhsZ = lhs.element.zIndex
                let rhsZ = rhs.element.zIndex
                if lhsZ == rhsZ { return lhs.offset < rhs.offset }
                return lhsZ < rhsZ
            }
            .map { $0.element }
    }
}
