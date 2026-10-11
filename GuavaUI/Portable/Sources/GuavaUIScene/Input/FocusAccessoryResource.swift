import GuavaUICore

/// A portal's logical scope relationship has exactly the portal node's lifetime.
public final class FocusAccessoryResource: NodeResource {
    private weak var owner: Node?
    private weak var chain: FocusChain?
    private weak var capture: PointerCapture?
    public init(owner: Node) { self.owner = owner }
    public func mount(node: Node) {
        chain = FocusChainHolder.current; capture = PointerCaptureHolder.current
        if let owner { chain?.attachAccessory(node, owner: owner) }
    }
    public func unmount(node: Node) {
        if let captured = capture?.target, chain?.contains(captured, in: node) == true { capture?.release() }
        chain?.detachAccessory(node); chain = nil; capture = nil
    }
}
