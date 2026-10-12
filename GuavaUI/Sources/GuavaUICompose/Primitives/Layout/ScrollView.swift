#if canImport(CoreGraphics)
import CoreGraphics
#endif
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
    static let isHovered = "__scrollview_scrollbar_is_hovered"
    static let chromeOpacity = "__scrollview_scrollbar_chrome_opacity"
    static let contentSize = "__scrollview_content_size"
    static let motion = "__scrollview_motion"
    static let report = "__scrollview_report"
    static let axes = "__scrollview_axes"
    static let pendingOffset = "__scrollview_pending_offset"

    static func motionAnimator(for node: Node,
                               physics: ScrollPhysics) -> ScrollAnimator {
        if let existing = node.attachments[motion] as? ScrollAnimator {
            existing.physics = physics
            return existing
        }
        let animator = ScrollAnimator(physics: physics) { [weak node] offset in
            guard let node else { return }
            node.contentOffset = offset
            (node.attachments[report] as? (Node) -> Void)?(node)
        }
        node.attachments[motion] = animator
        node.addResource(_ScrollMotionLifetime(animator))
        return animator
    }
}

private final class _ScrollMotionLifetime: NodeResource {
    let animator: ScrollAnimator
    init(_ animator: ScrollAnimator) { self.animator = animator }
    func mount(node: Node) {}
    func unmount(node: Node) { animator.cancel() }
}

private struct _ScrollViewScrollbarGeometry {
    var verticalTrack: CGRect?
    var verticalThumb: CGRect?
    var horizontalTrack: CGRect?
    var horizontalThumb: CGRect?
    var maxOffsetX: CGFloat
    var maxOffsetY: CGFloat
}

private struct _ScrollViewContentSizeCache {
    var size: CGSize
    var structureVersion: UInt64
}

public enum ScrollAxis: Sendable, Equatable { case vertical, horizontal, both }

public struct ScrollGeometry: Equatable, Sendable {
    public let offset: CGPoint
    public let viewportSize: CGSize
    public let contentSize: CGSize
}

/// Clipped scrolling with optional offset binding and viewport observations.
/// Content must retain its natural extent on the scrolling axis, e.g. a
/// no-shrink column. Use a virtualized collection for large datasets.
public struct ScrollView<Content: View>: _PrimitiveView {

    /// How the vertical scrollbar relates to the content area.
    /// `.overlay` floats the bar over the content (default; canvas-style
    /// surfaces). `.stable` reserves a fixed lane on the trailing edge — form
    /// surfaces use it so trailing controls (steppers, toggles) are never
    /// covered by the bar or its grab area.
    public enum ScrollbarGutter: Sendable, Equatable { case overlay, stable }

    private struct PaintIdentity: Equatable {
        let axes: ScrollAxis
        let trackColor: Color
        let thumbColor: Color
    }

    public let axes: ScrollAxis
    public let content: Content
    public var onViewportChange: ((ScrollViewport) -> Void)?
    public var scrollOffset: Binding<CGPoint>?
    public let onGeometryChange: ((ScrollGeometry) -> Void)?

    /// Logical points per line increment. Precise point input bypasses this.
    public var wheelStep: Float = 30
    public let consumePolicy: ScrollConsumePolicy
    public let scrollbarGutter: ScrollbarGutter

    /// Width of the reserved lane under `.stable`: track + inset each side.
    static var scrollbarGutterWidth: Float { 12 }

    public init(_ axes: ScrollAxis = .vertical,
                consumePolicy: ScrollConsumePolicy = .whenOffsetChanged,
                scrollbarGutter: ScrollbarGutter = .overlay,
                scrollOffset: Binding<CGPoint>? = nil,
                onViewportChange: ((ScrollViewport) -> Void)? = nil,
                onGeometryChange: ((ScrollGeometry) -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.consumePolicy = consumePolicy
        self.scrollbarGutter = scrollbarGutter
        self.content = content()
        self.scrollOffset = scrollOffset
        self.onViewportChange = onViewportChange
        self.onGeometryChange = onGeometryChange
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.clipsToBounds = true
        return n
    }

    public func _updateNode(_ node: Node) {
        let theme = node.theme
        let report: (Node) -> Void = { node in
            let size = Self.visibleViewportRect(for: node).size
            let snapshot = ScrollViewport(offset: node.contentOffset, size: size)
            if scrollOffset?.wrappedValue != node.contentOffset { scrollOffset?.wrappedValue = node.contentOffset }
            onViewportChange?(snapshot)
            onGeometryChange?(ScrollGeometry(offset: node.contentOffset, viewportSize: size,
                                            contentSize: Self.cachedScrollableContentSize(for: node)))
        }
        node.attachments[_ScrollViewAttachmentKeys.report] = report
        node.attachments[_ScrollViewAttachmentKeys.axes] = axes
        if let desired = scrollOffset?.wrappedValue, desired != node.contentOffset {
            // The child tree still has its previous layout at this point. A
            // new binding offset may target newly grown content, so adopting
            // it against that old range would discard the requested position.
            node.attachments[_ScrollViewAttachmentKeys.pendingOffset] = desired
            node.contentOffset = desired
        }
        let axes = self.axes
        let step = self.wheelStep
        let consumePolicy = self.consumePolicy
        let trackThickness: Float = 8
        let trackInset: Float = 2
        let trackHitSlop: Float = 6

        // Owns this container's motion — inertia, rubber band, return spring.
        // Created once and kept in attachments so a glide or a spring survives
        // recomposes; the report closure above is re-published every update so
        // it always sees the current callbacks instead of a stale one.
        let motion = _ScrollViewAttachmentKeys.motionAnimator(for: node,
                                                             physics: Self.resolvedPhysics(on: node))
        if node.attachments[_ScrollViewAttachmentKeys.pendingOffset] == nil {
            if node.prefersReducedMotion { motion.finishImmediately() }
            Self.publishScrollRange(to: motion, on: node)
            motion.adopt(node.contentOffset)
        }
        node.attachments[ScrollReveal.handlerKey] = { [weak node] (target: CGRect) in
            guard let node else { return }
            Self.publishScrollRange(to: motion, on: node)
            let viewport = Self.visibleViewportRect(for: node).offsetBy(dx: node.absoluteOrigin.x, dy: node.absoluteOrigin.y)
            var offset = node.contentOffset
            if axes != .vertical {
                offset.x += ScrollReveal.delta(start: target.minX, end: target.maxX, viewportStart: viewport.minX, viewportEnd: viewport.maxX)
            }
            if axes != .horizontal {
                offset.y += ScrollReveal.delta(start: target.minY, end: target.maxY, viewportStart: viewport.minY, viewportEnd: viewport.maxY)
            }
            motion.adopt(offset)
        } as (CGRect) -> Void

        if node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] == nil {
            node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] = Float(0)
        }
        if node.attachments[_ScrollViewAttachmentKeys.isHovered] == nil {
            node.attachments[_ScrollViewAttachmentKeys.isHovered] = false
        }
        node.layoutDidUpdate = { node in
            Self.refreshScrollableContentSize(on: node)
            Self.publishScrollRange(to: motion, on: node)
            if let desired = node.attachments.removeValue(forKey: _ScrollViewAttachmentKeys.pendingOffset) as? CGPoint {
                motion.adopt(desired)
            }
            report(node)
        }

        if let registry = InteractionRegistryHolder.current {
            registry.setHover(node) { phase in
                switch phase {
                case .enter:
                    node.attachments[_ScrollViewAttachmentKeys.isHovered] = true
                    Self.setScrollbarChromeVisible(true, on: node)
                case .leave:
                    node.attachments[_ScrollViewAttachmentKeys.isHovered] = false
                    let isDragging = node.attachments[_ScrollViewAttachmentKeys.dragState] != nil
                    Self.setScrollbarChromeVisible(isDragging, on: node)
                }
            }
            registry.setWheel(node, route: .scroll) { event, _ in
                if !event.input.isContinuation, let mouseX = event.mouseX, let mouseY = event.mouseY {
                    let local = Self.localPoint(x: mouseX, y: mouseY, in: node)
                    guard Self.visibleViewportRect(for: node).contains(local) else {
                        return .ignored
                    }
                }
                // Wheel up (positive Y) scrolls content up — i.e. offset.y decreases.
                let viewport = Self.visibleViewportRect(for: node)
                let delta = event.displacement(lineStep: step, pageWidth: Float(viewport.width), pageHeight: Float(viewport.height))
                var dx: Float = axes != .vertical ? -delta.x : 0
                var dy: Float = axes != .horizontal ? -delta.y : 0

                let previousOffset = node.contentOffset

                // Nothing measured yet — keep letting the event bubble.
                guard Self.publishScrollRange(to: motion, on: node) else {
                    return consumePolicy.result(didScroll: false)
                }
                if dx == 0 && dy == 0 {
                    if event.input.phase != .none || event.input.momentumPhase != .none {
                        motion.scrollDirectly(by: .zero)
                    }
                    return consumePolicy.result(didScroll: false)
                }

                // A surface with no overflow cannot consume a wheel or invent
                // elastic space. At a nested edge, hand outward input to the
                // nearest scroll ancestor instead of trapping it in a bounce.
                if motion.maximumOffset.x <= 0 { dx = 0 }
                if motion.maximumOffset.y <= 0 { dy = 0 }
                if consumePolicy == .whenOffsetChanged {
                    if Self.hasScrollAncestor(node, horizontal: true),
                       Self.pointsOutward(dx, at: previousOffset.x, maximum: motion.maximumOffset.x) { dx = 0 }
                    if Self.hasScrollAncestor(node, horizontal: false),
                       Self.pointsOutward(dy, at: previousOffset.y, maximum: motion.maximumOffset.y) { dy = 0 }
                }
                guard dx != 0 || dy != 0 else { return consumePolicy.result(didScroll: false) }

                // Precise input already contains the OS's acceleration and
                // momentum. Line wheels are discrete placements. Neither may
                // infer another fling or start a spring between input packets.
                motion.adopt(previousOffset)
                let nextOffset = motion.scrollDirectly(by: CGPoint(x: CGFloat(dx), y: CGFloat(dy)))
                return consumePolicy.result(didScroll: nextOffset != previousOffset)
            }
            registry.setPointer(node, route: .scrollChrome) { event, pointerPhase, eventPhase in
                switch pointerPhase {
                case .down:
                    guard event.button == .left else { return .ignored }
                    // Pressing anywhere inside the container grabs content that
                    // is still coasting — the same "touch to stop" every
                    // scrollable surface has. Never consumes the event, so a
                    // press that was meant for a child still reaches it.
                    motion.stopCoasting()
                    guard eventPhase == .capture || eventPhase == .target else {
                        return .ignored
                    }
                    let local = Self.localPoint(x: event.x, y: event.y, in: node)
                    let geometry = Self.scrollbarGeometry(for: node,
                                                          axes: axes,
                                                          trackThickness: trackThickness,
                                                          trackInset: trackInset)
                    if let state = Self.beginScrollbarDrag(axis: .vertical,
                                                           local: local,
                                                           geometry: geometry,
                                                           hitSlop: CGFloat(trackHitSlop),
                                                           motion: motion,
                                                           node: node) {
                        node.attachments[_ScrollViewAttachmentKeys.dragState] = state
                        PointerCaptureHolder.current?.acquire(node)
                        Self.setScrollbarChromeVisible(true, on: node)
                        return .handled
                    }
                    if let state = Self.beginScrollbarDrag(axis: .horizontal,
                                                           local: local,
                                                           geometry: geometry,
                                                           hitSlop: CGFloat(trackHitSlop),
                                                           motion: motion,
                                                           node: node) {
                        node.attachments[_ScrollViewAttachmentKeys.dragState] = state
                        PointerCaptureHolder.current?.acquire(node)
                        Self.setScrollbarChromeVisible(true, on: node)
                        return .handled
                    }
                    return .ignored
                case .up:
                    guard node.attachments[_ScrollViewAttachmentKeys.dragState] != nil else {
                        return .ignored
                    }
                    node.attachments[_ScrollViewAttachmentKeys.dragState] = nil
                    PointerCaptureHolder.current?.release()
                    // A thumb release preserves its absolute placement.
                    motion.finishImmediately()
                    let isHovered = node.attachments[_ScrollViewAttachmentKeys.isHovered] as? Bool ?? false
                    Self.setScrollbarChromeVisible(isHovered, on: node)
                    return .handled
                }
            }
            registry.setMotion(node, route: .scrollChrome) { event, _ in
                guard let state = node.attachments[_ScrollViewAttachmentKeys.dragState]
                        as? _ScrollViewDragState else {
                    return .ignored
                }
                guard Self.publishScrollRange(to: motion, on: node) else { return .handled }
                motion.adopt(node.contentOffset)
                let local = Self.localPoint(x: event.x, y: event.y, in: node)
                let pointer = state.axis == .vertical ? local.y : local.x
                let availableTrack = max(1, state.trackLength - state.thumbLength)
                // A scrollbar is an absolute placement, including release.
                let rawOffset = state.offsetStart
                    + ((pointer - state.pointerStart) / availableTrack) * state.maxOffset
                var nextPosition = motion.position
                switch state.axis {
                case .vertical:
                    nextPosition.y = rawOffset
                case .horizontal:
                    nextPosition.x = rawOffset
                }
                motion.scrollDirectly(by: CGPoint(x: nextPosition.x - motion.offset.x,
                                                 y: nextPosition.y - motion.offset.y))
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
        node.updateOverlayDraw(identity: PaintIdentity(axes: axes,
                                                       trackColor: trackColor,
                                                       thumbColor: thumbColor)) { [weak node] list, origin in
            guard let node else { return }
            let viewport = Self.visibleViewportRect(for: node)
            let viewW = Float(viewport.width)
            let viewH = Float(viewport.height)
            let contentSize = Self.cachedScrollableContentSize(for: node)
            let contentW = Float(contentSize.width)
            let contentH = Float(contentSize.height)
            guard contentW > 0 || contentH > 0 else { return }

            // Keep the scroll bounds in step with layout. `update` also covers
            // what this block used to do by hand: when the scrollable range
            // shrinks out from under an offset that still points past the new
            // end (cleared console, filtered list, enlarged viewport), the
            // stranded offset snaps back within the same frame, and any flight
            // aimed at the old range is dropped with it.
            let maxOffsetX = CGFloat(max(0, contentW - viewW))
            let maxOffsetY = CGFloat(max(0, contentH - viewH))
            if let motion = node.attachments[_ScrollViewAttachmentKeys.motion] as? ScrollAnimator {
                motion.update(maximumOffset: CGPoint(x: maxOffsetX, y: maxOffsetY),
                              viewportSize: viewport.size)
            } else if node.contentOffset.x > maxOffsetX || node.contentOffset.y > maxOffsetY {
                node.contentOffset = CGPoint(x: min(node.contentOffset.x, maxOffsetX),
                                             y: min(node.contentOffset.y, maxOffsetY))
            }
            report(node)
            let opacity = node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] as? Float ?? 0
            guard opacity > 0.001 else { return }
            let offX = Float(node.contentOffset.x)
            let offY = Float(node.contentOffset.y)
            let visibleTrackColor = trackColor.multipliedAlpha(opacity)
            let visibleThumbColor = thumbColor.multipliedAlpha(opacity)

            // Vertical bar.
            if (axes == .vertical || axes == .both), contentH > viewH, viewH > 0 {
                let trackX = Float(origin.x + viewport.maxX) - trackThickness - trackInset
                let trackY = Float(origin.y + viewport.minY) + trackInset
                let trackH = viewH - 2 * trackInset
                list.addRoundedRect(
                    UIRect(x: trackX, y: trackY,
                           width: trackThickness, height: trackH),
                    radius: trackThickness / 2,
                    color: visibleTrackColor
                )
                let maxOff = contentH - viewH
                let shrink = Self.thumbShrink(offset: CGFloat(offY),
                                              maximumOffset: CGFloat(maxOff),
                                              viewport: viewport.height)
                let thumbH = max(trackThickness, max(trackThickness * 2, trackH * (viewH / contentH)) * Float(shrink))
                let t = Self.thumbFraction(offset: CGFloat(offY), maximumOffset: CGFloat(maxOff))
                let thumbY = trackY + (trackH - thumbH) * Float(t)
                list.addRoundedRect(
                    UIRect(x: trackX, y: thumbY,
                           width: trackThickness, height: thumbH),
                    radius: trackThickness / 2,
                    color: visibleThumbColor
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
                    color: visibleTrackColor
                )
                let maxOff = contentW - viewW
                let shrink = Self.thumbShrink(offset: CGFloat(offX),
                                              maximumOffset: CGFloat(maxOff),
                                              viewport: viewport.width)
                let thumbW = max(trackThickness, max(trackThickness * 2, trackW * (viewW / contentW)) * Float(shrink))
                let t = Self.thumbFraction(offset: CGFloat(offX), maximumOffset: CGFloat(maxOff))
                let thumbX = trackX + (trackW - thumbW) * Float(t)
                list.addRoundedRect(
                    UIRect(x: thumbX, y: trackY,
                           width: thumbW, height: trackThickness),
                    radius: trackThickness / 2,
                    color: visibleThumbColor
                )
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        layout.overflow = .hidden
        layout.minWidth = 0
        layout.minHeight = 0
        if scrollbarGutter == .stable, axes != .horizontal {
            layout.setPadding(Self.scrollbarGutterWidth, edge: .right)
        } else {
            layout.setPadding(0, edge: .right)
        }
    }

    public var _children: [any View] { [content] }

    /// Push the scrollable range measured right now into `animator`.
    ///
    /// Returns `false` when the content has no measurable extent yet, in which
    /// case there are no bounds to bounce against and callers should leave the
    /// event unconsumed rather than inventing a rubber band out of nothing.
    @discardableResult
    private static func publishScrollRange(to animator: ScrollAnimator,
                                           on node: Node) -> Bool {
        let viewport = visibleViewportRect(for: node).size
        let content = cachedScrollableContentSize(for: node)
        guard content.width > 0 || content.height > 0 else { return false }
        animator.update(maximumOffset: CGPoint(x: max(0, content.width - viewport.width),
                                               y: max(0, content.height - viewport.height)),
                        viewportSize: viewport)
        return true
    }

    private static func resolvedPhysics(on node: Node) -> ScrollPhysics {
        var physics = node.scrollPhysics
        if node.prefersReducedMotion {
            physics.momentum.isEnabled = false
            physics.rubberBand.isEnabled = false
        }
        return physics
    }

    private static func pointsOutward(_ delta: Float, at offset: CGFloat, maximum: CGFloat) -> Bool {
        (delta < 0 && offset <= 0) || (delta > 0 && offset >= maximum)
    }

    private static func hasScrollAncestor(_ node: Node, horizontal: Bool) -> Bool {
        var parent = node.parent
        while let ancestor = parent {
            if let axes = ancestor.attachments[_ScrollViewAttachmentKeys.axes] as? ScrollAxis,
               horizontal ? axes != .vertical : axes != .horizontal { return true }
            parent = ancestor.parent
        }
        return false
    }

    private static func localPoint(x: Float, y: Float, in node: Node) -> CGPoint {
        node.convertFromWindow(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }

    /// Thumb travel fraction, held inside the track even while a rubber band
    /// pushes the offset past either end.
    private static func thumbFraction(offset: CGFloat, maximumOffset: CGFloat) -> CGFloat {
        guard maximumOffset > 0 else { return 0 }
        return max(0, min(1, offset / maximumOffset))
    }

    /// Thumb length multiplier while overscrolled. The bar shrinks as content
    /// is pulled past the end so it keeps reading as "how much of the content
    /// is visible", instead of sitting at full length beyond the track.
    private static func thumbShrink(offset: CGFloat,
                                    maximumOffset: CGFloat,
                                    viewport: CGFloat) -> CGFloat {
        guard viewport > 0 else { return 1 }
        let excess = max(-offset, offset - maximumOffset)
        guard excess > 0 else { return 1 }
        return max(0.4, 1 - excess / viewport)
    }

    private static func visibleViewportRect(for node: Node) -> CGRect {
        let nodeOrigin = node.absoluteOrigin
        var visible = CGRect(origin: nodeOrigin, size: node.frame.size)
        var current = node.parent

        while let ancestor = current {
            if ancestor.clipsToBounds {
                visible = visible.intersection(ancestor.absoluteFrame)
                if visible.isNull { return .zero }
            }
            current = ancestor.parent
        }

        return visible.offsetBy(dx: -nodeOrigin.x, dy: -nodeOrigin.y)
    }

    private static func cachedScrollableContentSize(for node: Node) -> CGSize {
        if let cached = node.attachments[_ScrollViewAttachmentKeys.contentSize]
            as? _ScrollViewContentSizeCache,
           cached.structureVersion == node.subtreeStructureVersion {
            return cached.size
        }
        return refreshScrollableContentSize(on: node)
    }

    @discardableResult
    private static func refreshScrollableContentSize(on node: Node) -> CGSize {
        let next = scrollableContentSize(for: node)
        let previous = (node.attachments[_ScrollViewAttachmentKeys.contentSize]
            as? _ScrollViewContentSizeCache)?.size
        if previous != next {
            node.markRenderDirty(reason: .styleSet(field: "scrollContentSize"))
        }
        node.attachments[_ScrollViewAttachmentKeys.contentSize] = _ScrollViewContentSizeCache(
            size: next,
            structureVersion: node.subtreeStructureVersion
        )

        let viewport = visibleViewportRect(for: node).size
        let maxOffsetX = max(0, next.width - viewport.width)
        let maxOffsetY = max(0, next.height - viewport.height)
        if let motion = node.attachments[_ScrollViewAttachmentKeys.motion] as? ScrollAnimator {
            motion.update(maximumOffset: CGPoint(x: maxOffsetX, y: maxOffsetY),
                          viewportSize: viewport)
        } else if node.contentOffset.x > maxOffsetX || node.contentOffset.y > maxOffsetY {
            node.contentOffset = CGPoint(x: min(node.contentOffset.x, maxOffsetX),
                                         y: min(node.contentOffset.y, maxOffsetY))
        }
        return next
    }

    private static func scrollableContentSize(for node: Node) -> CGSize {
        var bounds: CGRect = .null
        for child in node.children {
            bounds = bounds.union(contentBounds(for: child, origin: .zero))
        }
        guard !bounds.isNull else { return .zero }
        return CGSize(width: max(0, bounds.maxX),
                      height: max(0, bounds.maxY))
    }

    private static func setScrollbarChromeVisible(_ visible: Bool, on node: Node) {
        let current = node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] as? Float ?? 0
        let target: Float = visible ? 1 : 0
        withAnimation(.semantic(.fast, in: node.theme)) {
            node.animatableSet(propertyKey: _ScrollViewAttachmentKeys.chromeOpacity,
                               current: current,
                               to: target) { [weak node] opacity in
                guard let node else { return }
                node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] = opacity
                node.markRenderDirty(reason: .styleSet(field: "scrollbarChromeOpacity"))
            }
        }
    }

    private static func contentBounds(for node: Node, origin: CGPoint) -> CGRect {
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

    private static func beginScrollbarDrag(axis: _ScrollViewDragAxis,
                                           local: CGPoint,
                                           geometry: _ScrollViewScrollbarGeometry,
                                           hitSlop: CGFloat,
                                           motion: ScrollAnimator,
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

        guard let track, let thumb, maxOffset > 0 else {
            return nil
        }
        let hitTrack = expandedHitTrack(axis: axis, track: track, hitSlop: hitSlop)
        guard hitTrack.contains(local) else {
            return nil
        }

        // A grab anywhere cancels whatever the previous gesture left behind —
        // glide or return spring alike. Tracking starts empty, so this drag
        // cannot inherit the previous one's velocity either.
        motion.adopt(node.contentOffset)

        if !thumb.contains(local) {
            let availableTrack = max(1, Self.trackLength(for: axis, track: track) - Self.trackLength(for: axis, track: thumb))
            let centeredThumbStart = pointer - Self.trackLength(for: axis, track: thumb) / 2
            let rawOffset = ((centeredThumbStart - Self.trackStart(for: axis, track: track))
                             / availableTrack) * maxOffset
            var nextOffset = node.contentOffset
            nextOffset[keyPath: offsetKeyPath] = max(0, min(rawOffset, maxOffset))
            node.contentOffset = nextOffset
            motion.adopt(nextOffset)
        }

        return _ScrollViewDragState(
            axis: axis,
            pointerStart: pointer,
            offsetStart: node.contentOffset[keyPath: offsetKeyPath],
            maxOffset: maxOffset,
            trackStart: Self.trackStart(for: axis, track: track),
            trackLength: Self.trackLength(for: axis, track: track),
            thumbLength: Self.trackLength(for: axis, track: thumb)
        )
    }

    private static func scrollbarGeometry(for node: Node,
                                          axes: ScrollAxis,
                                          trackThickness: Float,
                                          trackInset: Float) -> _ScrollViewScrollbarGeometry {
        let viewport = visibleViewportRect(for: node)
        let viewW = viewport.width
        let viewH = viewport.height
        let contentSize = cachedScrollableContentSize(for: node)
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
            let shrink = thumbShrink(offset: node.contentOffset.y,
                                     maximumOffset: maxOffsetY,
                                     viewport: viewH)
            let thumbH = max(thickness, max(thickness * 2, track.height * (viewH / contentH)) * shrink)
            let t = thumbFraction(offset: node.contentOffset.y, maximumOffset: maxOffsetY)
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
            let shrink = thumbShrink(offset: node.contentOffset.x,
                                     maximumOffset: maxOffsetX,
                                     viewport: viewW)
            let thumbW = max(thickness, max(thickness * 2, track.width * (viewW / contentW)) * shrink)
            let t = thumbFraction(offset: node.contentOffset.x, maximumOffset: maxOffsetX)
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

    private static func trackStart(for axis: _ScrollViewDragAxis, track: CGRect) -> CGFloat {
        switch axis {
        case .vertical: return track.minY
        case .horizontal: return track.minX
        }
    }

    private static func trackLength(for axis: _ScrollViewDragAxis, track: CGRect) -> CGFloat {
        switch axis {
        case .vertical: return track.height
        case .horizontal: return track.width
        }
    }

    private static func expandedHitTrack(axis: _ScrollViewDragAxis,
                                         track: CGRect,
                                         hitSlop: CGFloat) -> CGRect {
        switch axis {
        case .vertical:
            return track.insetBy(dx: -hitSlop, dy: 0)
        case .horizontal:
            return track.insetBy(dx: 0, dy: -hitSlop)
        }
    }
}

public struct ScrollViewport: Equatable {
    public var offset: CGPoint
    public var size: CGSize
    public init(offset: CGPoint, size: CGSize) { self.offset = offset; self.size = size }
}
