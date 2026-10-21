#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
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

private struct _ScrollViewContentDragState {
    var start: CGPoint
    var offsetStart: CGPoint
    var dragged = false
}

private enum _ScrollViewAttachmentKeys {
    static let dragState = "__scrollview_scrollbar_drag_state"
    static let contentDragState = "__scrollview_content_drag_state"
    static let isHovered = "__scrollview_scrollbar_is_hovered"
    static let chromeOpacity = "__scrollview_scrollbar_chrome_opacity"
    static let touchIndicator = "__scrollview_touch_indicator"
    static let contentSize = "__scrollview_content_size"
    static let motion = "__scrollview_motion"
    static let report = "__scrollview_report"
    static let pendingOffset = "__scrollview_pending_offset"
    static let timedRequest = "__scrollview_timed_request"
    static let timedRequestID = "__scrollview_timed_request_id"
    static let anchorMarker = "__scrollview_anchor"
    static let anchorState = "__scrollview_anchor_state"

    static func motionAnimator(for node: Node,
                               physics: ScrollPhysics) -> ScrollAnimator {
        if let existing = node.attachments[motion] as? ScrollAnimator {
            existing.physics = physics
            return existing
        }
        let animator = ScrollAnimator(physics: physics) { [weak node] offset in
            guard let node else { return }
            if node.contentOffset != offset, node.attachments[touchIndicator] as? Bool == true {
                flashTouchIndicator(on: node)
            }
            node.contentOffset = offset
            (node.attachments[report] as? (Node) -> Void)?(node)
        }
        node.attachments[motion] = animator
        node.addResource(_ScrollMotionLifetime(animator))
        return animator
    }

    /// Touch surfaces have no hover to reveal chrome. Like platform scroll
    /// indicators, the thin thumb appears while content moves and fades once
    /// it rests. Reduced motion keeps it visible instead of animating it out.
    static func flashTouchIndicator(on node: Node) {
        let apply: (Float) -> Void = { [weak node] opacity in
            guard let node else { return }
            node.attachments[chromeOpacity] = opacity
            node.markRenderDirty(reason: .styleSet(field: "scrollbarChromeOpacity"))
        }
        node.animatableSet(propertyKey: chromeOpacity, current: node.attachments[chromeOpacity] as? Float ?? 0,
                           to: Float(1), apply: apply)
        guard !node.prefersReducedMotion else { return }
        withAnimation(Animation(duration: 0.3, curve: .easeOut, delay: 0.7)) {
            node.animatableSet(propertyKey: chromeOpacity, current: Float(1), to: Float(0), apply: apply)
        }
    }
}

private final class _ScrollMotionLifetime: NodeResource {
    let animator: ScrollAnimator
    init(_ animator: ScrollAnimator) { self.animator = animator }
    func mount(node: Node) {}
    func unmount(node: Node) { animator.cancel() }
}

private struct _ScrollViewAnchorState {
    var nodeID: ObjectIdentifier
    var relative: CGPoint
    var contentSize: CGSize
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

/// One declarative programmatic scroll. A new identity starts a new animation;
/// a duration of zero (or reduced motion) snaps immediately.
public struct ScrollRequest: Equatable, Sendable {
    public let id: UUID
    public let offset: CGPoint
    public let duration: Double

    public init(offset: CGPoint, duration: Double = 0.32) {
        self.id = UUID()
        self.offset = CGPoint(x: offset.x.isFinite ? offset.x : 0,
                              y: offset.y.isFinite ? offset.y : 0)
        self.duration = duration.isFinite ? max(0, duration) : 0
    }
}

public struct ScrollGeometry: Equatable, Sendable {
    public let offset: CGPoint
    public let viewportSize: CGSize
    public let contentSize: CGSize
}

/// The full-width box that normalizes a horizontal origin. It positions
/// content; its own (percent-resolved) width is not content to scroll to.
private let scrollHorizontalOriginRole = "scroll-horizontal-origin"

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
        let touchIndicator: Bool
    }

    public let axes: ScrollAxis
    public let content: Content
    public var onViewportChange: ((ScrollViewport) -> Void)?
    public var scrollOffset: Binding<CGPoint>?
    public let onGeometryChange: ((ScrollGeometry) -> Void)?
    public let accessibilityLabel: String?
    public let scrollRequest: ScrollRequest?
    /// Embedded one-line controls merge text into their owning row. An idle
    /// viewport stays transparent to accessibility; overflow exposes scrolling.
    var combinesAccessibility = false
    /// A fallback scroller around content that usually fits (a portal entry)
    /// clips only while it actually overflows, so a floating panel inside
    /// keeps its shadow.
    var clipsOnlyOverflow = false

    /// Logical points per line increment. Precise point input bypasses this.
    public var wheelStep: Float = 30
    public let consumePolicy: ScrollConsumePolicy
    public let scrollbarGutter: ScrollbarGutter

    /// Width of the reserved lane under `.stable`: track + inset each side.
    static var scrollbarGutterWidth: Float { 12 }

    /// The lane `.stable` actually reserves on `surface`. Touch-only surfaces
    /// overlay a thin indicator instead, so containers sizing rows beside the
    /// lane must ask for the surface rather than assume the constant.
    static func stableGutterWidth(on surface: UIEnvironment) -> Float {
        surface.supportsHover ? scrollbarGutterWidth : 0
    }

    public init(_ axes: ScrollAxis = .vertical,
                consumePolicy: ScrollConsumePolicy = .whenScrollable,
                scrollbarGutter: ScrollbarGutter = .overlay,
                scrollOffset: Binding<CGPoint>? = nil,
                onViewportChange: ((ScrollViewport) -> Void)? = nil,
                onGeometryChange: ((ScrollGeometry) -> Void)? = nil,
                accessibilityLabel: String? = nil,
                scrollRequest: ScrollRequest? = nil,
                @ViewBuilder content: () -> Content) {
        self.axes = axes
        self.consumePolicy = consumePolicy
        self.scrollbarGutter = scrollbarGutter
        self.content = content()
        self.scrollOffset = scrollOffset
        self.onViewportChange = onViewportChange
        self.onGeometryChange = onGeometryChange
        self.accessibilityLabel = accessibilityLabel
        self.scrollRequest = scrollRequest
    }

    private static func updateAccessibility(node: Node, label: String?, axes: ScrollAxis, combines: Bool) {
        let size = visibleViewportRect(for: node).size
        let content = cachedScrollableContentSize(for: node)
        let maxX = max(0, content.width - size.width)
        let maxY = max(0, content.height - size.height)
        if combines && maxX <= 0 && maxY <= 0 { node.accessibility = nil; return }
        let x = maxX > 0 ? min(100, max(0, Int((node.contentOffset.x / maxX * 100).rounded()))) : 0
        let y = maxY > 0 ? min(100, max(0, Int((node.contentOffset.y / maxY * 100).rounded()))) : 0
        let value: String
        switch axes {
        case .vertical: value = "\(y)%"
        case .horizontal: value = "\(x)%"
        case .both: value = "Horizontal \(x)%, vertical \(y)%"
        }
        node.accessibility = AccessibilitySemantics(.scrollArea) {
            $0.label = label ?? (combines ? "" : "Scrollable content")
            $0.combinesChildren = combines
            $0.value = value
            $0.help = "Use arrow keys, Page Up/Down, Home and End to scroll"
        }
    }

    private static func pageScroll(_ node: Node, axes: ScrollAxis, forward: Bool) {
        guard let motion = node.attachments[_ScrollViewAttachmentKeys.motion] as? ScrollAnimator else { return }
        let viewport = visibleViewportRect(for: node).size
        let dx = (axes == .vertical ? 0 : max(40, viewport.width - 40)) * (forward ? 1 : -1)
        let dy = (axes == .horizontal ? 0 : max(40, viewport.height - 40)) * (forward ? 1 : -1)
        motion.scrollDirectly(by: CGPoint(x: dx, y: dy))
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.clipsToBounds = true
        n.isScrollViewport = axes != .horizontal
        return n
    }

    public func _updateNode(_ node: Node) {
        node.isScrollViewport = axes != .horizontal
        let theme = node.theme
        let report: (Node) -> Void = { node in
            let size = Self.visibleViewportRect(for: node).size
            let snapshot = ScrollViewport(offset: node.contentOffset, size: size)
            if scrollOffset?.wrappedValue != node.contentOffset { scrollOffset?.wrappedValue = node.contentOffset }
            onViewportChange?(snapshot)
            onGeometryChange?(ScrollGeometry(offset: node.contentOffset, viewportSize: size,
                                            contentSize: Self.cachedScrollableContentSize(for: node)))
            Self.updateAccessibility(node: node, label: accessibilityLabel, axes: axes, combines: combinesAccessibility)
            if let motion = node.attachments[_ScrollViewAttachmentKeys.motion] as? ScrollAnimator {
                Self.updateAnchor(on: node, motion: motion, axes: axes)
            }
        }
        node.attachments[_ScrollViewAttachmentKeys.report] = report
        Self.updateAccessibility(node: node, label: accessibilityLabel, axes: axes, combines: combinesAccessibility)
        node.accessibilityActions.increment = { [weak node] in
            guard let node else { return }
            Self.pageScroll(node, axes: axes, forward: true)
        }
        node.accessibilityActions.decrement = { [weak node] in
            guard let node else { return }
            Self.pageScroll(node, axes: axes, forward: false)
        }
        if let desired = scrollOffset?.wrappedValue, desired != node.contentOffset {
            // The child tree still has its previous layout at this point. A
            // new binding offset may target newly grown content, so adopting
            // it against that old range would discard the requested position.
            node.attachments[_ScrollViewAttachmentKeys.pendingOffset] = desired
            node.contentOffset = desired
        }
        if let request = scrollRequest,
           node.attachments[_ScrollViewAttachmentKeys.timedRequestID] as? UUID != request.id {
            node.attachments[_ScrollViewAttachmentKeys.timedRequestID] = request.id
            node.attachments[_ScrollViewAttachmentKeys.timedRequest] = request
        }
        let axes = self.axes
        let step = self.wheelStep
        let consumePolicy = self.consumePolicy
        // Touch-only surfaces have no hover and no pointer to grab a thumb, so
        // they get a thin overlay indicator and never reserve a gutter.
        let touchIndicator = !node.supportsControlHover
        node.attachments[_ScrollViewAttachmentKeys.touchIndicator] = touchIndicator
        let gutter: Float = scrollbarGutter == .stable && !touchIndicator ? Self.scrollbarGutterWidth : 0
        node.layoutNode?.setPadding(axes != .horizontal ? gutter : 0, edge: .right)
        node.layoutNode?.setPadding(axes != .vertical ? gutter : 0, edge: .bottom)
        let trackThickness: Float = touchIndicator ? 3 : 8
        let trackInset: Float = touchIndicator ? 3 : 2
        let trackHitSlop: Float = 6

        // Owns this container's motion — inertia, rubber band, return spring.
        // Created once and kept in attachments so a glide or a spring survives
        // recomposes; the report closure above is re-published every update so
        // it always sees the current callbacks instead of a stale one.
        let motion = _ScrollViewAttachmentKeys.motionAnimator(for: node,
                                                             physics: Self.resolvedPhysics(on: node))
        let supportsTouchDrag = node.compositionValue(of: SurfaceEnvironment.key).input.contains(.touch)
        if node.attachments[_ScrollViewAttachmentKeys.pendingOffset] == nil {
            if node.prefersReducedMotion { motion.finishImmediately() }
            Self.publishScrollRange(to: motion, on: node)
            motion.adopt(node.contentOffset)
        }
        if let request = node.attachments[_ScrollViewAttachmentKeys.timedRequest] as? ScrollRequest {
            if motion.maximumOffset == .zero, request.offset.x != 0 || request.offset.y != 0 {
                // Content is not measured yet; keep the request for the first
                // layout pass instead of clamping it to zero.
                node.markDirty()
            } else {
                node.attachments.removeValue(forKey: _ScrollViewAttachmentKeys.timedRequest)
                var target = CGPoint(x: min(max(0, request.offset.x), motion.maximumOffset.x),
                                     y: min(max(0, request.offset.y), motion.maximumOffset.y))
                if axes == .vertical { target.x = 0 }
                if axes == .horizontal { target.y = 0 }
                if node.prefersReducedMotion {
                    motion.adopt(target)
                } else {
                    motion.scroll(to: target, duration: request.duration)
                }
                report(node)
            }
        }
        node.scrollReveal = { [weak node] (target: CGRect) in
            guard let node else { return }
            let previousOffset = node.contentOffset
            // A descendant can reveal itself during layout write-back, before
            // this viewport's hook publishes its new range. The node structure
            // may be unchanged even though the content has grown or reflowed.
            Self.refreshScrollableContentSize(on: node)
            Self.publishScrollRange(to: motion, on: node)
            // Updating a smaller range can clamp the offset. The caller's
            // window-space rectangle was measured before that clamp.
            let target = target.offsetBy(dx: previousOffset.x - node.contentOffset.x,
                                         dy: previousOffset.y - node.contentOffset.y)
            let viewport = Self.visibleViewportRect(for: node).offsetBy(dx: node.absoluteOrigin.x, dy: node.absoluteOrigin.y)
            var offset = node.contentOffset
            if axes != .vertical {
                offset.x += ScrollReveal.delta(start: target.minX, end: target.maxX, viewportStart: viewport.minX, viewportEnd: viewport.maxX)
            }
            if axes != .horizontal {
                offset.y += ScrollReveal.delta(start: target.minY, end: target.maxY, viewportStart: viewport.minY, viewportEnd: viewport.maxY)
            }
            motion.adopt(offset)
        }

        if node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] == nil {
            node.attachments[_ScrollViewAttachmentKeys.chromeOpacity] = Float(0)
        }
        if node.attachments[_ScrollViewAttachmentKeys.isHovered] == nil {
            node.attachments[_ScrollViewAttachmentKeys.isHovered] = false
        }
        node.layoutDidUpdate = { node in
            // Retained responsive panes suppress Yoga layout for the whole
            // subtree. Zero frames are not new scroll geometry: publishing
            // them would clamp the user's saved offset to zero while hidden.
            guard !Self.isLayoutSuppressed(node) else { return }
            Self.refreshScrollableContentSize(on: node)
            Self.publishScrollRange(to: motion, on: node)
            Self.updateAnchor(on: node, motion: motion, axes: axes)
            ScrollKeyboardFocus.update(node, canScroll: motion.maximumOffset.x > 0.5 || motion.maximumOffset.y > 0.5)
            if clipsOnlyOverflow {
                let overflows = motion.maximumOffset.x > 0.5 || motion.maximumOffset.y > 0.5
                node.clipsToBounds = overflows
            }
            if let desired = node.attachments.removeValue(forKey: _ScrollViewAttachmentKeys.pendingOffset) as? CGPoint {
                motion.adopt(desired)
            }
            if let request = node.attachments.removeValue(forKey: _ScrollViewAttachmentKeys.timedRequest) as? ScrollRequest {
                var target = CGPoint(x: min(max(0, request.offset.x), motion.maximumOffset.x),
                                     y: min(max(0, request.offset.y), motion.maximumOffset.y))
                if axes == .vertical { target.x = 0 }
                if axes == .horizontal { target.y = 0 }
                if node.prefersReducedMotion {
                    motion.adopt(target)
                } else {
                    motion.scroll(to: target, duration: request.duration)
                }
            }
            report(node)
        }

        if let registry = InteractionRegistryHolder.current {
            registry.setHover(node) { phase in
                switch phase {
                case .enter:
                    node.attachments[_ScrollViewAttachmentKeys.isHovered] = true
                    guard !touchIndicator else { return }
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
                    return consumePolicy.result(didScroll: false, canScroll: false)
                }
                let horizontalOverflow = axes != .vertical && motion.maximumOffset.x > 0
                let verticalOverflow = axes != .horizontal && motion.maximumOffset.y > 0
                if dx == 0 && dy == 0 {
                    if event.input.phase != .none || event.input.momentumPhase != .none {
                        motion.scrollDirectly(by: .zero)
                    }
                    // Zero-delta lifecycle packets cannot identify an axis.
                    // An existing phased stream already retains its owner.
                    return consumePolicy.result(didScroll: false, canScroll: false)
                }

                // Overflow owns the input at either bound. An empty axis still
                // passes through, so a horizontal child does not trap a vertical
                // parent's input. Explicit .whenOffsetChanged enables chaining.
                if !horizontalOverflow { dx = 0 }
                if !verticalOverflow { dy = 0 }
                guard dx != 0 || dy != 0 else {
                    return consumePolicy.result(didScroll: false, canScroll: false)
                }

                // Precise input already contains the OS's acceleration and
                // momentum. Line wheels are discrete placements. Neither may
                // infer another fling or start a spring between input packets.
                motion.adopt(previousOffset)
                let nextOffset = motion.scrollDirectly(by: CGPoint(x: CGFloat(dx), y: CGFloat(dy)))
                return consumePolicy.result(didScroll: nextOffset != previousOffset, canScroll: true)
            }
            registry.setKey(node, route: .scroll) { event, phase in
                guard phase == .target else { return .ignored }
                guard Self.publishScrollRange(to: motion, on: node) else { return .ignored }
                let viewport = Self.visibleViewportRect(for: node)
                let line: CGFloat = 40
                let page = max(line, viewport.height * 0.9)
                var dx: CGFloat = 0
                var dy: CGFloat = 0
                switch event.scancode {
                case Scancode.arrowUp:
                    dy = -line
                case Scancode.arrowDown:
                    dy = line
                case Scancode.arrowLeft:
                    dx = -line
                case Scancode.arrowRight:
                    dx = line
                case Scancode.pageUp:
                    dy = -page
                case Scancode.pageDown:
                    dy = page
                case Scancode.home:
                    dx = -motion.offset.x
                    dy = -motion.offset.y
                case Scancode.end:
                    dx = motion.maximumOffset.x - motion.offset.x
                    dy = motion.maximumOffset.y - motion.offset.y
                default:
                    return .ignored
                }
                if axes == .vertical { dx = 0 }
                if axes == .horizontal { dy = 0 }
                guard dx != 0 || dy != 0 else { return .ignored }
                let previous = motion.offset
                motion.stopCoasting()
                let next = motion.scrollDirectly(by: CGPoint(x: dx, y: dy))
                return next != previous ? .handled : .ignored
            }
            registry.setPointer(node, route: .scrollChrome) { event, pointerPhase, eventPhase in
                switch pointerPhase {
                case .down:
                    guard event.button == .left else { return .ignored }
                    let local = Self.localPoint(x: event.x, y: event.y, in: node)
                    // Chrome routes are global. Its expanded hit lane must
                    // remain inside this viewport and every ancestor clip.
                    guard Self.visibleViewportRect(for: node).contains(local) else { return .ignored }
                    // Pressing anywhere inside the container grabs content that
                    // is still coasting — the same "touch to stop" every
                    // scrollable surface has. Never consumes the event, so a
                    // press that was meant for a child still reaches it.
                    motion.stopCoasting()
                    guard eventPhase == .capture || eventPhase == .target else {
                        return .ignored
                    }
                    let geometry = Self.scrollbarGeometry(for: node,
                                                          axes: axes,
                                                          trackThickness: trackThickness,
                                                          trackInset: trackInset)
                    if !touchIndicator, let state = Self.beginScrollbarDrag(axis: .vertical,
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
                    if !touchIndicator, let state = Self.beginScrollbarDrag(axis: .horizontal,
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
                    if supportsTouchDrag {
                        node.attachments[_ScrollViewAttachmentKeys.contentDragState] =
                            _ScrollViewContentDragState(start: local, offsetStart: node.contentOffset)
                    }
                    return .ignored
                case .up:
                    if node.attachments[_ScrollViewAttachmentKeys.dragState] != nil {
                        node.attachments[_ScrollViewAttachmentKeys.dragState] = nil
                        PointerCaptureHolder.current?.release()
                        // A thumb release preserves its absolute placement.
                        motion.finishImmediately()
                        let isHovered = node.attachments[_ScrollViewAttachmentKeys.isHovered] as? Bool ?? false
                        Self.setScrollbarChromeVisible(isHovered, on: node)
                        return .handled
                    }
                    if let state = node.attachments[_ScrollViewAttachmentKeys.contentDragState]
                        as? _ScrollViewContentDragState {
                        node.attachments[_ScrollViewAttachmentKeys.contentDragState] = nil
                        guard state.dragged else { return .ignored }
                        PointerCaptureHolder.current?.release()
                        motion.settle()
                        return .handled
                    }
                    return .ignored
                }
            }
            registry.setMotion(node, route: .scrollChrome) { event, phase in
                // Let the deepest content gesture claim a touch drag first.
                // Ancestors also observed the down event; handling capture
                // here would steal nested scrolling, swipes and refreshes.
                if phase == .capture,
                   node.attachments[_ScrollViewAttachmentKeys.dragState] == nil { return .ignored }
                if let state = node.attachments[_ScrollViewAttachmentKeys.contentDragState]
                    as? _ScrollViewContentDragState {
                    let local = Self.localPoint(x: event.x, y: event.y, in: node)
                    let dx = local.x - state.start.x
                    let dy = local.y - state.start.y
                    if !state.dragged {
                        let along = axes == .horizontal ? abs(dx) : axes == .vertical ? abs(dy) : max(abs(dx), abs(dy))
                        let across = axes == .horizontal ? abs(dy) : axes == .vertical ? abs(dx) : 0
                        guard along >= 4, along >= across else { return .ignored }
                    }
                    var nextState = state
                    if !nextState.dragged {
                        nextState.dragged = true
                        PointerCaptureHolder.current?.acquire(node)
                    }
                    node.attachments[_ScrollViewAttachmentKeys.contentDragState] = nextState
                    _ = motion.move(to: CGPoint(
                        x: axes == .vertical ? state.offsetStart.x : state.offsetStart.x - dx,
                        y: axes == .horizontal ? state.offsetStart.y : state.offsetStart.y - dy))
                    return .handled
                }
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
        // A touch indicator is a thumb only; it has no track to aim at.
        let trackColor = touchIndicator ? Color.clear : theme.colors.surfaceVariant
        let thumbColor = touchIndicator ? theme.colors.onSurfaceMuted.multipliedAlpha(0.6) : theme.colors.onSurfaceMuted
        node.updateOverlayDraw(identity: PaintIdentity(axes: axes,
                                                       trackColor: trackColor,
                                                       thumbColor: thumbColor,
                                                       touchIndicator: touchIndicator)) { [weak node] list, origin in
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

            // Sub-point overflow is layout rounding, not content to scroll to;
            // drawing a bar for it puts a scrollbar under every fitting strip.
            let overflowTolerance: Float = 0.5

            // Vertical bar.
            if (axes == .vertical || axes == .both), contentH > viewH + overflowTolerance, viewH > 0 {
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
            if (axes == .horizontal || axes == .both), contentW > viewW + overflowTolerance, viewW > 0 {
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
        // Gutter padding depends on the surface input and is set in `_updateNode`.
    }

    public var _children: [any View] {
        if axes == .vertical { return [content] }
        // Yoga right-aligns an oversized RTL child at a negative x. Scrolling
        // uses physical offsets starting at zero, so normalize that origin
        // while retaining the content's inherited logical direction.
        return [HorizontalScrollOrigin { content }.frame(width: .percent(100))
            .layoutRole(scrollHorizontalOriginRole)]
    }

    /// Push the scrollable range measured right now into `animator`.
    ///
    /// Returns `false` when the content has no measurable extent yet, in which
    /// case there are no bounds to bounce against and callers should leave the
    /// event unconsumed rather than inventing a rubber band out of nothing.
    @discardableResult
    private static func publishScrollRange(to animator: ScrollAnimator,
                                           on node: Node) -> Bool {
        guard !isLayoutSuppressed(node), node.frame.width > 0, node.frame.height > 0 else { return false }
        let viewport = visibleViewportRect(for: node).size
        let content = cachedScrollableContentSize(for: node)
        guard content.width > 0 || content.height > 0 else { return false }
        animator.update(maximumOffset: CGPoint(x: max(0, content.width - viewport.width),
                                               y: max(0, content.height - viewport.height)),
                        viewportSize: viewport)
        return true
    }

    private static func isLayoutSuppressed(_ node: Node) -> Bool {
        var ancestor: Node? = node
        while let candidate = ancestor {
            if candidate.layoutNode?.display == Display.none { return true }
            ancestor = candidate.parent
        }
        return false
    }

    private static func resolvedPhysics(on node: Node) -> ScrollPhysics {
        var physics = node.scrollPhysics
        if node.prefersReducedMotion {
            physics.momentum.isEnabled = false
            physics.rubberBand.isEnabled = false
        }
        return physics
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

    private static func updateAnchor(on node: Node, motion: ScrollAnimator, axes: ScrollAxis) {
        var anchors: [Node] = []
        func collect(_ candidate: Node) {
            if candidate.attachments[_ScrollViewAttachmentKeys.anchorMarker] != nil {
                anchors.append(candidate)
            }
            for child in candidate.children { collect(child) }
        }
        collect(node)
        guard !anchors.isEmpty else {
            node.attachments.removeValue(forKey: _ScrollViewAttachmentKeys.anchorState)
            return
        }
        let origin = node.absoluteOrigin
        let viewportHeight = max(1, visibleViewportRect(for: node).height)
        func relative(_ anchor: Node) -> CGPoint {
            CGPoint(x: anchor.absoluteFrame.minX - origin.x,
                    y: anchor.absoluteFrame.minY - origin.y)
        }
        func intersectsViewport(_ anchor: Node) -> Bool {
            let point = relative(anchor)
            return point.y + anchor.absoluteFrame.height > 0 && point.y < viewportHeight
        }
        let visibleAnchors = anchors.filter(intersectsViewport)
        let fullyVisible = visibleAnchors.filter { relative($0).y >= 0 }
        let selected = fullyVisible.min { relative($0).y < relative($1).y }
            ?? visibleAnchors.max { relative($0).y < relative($1).y }
            ?? anchors[0]
        let content = cachedScrollableContentSize(for: node)
        var baseline = relative(selected)
        if let previous = node.attachments[_ScrollViewAttachmentKeys.anchorState] as? _ScrollViewAnchorState,
           previous.contentSize != content,
           let old = anchors.first(where: { ObjectIdentifier($0) == previous.nodeID }) {
            let delta = CGPoint(x: relative(old).x - previous.relative.x,
                                y: relative(old).y - previous.relative.y)
            var offset = node.contentOffset
            if axes != .vertical { offset.x += delta.x }
            if axes != .horizontal { offset.y += delta.y }
            motion.adopt(offset)
            baseline = previous.relative
        }
        node.attachments[_ScrollViewAttachmentKeys.anchorState] = _ScrollViewAnchorState(
            nodeID: ObjectIdentifier(selected), relative: baseline, contentSize: content)
    }

    static func visibleViewportRect(for node: Node) -> CGRect {
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

    static func cachedScrollableContentSize(for node: Node) -> CGSize {
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
        guard node.isLayoutVisible else { return .null }
        let frame = node.frame.offsetBy(dx: origin.x, dy: origin.y)
        let isOrigin = node.attachments[LayoutDebugAttachmentKey.layoutRole] as? String == scrollHorizontalOriginRole
        var bounds = isOrigin ? CGRect.null : frame

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


public extension View {
    /// Marks this subtree as a scroll anchor. When content size changes,
    /// ScrollView keeps the topmost visible anchor at the same viewport
    /// position, which is what chat-history prepends need.
    func scrollAnchor() -> some View {
        modifier(ScrollAnchorModifier())
    }
}

private struct ScrollAnchorModifier: ViewModifier {
    func apply(node: Node) {
        node.attachments[_ScrollViewAttachmentKeys.anchorMarker] = true
    }
}

/// Programmatic scrolling of the scroll view that contains a node, for drags
/// that reach a viewport edge. Callers never see the scroll view's storage.
enum EnclosingScroll {
    /// The nearest ancestor ScrollView node.
    static func container(of node: Node) -> Node? {
        var current = node.parent
        while let candidate = current {
            if candidate.attachments[_ScrollViewAttachmentKeys.report] != nil { return candidate }
            current = candidate.parent
        }
        return nil
    }

    /// The scroll view's visible viewport in window coordinates.
    static func viewport(of scroll: Node) -> CGRect {
        ScrollView<EmptyView>.visibleViewportRect(for: scroll)
    }

    /// Scrolls vertically by up to `delta`, clamped to the content, and
    /// reports the new offset to the scroll view's observers.
    @discardableResult
    static func scroll(_ scroll: Node, byY delta: CGFloat) -> CGFloat {
        let content = ScrollView<EmptyView>.cachedScrollableContentSize(for: scroll)
        let maxY = max(0, content.height - viewport(of: scroll).height)
        let current = scroll.contentOffset
        let nextY = min(maxY, max(0, current.y + delta))
        guard nextY != current.y else { return 0 }
        scroll.contentOffset = CGPoint(x: current.x, y: nextY)
        (scroll.attachments[_ScrollViewAttachmentKeys.motion] as? ScrollAnimator)?.adopt(scroll.contentOffset)
        (scroll.attachments[_ScrollViewAttachmentKeys.report] as? (Node) -> Void)?(scroll)
        return nextY - current.y
    }
}
