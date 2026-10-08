import GuavaUIRuntime

/// Shared navigation policy for single-selection groups; disabled items are excluded by callers.
public enum SelectionNavigation: Sendable {
    case previous, next, first, last
    public static func command(for scancode: UInt32) -> Self? {
        switch scancode {
        case Scancode.arrowUp, Scancode.arrowLeft: .previous
        case Scancode.arrowDown, Scancode.arrowRight: .next
        case Scancode.home: .first
        case Scancode.end: .last
        default: nil
        }
    }
    public func destination<ID: Equatable>(in items: [ID], from selection: ID?, wraps: Bool = true) -> ID? {
        guard !items.isEmpty else { return nil }
        let index = selection.flatMap { items.firstIndex(of: $0) }
        switch self {
        case .first: return items.first
        case .last: return items.last
        case .next:
            guard let index else { return items.first }
            return items[wraps ? (index + 1) % items.count : min(index + 1, items.count - 1)]
        case .previous:
            guard let index else { return items.last }
            return items[wraps ? (index + items.count - 1) % items.count : max(0, index - 1)]
        }
    }
}

struct RovingItemModifier: ViewModifier {
    let id: AnyHashable
    let isTabStop: Bool
    func apply(node: Node) {
        node.attachments["__roving.item"] = id
        node.isTabStop = isTabStop
    }
}

/// A keyboard boundary whose enabled items have one sequential Tab stop.
struct RovingFocusHost<Content: View>: _PrimitiveView {
    let enabledItems: [AnyHashable]
    let selection: () -> AnyHashable?
    let onSelect: (AnyHashable) -> Void
    let content: Content
    init(enabledItems: [AnyHashable], selection: @escaping () -> AnyHashable?, onSelect: @escaping (AnyHashable) -> Void,
         @ViewBuilder content: () -> Content) {
        self.enabledItems = enabledItems; self.selection = selection
        self.onSelect = onSelect; self.content = content()
    }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node) { [weak node] event, phase in
            guard phase == .bubble, let command = SelectionNavigation.command(for: event.scancode),
                  let target = command.destination(in: enabledItems, from: selection()), let node else { return .ignored }
            onSelect(target)
            func updateTabStops(_ candidate: Node) {
                if let id = candidate.attachments["__roving.item"] as? AnyHashable { candidate.isTabStop = id == target }
                candidate.children.forEach(updateTabStops)
            }
            updateTabStops(node)
            func locate(_ candidate: Node) -> Node? {
                if candidate.attachments["__roving.item"] as? AnyHashable == target, candidate.isFocusable { return candidate }
                return candidate.children.lazy.compactMap(locate).first
            }
            if let targetNode = locate(node) { FocusChainHolder.current?.focus(targetNode) }
            return .handled
        }
    }
    var _children: [any View] { [content] }
}
