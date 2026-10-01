#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

/// Centered, window-sized modal with focus trapping and focus restoration.
/// The application root must provide a PortalHost (normally through LayerRoot).
public struct Modal<Content: View>: View {
    let isPresented: Binding<Bool>
    let onDismiss: (() -> Void)?
    let content: Content
    public init(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.isPresented = isPresented
        self.onDismiss = onDismiss
        self.content = content()
    }
    public var body: some View {
        if isPresented.wrappedValue {
            _ModalPresenter(content: content, onDismiss: {
                onDismiss?()
                isPresented.wrappedValue = false
            })
        }
    }
}

private struct _ModalPresenter<Content: View>: _PrimitiveView {
    let content: Content
    let onDismiss: () -> Void
    func _makeNode() -> Node {
        let node = Node()
        node.addResource(PortalResource())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { nil }
    func _updateNode(_ node: Node) {
        present(node)
        node.layoutDidUpdate = { node in
            var root = node
            while let parent = root.parent { root = parent }
            if node.attachments["modal.windowSize"] as? CGSize != root.frame.size { present(node) }
        }
    }
    private func present(_ node: Node) {
        var root = node
        while let parent = root.parent { root = parent }
        let size = root.frame.size
        node.attachments["modal.windowSize"] = size
        node.firstResource(PortalResource.self)?.present(
            in: node.compositionValue(of: PortalStoreEnvironment.key), position: .zero,
            width: Float(size.width), constrainToWindow: false,
            content: AnyView(_ModalSurface(size: size, content: content, onDismiss: onDismiss)))
    }
}

private struct _ModalSurface<Content: View>: _PrimitiveView {
    let size: CGSize
    let content: Content
    let onDismiss: () -> Void
    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.addResource(ModalFocusResource())
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) {
        layout.width = Float(size.width)
        layout.height = Float(size.height)
        layout.flexDirection = .column
        layout.alignItems = .center
        layout.justifyContent = .center
    }
    func _updateNode(_ node: Node) {
        node.backgroundColor = Color(r: 0, g: 0, b: 0, a: 0.25)
        node.firstResource(ModalFocusResource.self)?.activate(node: node, chain: FocusChainHolder.current)
        let chain = FocusChainHolder.current
        node.layoutDidUpdate = { _ in chain?.ensureModalFocus() }
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { _, _, phase in phase == .target ? .handled : .ignored }
        registry.setWheel(node) { _, phase in phase == .capture ? .ignored : .handled }
        registry.setKey(node) { event, phase in
            guard phase != .capture else { return .ignored }
            if event.scancode == Scancode.escape { onDismiss() }
            return .handled
        }
    }
    var _children: [any View] {
        [TransitionView(isVisible: true, transition: .opacity.combined(with: .offset(y: 12)), motion: .fast) {
            content
        }
        .frame(width: min(960, max(0, Float(size.width) - 48)),
               height: min(720, max(0, Float(size.height) - 64)))]
    }
}
