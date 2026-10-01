import Foundation
import GuavaUIRuntime

public struct Modal<Content: View>: View {
    private let isPresented: Binding<Bool>
    private let width: Float
    private let height: Float
    private let content: Content
    public init(isPresented: Binding<Bool>, width: Float = 760, height: Float = 560,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented; self.width = width; self.height = height; self.content = content()
    }
    @State private var retained = false
    public var body: some View {
        _ModalPresenter(isPresented: isPresented, retained: retained, width: width, height: height,
                        content: content, onPresented: { if !retained { retained = true } },
                        onExited: { if retained { retained = false } })
    }
}

private struct _ModalPresenter<Content: View>: _PrimitiveView {
    let isPresented: Binding<Bool>; let retained: Bool
    let width: Float; let height: Float; let content: Content
    let onPresented: () -> Void; let onExited: () -> Void
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = false; node.addResource(PortalResource()); return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        present(node)
        node.layoutDidUpdate = { node in
            if node.attachments["modal.windowBounds"] as? CGRect != portalWindowBounds(node) { present(node) }
        }
    }
    private func present(_ node: Node) {
        node.attachments["modal.windowBounds"] = portalWindowBounds(node)
        let resource = node.firstResource(PortalResource.self)
        guard isPresented.wrappedValue || retained else { resource?.unmount(node: node); return }
        if isPresented.wrappedValue { onPresented() }
        let store = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        resource?.present(in: store, position: .zero, width: nil,
                          content: AnyView(AnimatedVisibility(isVisible: isPresented.wrappedValue,
                            transition: .opacity, animateOnMount: true,
                            onVisibilitySettled: { visible in if !visible { onExited() } }) {
                              FocusScope {
                                _ModalBackdrop(width: width, height: height, onDismiss: { isPresented.wrappedValue = false }, content: content)
                              }
                          }.frame(width: .percent(100), height: .percent(100))), fillsWindow: true)
    }
    var _children: [any View] { [] }
}

private struct _ModalBackdrop<Content: View>: _PrimitiveView {
    let width: Float; let height: Float; let onDismiss: () -> Void; let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = true; return node }
    func _updateNode(_ node: Node) {
        node.backgroundColor = node.theme.colors.background.multipliedAlpha(0.6)
        InteractionRegistryHolder.current?.setPointer(node, route: InputHandlerRoute(role: .control, priority: .modal, debugName: "modal.backdrop")) { _, phase, eventPhase in
            guard eventPhase == .target else { return .ignored }
            if phase == .down { onDismiss() }; return .handled
        }
        InteractionRegistryHolder.current?.setKey(node, route: .overlay) { event, _ in
            if event.scancode == Scancode.escape { onDismiss(); return .handled }; return .ignored
        }
        InteractionRegistryHolder.current?.setWheel(node) { _, phase in phase == .capture ? .ignored : .handled }
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.positionType = .absolute
        layout.setPosition(0, edge: .left); layout.setPosition(0, edge: .top)
        layout.setPosition(0, edge: .right); layout.setPosition(0, edge: .bottom)
        layout.flexDirection = .column; layout.alignItems = .center; layout.justifyContent = .center
        return layout
    }
    func _children(for node: Node) -> [any View] {
        let bounds = portalWindowBounds(node)
        return [AnimatedVisibility(isVisible: true, transition: .opacity.combined(with: .move(edge: .bottom, distance: 12)), animateOnMount: true) {
            content.frame(width: .percent(100), height: .percent(100))
                .background(.surface).cornerRadius(8).border(.border, width: 1)
        }
        // The animation host must own the dialog's size: flexible content
        // otherwise has no definite height and can collapse to its flex basis.
        .frame(width: min(width, Float(max(0, bounds.width - 32))),
               height: min(height, Float(max(0, bounds.height - 32))))]
    }
}
