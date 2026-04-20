import Foundation

/// Tracks the currently focused node and provides tab-order traversal.
///
/// Focus chain order = depth-first, in tree order, including only nodes with
/// `isFocusable == true`. Recomputed lazily when callers ask for next/previous.
public final class FocusChain {

    public private(set) weak var focused: Node?

    public init() {}

    public func focus(_ node: Node?) {
        focused = node
    }

    /// Move focus to the next focusable node in tree order, wrapping around.
    /// Returns the node that received focus, or nil if no focusable nodes exist.
    @discardableResult
    public func focusNext(in root: Node) -> Node? {
        let chain = focusables(in: root)
        guard !chain.isEmpty else { focused = nil; return nil }

        guard let cur = focused,
              let i = chain.firstIndex(where: { $0 === cur }) else {
            focused = chain.first
            return chain.first
        }
        let next = chain[(i + 1) % chain.count]
        focused = next
        return next
    }

    @discardableResult
    public func focusPrevious(in root: Node) -> Node? {
        let chain = focusables(in: root)
        guard !chain.isEmpty else { focused = nil; return nil }

        guard let cur = focused,
              let i = chain.firstIndex(where: { $0 === cur }) else {
            focused = chain.last
            return chain.last
        }
        let prev = chain[(i - 1 + chain.count) % chain.count]
        focused = prev
        return prev
    }

    public func clear() {
        focused = nil
    }

    // MARK: - Internal

    private func focusables(in root: Node) -> [Node] {
        var out: [Node] = []
        collect(node: root, into: &out)
        return out
    }

    private func collect(node: Node, into out: inout [Node]) {
        if node.isFocusable { out.append(node) }
        for c in node.children { collect(node: c, into: &out) }
    }
}
