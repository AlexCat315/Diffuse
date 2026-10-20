import GuavaUICore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Phase 4b. RenderTree-aware renderer that records each layer-root subtree
/// into its own cached `DrawList`, then composites cached layer slices into
/// the frame `DrawList` by appending their vertices/indices.
///
/// Cache invariants per layer-root `RenderObject`:
/// - `cacheInvalid == false` AND
/// - the layer's placement at composite time matches the one captured when the
///   cache was recorded (`lastPlacement`: position, paint and shadow scales) AND
/// - the layer's parent clip stack at composite time matches the one captured
///   when the cache was recorded (tracked by `lastClipStack`).
///
/// Stable unclipped leaf layers may move under the same parent clip without
/// re-recording. Their cached vertices are translated while being appended;
/// this is the common path for text and controls moving during scrolling. That
/// shortcut needs the scale to be unchanged as well — translating vertices
/// cannot resize them, so a scaling layer has to re-record.
///
/// Visible geometry matches `NodeRenderer` for the same tree. Completely
/// clipped subtrees and cached offscreen leaves can be omitted. Cached layers
/// append as independent batch runs rather than coalescing across boundaries.
public final class LayerAwareNodeRenderer {

    public init() {}

    /// Composite `tree` into `frame`. The caller resets the frame DrawList
    /// before each render pass.
    public func render(tree: RenderTree, into frame: DrawList) {
        guard let root = tree.root else { return }
        if let node = root.node {
            frame.setViewportBounds(UIRect(x: Float(node.frame.origin.x),
                                           y: Float(node.frame.origin.y),
                                           width: Float(node.frame.width),
                                           height: Float(node.frame.height)))
        }
        compose(root, into: frame, placed: .identity,
               parentClipStack: [])
    }

    /// `placed` is where the parent's content sits; the node composes its own
    /// placement onto it. Carrying the transform rather than a resolved origin
    /// is what lets a scale reach the subtree and, through `lastPlacement`, what
    /// makes the cache notice when it changes.
    private func compose(_ obj: RenderObject,
                         into frame: DrawList,
                         placed: Affine2D,
                         parentClipStack: [UIClip]) {
        guard let node = obj.node, node.isLayoutVisible else { return }
        let f = node.frame
        let own = node.placementStep(scrolling: .zero).followed(by: placed)
        let origin = own.origin
        let absX = origin.x
        let absY = origin.y
        let scale = own.a
        let width = Float(f.width) * scale
        let height = Float(f.height) * scale

        if node.clipsToBounds, width > 0, height > 0,
           RenderCulling.isOutside(UIRect(x: absX, y: absY, width: width, height: height), list: frame) {
            return
        }

        if obj.isLayerRoot {
            // Try to reuse a cached layer DrawList.
            let placementUnchanged = obj.lastPlacement == own
            let clipUnchanged = obj.lastClipStack == parentClipStack
            if !obj.cacheInvalid,
               clipUnchanged,
               let cached = obj.cachedLayerList,
               cached.pixelScale == frame.pixelScale {
                if obj.children.isEmpty, let bounds = obj.cachedPaintBounds,
                   let cachedPlacement = obj.lastPlacement,
                   own.a == cachedPlacement.a, own.shadowScale == cachedPlacement.shadowScale {
                    let translated = UIRect(x: bounds.x + absX - cachedPlacement.e,
                                            y: bounds.y + absY - cachedPlacement.f,
                                            width: bounds.width, height: bounds.height)
                    if RenderCulling.isOutside(translated, list: frame) { return }
                }
                if placementUnchanged {
                    frame.append(cached)
                    return
                }
                // Translation-only reuse. Only valid at an unchanged scale: the
                // cached vertices were baked at the old size and moving them
                // cannot resize them.
                if obj.children.isEmpty,
                   !node.clipsToBounds,
                   own.a == obj.lastPlacement?.a,
                   own.shadowScale == obj.lastPlacement?.shadowScale,
                   let cachedPlacement = obj.lastPlacement,
                   !Self.crossesRoundedCorner(obj.cachedPaintBounds, from: cachedPlacement, to: own, clips: parentClipStack) {
                    frame.append(
                        cached,
                        vertexTranslationX: own.e - cachedPlacement.e,
                        vertexTranslationY: own.f - cachedPlacement.f
                    )
                    return
                }
            }

            if !obj.children.isEmpty {
                // A changed container renders directly into its parent. This
                // avoids rebuilding/copying a stack of flattened ancestor
                // caches during scrolling or live chart updates. If another
                // frame arrives without invalidation, cache it then; stable
                // continuous frames subsequently become one bulk append.
                if obj.cacheInvalid || !placementUnchanged || !clipUnchanged {
                    recordSelfAndDescendants(
                        obj,
                        node: node,
                        into: frame,
                        placed: placed,
                        clipStack: parentClipStack
                    )
                    obj.cachedLayerList = nil
                    obj.lastPlacement = own
                    obj.lastClipStack = parentClipStack
                    obj.cacheInvalid = false
                    return
                }
            }

            // Re-record. Use a fresh per-layer DrawList so the cache is
            // independent of the frame DrawList and reusable next time.
            let layerList = DrawList()
            layerList.pixelScale = frame.pixelScale
            layerList.setViewportBounds(frame.viewportBounds)
            // Push the parent clip stack so nested clips intersect properly.
            for clip in parentClipStack { layerList.pushClip(clip) }
            recordSelfAndDescendants(
                obj,
                node: node,
                into: layerList,
                placed: placed,
                clipStack: parentClipStack
            )
            for clip in parentClipStack.reversed() { layerList.popClip(clip) }
            obj.cachedLayerList = layerList
            obj.cachedPaintBounds = obj.children.isEmpty ? RenderCulling.bounds(of: layerList) : nil
            obj.lastPlacement = own
            obj.lastClipStack = parentClipStack
            obj.cacheInvalid = false
            // Do not bake an offscreen leaf into its ancestor's first cache.
            // Its painter runs once to establish actual bounds, then the
            // cached geometry remains available when it enters the viewport.
            if let bounds = obj.cachedPaintBounds, RenderCulling.isOutside(bounds, list: frame) { return }
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
            placed: placed,
            clipStack: parentClipStack
        )
    }

    /// Record `node`'s own paint output and recurse into children. Nested
    /// layer roots are NOT recorded into `list`; instead their composite
    /// happens via `compose(...)` (which may reuse a cached slice).
    private func recordSelfAndDescendants(_ obj: RenderObject,
                                          node: Node,
                                          into list: DrawList,
                                          placed: Affine2D,
                                          clipStack: [UIClip]) {
        guard node.isLayoutVisible else { return }
        let firstVertex = list.vertices.count
        let own = node.placementStep(scrolling: .zero).followed(by: placed)
        let origin = own.origin
        let originX = origin.x
        let originY = origin.y
        let scale = own.a
        let width = Float(node.frame.size.width) * scale
        let height = Float(node.frame.size.height) * scale

        // Lengths on the node's own box are measured in the node's units, so
        // they scale with it — see `NodeRenderer` for the same reasoning.
        let radius = node.cornerRadius * scale
        let borderWidth = node.borderWidth * scale

        // A reveal describes the frame, not this box, so it rides along with
        // whatever geometry the node emits. `DrawList.append` carries it into
        // the frame list when the node is recorded into a layer cache.
        if let reveal = node.revealRequest { list.beginReveal(reveal) }

        // Clip push if applicable. clipsToBounds always implies layer root,
        // so only the root-of-this-layer node can push a new clip rect.
        let clipped = node.clipsToBounds && width > 0 && height > 0
        var clipRect: UIRect? = nil
        if clipped {
            clipRect = UIRect(x: originX, y: originY, width: width, height: height)
            list.pushClip(clipRect!)
        }

        // Painters (mirror NodeRenderer order):
        emitShadow(node, into: list, x: originX, y: originY, w: width, h: height,
                   radius: radius, scale: own.shadowScale)
        // A frosted node rings its fill afterwards: the backdrop composite is
        // attached to the fill's batch and would otherwise cover the border.
        let frosted = node.backdropBlur > 0 && node.backgroundColor != nil
        if !frosted {
            emitBorder(node, into: list, x: originX, y: originY, w: width, h: height,
                       radius: radius, borderWidth: borderWidth)
        }
        emitBackground(node, into: list, x: originX, y: originY, w: width, h: height,
                       radius: radius, borderWidth: borderWidth)
        if frosted {
            emitBorder(node, into: list, x: originX, y: originY, w: width, h: height,
                       radius: radius, borderWidth: borderWidth)
        }
        let mask = contentMask(node, x: originX, y: originY, width: width, height: height,
                               radius: radius, borderWidth: borderWidth)
        if let mask { list.pushMask(mask) }
        if let draw = node.draw {
            paintScaled(draw, into: list, origin: CGPoint(x: Double(originX), y: Double(originY)), scale: scale)
        }

        // Children, placed where this node's *content* sits: its own frame slid
        // by -contentOffset and then scaled. The offset stays fractional
        // throughout motion and at rest.
        let content = node.placementStep(scrolling: node.contentOffset).followed(by: placed)
        let childClipStack: [UIClip] = clipped ? clipStack + [UIClip(clipRect!, mask: mask)] : clipStack
        let children = node.childrenMayNeedZSort ? renderOrderedChildren(of: obj) : obj.children
        let descendantStart = list.vertices.count
        for child in children {
            // A nested layer root composites separately (cache-aware), so we
            // call `compose` rather than recording inline.
            if child.isLayerRoot {
                compose(child,
                        into: list,
                        placed: content,
                        parentClipStack: childClipStack)
            } else {
                guard let childNode = child.node else { continue }
                recordSelfAndDescendants(
                    child,
                    node: childNode,
                    into: list,
                    placed: content,
                    clipStack: childClipStack
                )
            }
        }
        if mask != nil { list.popMask() }

        list.multiplyOpacity(fromVertexIndex: descendantStart, by: node.opacity)
        if let overlay = node.overlayDraw {
            paintScaled(overlay, into: list, origin: CGPoint(x: Double(originX), y: Double(originY)), scale: scale)
        }

        list.multiplyOpacity(node.subtreeOpacity, fromVertex: firstVertex)
        if clipped {
            list.popClip()
        }
    }

    /// A cached leaf was clipped where it was recorded. If it touched a rounded
    /// corner there, or would touch one after moving, re-record it instead of
    /// translating geometry that was cut for the old position.
    private static func crossesRoundedCorner(_ bounds: UIRect?, from old: Affine2D, to new: Affine2D, clips: [UIClip]) -> Bool {
        let masks = clips.compactMap(\.mask)
        guard !masks.isEmpty else { return false }
        guard let bounds else { return true }
        let moved = UIRect(x: bounds.x + new.e - old.e, y: bounds.y + new.f - old.f, width: bounds.width, height: bounds.height)
        return masks.contains { $0.touchesCorner(bounds) || $0.touchesCorner(moved) }
    }

    // MARK: - Painter helpers (mirror NodeRenderer.swift)

    private func emitShadow(_ node: Node, into list: DrawList,
                            x: Float, y: Float, w: Float, h: Float,
                            radius: Float, scale: Float) {
        let rect = UIRect(x: x, y: y, width: w, height: h)
        // An opaque background is painted over this node immediately after, so
        // the shadow's interior is never visible. Clipping to it keeps the
        // fringe and drops the wasted fills.
        let occluded = node.backgroundColor != nil ? rect : nil
        list.addShadow(LayeredShadow(ambient: node.ambientShadow.scaled(by: scale),
                                    key: node.shadow.scaled(by: scale)),
                       rect: rect, cornerRadius: radius, opacity: node.opacity,
                       frostedRect: node.backdropBlur > 0 ? rect : nil,
                       occludedRect: occluded)
    }

    private func emitBorder(_ node: Node, into list: DrawList,
                            x: Float, y: Float, w: Float, h: Float,
                            radius: Float, borderWidth: Float) {
        guard let bc = node.borderColor, borderWidth > 0,
              w > 0, h > 0 else { return }
        let rect = UIRect(x: x, y: y, width: w, height: h)
        let color = applyOpacity(bc, node.opacity)
        list.addRoundedRectStroke(rect, radius: radius,
                                  width: borderWidth, color: color)
    }

    private func emitBackground(_ node: Node, into list: DrawList,
                                x: Float, y: Float, w: Float, h: Float,
                                radius: Float, borderWidth: Float) {
        guard node.backgroundColor != nil || node.backgroundGradient != nil, w > 0, h > 0 else { return }
        let inset: Float = (node.borderColor != nil && node.borderWidth > 0) ? borderWidth : 0
        let bgWidth = max(0, w - 2 * inset)
        let bgHeight = max(0, h - 2 * inset)
        guard bgWidth > 0 && bgHeight > 0 else { return }
        let rect = UIRect(x: x + inset, y: y + inset,
                          width: bgWidth, height: bgHeight)
        let bgRadius = max(0, radius - inset)
        // The backdrop covers the whole node, not just the fill: the border
        // ring is drawn on top of it and must stay crisp.
        if node.backdropBlur > 0 {
            list.beginBackdrop(UIBackdrop(rect: UIRect(x: x, y: y, width: w, height: h),
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

    private func applyOpacity(_ color: Color, _ opacity: Float) -> Color {
        guard opacity < 1 else { return color }
        return Color(r: color.r, g: color.g, b: color.b, a: color.a * opacity)
    }

    private func renderOrderedChildren(of obj: RenderObject) -> [RenderObject] {
        obj.children.enumerated()
            .sorted { lhs, rhs in
                let lhsZ = lhs.element.node?.zIndex ?? 0
                let rhsZ = rhs.element.node?.zIndex ?? 0
                if lhsZ == rhsZ { return lhs.offset < rhs.offset }
                return lhsZ < rhsZ
            }
            .map { $0.element }
    }
}
