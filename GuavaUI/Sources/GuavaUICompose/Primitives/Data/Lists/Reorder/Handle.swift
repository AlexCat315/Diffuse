import Foundation
import GuavaUIRuntime

enum _ReorderHandleKeys {
    static let active = "__reorder.active"
    static let startY = "__reorder.startY"
    static let hovered = "__reorder.hovered"
    static let lastY = "__reorder.lastY"
    static let report = "__reorder.report"
}

/// Drag/focus handle behind one reorderable row. Interaction state lives on
/// the node so a parent recompose mid-drag keeps the pointer transaction.
struct _ReorderHandle: _PrimitiveView {
    let index: Int
    let count: Int
    let label: String
    let isEnabled: Bool
    let isDragging: Bool
    let rowHeight: Float
    let onStart: () -> Void
    /// Pointer travel and automatic scroll distance since the drag began.
    let onDelta: (CGFloat, CGFloat) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onStep: (Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.addResource(EdgeAutoScroll())
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 44
        layout.height = rowHeight
        layout.flexShrink = 0
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        node.isFocusable = isEnabled
        node.attachments[LayoutDebugAttachmentKey.debugName] = "reorder-handle-\(index)"
        node.cornerRadius = 6
        node.cursor = isEnabled ? .pointer : nil
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = label
            $0.value = "Position \(index + 1) of \(count)"
            $0.help = "Drag the handle, or use Up and Down to move this row."
            $0.state.isEnabled = isEnabled
            $0.state.isSelected = isDragging
        }
        node.accessibilityActions.increment = isEnabled ? { onStep(1) } : nil
        node.accessibilityActions.decrement = isEnabled ? { onStep(-1) } : nil

        let applyBackground: (Bool) -> Void = { hovered in
            let active = node.attachments[_ReorderHandleKeys.active] as? Bool == true
            node.backgroundColor = active ? node.theme.colors.stateLayerPressed
                : (hovered && isEnabled ? node.theme.colors.stateLayerHover : .clear)
        }
        // The drag position is pointer travel plus any automatic scroll, so the
        // drop boundary stays in content coordinates while the list scrolls.
        let autoScroll = node.firstResource(EdgeAutoScroll.self)
        node.attachments[_ReorderHandleKeys.report] = { [weak node] in
            guard let node, let start = node.attachments[_ReorderHandleKeys.startY] as? Float,
                  let last = node.attachments[_ReorderHandleKeys.lastY] as? Float else { return }
            onDelta(CGFloat(last - start), autoScroll?.scrolledDistance ?? 0)
        }
        let report: () -> Void = { [weak node] in (node?.attachments[_ReorderHandleKeys.report] as? () -> Void)?() }
        applyBackground(node.attachments[_ReorderHandleKeys.hovered] as? Bool == true)
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { phase in
            let hovered = phase == .enter && node.supportsControlHover
            node.attachments[_ReorderHandleKeys.hovered] = hovered
            applyBackground(hovered)
        }
        registry.setPointer(node) { event, phase, _ in
            guard isEnabled, event.button == .left else { return .ignored }
            switch phase {
            case .down:
                node.attachments[_ReorderHandleKeys.active] = true
                node.attachments[_ReorderHandleKeys.startY] = event.y
                node.attachments[_ReorderHandleKeys.lastY] = event.y
                autoScroll?.begin(pointerY: event.y, onScroll: report)
                PointerCaptureHolder.current?.acquire(node)
                applyBackground(true)
                onStart()
                return .handled
            case .up:
                guard node.attachments[_ReorderHandleKeys.active] as? Bool == true else {
                    return .ignored
                }
                node.attachments[_ReorderHandleKeys.active] = false
                node.attachments.removeValue(forKey: _ReorderHandleKeys.startY)
                autoScroll?.end()
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                applyBackground(node.attachments[_ReorderHandleKeys.hovered] as? Bool == true)
                onEnd()
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard node.attachments[_ReorderHandleKeys.active] as? Bool == true else { return .ignored }
            node.attachments[_ReorderHandleKeys.lastY] = event.y
            autoScroll?.update(pointerY: event.y)
            report()
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase != .capture, isEnabled else { return .ignored }
            switch event.scancode {
            case Scancode.arrowUp:
                onStep(-1)
                return .handled
            case Scancode.arrowDown:
                onStep(1)
                return .handled
            case Scancode.escape:
                guard node.attachments[_ReorderHandleKeys.active] as? Bool == true else {
                    return .ignored
                }
                node.attachments[_ReorderHandleKeys.active] = false
                node.attachments.removeValue(forKey: _ReorderHandleKeys.startY)
                autoScroll?.end()
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                onCancel()
                return .handled
            default:
                return .ignored
            }
        }
    }

    var _children: [any View] {
        [Icon(UIIcons.Action.grip, size: .small, color: .onSurfaceMuted)
            .iconScaling(.fixed)
            .accessibilityHidden()]
    }
}

