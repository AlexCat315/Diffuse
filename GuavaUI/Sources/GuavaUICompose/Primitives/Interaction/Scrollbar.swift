import Foundation
import GuavaUIRuntime

/// Focusable scroll thumb for a caller-owned offset. It is a companion to
/// `ScrollView`: bind the same offset and place it beside the viewport. The
/// component paints only the track and thumb; the caller owns layout.
public struct Scrollbar: View {
    public enum Axis: Sendable, Equatable { case vertical, horizontal }

    public let axis: Axis
    public let offset: Binding<CGFloat>
    public let contentExtent: CGFloat
    public let viewportExtent: CGFloat
    public let thickness: Float
    public let minimumThumbExtent: CGFloat
    public let label: String

    public init(axis: Axis = .vertical,
                offset: Binding<CGFloat>,
                contentExtent: CGFloat,
                viewportExtent: CGFloat,
                thickness: Float = 12,
                minimumThumbExtent: CGFloat = 32,
                label: String = "Scrollbar") {
        self.axis = axis
        self.offset = offset
        self.contentExtent = max(0, contentExtent)
        self.viewportExtent = max(0, viewportExtent)
        self.thickness = thickness.isFinite ? max(8, thickness) : 12
        self.minimumThumbExtent = minimumThumbExtent.isFinite ? max(16, minimumThumbExtent) : 32
        self.label = label
    }

    public var body: some View {
        ScrollbarHost(axis: axis, offset: offset,
                      contentExtent: contentExtent, viewportExtent: viewportExtent,
                      thickness: thickness, minimumThumbExtent: minimumThumbExtent,
                      label: label)
    }
}

private enum _ScrollbarAttachmentKeys {
    static let chromeOpacity = "__scrollbar_chrome_opacity"
    static let isHovered = "__scrollbar_is_hovered"
    static let isDragging = "__scrollbar_is_dragging"
    static let desiredVisible = "__scrollbar_desired_visible"
    static let lastOffset = "__scrollbar_last_offset"
}

private struct ScrollbarPaint: Equatable {
    let axis: Scrollbar.Axis
    let offset: CGFloat
    let content: CGFloat
    let viewport: CGFloat
    let thickness: Float
    let minimum: CGFloat
    let focused: Bool
    let visibleFocus: Bool
}

private struct ScrollbarHost: _PrimitiveView {
    let axis: Scrollbar.Axis
    let offset: Binding<CGFloat>
    let contentExtent: CGFloat
    let viewportExtent: CGFloat
    let thickness: Float
    let minimumThumbExtent: CGFloat
    let label: String

    private var maxOffset: CGFloat { max(0, contentExtent - viewportExtent) }
    private var value: CGFloat { min(maxOffset, max(0, offset.wrappedValue)) }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        if axis == .vertical { layout.width = thickness } else { layout.height = thickness }
        return layout
    }

    func _updateNode(_ node: Node) {
        // Hover-capable surfaces auto-hide the companion until hover, focus,
        // drag, or a scroll flash reveals it. Touch-only surfaces have no
        // hover to reveal chrome, so the bar stays visible there.
        if node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] == nil {
            node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] = node.supportsControlHover ? Float(0) : Float(1)
            node.attachments[_ScrollbarAttachmentKeys.isHovered] = false
            node.attachments[_ScrollbarAttachmentKeys.isDragging] = false
            node.attachments[_ScrollbarAttachmentKeys.desiredVisible] = false
            node.attachments[_ScrollbarAttachmentKeys.lastOffset] = value
        }
        let percent = maxOffset > 0 ? Int((value / maxOffset * 100).rounded()) : 0
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = label
            $0.value = "\(percent)%"
            $0.help = "Use arrow keys, Page Up/Down, Home and End to scroll"
        }
        node.accessibilityActions.increment = { [weak node] in
            guard let node else { return }
            scroll(node, by: viewportExtent * 0.9)
        }
        node.accessibilityActions.decrement = { [weak node] in
            guard let node else { return }
            scroll(node, by: -viewportExtent * 0.9)
        }
        node.accessibilityActions.setValue = { [weak node] text in
            guard let node, maxOffset > 0 else { return }
            let digits = text.filter { $0.isNumber }
            guard let pct = Int(digits) else { return }
            offset.wrappedValue = maxOffset * CGFloat(min(100, max(0, pct))) / 100
        }
        guard let registry = InteractionRegistryHolder.current else { return }
        // Focus changes don't re-run view updates; the shared focus sink is
        // how controls react (Button, MenuItemRow, resize handles use it too).
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] (_: Bool) in
            guard let node else { return }
            applyDesiredVisibility(node)
        }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                node.attachments[_ScrollbarAttachmentKeys.isHovered] = true
            case .leave:
                node.attachments[_ScrollbarAttachmentKeys.isHovered] = false
            }
            applyDesiredVisibility(node)
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                FocusChainHolder.current?.focus(node)
                PointerCaptureHolder.current?.acquire(node)
                node.attachments[_ScrollbarAttachmentKeys.isDragging] = true
                applyDesiredVisibility(node)
                update(node, to: CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)))
                return .handled
            case .up:
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                node.attachments[_ScrollbarAttachmentKeys.isDragging] = false
                applyDesiredVisibility(node)
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            // Scrub only while dragging; plain hover motion over the bar must
            // not move the thumb.
            guard PointerCaptureHolder.current?.target === node else { return .ignored }
            update(node, to: CGPoint(x: CGFloat(event.x), y: CGFloat(event.y)))
            return .handled
        }
        registry.setKey(node) { [weak node] event, phase in
            guard phase != .capture, let node else { return .ignored }
            switch event.scancode {
            case Scancode.arrowUp, Scancode.arrowLeft:
                scroll(node, by: -max(20, viewportExtent * 0.1))
            case Scancode.arrowDown, Scancode.arrowRight:
                scroll(node, by: max(20, viewportExtent * 0.1))
            case Scancode.pageUp: scroll(node, by: -viewportExtent * 0.9)
            case Scancode.pageDown: scroll(node, by: viewportExtent * 0.9)
            case Scancode.home: offset.wrappedValue = 0
            case Scancode.end: offset.wrappedValue = maxOffset
            default: return .ignored
            }
            return .handled
        }
        let focused = FocusChainHolder.current?.focused === node
        let visibleFocus = focused && (FocusChainHolder.current?.isFocusVisible ?? false)
        let identity = ScrollbarPaint(axis: axis, offset: value, content: contentExtent,
                                      viewport: viewportExtent, thickness: thickness,
                                      minimum: minimumThumbExtent,
                                      focused: focused, visibleFocus: visibleFocus)
        node.updateDraw(identity: identity) { [weak node] list, origin in
            guard let node else { return }
            draw(node: node, list: list, origin: origin)
        }

        let last = node.attachments[_ScrollbarAttachmentKeys.lastOffset] as? CGFloat ?? value
        if last != value {
            node.attachments[_ScrollbarAttachmentKeys.lastOffset] = value
            flashIfUnheld(on: node)
        }
        applyDesiredVisibility(node)
    }

    /// Hover, focus, and drag each hold the bar visible. Only transitions of
    /// the combined state drive the fade, so per-frame updates don't fight an
    /// in-flight scroll flash.
    private func applyDesiredVisibility(_ node: Node) {
        guard node.supportsControlHover else { return }
        let hovered = node.attachments[_ScrollbarAttachmentKeys.isHovered] as? Bool ?? false
        let dragging = node.attachments[_ScrollbarAttachmentKeys.isDragging] as? Bool ?? false
        let focused = FocusChainHolder.current?.focused === node
        let desired = hovered || dragging || focused
        let previous = node.attachments[_ScrollbarAttachmentKeys.desiredVisible] as? Bool ?? false
        guard desired != previous else { return }
        node.attachments[_ScrollbarAttachmentKeys.desiredVisible] = desired
        setChromeVisible(desired, on: node)
    }

    private func setChromeVisible(_ visible: Bool, on node: Node) {
        let current = node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] as? Float ?? 0
        withAnimation(.semantic(.fast, in: node.theme)) {
            node.animatableSet(propertyKey: _ScrollbarAttachmentKeys.chromeOpacity,
                               current: current, to: visible ? Float(1) : Float(0)) { [weak node] opacity in
                guard let node else { return }
                node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] = opacity
                node.markRenderDirty(reason: .styleSet(field: "scrollbarChromeOpacity"))
            }
        }
    }

    /// Scrolling reveals the bar even when nothing holds it: it appears at
    /// once and fades 0.3s after the content rests for 0.7s — the same
    /// numbers as ScrollView's touch indicator. Reduced motion keeps it
    /// visible instead of animating it out; any held state cancels the fade
    /// because the same property key retargets the in-flight controller.
    private func flashIfUnheld(on node: Node) {
        guard node.supportsControlHover else { return }
        guard node.attachments[_ScrollbarAttachmentKeys.desiredVisible] as? Bool != true else { return }
        let apply: (Float) -> Void = { [weak node] opacity in
            guard let node else { return }
            node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] = opacity
            node.markRenderDirty(reason: .styleSet(field: "scrollbarChromeOpacity"))
        }
        node.animatableSet(propertyKey: _ScrollbarAttachmentKeys.chromeOpacity,
                           current: node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] as? Float ?? 0,
                           to: Float(1), apply: apply)
        guard !node.prefersReducedMotion else { return }
        withAnimation(Animation(duration: 0.3, curve: .easeOut, delay: 0.7)) {
            node.animatableSet(propertyKey: _ScrollbarAttachmentKeys.chromeOpacity,
                               current: Float(1), to: Float(0), apply: apply)
        }
    }

    private func update(_ node: Node, to point: CGPoint) {
        guard maxOffset > 0 else { return }
        let track = axis == .vertical ? node.frame.height : node.frame.width
        let thumb = thumbExtent(track: track)
        let travel = max(1, track - thumb)
        let local = axis == .vertical ? point.y - node.absoluteFrame.minY : point.x - node.absoluteFrame.minX
        let fraction = min(1, max(0, (local - thumb / 2) / travel))
        offset.wrappedValue = fraction * maxOffset
    }

    private func scroll(_ node: Node, by delta: CGFloat) {
        offset.wrappedValue = min(maxOffset, max(0, value + delta))
    }

    private func thumbExtent(track: CGFloat) -> CGFloat {
        guard contentExtent > viewportExtent, contentExtent > 0 else { return track }
        let proportional = track * viewportExtent / contentExtent
        return min(track, max(minimumThumbExtent, proportional))
    }

    private func draw(node: Node, list: DrawList, origin: CGPoint) {
        let track = CGFloat(axis == .vertical ? node.frame.height : node.frame.width)
        guard track > 0 else { return }
        let opacity = node.attachments[_ScrollbarAttachmentKeys.chromeOpacity] as? Float ?? 1
        guard opacity > 0.01 else { return }
        let width = CGFloat(thickness)
        let thumb = thumbExtent(track: track)
        let travel = max(0, track - thumb)
        let fraction = maxOffset > 0 ? value / maxOffset : 0
        let position = fraction * travel
        let trackColor = node.theme.colors.surfaceVariant.multipliedAlpha(0.7 * opacity)
        let thumbColor = node.theme.colors.onSurfaceMuted.multipliedAlpha(0.85 * opacity)
        if axis == .vertical {
            list.addRoundedRect(UIRect(x: Float(origin.x + (width - 4) / 2), y: Float(origin.y),
                                       width: 4, height: Float(track)), radius: 2, color: trackColor)
            let x = Float(origin.x + (width - 6) / 2)
            if FocusChainHolder.current?.focused === node,
               FocusChainHolder.current?.isFocusVisible == true {
                list.addRoundedRect(UIRect(x: x - 1, y: Float(origin.y + position) - 1,
                                           width: 8, height: Float(thumb) + 2), radius: 4,
                                    color: node.theme.colors.focusRing)
            }
            list.addRoundedRect(UIRect(x: x, y: Float(origin.y + position),
                                       width: 6, height: Float(thumb)), radius: 3, color: thumbColor)
        } else {
            list.addRoundedRect(UIRect(x: Float(origin.x), y: Float(origin.y + (width - 4) / 2),
                                       width: Float(track), height: 4), radius: 2, color: trackColor)
            let y = Float(origin.y + (width - 6) / 2)
            if FocusChainHolder.current?.focused === node,
               FocusChainHolder.current?.isFocusVisible == true {
                list.addRoundedRect(UIRect(x: Float(origin.x + position) - 1, y: y - 1,
                                           width: Float(thumb) + 2, height: 8), radius: 4,
                                    color: node.theme.colors.focusRing)
            }
            list.addRoundedRect(UIRect(x: Float(origin.x + position), y: y,
                                       width: Float(thumb), height: 6), radius: 3, color: thumbColor)
        }
    }
}
