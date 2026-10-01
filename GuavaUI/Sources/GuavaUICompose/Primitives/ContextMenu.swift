#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import EngineKernel
import GuavaUIRuntime

/// Window-local context menu, opened by right-click without starting a row drag.
public struct ContextMenu<Content: View>: View {
    let content: Content
    let width: Float
    let entries: () -> [MenuEntry]
    let onOpen: () -> Void
    @State private var position: CGPoint? = nil
    @State private var highlightedIndex = 0

    public init(width: Float = 220, entries: @escaping () -> [MenuEntry],
                onOpen: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.width = width
        self.entries = entries
        self.onOpen = onOpen
        self.content = content()
    }

    public var body: some View {
        let menuEntries = position == nil ? [] : entries()
        let items = menuEntries.compactMap { entry -> MenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        }
        _ContextMenuRegion(content: content, position: position, width: width,
                           menu: AnyView(Menu(menuEntries, width: width, highlightedIndex: highlightedIndex,
                                              onItemActivated: { position = nil })),
                           onOpen: { point in
                               onOpen()
                               highlightedIndex = 0
                               position = point
                           }, onDismiss: { position = nil }, onKey: { event in
            switch event.scancode {
            case Scancode.escape, Scancode.tab:
                position = nil
            case Scancode.arrowDown, Scancode.arrowUp:
                guard !items.isEmpty else { return }
                let direction = event.scancode == Scancode.arrowDown ? 1 : -1
                var next = highlightedIndex
                for _ in items.indices {
                    next = (next + direction + items.count) % items.count
                    if items[next].isEnabled { highlightedIndex = next; break }
                }
            case Scancode.return, Scancode.keypadEnter:
                if items.indices.contains(highlightedIndex), items[highlightedIndex].isEnabled {
                    position = nil
                    items[highlightedIndex].action()
                }
            default: break
            }
        })
    }
}

private struct _ContextMenuRegion<Content: View>: _PrimitiveView {
    let content: Content
    let position: CGPoint?
    let width: Float
    let menu: AnyView
    let onOpen: (CGPoint) -> Void
    let onDismiss: () -> Void
    let onKey: (KeyEvent) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.addResource(PortalResource())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }
    func _updateNode(_ node: Node) {
        let resource = node.firstResource(PortalResource.self)
        if let position {
            resource?.present(in: node.compositionValue(of: PortalStoreEnvironment.key),
                              position: position, width: width, content: menu)
        } else { resource?.unmount(node: node) }
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node, route: position == nil ? .control : .overlay) { event, pointerPhase, phase in
            let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
            if position != nil {
                if resource?.frame?.contains(point) == true { return .ignored }
                if pointerPhase == .down { onDismiss(); return .handled }
                return .ignored
            }
            guard phase == .capture || phase == .target, event.button == .right else { return .ignored }
            if pointerPhase == .down { onOpen(point) }
            return .handled
        }
        if position != nil {
            registry.setKey(node, route: .overlay) { event, _ in onKey(event); return .handled }
        } else {
            registry.setKey(node) { _, _ in .ignored }
        }
    }
    var _children: [any View] { [content] }
}

public extension View {
    func contextMenu(width: Float = 220, onOpen: @escaping () -> Void = {},
                     entries: @escaping () -> [MenuEntry]) -> ContextMenu<Self> {
        ContextMenu(width: width, entries: entries, onOpen: onOpen) { self }
    }
}
