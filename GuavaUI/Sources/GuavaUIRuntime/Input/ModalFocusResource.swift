/// Restores the previous focus when a modal subtree leaves the window.
public final class ModalFocusResource: NodeResource {
    private weak var chain: FocusChain?
    public init() {}
    public func mount(node: Node) {}
    public func activate(node: Node, chain: FocusChain?) {
        guard self.chain == nil, let chain else { return }
        self.chain = chain
        if let capture = PointerCaptureHolder.current, let target = capture.target,
           !chain.contains(target, in: node) { capture.release() }
        chain.beginModal(node)
    }
    public func unmount(node: Node) {
        chain?.endModal(node)
        chain = nil
    }
}
