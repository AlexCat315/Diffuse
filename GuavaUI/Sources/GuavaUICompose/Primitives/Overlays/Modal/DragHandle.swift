internal import Foundation
internal import GuavaUIRuntime

/// Full-width drag area with a centered visual grabber. The hit target is
/// 44pt tall even when the visible bar is only 4pt.
struct SheetDragHandle: _PrimitiveView {
    let onTranslation: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    final class DragState {
        var startY: CGFloat = 0
        var lastY: CGFloat = 0
        var lastTime: Double = 0
        var translation: CGFloat = 0
        var velocity: CGFloat = 0
        var active = false

        func begin(_ y: CGFloat, at time: Double) {
            startY = y
            lastY = y
            lastTime = time
            translation = 0
            velocity = 0
            active = true
        }

        func move(to y: CGFloat, at time: Double) {
            guard active else { return }
            let delta = time - lastTime
            if delta > 0.001 {
                velocity = (y - lastY) / CGFloat(delta)
            }
            lastY = y
            lastTime = time
            translation = y - startY
        }
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.attachments["bottom-sheet.drag"] = DragState()
        node.attachments[LayoutDebugAttachmentKey.debugName] = "bottom-sheet-handle"
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = 44
        layout.alignSelf = .stretch
        layout.flexDirection = .column
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.height = 44
        layout.alignSelf = .stretch
        layout.flexDirection = .column
        layout.alignItems = .center
        layout.justifyContent = .center
    }

    func _updateNode(_ node: Node) {
        node.isHitTestable = true
        node.attachments[LayoutDebugAttachmentKey.debugName] = "bottom-sheet-handle"
        node.accessibility = AccessibilitySemantics(.button) { $0.label = "Resize sheet" }
        let state = (node.attachments["bottom-sheet.drag"] as? DragState) ?? {
            let created = DragState()
            node.attachments["bottom-sheet.drag"] = created
            return created
        }()
        let route = InputHandlerRoute(role: .drag, priority: .chrome,
                                      debugName: "bottom-sheet.handle")
        InteractionRegistryHolder.current?.setPointer(node, route: route) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            if phase == .down {
                state.begin(CGFloat(event.y), at: ProcessInfo.processInfo.systemUptime)
                onTranslation(0)
                PointerCaptureHolder.current?.acquire(node)
            } else {
                state.active = false
                PointerCaptureHolder.current?.release()
                onEnd(state.translation, state.velocity)
            }
            return .handled
        }
        InteractionRegistryHolder.current?.setMotion(node, route: route) { event, _ in
            guard state.active else { return .ignored }
            state.move(to: CGFloat(event.y), at: ProcessInfo.processInfo.systemUptime)
            onTranslation(state.translation)
            return .handled
        }
    }

    var _children: [any View] {
        [Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Box {}.frame(width: 36, height: 4).background(.onSurfaceMuted).cornerRadius(2)
        }.frame(width: .percent(100), height: .points(44))]
    }
}
