import Foundation
import GuavaUIRuntime

public struct Modal<Content: View>: View {
    private let isPresented: Binding<Bool>
    public var options = ModalOptions()
    private var fittingGeometry: ((inout ModalGeometry, CGSize) -> Void)?
    private let content: Content
    public init(isPresented: Binding<Bool>, configure: (inout ModalOptions) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented; self.content = content(); configure(&options); options.geometry.validate()
    }
    init(isPresented: Binding<Bool>, configure: (inout ModalOptions) -> Void,
         fittingGeometry: @escaping (inout ModalGeometry, CGSize) -> Void,
         @ViewBuilder content: () -> Content) {
        self.init(isPresented: isPresented, configure: configure, content: content)
        self.fittingGeometry = fittingGeometry
    }
    @State private var retained = false
    public var body: some View {
        _ModalPresenter(isPresented: isPresented, retained: retained, options: options, fittingGeometry: fittingGeometry,
                        content: content, onPresented: { if !retained { retained = true } },
                        onExited: { if retained { retained = false } })
    }
}

private struct _ModalPresenter<Content: View>: _PrimitiveView {
    let isPresented: Binding<Bool>; let retained: Bool
    let options: ModalOptions
    let fittingGeometry: ((inout ModalGeometry, CGSize) -> Void)?
    let content: Content
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
        var fitted = options
        fittingGeometry?(&fitted.geometry, portalWindowBounds(node).size)
        fitted.geometry.fitCompactWindow(portalWindowBounds(node).size)
        resource?.present(in: store, position: .zero, width: nil,
                          content: AnyView(AnimatedVisibility(isVisible: isPresented.wrappedValue,
                            transition: .opacity, animateOnMount: true,
                            onVisibilitySettled: { visible in if !visible { onExited() } }) {
                              FocusScope {
                                _ModalBackdrop(isVisible: isPresented.wrappedValue, options: fitted, onDismiss: { isPresented.wrappedValue = false }, content: content)
                              }
                          }.frame(width: .percent(100), height: .percent(100))), fillsWindow: true)
    }
    var _children: [any View] { [] }
}

private struct _ModalBackdrop<Content: View>: _PrimitiveView {
    let isVisible: Bool
    let options: ModalOptions; let onDismiss: () -> Void; let content: Content
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = true; node.clipsToBounds = true; return node }
    func _updateNode(_ node: Node) {
        switch options.backdrop {
        case .standard: node.backgroundColor = node.theme.colors.overlay
        case .dimmed: node.backgroundColor = Color.black.multipliedAlpha(0.2)
        }
        InteractionRegistryHolder.current?.setPointer(node, route: InputHandlerRoute(role: .control, priority: .modal, debugName: "modal.backdrop")) { event, phase, eventPhase in
            guard eventPhase == .target else { return .ignored }
            guard event.button == .left else { return .handled }
            if options.dismissal.closesOnBackdrop && phase == .down { onDismiss() }; return .handled
        }
        InteractionRegistryHolder.current?.setKey(node, route: .overlay) { event, _ in
            if event.scancode == Scancode.escape { if options.dismissal.closesOnEscape { onDismiss() }; return .handled }; return .ignored
        }
        InteractionRegistryHolder.current?.setWheel(node) { _, phase in phase == .capture ? .ignored : .handled }
    }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.positionType = .absolute
        layout.setPosition(0, edge: .left); layout.setPosition(0, edge: .top)
        layout.setPosition(0, edge: .right); layout.setPosition(0, edge: .bottom)
        // `inset` is the documented margin from the window edge, not only a
        // cap on the dialog size. Without padding, top/bottom placement put a
        // rounded panel flush against the window and clipped its corners.
        if options.geometry.inset > 0 {
            layout.setPadding(options.geometry.inset, edge: .all)
        }
        layout.flexDirection = .column
        layout.alignItems = options.geometry.placement == .leading ? .flexStart : options.geometry.placement == .trailing ? .flexEnd : .center
        layout.justifyContent = options.geometry.placement == .bottom ? .flexEnd : options.geometry.placement == .top ? .flexStart : .center
        return layout
    }
    func _children(for node: Node) -> [any View] {
        let bounds = portalWindowBounds(node)
        let size = CGSize(width: min(CGFloat(options.geometry.width), max(0, bounds.width - CGFloat(options.geometry.inset * 2))),
                          height: min(CGFloat(options.geometry.height), max(0, bounds.height - CGFloat(options.geometry.inset * 2))))
        return [AnimatedVisibility(isVisible: isVisible, transition: options.geometry.transition(size: size), animateOnMount: true) {
            content.frame(width: .percent(100), height: options.fitsContentHeight ? nil : .percent(100)).accessibility { $0.role = .dialog }
                .background(options.surface).cornerRadius(options.geometry.cornerRadius).border(.border, width: 1).surfaceFinish()
        }
        // Fixed dialogs need a definite animation-host height for flexible
        // content. Action sheets instead measure their bounded intrinsic height.
        .frame(width: Float(size.width), height: options.fitsContentHeight ? nil : Float(size.height), maxHeight: Float(size.height))
        .offset(y: options.translationY)]
    }
}
