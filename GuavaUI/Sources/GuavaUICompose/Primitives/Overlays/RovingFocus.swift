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
        // A caller modifier can replay after the button updates locally.
        // Resolve the current group selection instead of restoring its old snapshot.
        var ancestor = node.parent
        while let parent = ancestor {
            if let current = parent.attachments["__roving.tabStop"] as? () -> AnyHashable? {
                node.isTabStop = current() == id
                return
            }
            ancestor = parent.parent
        }
        node.isTabStop = isTabStop
    }
}

/// A keyboard boundary whose enabled items have one sequential Tab stop.
struct RovingFocusHost<Content: View>: _PrimitiveView {
    let enabledItems: [AnyHashable]
    let selection: () -> AnyHashable?
    let onSelect: (AnyHashable) -> Void
    let wraps: Bool
    let command: (KeyEvent) -> SelectionNavigation?
    let content: Content
    init(enabledItems: [AnyHashable], selection: @escaping () -> AnyHashable?, onSelect: @escaping (AnyHashable) -> Void,
         wraps: Bool = true, command: @escaping (KeyEvent) -> SelectionNavigation? = { SelectionNavigation.command(for: $0.scancode) },
         @ViewBuilder content: () -> Content) {
        self.enabledItems = enabledItems; self.selection = selection
        self.onSelect = onSelect; self.wraps = wraps; self.command = command; self.content = content()
    }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        node.attachments["__roving.tabStop"] = {
            let selected = selection()
            return selected.flatMap { enabledItems.contains($0) ? $0 : nil } ?? enabledItems.first
        } as () -> AnyHashable?
        InteractionRegistryHolder.current?.setKey(node) { [weak node] event, phase in
            guard phase == .bubble, let command = command(event), let node else { return .ignored }
            var source = selection()
            if let focused = FocusChainHolder.current?.focused {
                var candidate: Node? = focused
                var focusedItem: AnyHashable?
                while let current = candidate, current !== node {
                    if let id = current.attachments["__roving.item"] as? AnyHashable { focusedItem = id; break }
                    candidate = current.parent
                }
                // Text fields and other controls inside a panel keep their
                // unhandled arrow keys; only group headers participate here.
                guard let focusedItem, enabledItems.contains(focusedItem) else { return .ignored }
                source = focusedItem
            }
            guard let target = command.destination(in: enabledItems, from: source, wraps: wraps) else { return .ignored }
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
            if let targetNode = locate(node) {
                FocusChainHolder.current?.focus(targetNode)
                ScrollReveal.reveal(targetNode)
            }
            return .handled
        }
    }
    var _children: [any View] { [content] }
}
