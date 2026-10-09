import EngineKernel
import GuavaUIRuntime

/// Invisible host for application-level keyboard shortcuts.
///
/// The dispatcher delivers normal focused key handlers first, then falls back
/// to handlers registered with `.shortcut`, so text fields and focused controls
/// keep priority while app-level commands still work without panel focus.
public struct ShortcutHost: _PrimitiveView {
    public let route: InputHandlerRoute
    private let onKeyDown: (KeyEvent) -> EventResult
    private let onKeyUp: ((KeyEvent) -> EventResult)?

    public init(route: InputHandlerRoute = .shortcut,
                onKeyDown: @escaping (KeyEvent) -> Bool) {
        self.route = route
        self.onKeyDown = { onKeyDown($0) ? .handled : .ignored }
        self.onKeyUp = nil
    }

    public init(route: InputHandlerRoute = .shortcut,
                onKeyDownResult: @escaping (KeyEvent) -> EventResult,
                onKeyUpResult: ((KeyEvent) -> EventResult)? = nil) {
        self.route = route
        self.onKeyDown = onKeyDownResult
        self.onKeyUp = onKeyUpResult
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = false
        return node
    }

    public func _updateNode(_ node: Node) {
        guard let registry = InteractionRegistryHolder.current else { return }
        let snap = self
        registry.remove(node)
        registry.setKey(node, route: snap.route) { event, _ in
            snap.onKeyDown(event)
        }
        if let onKeyUp = snap.onKeyUp {
            registry.setKeyUp(node, route: snap.route) { event, _ in
                onKeyUp(event)
            }
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }
}
