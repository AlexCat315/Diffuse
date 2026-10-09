import Foundation
import GuavaUIRuntime

extension Rating {
    public func _makeNode() -> Node {
        let node = Node(), session = RatingSession()
        node.attachments["rating.session"] = session; node.addResource(session)
        return node
    }
    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateNode(_ node: Node) {
        var selection = selection, appearance = appearance
        selection.validate(); appearance.validate()
        let geometry = RatingGeometry(appearance: appearance, selection: selection, node: node)
        let session = node.attachments["rating.session"] as! RatingSession
        session.binding = value
        let configuration = RatingSession.Configuration(value: selection.clamped(value.wrappedValue), selection: selection, geometry: geometry)
        if session.configuration != configuration { session.cancel(node: node); session.configuration = configuration }
        node.isFocusable = selection.isInteractive; node.isHitTestable = selection.isInteractive
        if !selection.isInteractive, FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
        node.cursor = selection.isInteractive ? .pointer : .arrow
        node.layoutNode?.width = geometry.width; node.layoutNode?.height = geometry.height
        node.layoutNode?.flexShrink = 0
        node.layoutNode?.setMeasureFunc { _, _, _, _ in CGSize(width: CGFloat(geometry.width), height: CGFloat(geometry.height)) }
        node.accessibility = AccessibilitySemantics(selection.isReadOnly ? .image : .slider) {
            $0.label = label; $0.value = String(configuration.value)
            $0.help = "\(configuration.value.formatted()) out of \(selection.maximum)"
            $0.state.isEnabled = selection.isEnabled; $0.state.isReadOnly = selection.isReadOnly
        }
        node.accessibilityActions = AccessibilityActions()
        let write: (Double) -> Void = { [weak node] raw in
            guard let node else { return }
            session.cancel(node: node)
            let next = selection.snapped(raw)
            if next != session.binding.wrappedValue { session.binding.wrappedValue = next }
            node.markRenderDirty(reason: .styleSet(field: "ratingValue"))
        }
        if selection.isInteractive {
            node.accessibilityActions.setValue = { if let number = Double($0), number.isFinite { write(number) } }
            node.accessibilityActions.increment = { write(selection.clamped(session.binding.wrappedValue) + selection.precision.increment) }
            node.accessibilityActions.decrement = { write(selection.clamped(session.binding.wrappedValue) - selection.precision.increment) }
        }
        let palette = RatingPalette(appearance: appearance, selection: selection, theme: node.theme)
        let paint = (node.attachments["rating.paint"] as? RatingPaint) ?? RatingPaint(size: geometry.starSize)
        node.attachments["rating.paint"] = paint
        node.updateDraw(identity: RatingDrawIdentity(configuration: configuration, palette: palette)) { [weak node] list, origin in
            guard let node else { return }
            paint.draw(value: session.preview ?? selection.clamped(session.binding.wrappedValue), geometry: geometry,
                       palette: palette, node: node, origin: origin, list: list)
        }
        guard selection.isInteractive, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node); return
        }
        registry.setHover(node) { [weak node] phase in
            if let node, phase == .leave { session.hover(nil, node: node) }
        }
        registry.setMotion(node) { [weak node] event, phase in
            guard let node else { return .ignored }
            guard phase == .target else { return .ignored }
            session.hover(geometry.contains(event.x, event.y, node: node) ? geometry.candidate(at: event.x, node: node, precision: selection.precision) : nil, node: node)
            return session.pressedCandidate == nil ? .ignored : .handled
        }
        registry.setPointer(node) { [weak node] event, phase, route in
            guard let node else { return .ignored }
            guard event.button == .left, route == .target else { return .ignored }
            switch phase {
            case .down:
                guard geometry.contains(event.x, event.y, node: node) else { return .ignored }
                session.begin(geometry.candidate(at: event.x, node: node, precision: selection.precision), node: node)
            case .up:
                guard session.pressedCandidate != nil else { return .ignored }
                let inside = geometry.contains(event.x, event.y, node: node)
                let candidate = geometry.candidate(at: event.x, node: node, precision: selection.precision)
                let clears = selection.allowsClear && !session.hasMoved && candidate == selection.clamped(session.binding.wrappedValue)
                session.cancel(node: node)
                if inside { write(clears ? 0 : candidate) }
            }
            return .handled
        }
        registry.setKey(node) { [weak node] event, phase in
            guard let node else { return .ignored }
            guard phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
            let current = selection.clamped(session.binding.wrappedValue)
            switch event.scancode {
            case Scancode.arrowLeft, Scancode.arrowDown: write(current - selection.precision.increment)
            case Scancode.arrowRight, Scancode.arrowUp: write(current + selection.precision.increment)
            case Scancode.home: write(0)
            case Scancode.end: write(Double(selection.maximum))
            case Scancode.backspace, Scancode.delete:
                guard selection.allowsClear else { return .ignored }; write(0)
            case Scancode.escape: session.cancel(node: node)
            default: return .ignored
            }
            return .handled
        }
    }
}

private struct RatingDrawIdentity: Equatable {
    let configuration: RatingSession.Configuration
    let palette: RatingPalette
}
