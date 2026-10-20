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
    var content = MenuItemContent()
    init(item: MenuItem) {
        id = item.id; title = item.title; shortcut = item.shortcut
        isEnabled = item.isEnabled; isSelected = item.isSelected; role = item.role; content = item.content
    }
    init(submenu: MenuSubmenu) {
        id = submenu.id; title = submenu.title; isEnabled = submenu.isEnabled; hasSubmenu = true
        content = MenuItemContent(icon: submenu.icon)
    }
    var isLink: Bool { content.link != nil && !hasSubmenu }
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
    /// Plain session data: pointer samples must not recompose the menu.
    var pointer = MenuPointerIntent()
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
    var onPointer: ((CGPoint) -> Void)?
    var onFrame: ((CGRect) -> Void)?
    let content: Content
    init(hoverIntent: MenuHoverIntent, onKey: @escaping (KeyEvent, Node) -> Bool,
         onText: @escaping (String, Node) -> Bool, onPointer: ((CGPoint) -> Void)? = nil,
         onFrame: ((CGRect) -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.hoverIntent = hoverIntent; self.onKey = onKey; self.onText = onText
        self.onPointer = onPointer; self.onFrame = onFrame; self.content = content()
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
        if let onPointer {
            InteractionRegistryHolder.current?.setMotion(node) { event, phase in
                if phase == .capture { onPointer(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) }
                return .ignored
            }
        }
        // Layout-less host: the panel child carries the measured frame.
        node.layoutDidUpdate = onFrame.map { report in { node in report(node.children.first?.absoluteFrame ?? .zero) } }
    }
    var _children: [any View] { [content] }
}

func menuRow(_ id: AnyHashable, in node: Node) -> Node? {
    if node.attachments["__menu_item_id"] as? AnyHashable == id { return node }
    for child in node.children {
        if let row = menuRow(id, in: child) { return row }
    }
    return nil
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
    private var delay: Double = 0.18
    func schedule(id: AnyHashable, delay: Double = 0.18, action: @escaping () -> Void) {
        self.id = id; self.action = action; self.delay = delay; elapsed = 0; isFinished = false
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
        if elapsed >= delay { let callback = action; cancel(); callback?() }
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
    let maxVisibleRows: Int
    func apply(node: Node) {
        let surface = node.compositionValue(of: SurfaceEnvironment.key)
        let rowHeight = max(node.compositionValue(of: MenuRowMetrics.minimumHeight), node.textScaler.scale(node.theme.typography.body.lineHeight) + 12,
            surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
        let preferredHeight = Float(maxVisibleRows) * rowHeight
        func constrain(_ node: Node) {
            let height = min(preferredHeight, max(0, Float(portalWindowBounds(node).height) - 12))
            if node.layoutNode?.maxHeight != height { node.layoutNode?.maxHeight = height }
        }
        constrain(node)
        let previous = node.layoutDidUpdate
        node.layoutDidUpdate = { previous?($0); constrain($0) }
    }
}
