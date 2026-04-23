import CoreGraphics
import GuavaUIRuntime

/// Renders one split node — two child layouts arranged along `axis` with a
/// draggable resize handle between them.
struct _DockSplit: View {
    let splitID: DockNodeID
    let axis: DockSplitAxis
    let fraction: Float
    let first: DockLayoutNode
    let second: DockLayoutNode
    let controller: DockController
    let content: DockContentResolver

    var body: some View {
        let f = clampFraction(fraction)
        let direction: FlexDirection = (axis == .horizontal) ? .row : .column
        return Box(direction: direction, alignItems: .stretch, spacing: 0) {
            _DockNodeView(node: first, controller: controller, content: content)
                .flex(f, shrink: 1, basis: 0)
            _DockResizeHandle(splitID: splitID, axis: axis, controller: controller)
            _DockNodeView(node: second, controller: controller, content: content)
                .flex(1 - f, shrink: 1, basis: 0)
        }
    }
}

/// Draggable separator between two split children. Acquires pointer capture
/// on `down`, maps subsequent motion to a fraction relative to its parent
/// (the split `Box`'s frame), and pushes a `.resizeSplit` op to the
/// controller. Hit-slop widens the grab area without changing the visible
/// 1-px line, mirroring how OS resize handles feel.
struct _DockResizeHandle: _PrimitiveView {
    let splitID: DockNodeID
    let axis: DockSplitAxis
    let controller: DockController

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        return n
    }

    func _updateNode(_ node: Node) {
        // The handle node itself is a transparent hit-pad sized to the
        // full hit area (`splitDividerThickness + 2 * splitDividerHitSlop`).
        // The visible coloured line is painted by a single child node
        // inserted via `_children(for:)` so the visual stays at the
        // configured thickness while the grab area is wider.
        let appearance = resolveDockAppearance(on: node)
        node.backgroundColor = nil
        node.cursor = (axis == .horizontal) ? .resizeHorizontal : .resizeVertical

        let total = appearance.splitDividerThickness + appearance.splitDividerHitSlop * 2
        switch axis {
        case .horizontal:
            node.layoutNode?.width = total
        case .vertical:
            node.layoutNode?.height = total
        }

        let snapshot = self
        guard let registry = InteractionRegistryHolder.current else { return }

        registry.setPointer(node) { _, phase, _ in
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                return .handled
            case .up:
                PointerCaptureHolder.current?.release()
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            // Only react when the handle is actively being dragged. The
            // capture target is set on `.down` and cleared on `.up`, so
            // checking the holder gives a cheap drag-active gate.
            guard PointerCaptureHolder.current?.target === node else {
                return .ignored
            }
            snapshot.applyDrag(windowX: event.x, windowY: event.y, node: node)
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        // The hit-pad layout-node also centres its single child via
        // alignItems / justifyContent so the visible line sits in the
        // middle of the slop zone.
        switch axis {
        case .horizontal:
            l.flexDirection = .row
            l.alignItems = .stretch
            l.justifyContent = .center
            l.width = 1
        case .vertical:
            l.flexDirection = .column
            l.alignItems = .stretch
            l.justifyContent = .center
            l.height = 1
        }
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        switch axis {
        case .horizontal:
            layout.flexDirection = .row
            layout.alignItems = .stretch
            layout.justifyContent = .center
            if (layout.width ?? 0) <= 0 { layout.width = 1 }
        case .vertical:
            layout.flexDirection = .column
            layout.alignItems = .stretch
            layout.justifyContent = .center
            if (layout.height ?? 0) <= 0 { layout.height = 1 }
        }
    }

    func _children(for node: Node) -> [any View] {
        return [_DockResizeHandleVisual(axis: axis)]
    }

    private func applyDrag(windowX: Float, windowY: Float, node: Node) {
        // The parent of the handle is the split's `Box` node; its frame is
        // the available space along the split axis.
        guard let parent = node.parent else { return }
        let parentOrigin = absoluteOrigin(of: parent)
        switch axis {
        case .horizontal:
            let width = max(1, Float(parent.frame.width))
            let local = windowX - parentOrigin.x
            let fraction = local / width
            controller.apply(.resizeSplit(node: splitID, fraction: fraction))
        case .vertical:
            let height = max(1, Float(parent.frame.height))
            let local = windowY - parentOrigin.y
            let fraction = local / height
            controller.apply(.resizeSplit(node: splitID, fraction: fraction))
        }
    }

    private func absoluteOrigin(of node: Node) -> (x: Float, y: Float) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var cursor: Node? = node
        while let n = cursor {
            x += n.frame.origin.x
            y += n.frame.origin.y
            cursor = n.parent
        }
        return (Float(x), Float(y))
    }
}

/// The visible coloured line painted in the centre of the resize handle's
/// hit-pad. Width/height equal `appearance.splitDividerThickness`; the
/// surrounding hit slop stays transparent.
struct _DockResizeHandleVisual: _PrimitiveView {
    let axis: DockSplitAxis

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        node.backgroundColor = appearance.splitDividerColor
        let thickness = max(1, appearance.splitDividerThickness)
        switch axis {
        case .horizontal:
            node.layoutNode?.width = thickness
        case .vertical:
            node.layoutNode?.height = thickness
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        switch axis {
        case .horizontal:
            l.width = 1
            l.alignSelf = .stretch
        case .vertical:
            l.height = 1
            l.alignSelf = .stretch
        }
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        switch axis {
        case .horizontal:
            layout.alignSelf = .stretch
            if (layout.width ?? 0) <= 0 { layout.width = 1 }
        case .vertical:
            layout.alignSelf = .stretch
            if (layout.height ?? 0) <= 0 { layout.height = 1 }
        }
    }
}
