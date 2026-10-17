import Foundation
import GuavaUIRuntime

/// Bottom-sheet geometry and drag behavior.
public struct BottomSheetOptions {
    /// Sheet heights in logical points, from smallest to largest.
    public var detents: [Float] = [320, 560]
    public var initialDetent = 0
    public var showsHandle = true
    public var allowsDragToDismiss = true
    public var dragDismissThreshold: Float = 80
    public var dragDismissVelocity: Float = 900
    public var dismissal = ModalDismissal()
    /// Width used when the surface is expanded and the sheet degrades to a
    /// centered dialog-like panel.
    public var dialogWidth: Float = 560
    public var dialogInset: Float = 16
    public init() {}
}

/// Phone-first bottom sheet: full-width bottom panel on compact/medium
/// surfaces, centered dialog-like panel on expanded surfaces. The content
/// owns its layout; this component owns the handle, detents, and dismissal.
public struct BottomSheet<Content: View>: View {
    public let isPresented: Binding<Bool>
    public var options = BottomSheetOptions()
    private let content: Content

    @State private var detent: Int
    @State private var dragOffset: CGFloat = 0

    public init(isPresented: Binding<Bool>,
                configure: (inout BottomSheetOptions) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.content = content()
        configure(&options)
        options.detents = options.detents.filter { $0.isFinite && $0 > 0 }
        if options.detents.isEmpty { options.detents = [320, 560] }
        options.dragDismissThreshold = options.dragDismissThreshold.isFinite
            ? max(0, options.dragDismissThreshold) : 80
        options.dragDismissVelocity = options.dragDismissVelocity.isFinite
            ? max(0, options.dragDismissVelocity) : 900
        options.dialogWidth = options.dialogWidth.isFinite ? max(120, options.dialogWidth) : 560
        options.dialogInset = options.dialogInset.isFinite ? max(0, options.dialogInset) : 16
        _detent = State(wrappedValue: min(max(0, options.initialDetent), options.detents.count - 1))
    }

    public var body: some View {
        WidthClassReader { widthClass in
            let compact = widthClass != .expanded
            let height = options.detents[min(max(0, detent), options.detents.count - 1)]
            Modal(isPresented: isPresented, configure: { modal in
                modal.dismissal = options.dismissal
                modal.geometry.cornerRadius = 12
                if compact {
                    modal.geometry.placement = .bottom
                    modal.geometry.inset = 0
                    modal.geometry.width = .greatestFiniteMagnitude
                    modal.geometry.height = height
                } else {
                    modal.geometry.placement = .center
                    modal.geometry.inset = options.dialogInset
                    modal.geometry.width = options.dialogWidth
                    modal.geometry.height = height
                }
            }) {
                Box(direction: .column, alignItems: .stretch) {
                    if options.showsHandle {
                        BottomSheetDragHandle(
                            onTranslation: { translation in
                                dragOffset = max(-120, min(translation, 800))
                            },
                            onEnd: { translation, velocity in
                                settle(translation: translation, velocity: velocity)
                            }
                        )
                    }
                    content
                }
                .offset(y: Float(dragOffset))
                .debugName("bottom-sheet-content")
            }
        }
    }

    private func settle(translation: CGFloat, velocity: CGFloat) {
        let upward = CGFloat(-options.dragDismissThreshold)
        if translation < upward, detent + 1 < options.detents.count {
            detent += 1
        } else if translation > CGFloat(options.dragDismissThreshold)
                    || (velocity > CGFloat(options.dragDismissVelocity) && translation > 0) {
            if detent > 0 {
                detent -= 1
            } else if options.allowsDragToDismiss {
                isPresented.wrappedValue = false
            }
        }
        dragOffset = 0
    }
}

/// Full-width drag area with a centered visual grabber. The hit target is
/// 44pt tall even when the visible bar is only 4pt.
private struct BottomSheetDragHandle: _PrimitiveView {
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
        layout.setWidthPercent(100)
        layout.height = 44
        layout.flexDirection = .column
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.setWidthPercent(100)
        layout.height = 44
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
        [Box {}.frame(width: 36, height: 4).background(.onSurfaceMuted).cornerRadius(2)]
    }
}
