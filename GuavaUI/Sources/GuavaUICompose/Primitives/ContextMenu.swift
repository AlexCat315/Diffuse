import Foundation
import EngineKernel
import GuavaUIRuntime

public extension View {
    func contextMenu(_ entries: [MenuEntry], width: Float = 240,
                     onOpen: (() -> Void)? = nil) -> some View {
        _ContextMenu(content: self, entries: entries, width: width, onOpen: onOpen)
    }
}

private struct _ContextMenu<Content: View>: View {
    let content: Content; let entries: [MenuEntry]; let width: Float; let onOpen: (() -> Void)?
    @State private var point: CGPoint?
    var body: some View {
        _ContextMenuHost(content: content, entries: entries, width: width, point: point,
                         onOpen: { position in onOpen?(); point = position }, onDismiss: { point = nil })
    }
}

private struct _ContextMenuHost<Content: View>: _PrimitiveView {
    let content: Content; let entries: [MenuEntry]; let width: Float; let point: CGPoint?
    let onOpen: (CGPoint) -> Void; let onDismiss: () -> Void
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.addResource(PortalResource()); return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        let route = InputHandlerRoute(role: .control, priority: .chrome, debugName: "context-menu")
        InteractionRegistryHolder.current?.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .right || (event.button == .left && !event.modifiers.isDisjoint(with: .ctrl)) else { return .ignored }
            if phase == .down { onOpen(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) }
            return .handled
        }
        let resource = node.firstResource(PortalResource.self)
        guard let point else { resource?.unmount(node: node); return }
        resource?.present(in: node.compositionValue(of: PortalStoreEnvironment.key), position: point, width: width,
                          content: AnyView(_PopupMenu(entries: entries, width: width, onDismiss: onDismiss)))
        resource?.setDismissal(anchor: { .zero }, dismiss: onDismiss)
    }
    var _children: [any View] { [content] }
}

struct _PopupMenu: View {
    let entries: [MenuEntry]; let width: Float; let onDismiss: () -> Void
    @State private var highlighted: Int = 0
    private var enabledIndices: [Int] {
        entries.indices.filter { if case .item(let item) = entries[$0] { return item.isEnabled }; return false }
    }
    var body: some View {
        FocusScope(restoresCommands: true) {
            _MenuKeyHost(onKey: handleKey) {
                Menu(entries, width: width, maxVisibleRows: 12, highlightedIndex: highlighted,
                     onItemActivated: onDismiss)
            }
        }
    }
    private func handleKey(_ key: KeyEvent) -> Bool {
        if key.scancode == Scancode.escape { onDismiss(); return true }
        let enabled = enabledIndices
        guard !enabled.isEmpty else { return false }
        let current = enabled.firstIndex(of: highlighted) ?? 0
        switch key.scancode {
        case Scancode.arrowDown: highlighted = enabled[(current + 1) % enabled.count]; return true
        case Scancode.arrowUp: highlighted = enabled[(current - 1 + enabled.count) % enabled.count]; return true
        case Scancode.return, Scancode.keypadEnter:
            let index = enabled.contains(highlighted) ? highlighted : enabled[0]
            if case .item(let item) = entries[index] { item.action(); onDismiss() }
            return true
        default: return false
        }
    }
}

struct _MenuKeyHost<Content: View>: _PrimitiveView {
    let onKey: (KeyEvent) -> Bool; let content: Content
    init(onKey: @escaping (KeyEvent) -> Bool, @ViewBuilder content: () -> Content) { self.onKey = onKey; self.content = content() }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node, route: .overlay) { event, _ in onKey(event) ? .handled : .ignored }
    }
    var _children: [any View] { [content] }
}
