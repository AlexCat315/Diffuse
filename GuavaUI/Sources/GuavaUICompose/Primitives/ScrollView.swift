import CoreGraphics
import GuavaUIRuntime

private enum _ScrollViewDragAxis {
    case vertical
    case horizontal
}

private struct _ScrollViewDragState {
    var axis: _ScrollViewDragAxis
    var pointerStart: CGFloat
    var offsetStart: CGFloat
    var maxOffset: CGFloat
    var trackStart: CGFloat
    var trackLength: CGFloat
    var thumbLength: CGFloat
}

private enum _ScrollViewAttachmentKeys {
    static let dragState = "__scrollview_scrollbar_drag_state"
}

private struct _ScrollViewScrollbarGeometry {
    var verticalTrack: CGRect?
    var verticalThumb: CGRect?
    var horizontalTrack: CGRect?
    var horizontalThumb: CGRect?
    var maxOffsetX: CGFloat
    var maxOffsetY: CGFloat
}

/// Clipping container that scrolls its content via mouse wheel input.
///
/// v1 limitations:
/// - Content is laid out within the ScrollView's box. To enable real overflow
///   the inner content must use explicit sizes that exceed the ScrollView's
///   frame; flex-grown children will be compressed by Yoga.
/// - Wheel routing requires the cursor to be over the ScrollView (handled by
///   `EventDispatcher`'s wheel hit-test).
public struct ScrollView<Content: View>: _PrimitiveView {
    public enum Axis: Sendable { case vertical, horizontal, both }

    public let axes: Axis
    public let content: Content

    /// Pixels scrolled per wheel notch. SDL3 reports wheel deltas in lines.
    public var wheelStep: Float = 30
    public let consumePolicy: ScrollConsumePolicy

    public init(_ axes: Axis = .vertical,
                consumePolicy: ScrollConsumePolicy = .whenOffsetChanged,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.consumePolicy = consumePolicy
        self.content = content()
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.clipsToBounds = true
        return n
    }

    public func _updateNode(_ node: Node) {
        let theme = node.theme
        let axes = self.axes
        let step = self.wheelStep
        let consumePolicy = self.consumePolicy
        let trackThickness: Float = 8
        let trackInset: Float = 2
        let capture = PointerCaptureHolder.current

        if let registry = InteractionRegistryHolder.current {
            registry.setWheel(node, route: .scroll) { event, _ in
                // Wheel up (positive Y) scrolls content up — i.e. offset.y decreases.
                let dx: Float = (axes == .horizontal || axes == .both) ? -event.x * step : 0
                let dy: Float = (axes == .vertical   || axes == .both) ? -event.y * step : 0
                if dx == 0 && dy == 0 { return .ignored }

                let previousOffset = node.contentOffset
                var nextOffset = previousOffset
                nextOffset.x += CGFloat(dx)
                nextOffset.y += CGFloat(dy)

                // Clamp to [0, max(0, contentSize - viewSize)] using the full
                // content subtree. The direct wrapper can be flex-clamped to
                // the viewport while its descendants still overflow.
                let viewSize = visibleViewportRect(for: node).size
                let contentSize = scrollableContentSize(for: node)
                if contentSize.width > 0 || contentSize.height > 0 {
                    nextOffset.x = max(0, min(nextOffset.x, max(0, contentSize.width  - viewSize.width)))
                    nextOffset.y = max(0, min(nextOffset.y, max(0, contentSize.height - viewSize.height)))
                } else {
                    nextOffset = .zero
                }
                node.contentOffset = nextOffset
                return consumePolicy.result(didScroll: nextOffset != previousOffset)
            }
            registry.setPointer(node, route: .scrollChrome) { event, pointerPhase, eventPhase in
                switch pointerPhase {
                case .down:
                    guard event.button == .left else { return .ignored }
                    guard eventPhase == .capture || eventPhase == .target else {
                        return .ignored
                    }
                    let local = localPoint(x: event.x, y: event.y, in: node)
                    let geometry = scrollbarGeometry(for: node,
                                                     axes: axes,
                                                     trackThickness: trackThickness,
                                                     trackInset: trackInset)
                    if let state = beginScrollbarDrag(axis: .vertical,
                                                      local: local,
                                                      geometry: geometry,
                                                      node: node) {
                        node.attachments[_ScrollViewAttachmentKeys.dragState] = state
                        capture?.acquire(node)
                        return .handled
                    }
                    if let state = beginScrollbarDrag(axis: .horizontal,
                                                      local: local,
                                                      geometry: geometry,
                                                      node: node) {
                        node.attachments[_ScrollViewAttachmentKeys.dragState] = state
                        capture?.acquire(node)
                        return .handled
                    }
                    return .ignored
                case .up:
                    guard node.attachments[_ScrollViewAttachmentKeys.dragState] != nil else {
                        return .ignored
                    }
                    node.attachments[_ScrollViewAttachmentKeys.dragState] = nil
                    capture?.release()
                    return .handled
                }
            }
            registry.setMotion(node, route: .scrollChrome) { event, _ in
                guard let state = node.attachments[_ScrollViewAttachmentKeys.dragState]
                        as? _ScrollViewDragState else {
                    return .ignored
                }
                let local = localPoint(x: event.x, y: event.y, in: node)
                let pointer = state.axis == .vertical ? local.y : local.x
                let availableTrack = max(1, state.trackLength - state.thumbLength)
                let rawOffset = state.offsetStart
                    + ((pointer - state.pointerStart) / availableTrack) * state.maxOffset
                let clampedOffset = max(0, min(rawOffset, state.maxOffset))
                var nextOffset = node.contentOffset
                switch state.axis {
                case .vertical:
                    nextOffset.y = clampedOffset
                case .horizontal:
                    nextOffset.x = clampedOffset
                }
                node.contentOffset = nextOffset
                return .handled
            }
        }

        // Scrollbar painter — runs after children render. We can't draw after
        // children with the current `Node.draw` ordering (it runs before
        // children), so we paint the bar onto the ScrollView's own background
        // pass. To keep it visible above scrolled content, we add a sibling
        // overlay node on first update.
        let trackColor = theme.colors.surfaceVariant
        let thumbColor = theme.colors.onSurfaceMuted
        node.overlayDraw = { [weak node] list, origin in
            guard let node else { return }
            let viewport = visibleViewportRect(for: node)
            let viewW = Float(viewport.width)
            let viewH = Float(viewport.height)
            let contentSize = scrollableContentSize(for: node)
            let contentW = Float(contentSize.width)
            let contentH = Float(contentSize.height)
            guard contentW > 0 || contentH > 0 else { return }
            let offX = Float(node.contentOffset.x)
            let offY = Float(node.contentOffset.y)

            // Vertical bar.
            if (axes == .vertical || axes == .both), contentH > viewH, viewH > 0 {
                let trackX = Float(origin.x + viewport.maxX) - trackThickness - trackInset
                let trackY = Float(origin.y + viewport.minY) + trackInset
                let trackH = viewH - 2 * trackInset
                list.addRoundedRect(
                    UIRect(x: trackX, y: trackY,
                           width: trackThickness, height: trackH),
                    radius: trackThickness / 2,
                    color: trackColor
                )
                let thumbH = max(trackThickness * 2, trackH * (viewH / contentH))
                let maxOff = contentH - viewH
                let t = maxOff > 0 ? offY / maxOff : 0
                let thumbY = trackY + (trackH - thumbH) * t
                list.addRoundedRect(
                    UIRect(x: trackX, y: thumbY,
                           width: trackThickness, height: thumbH),
                    radius: trackThickness / 2,
                    color: thumbColor
                )
            }

            // Horizontal bar.
            if (axes == .horizontal || axes == .both), contentW > viewW, viewW > 0 {
                let trackY = Float(origin.y + viewport.maxY) - trackThickness - trackInset
                let trackX = Float(origin.x + viewport.minX) + trackInset
                let trackW = viewW - 2 * trackInset
                list.addRoundedRect(
                    UIRect(x: trackX, y: trackY,
                           width: trackW, height: trackThickness),
                    radius: trackThickness / 2,
                    color: trackColor
                )
                let thumbW = max(trackThickness * 2, trackW * (viewW / contentW))
                let maxOff = contentW - viewW
                let t = maxOff > 0 ? offX / maxOff : 0
                let thumbX = trackX + (trackW - thumbW) * t
                list.addRoundedRect(
                    UIRect(x: thumbX, y: trackY,
                           width: thumbW, height: trackThickness),
                    radius: trackThickness / 2,
                    color: thumbColor
                )
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.overflow = .hidden
        layout.minWidth = 0
        layout.minHeight = 0
    }

    public var _children: [any View] { [content] }

    private func localPoint(x: Float, y: Float, in node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x - parent.contentOffset.x
            origin.y += parent.frame.origin.y - parent.contentOffset.y
            current = parent.parent
        }
        return CGPoint(x: CGFloat(x) - origin.x,
                       y: CGFloat(y) - origin.y)
    }

    private func visibleViewportRect(for node: Node) -> CGRect {
        let nodeOrigin = absoluteOrigin(of: node)
        var visible = CGRect(origin: nodeOrigin, size: node.frame.size)
        var current = node.parent

        while let ancestor = current {
            if ancestor.clipsToBounds {
                let ancestorOrigin = absoluteOrigin(of: ancestor)
                let ancestorFrame = CGRect(origin: ancestorOrigin,
                                           size: ancestor.frame.size)
                visible = visible.intersection(ancestorFrame)
                if visible.isNull { return .zero }
            }
            current = ancestor.parent
        }

        return visible.offsetBy(dx: -nodeOrigin.x, dy: -nodeOrigin.y)
    }

    private func absoluteOrigin(of node: Node) -> CGPoint {
        var origin = node.frame.origin
        var current = node.parent
        while let parent = current {
            origin.x += parent.frame.origin.x - parent.contentOffset.x
            origin.y += parent.frame.origin.y - parent.contentOffset.y
            current = parent.parent
        }
        return origin
    }

    private func scrollableContentSize(for node: Node) -> CGSize {
        var bounds: CGRect = .null
        for child in node.children {
            bounds = bounds.union(contentBounds(for: child, origin: .zero))
        }
        guard !bounds.isNull else { return .zero }
        return CGSize(width: max(0, bounds.maxX),
                      height: max(0, bounds.maxY))
    }

    private func contentBounds(for node: Node, origin: CGPoint) -> CGRect {
        let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        var bounds = frame

        guard !node.clipsToBounds else {
            return bounds
        }

        let childOrigin = CGPoint(x: origin.x + node.frame.origin.x,
                                  y: origin.y + node.frame.origin.y)
        for child in node.children {
            bounds = bounds.union(contentBounds(for: child, origin: childOrigin))
        }
        return bounds
    }

    private func beginScrollbarDrag(axis: _ScrollViewDragAxis,
                                    local: CGPoint,
                                    geometry: _ScrollViewScrollbarGeometry,
                                    node: Node) -> _ScrollViewDragState? {
        let track: CGRect?
        let thumb: CGRect?
        let maxOffset: CGFloat
        let offsetKeyPath: WritableKeyPath<CGPoint, CGFloat>
        let pointer: CGFloat

        switch axis {
        case .vertical:
            track = geometry.verticalTrack
            thumb = geometry.verticalThumb
            maxOffset = geometry.maxOffsetY
            offsetKeyPath = \.y
            pointer = local.y
        case .horizontal:
            track = geometry.horizontalTrack
            thumb = geometry.horizontalThumb
            maxOffset = geometry.maxOffsetX
            offsetKeyPath = \.x
            pointer = local.x
        }

        guard let track, let thumb, maxOffset > 0, track.contains(local) else {
            return nil
        }

        var nextOffset = node.contentOffset
        if !thumb.contains(local) {
            let availableTrack = max(1, trackLength(for: axis, track: track) - trackLength(for: axis, track: thumb))
            let centeredThumbStart = pointer - trackLength(for: axis, track: thumb) / 2
            let rawOffset = ((centeredThumbStart - trackStart(for: axis, track: track))
                             / availableTrack) * maxOffset
            nextOffset[keyPath: offsetKeyPath] = max(0, min(rawOffset, maxOffset))
            node.contentOffset = nextOffset
        }

        return _ScrollViewDragState(
            axis: axis,
            pointerStart: pointer,
            offsetStart: node.contentOffset[keyPath: offsetKeyPath],
            maxOffset: maxOffset,
            trackStart: trackStart(for: axis, track: track),
            trackLength: trackLength(for: axis, track: track),
            thumbLength: trackLength(for: axis, track: thumb)
        )
    }

    private func scrollbarGeometry(for node: Node,
                                   axes: Axis,
                                   trackThickness: Float,
                                   trackInset: Float) -> _ScrollViewScrollbarGeometry {
        let viewport = visibleViewportRect(for: node)
        let viewW = viewport.width
        let viewH = viewport.height
        let contentSize = scrollableContentSize(for: node)
        let contentW = contentSize.width
        let contentH = contentSize.height
        let maxOffsetX = max(0, contentW - viewW)
        let maxOffsetY = max(0, contentH - viewH)
        let thickness = CGFloat(trackThickness)
        let inset = CGFloat(trackInset)

        var verticalTrack: CGRect?
        var verticalThumb: CGRect?
        var horizontalTrack: CGRect?
        var horizontalThumb: CGRect?

        if (axes == .vertical || axes == .both), maxOffsetY > 0, viewH > 0, contentH > 0 {
            let track = CGRect(x: viewport.maxX - thickness - inset,
                               y: viewport.minY + inset,
                               width: thickness,
                               height: max(0, viewH - 2 * inset))
            let thumbH = max(thickness * 2, track.height * (viewH / contentH))
            let t = maxOffsetY > 0 ? node.contentOffset.y / maxOffsetY : 0
            verticalTrack = track
            verticalThumb = CGRect(x: track.minX,
                                   y: track.minY + (track.height - thumbH) * t,
                                   width: track.width,
                                   height: thumbH)
        }

        if (axes == .horizontal || axes == .both), maxOffsetX > 0, viewW > 0, contentW > 0 {
            let track = CGRect(x: viewport.minX + inset,
                               y: viewport.maxY - thickness - inset,
                               width: max(0, viewW - 2 * inset),
                               height: thickness)
            let thumbW = max(thickness * 2, track.width * (viewW / contentW))
            let t = maxOffsetX > 0 ? node.contentOffset.x / maxOffsetX : 0
            horizontalTrack = track
            horizontalThumb = CGRect(x: track.minX + (track.width - thumbW) * t,
                                     y: track.minY,
                                     width: thumbW,
                                     height: track.height)
        }

        return _ScrollViewScrollbarGeometry(verticalTrack: verticalTrack,
                                            verticalThumb: verticalThumb,
                                            horizontalTrack: horizontalTrack,
                                            horizontalThumb: horizontalThumb,
                                            maxOffsetX: maxOffsetX,
                                            maxOffsetY: maxOffsetY)
    }

    private func trackStart(for axis: _ScrollViewDragAxis, track: CGRect) -> CGFloat {
        switch axis {
        case .vertical: return track.minY
        case .horizontal: return track.minX
        }
    }

    private func trackLength(for axis: _ScrollViewDragAxis, track: CGRect) -> CGFloat {
        switch axis {
        case .vertical: return track.height
        case .horizontal: return track.width
        }
    }
}
