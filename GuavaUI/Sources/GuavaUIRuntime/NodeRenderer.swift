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

        // 2. Drop shadow (painted before background so it sits behind).
        if let shadowColor = node.shadowColor, shadowColor.a > 0,
           width > 0, height > 0 {
            let blur = max(0, node.shadowBlur)
            let radius = max(node.cornerRadius, 0)
            // Cheap fake-blur: emit `steps` concentric expanded rects with
            // decreasing alpha. Cost is bounded (≤ 6 per node). 6 steps with a
            // quadratic weight give a smoother gradient than 4 linear steps at
            // typical 8–12 px blur radii used for tool-chrome elevation.
            let steps = blur > 0 ? 6 : 1
            for i in 0..<steps {
                let t = Float(i) / Float(max(1, steps - 1))
                let inset = -blur * (1 - t)
                // Quadratic falloff: concentrated near the element, trails to
                // near-zero at the outer edge (t = 1 → weight = 0).
                let weight = (1 - t) * (1 - t)
                let alpha = shadowColor.a * weight / Float(steps) * 2.4
                let rect = UIRect(
                    x: absX + node.shadowOffsetX + inset,
                    y: absY + node.shadowOffsetY + inset,
                    width:  width  - 2 * inset,
                    height: height - 2 * inset
                )
                let stepColor = Color(
                    r: shadowColor.r,
                    g: shadowColor.g,
                    b: shadowColor.b,
                    a: min(1, alpha) * node.opacity
                )
                let stepRadius = radius + max(0, -inset)
                if stepRadius > 0 {
                    list.addRoundedRect(rect, radius: stepRadius, color: stepColor)
                } else {
                    list.addRect(rect, color: stepColor)
                }
            }
        }

        // 3. Border (painted before background; background inset covers the
        //    interior so only a `borderWidth`-wide ring shows through).
        if let bc = node.borderColor, node.borderWidth > 0,
           width > 0, height > 0 {
            let rect = UIRect(x: absX, y: absY, width: width, height: height)
            let color = applyOpacity(bc, node.opacity)
            if node.cornerRadius > 0 {
                list.addRoundedRect(rect, radius: node.cornerRadius, color: color)
            } else {
                list.addRect(rect, color: color)
            }
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
        let childOriginX = absX - Float(node.contentOffset.x)
        let childOriginY = absY - Float(node.contentOffset.y)
        for child in renderOrderedChildren(of: node) {
            renderNode(child, list: list, originX: childOriginX, originY: childOriginY)
        }

        // 7. Overlay (scrollbars, focus rings drawn above content).
        if let overlay = node.overlayDraw {
            overlay(list, CGPoint(x: Double(absX), y: Double(absY)))
        }

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
