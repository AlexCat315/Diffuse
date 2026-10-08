import Foundation
import GuavaUIRuntime

final class DataTableFocusTarget {
    weak var node: Node?
    func focus() { if let node { FocusChainHolder.current?.focus(node) } }
}
struct DataTableInputHost<Content: View>: _PrimitiveView {
    let focus: DataTableFocusTarget
    let isEnabled: Bool
    let onKey: (KeyEvent) -> Bool
    let content: Content
    func _makeNode() -> Node { Node() }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.flexDirection = .column; layout.alignItems = .stretch
        layout.flexGrow = 1; layout.flexShrink = 1; return layout
    }
    func _updateNode(_ node: Node) {
        focus.node = node; node.isFocusable = isEnabled; node.attachments["dataTable.input"] = true
        InteractionRegistryHolder.current?.setKey(node) { event, phase in
            guard isEnabled, phase != .capture else { return .ignored }
            return onKey(event) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}

/// A clipped pane whose child is moved in layout coordinates, so hit testing,
/// drawing and accessibility all agree. Used by the fixed header and columns.
struct DataTableClippedPane<Content: View>: _PrimitiveView {
    let onWheel: (MouseWheelEvent) -> Bool
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.clipsToBounds = true; node.isHitTestable = true; return node }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .stretch; return layout }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setWheel(node) { event, phase in
            guard phase != .capture else { return .ignored }
            return onWheel(event) ? .handled : .ignored
        }
    }
    var _children: [any View] { [content] }
}

struct DataTableRowHost<Content: View>: _PrimitiveView {
    let index: Int
    let isSelected: Bool
    let isStriped: Bool
    let isEnabled: Bool
    let isFrozenLane: Bool
    let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .stretch; return layout }
    func _updateNode(_ node: Node) {
        node.attachments["dataTable.rowIndex"] = index
        node.backgroundColor = isSelected ? node.theme.colors.selection : isStriped && index % 2 == 1 ? node.theme.colors.surfaceVariant : node.theme.colors.surface
        node.accessibility = AccessibilitySemantics(isFrozenLane ? .group : .row) {
            $0.label = "Row \(index + 1)"; $0.state.isSelected = isSelected; $0.state.isEnabled = isEnabled
        }
        node.updateDraw(identity: index) { list, origin in
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y + node.frame.height) - 1,
                                width: Float(node.frame.width), height: 1), color: node.theme.colors.border.multipliedAlpha(node.opacity * 0.5))
        }
    }
    var _children: [any View] { [content] }
}

struct DataTableCellHost<Content: View>: _PrimitiveView {
    let title: String
    let isActive: Bool
    let isEnabled: Bool
    let onSelect: (KeyModifiers) -> Void
    let onEdit: () -> Void
    let content: Content
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.automaticallyFocusOnPointerDown = false; return node
    }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .stretch; layout.flexGrow = 1; return layout }
    func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.cell) { $0.label = title; $0.state.isSelected = isActive; $0.state.isEnabled = isEnabled }
        node.accessibilityActions.activate = isEnabled ? { onSelect([]) } : nil
        node.backgroundColor = nil; node.borderWidth = isActive ? 1 : 0; node.borderColor = node.theme.colors.focusRing
        guard isEnabled else { InteractionRegistryHolder.current?.remove(node); return }
        InteractionRegistryHolder.current?.setHover(node) { node.backgroundColor = $0 == .enter ? node.theme.colors.stateLayerHover : nil }
        InteractionRegistryHolder.current?.setPointer(node) { event, phase, eventPhase in
            guard event.button == .left, eventPhase != .capture else { return .ignored }
            if phase == .down { onSelect(event.modifiers); if event.clicks >= 2 { onEdit() } }
            return .handled
        }
    }
    var _children: [any View] { [content] }
}
