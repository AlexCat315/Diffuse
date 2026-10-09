import Foundation
import EngineKernel
import GuavaUIRuntime

public extension View {
    func contextMenu(_ entries: [MenuEntry], width: Float = 240,
                     onOpen: (() -> Void)? = nil) -> ContextMenu<Self> {
        ContextMenu(width: width, entries: { entries }, onOpen: { onOpen?() }) { self }
    }
    func contextMenu(width: Float = 220, onOpen: @escaping () -> Void = {},
                     entries: @escaping () -> [MenuEntry]) -> ContextMenu<Self> {
        ContextMenu(width: width, entries: entries, onOpen: onOpen) { self }
    }
}

public struct ContextMenu<Content: View>: View {
    let content: Content; let entries: () -> [MenuEntry]; let width: Float; let onOpen: () -> Void
    @State private var point: CGPoint?
    public init(width: Float = 220, entries: @escaping () -> [MenuEntry],
                onOpen: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.content = content(); self.entries = entries
        self.width = width.isFinite ? max(80, width) : 220; self.onOpen = onOpen
    }
    public var body: some View {
        _ContextMenuHost(content: content, entries: point == nil ? [] : entries(), width: width, point: point,
                         onOpen: { position in onOpen(); point = position }, onDismiss: { point = nil })
    }
}

private struct _ContextMenuHost<Content: View>: _PrimitiveView {
    let content: Content; let entries: [MenuEntry]; let width: Float; let point: CGPoint?
    let onOpen: (CGPoint) -> Void; let onDismiss: () -> Void
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.addResource(PortalResource())
        node.attachments[LayoutDebugAttachmentKey.debugName] = "context-menu-anchor"
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }
    func _updateNode(_ node: Node) {
        let route = InputHandlerRoute(role: .control, priority: .chrome, debugName: "context-menu")
        InteractionRegistryHolder.current?.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .right || (event.button == .left && !event.modifiers.isDisjoint(with: .ctrl)) else { return .ignored }
            if phase == .down { onOpen(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) }
            return .handled
        }
        let resource = node.firstResource(PortalResource.self)
        guard let point else { resource?.dismiss(node: node); return }
        resource?.present(in: node.compositionValue(of: PortalStoreEnvironment.key), position: point, width: width,
                          content: AnyView(_PopupMenu(entries: entries, width: width, onDismiss: onDismiss)),
                          transition: .opacity.combined(with: .move(edge: .top, distance: 4)))
        resource?.setDismissal(anchor: { .zero }, dismiss: onDismiss)
    }
    var _children: [any View] { [content] }
}

struct _PopupMenu: View {
    let entries: [MenuEntry]; let width: Float; let onDismiss: () -> Void
    var body: some View {
        FocusScope(restoresCommands: true) {
            Menu(entries, width: width, maxVisibleRows: 12,
                 onItemActivated: onDismiss, onDismiss: onDismiss)
        }
    }
}

struct _MenuKeyHost<Content: View>: _PrimitiveView {
    let onKey: (KeyEvent) -> Bool; let content: Content
    init(onKey: @escaping (KeyEvent) -> Bool, @ViewBuilder content: () -> Content) { self.onKey = onKey; self.content = content() }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setKey(node, route: .overlay) { event, phase in
            guard phase != .capture else { return .ignored }
            return onKey(event) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}
