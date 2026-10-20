import GuavaUICore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Walks a `Node` tree post-layout and emits draw commands into a `DrawList`.
///
/// Convention: `Node.frame` is interpreted as parent-local; the renderer
/// carries a placement down the tree rather than a bare origin, so a node's
/// `transform` reaches the subtree it scales. Background fills and the
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
        renderNode(root, list: list, placed: .identity)
    }

    /// `placed` is where the parent's content sits; the node composes its own
    /// placement onto it. Carrying the whole transform rather than a resolved
    /// origin is what lets a scale reach this node's children — an origin alone
    /// has nowhere to record how much bigger or smaller they should be drawn.
    private func renderNode(_ node: Node, list: DrawList, placed: Affine2D) {
        guard node.isLayoutVisible else { return }
        let firstVertex = list.vertices.count
        let f = node.frame
        let own = node.placementStep(scrolling: .zero).followed(by: placed)
        let origin = own.origin
        let absX = origin.x
        let absY = origin.y
        let scale = own.a
        let width  = Float(f.size.width) * scale
        let height = Float(f.size.height) * scale

        // Every length on the node's own box is measured in the node's units, so
        // it scales with the box. A 10pt corner drawn at 0.96 is a 9.6pt corner
        // — leaving it at 10 would make the panel visibly rounder as it grew.
        let radius = node.cornerRadius * scale
        let borderWidth = node.borderWidth * scale

        // 0. A reveal describes the frame, not this box. See `UIReveal`.
        if let reveal = node.revealRequest { list.beginReveal(reveal) }

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
        // An opaque background covers the shadow's interior the moment it is
        // painted, so clip to that too and keep only the visible fringe.
        let occluded: UIRect? = node.backgroundColor != nil ? rect : nil
        list.addShadow(LayeredShadow(ambient: node.ambientShadow.scaled(by: own.shadowScale),
                                    key: node.shadow.scaled(by: own.shadowScale)),
                       rect: rect, cornerRadius: radius, opacity: node.opacity,
                       frostedRect: node.backdropBlur > 0 ? rect : nil,
                       occludedRect: occluded)

        // 3. Border ring, including when the background is transparent. A
        //    frosted node draws it after the fill: the backdrop composite is
        //    attached to the fill's batch and would otherwise cover the ring.
        let drawBorder = {
            if let bc = node.borderColor, borderWidth > 0, width > 0, height > 0 {
                list.addRoundedRectStroke(rect, radius: radius, width: borderWidth,
                                          color: self.applyOpacity(bc, node.opacity))
            }
        }
        let frosted = node.backdropBlur > 0 && node.backgroundColor != nil
        if !frosted { drawBorder() }

        // 4. Background fill (inset by border width so it does not overdraw
        //    the border ring).
        if node.backgroundColor != nil || node.backgroundGradient != nil, width > 0, height > 0 {
            let inset = (node.borderColor != nil && node.borderWidth > 0) ? borderWidth : 0
            let bgWidth  = max(0, width  - 2 * inset)
            let bgHeight = max(0, height - 2 * inset)
            if bgWidth > 0 && bgHeight > 0 {
                let rect = UIRect(x: absX + inset, y: absY + inset,
                                  width: bgWidth, height: bgHeight)
                let bgRadius = max(0, radius - inset)
                // The backdrop covers the whole node, not just the fill: the
                // border ring is drawn on top of it and must stay crisp.
                if node.backdropBlur > 0 {
                    list.beginBackdrop(UIBackdrop(
                        rect: UIRect(x: absX, y: absY, width: width, height: height),
                        cornerRadius: radius,
                        blurRadius: node.backdropBlur, opacity: node.opacity))
                }
                if let gradient = node.backgroundGradient {
                    list.addLinearGradient(rect, radius: bgRadius, gradient: gradient.multipliedAlpha(node.opacity))
                } else if let bg = node.backgroundColor {
                    let color = applyOpacity(bg, node.opacity)
                    if bgRadius > 0 {
                        list.addRoundedRect(rect, radius: bgRadius, color: color)
                    } else {
                        list.addRect(rect, color: color)
                    }
                }
            }
        }
        if frosted { drawBorder() }

        // 5. Custom content (Text/Image/etc). A rounded clipping container
        //    keeps it and its children inside the inner rounded edge.
        let mask = contentMask(node, x: absX, y: absY, width: width, height: height,
                               radius: radius, borderWidth: borderWidth)
        if let mask { list.pushMask(mask) }
        if let draw = node.draw {
            paintScaled(draw, into: list, origin: CGPoint(x: Double(absX), y: Double(absY)), scale: scale)
        }

        // 6. Children — placed where this node's *content* sits, which is its
        //    own frame slid by -contentOffset and then scaled. The offset stays
        //    fractional throughout motion and at rest.
        let content = node.placementStep(scrolling: node.contentOffset).followed(by: placed)
        let descendantStart = list.vertices.count
        if node.childrenMayNeedZSort {
            for child in renderOrderedChildren(of: node) {
                renderNode(child, list: list, placed: content)
            }
        } else {
            for child in node.children {
                renderNode(child, list: list, placed: content)
            }
        }
        if mask != nil { list.popMask() }

        // 7. Overlay (scrollbars, focus rings drawn above content).
        list.multiplyOpacity(fromVertexIndex: descendantStart, by: node.opacity)
        if let overlay = node.overlayDraw {
            paintScaled(overlay, into: list, origin: CGPoint(x: Double(absX), y: Double(absY)), scale: scale)
        }

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
