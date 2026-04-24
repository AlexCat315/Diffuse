import CoreGraphics

/// Phase 4b. RenderTree-aware renderer that records each layer-root subtree
/// into its own cached `DrawList`, then composites cached layer slices into
/// the frame `DrawList` by appending their vertices/indices.
///
/// Cache invariants per layer-root `RenderObject`:
/// - `cacheInvalid == false` AND
/// - `lastAbsoluteOrigin == currentAbsoluteOrigin` AND
/// - the layer's parent clip stack at composite time matches the one captured
///   when the cache was recorded (tracked by `lastClipStack`).
///
/// When all three hold we append `cachedLayerList` and skip the recursive
/// walk into this layer's subtree. Otherwise the layer is re-recorded.
///
/// Behavioral parity with `NodeRenderer`: the emitted vertex/index/batch
/// stream matches `NodeRenderer.render(root:into:)` for the same Node tree,
/// modulo batch merging at layer boundaries (cached layers append as
/// independent batch runs rather than coalescing across the boundary).
public final class LayerAwareNodeRenderer {

    public init() {}

    /// Composite `tree` into `frame`. The caller resets the frame DrawList
    /// before each render pass.
    public func render(tree: RenderTree, into frame: DrawList) {
        guard let root = tree.root else { return }
        compose(root, into: frame, parentOriginX: 0, parentOriginY: 0,
                parentClipStack: [])
    }

    private func compose(_ obj: RenderObject,
                         into frame: DrawList,
                         parentOriginX: Float,
                         parentOriginY: Float,
                         parentClipStack: [UIRect]) {
        guard let node = obj.node else { return }
        let f = node.frame
        let absX = parentOriginX + Float(f.origin.x)
        let absY = parentOriginY + Float(f.origin.y)
        let origin = CGPoint(x: CGFloat(absX), y: CGFloat(absY))

        if obj.isLayerRoot {
            // Try to reuse a cached layer DrawList.
            let originUnchanged = obj.lastAbsoluteOrigin.map {
                $0 == origin
            } ?? false
            let clipUnchanged = obj.lastClipStack == parentClipStack
            if !obj.cacheInvalid,
               originUnchanged,
               clipUnchanged,
               let cached = obj.cachedLayerList {
                frame.append(cached)
                return
            }

            // Re-record. Use a fresh per-layer DrawList so the cache is
            // independent of the frame DrawList and reusable next time.
            let layerList = DrawList()
            // Push the parent clip stack so nested clips intersect properly.
            for rect in parentClipStack { layerList.pushClip(rect) }
            recordSelfAndDescendants(
                obj,
                node: node,
                into: layerList,
                originX: absX,
                originY: absY,
                clipStack: parentClipStack
            )
            for _ in parentClipStack { layerList.popClip() }
            obj.cachedLayerList = layerList
            obj.lastAbsoluteOrigin = origin
            obj.lastClipStack = parentClipStack
            obj.cacheInvalid = false
            frame.append(layerList)
            return
        }

        // Non-layer object never reached at top level (root is always a
        // layer root), so this branch only runs as a child of a non-layer
        // path. We still emit directly into `frame` for safety.
        recordSelfAndDescendants(
            obj,
            node: node,
            into: frame,
            originX: absX,
            originY: absY,
            clipStack: parentClipStack
        )
    }

    /// Record `node`'s own paint output and recurse into children. Nested
    /// layer roots are NOT recorded into `list`; instead their composite
    /// happens via `compose(...)` (which may reuse a cached slice).
    private func recordSelfAndDescendants(_ obj: RenderObject,
                                          node: Node,
                                          into list: DrawList,
                                          originX: Float,
                                          originY: Float,
                                          clipStack: [UIRect]) {
        let width = Float(node.frame.size.width)
        let height = Float(node.frame.size.height)

        // Clip push if applicable. clipsToBounds always implies layer root,
        // so only the root-of-this-layer node can push a new clip rect.
        let clipped = node.clipsToBounds && width > 0 && height > 0
        var clipRect: UIRect? = nil
        if clipped {
            clipRect = UIRect(x: originX, y: originY, width: width, height: height)
            list.pushClip(clipRect!)
        }

        // Painters (mirror NodeRenderer order):
        emitShadow(node, into: list, x: originX, y: originY, w: width, h: height)
        emitBorder(node, into: list, x: originX, y: originY, w: width, h: height)
        emitBackground(node, into: list, x: originX, y: originY, w: width, h: height)
        if let draw = node.draw {
            draw(list, CGPoint(x: Double(originX), y: Double(originY)))
        }

        // Children. Translate by -contentOffset for scrollable containers.
        let childX = originX - Float(node.contentOffset.x)
        let childY = originY - Float(node.contentOffset.y)
        let childClipStack: [UIRect] = clipped ? clipStack + [clipRect!] : clipStack
        for child in obj.children {
            // A nested layer root composites separately (cache-aware), so we
            // call `compose` rather than recording inline.
            if child.isLayerRoot {
                compose(child,
                        into: list,
                        parentOriginX: childX,
                        parentOriginY: childY,
                        parentClipStack: childClipStack)
            } else {
                guard let childNode = child.node else { continue }
                let cf = childNode.frame
                recordSelfAndDescendants(
                    child,
                    node: childNode,
                    into: list,
                    originX: childX + Float(cf.origin.x),
                    originY: childY + Float(cf.origin.y),
                    clipStack: childClipStack
                )
            }
        }

        if let overlay = node.overlayDraw {
            overlay(list, CGPoint(x: Double(originX), y: Double(originY)))
        }

        if clipped {
            list.popClip()
        }
    }

    // MARK: - Painter helpers (mirror NodeRenderer.swift)

    private func emitShadow(_ node: Node, into list: DrawList,
                            x: Float, y: Float, w: Float, h: Float) {
        guard let shadowColor = node.shadowColor, shadowColor.a > 0,
              w > 0, h > 0 else { return }
        let blur = max(0, node.shadowBlur)
        let radius = max(node.cornerRadius, 0)
                let steps = blur > 0 ? 6 : 1
        for i in 0..<steps {
                        let t = Float(i) / Float(max(1, steps - 1))
            let inset = -blur * (1 - t)
                        let weight = (1 - t) * (1 - t)
                        let alpha = shadowColor.a * weight / Float(steps) * 2.4
            let rect = UIRect(
                x: x + node.shadowOffsetX + inset,
                y: y + node.shadowOffsetY + inset,
                width: w - 2 * inset,
                height: h - 2 * inset
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

    private func emitBorder(_ node: Node, into list: DrawList,
                            x: Float, y: Float, w: Float, h: Float) {
        guard let bc = node.borderColor, node.borderWidth > 0,
              w > 0, h > 0 else { return }
        let rect = UIRect(x: x, y: y, width: w, height: h)
        let color = applyOpacity(bc, node.opacity)
        if node.cornerRadius > 0 {
            list.addRoundedRect(rect, radius: node.cornerRadius, color: color)
        } else {
            list.addRect(rect, color: color)
        }
    }

    private func emitBackground(_ node: Node, into list: DrawList,
                                x: Float, y: Float, w: Float, h: Float) {
        guard let bg = node.backgroundColor, w > 0, h > 0 else { return }
        let inset: Float = (node.borderColor != nil && node.borderWidth > 0)
            ? node.borderWidth : 0
        let bgWidth = max(0, w - 2 * inset)
        let bgHeight = max(0, h - 2 * inset)
        guard bgWidth > 0 && bgHeight > 0 else { return }
        let rect = UIRect(x: x + inset, y: y + inset,
                          width: bgWidth, height: bgHeight)
        let color = applyOpacity(bg, node.opacity)
        let bgRadius = max(0, node.cornerRadius - inset)
        if bgRadius > 0 {
            list.addRoundedRect(rect, radius: bgRadius, color: color)
        } else {
            list.addRect(rect, color: color)
        }
    }

    private func applyOpacity(_ color: Color, _ opacity: Float) -> Color {
        guard opacity < 1 else { return color }
        return Color(r: color.r, g: color.g, b: color.b, a: color.a * opacity)
    }
}
