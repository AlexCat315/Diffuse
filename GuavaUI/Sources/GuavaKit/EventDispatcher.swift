// Routes pointer events to nodes for one tree. DOM-style capture/target/bubble.
// Hit-testing goes through `UIContext.hitTest`, which uses the geometry-correct
// cache from Stage 1 — so dispatch can never be misrouted by stale geometry.

public final class EventDispatcher {
    public let context: UIContext

    /// Root → leaf path currently considered hovered, for enter/leave diffing.
    private var hoveredPath: [UINode] = []

    public init(context: UIContext) {
        self.context = context
    }

    // MARK: - Pointer

    /// Down hit-tests fresh and delivers through the phases. A handler may call
    /// `context.pointerCapture.acquire(node)` to capture subsequent move/up.
    @discardableResult
    public func pointerDown(_ event: PointerEvent) -> EventResult {
        let priorFocus = context.focusedNode
        let priorPortals = context.portals.count
        let hit = context.hitTest(event.position)
        let result = hit.map { deliver(path: $0.path, event: event) } ?? .ignored
        settleOutsidePress(hitPath: hit?.path ?? [], priorFocus: priorFocus, priorPortals: priorPortals)
        return result
    }

    /// A press that lands outside the focused field / open overlays clears them.
    /// Runs *after* delivery, so a press that moved focus or opened an overlay is
    /// preserved: such a node is on the hit path, or it changed `focusedNode` /
    /// the portal count, which the guards below detect.
    private func settleOutsidePress(hitPath: [UINode], priorFocus: UINode?, priorPortals: Int) {
        if let priorFocus, context.focusedNode === priorFocus,
           !hitPath.contains(where: { $0 === priorFocus }) {
            context.focusedNode = nil
        }
        if priorPortals > 0, context.portals.count == priorPortals {
            let host = context.portalHostNode
            let insidePortal = host.map { h in hitPath.contains { $0 === h } } ?? false
            if !insidePortal { context.portals.dismissAll() }
        }
    }

    /// Up goes to the capture target if one is active (skipping hit-test, so a
    /// drag that wandered off the node still ends on it); otherwise hit-tests.
    @discardableResult
    public func pointerUp(_ event: PointerEvent) -> EventResult {
        if let captured = context.pointerCapture.target {
            let r = deliver(path: pathFromRoot(to: captured), event: event)
            refreshHover(at: event.position)
            return r
        }
        guard let hit = context.hitTest(event.position) else { return .ignored }
        let r = deliver(path: hit.path, event: event)
        refreshHover(at: event.position)
        return r
    }

    /// Move respects capture for delivery; hover always tracks the real cursor.
    @discardableResult
    public func pointerMove(_ event: PointerEvent) -> EventResult {
        let hitPath = context.hitTest(event.position)?.path ?? []
        updateHover(to: hitPath)
        if let captured = context.pointerCapture.target {
            return deliver(path: pathFromRoot(to: captured), event: event)
        }
        guard !hitPath.isEmpty else { return .ignored }
        return deliver(path: hitPath, event: event)
    }

    // MARK: - Delivery

    private func deliver(path: [UINode], event: PointerEvent) -> EventResult {
        guard !path.isEmpty else { return .ignored }
        // Capture phase: root → target-exclusive.
        for node in path.dropLast() {
            if invoke(node, event, .capture) == .handled { return .handled }
        }
        // Target phase.
        if let target = path.last, invoke(target, event, .target) == .handled {
            return .handled
        }
        // Bubble phase: target-exclusive → root.
        for node in path.dropLast().reversed() {
            if invoke(node, event, .bubble) == .handled { return .handled }
        }
        return .ignored
    }

    private func invoke(_ node: UINode, _ event: PointerEvent, _ phase: EventPhase) -> EventResult {
        node.interaction.onPointer?(event, phase, context) ?? .ignored
    }

    // MARK: - Hover (enter/leave on the changed suffix of the path)

    private func refreshHover(at point: Point) {
        updateHover(to: context.hitTest(point)?.path ?? [])
    }

    private func updateHover(to newPath: [UINode]) {
        let common = commonPrefix(hoveredPath, newPath)
        if common == hoveredPath.count && common == newPath.count { return }
        // Leave nodes no longer hovered (deepest first).
        for node in hoveredPath[common...].reversed() {
            node.interaction.onHoverLeave?()
        }
        // Enter newly hovered nodes (shallowest first).
        for node in newPath[common...] {
            node.interaction.onHoverEnter?()
        }
        hoveredPath = newPath
    }

    private func commonPrefix(_ a: [UINode], _ b: [UINode]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n, a[i] === b[i] { i += 1 }
        return i
    }

    // MARK: - Helpers

    private func pathFromRoot(to node: UINode) -> [UINode] {
        var out: [UINode] = []
        var cur: UINode? = node
        while let n = cur { out.append(n); cur = n.parent }
        return out.reversed()
    }

    // MARK: - Wheel

    /// Delivers a wheel event to the deepest hit node first, then walks up
    /// the ancestor chain. The first handler returning `.handled` consumes the
    /// event (so an inner ScrollView doesn't also scroll its outer parent).
    @discardableResult
    public func dispatchWheel(_ event: WheelEvent) -> EventResult {
        guard let path = context.hitTest(event.position)?.path, !path.isEmpty else {
            return .ignored
        }
        // Deepest → root: inner view gets first refusal.
        for node in path.reversed() {
            if let handler = node.interaction.onWheel {
                if handler(event) == .handled { return .handled }
            }
        }
        return .ignored
    }

    // MARK: - Keyboard

    @discardableResult
    public func dispatchKeyDown(_ event: KeyboardEvent) -> EventResult {
        if let node = context.focusedNode,
           node.interaction.onKeyDown?(event) == .handled {
            return .handled
        }
        // Unconsumed Escape is a global "dismiss": drop focus and any overlays.
        if event.key == "Escape" {
            let acted = context.focusedNode != nil || context.portals.count > 0
            context.focusedNode = nil
            context.portals.dismissAll()
            return acted ? .handled : .ignored
        }
        return .ignored
    }
}
