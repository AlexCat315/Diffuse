internal import Foundation
import GuavaUIRuntime

/// How a numeric prefix chip turns horizontal drag into value changes.
struct NumericScrub {
    /// Value change per logical point of drag, before modifiers.
    let perPoint: Float
    let clamp: (Float) -> Float
    let reset: Float?

    /// Shift is coarse (×10), Option/Alt is fine (×0.1).
    func value(from start: Float, dragged dx: Float, modifiers: KeyModifiers) -> Float {
        var rate = perPoint
        if modifiers.contains(.shift) { rate *= 10 }
        if modifiers.contains(.alt) { rate *= 0.1 }
        return clamp(start + dx * rate)
    }
}

/// The prefix chip of a numeric field. Dragging it horizontally scrubs the
/// value live; a double click resets to the field's reset value. The text
/// field stays the keyboard and assistive path, so the chip adds no focus stop.
struct NumericScrubHandle<Label: View>: _PrimitiveView {
    let value: Binding<Float>
    let scrub: NumericScrub
    let isEnabled: Bool
    let label: Label

    init(value: Binding<Float>, scrub: NumericScrub, isEnabled: Bool, @ViewBuilder label: () -> Label) {
        self.value = value; self.scrub = scrub; self.isEnabled = isEnabled; self.label = label()
    }

    func _makeNode() -> Node {
        let node = Node(), session = NumericScrubSession()
        node.attachments[NumericScrubSession.key] = session
        node.addResource(session)
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        // The chip is stretched by the field row; its label stays centered.
        let layout = LayoutNode()
        layout.flexDirection = .row
        layout.alignItems = .center
        layout.justifyContent = .center
        // Tooltip and menu wrappers are columns; grow to their full height.
        layout.flexGrow = 1
        return layout
    }

    func _updateNode(_ node: Node) {
        let session = node.attachments[NumericScrubSession.key] as! NumericScrubSession
        let value = value, scrub = scrub
        node.isHitTestable = isEnabled
        node.cursor = isEnabled ? .resizeHorizontal : .arrow
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            session.cancel(node: node, restoring: nil)
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setPointer(node) { [weak node] event, phase, route in
            guard let node, event.button == .left, route == .target else { return .ignored }
            switch phase {
            case .down:
                if event.clicks >= 2, let reset = scrub.reset {
                    session.cancel(node: node, restoring: nil)
                    if value.wrappedValue != reset { value.wrappedValue = reset }
                    return .handled
                }
                session.begin(at: event.x, value: value.wrappedValue, modifiers: event.modifiers, node: node)
            case .up:
                session.cancel(node: node, restoring: nil)
            }
            return .handled
        }
        registry.setMotion(node) { event, phase in
            guard phase == .target, let start = session.start else { return .ignored }
            let next = scrub.value(from: start.value, dragged: event.x - start.x, modifiers: start.modifiers)
            if value.wrappedValue != next { value.wrappedValue = next }
            return .handled
        }
    }

    func _children(for node: Node) -> [any View] { [label] }
}

/// Drag state that survives recomposition while the value changes underneath it.
final class NumericScrubSession: NodeResource {
    static let key = "numeric.scrub"
    /// Modifiers held when the drag starts choose coarse or fine for the whole drag.
    private(set) var start: (x: Float, value: Float, modifiers: KeyModifiers)?
    private weak var capture: PointerCapture?

    func mount(node: Node) { capture = PointerCaptureHolder.current }
    func unmount(node: Node) { cancel(node: node, restoring: nil) }

    func begin(at x: Float, value: Float, modifiers: KeyModifiers, node: Node) {
        start = (x, value, modifiers)
        capture?.acquire(node)
    }

    /// Ends the drag; with a binding, writes the starting value back.
    func cancel(node: Node, restoring binding: Binding<Float>?) {
        if let binding, let start { binding.wrappedValue = start.value }
        start = nil
        if capture?.target === node { capture?.release() }
    }
}
