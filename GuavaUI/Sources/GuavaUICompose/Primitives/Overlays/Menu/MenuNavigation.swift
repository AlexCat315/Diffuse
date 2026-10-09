import Foundation
import GuavaUIRuntime

struct MenuRowPresentation {
    let id: AnyHashable
    let title: String
    var shortcut: String?
    var isEnabled = true
    var isSelected = false
    var role: MenuItemRole = .normal
    var hasSubmenu = false
    init(item: MenuItem) {
        id = item.id; title = item.title; shortcut = item.shortcut
        isEnabled = item.isEnabled; isSelected = item.isSelected; role = item.role
    }
    init(submenu: MenuSubmenu) {
        id = submenu.id; title = submenu.title; isEnabled = submenu.isEnabled; hasSubmenu = true
    }
}

struct MenuRowEvents {
    var activate: (Node) -> Void
    var hover: (Node, Bool) -> Void
    var focus: () -> Void
    var reveal: (Node) -> Void
    var closeSubmenu: () -> Void
}

struct MenuNavigationState: Equatable {
    var highlighted: AnyHashable?
    var opened: AnyHashable?
    var revealToken = 0
}

/// Child portals keep callbacks after their parent view value is replaced.
/// Sharing this session preserves those callbacks' navigation identity.
final class MenuSession {
    private var navigationValue = MenuNavigationState()
    private var offsetValue = CGPoint.zero
    private let registrar = ObservableStateRegistrar()
    let hoverIntent = MenuHoverIntent()
    var typeahead = MenuTypeahead()
    var navigation: MenuNavigationState {
        get { registrar.access("navigation"); return navigationValue }
        set {
            guard navigationValue != newValue else { return }
            navigationValue = newValue; registrar.invalidate("navigation")
        }
    }
    var scrollOffset: CGPoint {
        get { registrar.access("offset"); return offsetValue }
        set {
            guard offsetValue != newValue else { return }
            offsetValue = newValue; registrar.invalidate("offset")
        }
    }
}

struct MenuLevelHost<Content: View>: _PrimitiveView {
    let hoverIntent: MenuHoverIntent
    let onKey: (KeyEvent, Node) -> Bool
    let onText: (String, Node) -> Bool
    let content: Content
    init(hoverIntent: MenuHoverIntent, onKey: @escaping (KeyEvent, Node) -> Bool,
         onText: @escaping (String, Node) -> Bool, @ViewBuilder content: () -> Content) {
        self.hoverIntent = hoverIntent; self.onKey = onKey; self.onText = onText; self.content = content()
    }
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.addResource(hoverIntent)
        node.attachments["__menu.level"] = true; return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node) { [weak node] event, phase in
            guard phase != .capture, let node else { return .ignored }
            return onKey(event, node) ? .handled : .ignored
        }
        InteractionRegistryHolder.current?.setText(node) { [weak node] text, phase in
            guard phase != .capture, let node else { return .ignored }
            return onText(text, node) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}

func menuRow(_ id: AnyHashable, in node: Node) -> Node? {
    if node.attachments["__menu_item_id"] as? AnyHashable == id { return node }
    return node.children.lazy.compactMap { menuRow(id, in: $0) }.first
}

/// A short intent delay lets a pointer cross sibling rows while travelling
/// into an already-open child. Leaving a pending row cancels its switch.
final class MenuHoverIntent: NodeResource, AnyAnimationController {
    private var id: AnyHashable?
    private var action: (() -> Void)?
    private var elapsed: Double = 0
    var isFinished = true
    func mount(node: Node) {}
    func unmount(node: Node) { cancel() }
    func schedule(id: AnyHashable, action: @escaping () -> Void) {
        self.id = id; self.action = action; elapsed = 0; isFinished = false
        AnimatorScheduler.current.register(self)
    }
    func cancel() { cancel(id: nil) }
    func cancel(id: AnyHashable?) {
        if let id, self.id != id { return }
        isFinished = true; self.id = nil; action = nil
    }
    func tick(deltaTime: Double) {
        guard !isFinished else { return }
        elapsed += max(0, deltaTime)
        if elapsed >= 0.18 { let callback = action; cancel(); callback?() }
    }
    func finishImmediately() { cancel() }
}

struct MenuTypeahead {
    private var prefix = ""
    private var lastInput: TimeInterval = 0
    mutating func destination(_ text: String, rows: [MenuRowPresentation], from current: AnyHashable?,
                              time: TimeInterval = Date.timeIntervalSinceReferenceDate) -> AnyHashable? {
        guard !text.isEmpty, !rows.isEmpty else { return nil }
        if time - lastInput > 0.8 { prefix = "" }
        lastInput = time
        let input = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if prefix == input && input.count == 1 { prefix = input } else { prefix += input }
        let start = rows.firstIndex { $0.id == current } ?? -1
        for distance in 1...rows.count {
            let row = rows[(start + distance) % rows.count]
            if row.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).hasPrefix(prefix) {
                return row.id
            }
        }
        return nil
    }
}

struct MenuScrollMarker: ViewModifier {
    static let key = "__menu.scroll"
    func apply(node: Node) { node.attachments[Self.key] = true }
}

struct MenuWindowBounds: ViewModifier {
    func apply(node: Node) {
        let preferredHeight = node.layoutNode?.maxHeight ?? .greatestFiniteMagnitude
        func constrain(_ node: Node) {
            let height = min(preferredHeight, max(0, Float(portalWindowBounds(node).height) - 12))
            if node.layoutNode?.maxHeight != height { node.layoutNode?.maxHeight = height }
        }
        constrain(node)
        let previous = node.layoutDidUpdate
        node.layoutDidUpdate = { previous?($0); constrain($0) }
    }
}
