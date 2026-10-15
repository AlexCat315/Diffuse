import GuavaUICore
/// Restores the previous focus when a modal subtree leaves the window.
public final class ModalFocusResource: NodeResource {
    private weak var chain: FocusChain?
    /// Inspection must use the scope's owning window rather than ambient input
    /// from a different window when an agent query arrives between frames.
    package var boundFocusChain: FocusChain? { chain }
    public init() {}
    public func mount(node: Node) {}
    public func bind(_ node: Node, chain next: FocusChain?, restoresCommands: Bool = false) {
        if chain !== next { chain?.popScope(node); chain = next }
        next?.pushScope(node, restoresCommands: restoresCommands)
        if let captured = PointerCaptureHolder.current?.target, next?.permitsInput(captured) == false {
            PointerCaptureHolder.current?.release()
        }
    }
    public func activate(node: Node, chain: FocusChain?) {
        bind(node, chain: chain)
    }
    public func unmount(node: Node) {
        chain?.endModal(node)
        chain = nil
    }
}
