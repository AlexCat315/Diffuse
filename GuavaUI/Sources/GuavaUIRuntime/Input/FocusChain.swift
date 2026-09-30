import Foundation

/// Tracks the currently focused node and provides tab-order traversal.
///
/// Focus chain order = depth-first, in tree order, including only nodes with
/// `isFocusable == true`. Recomputed lazily when callers ask for next/previous
/// by walking the live `Node` tree (Phase 7: the input mirror was removed).
public final class FocusChain {

    public private(set) weak var focused: Node?

    private final class Scope {
        weak var root: Node?
        weak var previous: Node?
        weak var previousTreeRoot: Node?
        init(root: Node, previous: Node?) {
            self.root = root
            self.previous = previous
            var ancestor = previous
            while let parent = ancestor?.parent { ancestor = parent }
            previousTreeRoot = ancestor
        }
    }
    private var scopes: [Scope] = []
    public var modalRoot: Node? { scopes.last?.root }

    public init() {}

    public func contains(_ node: Node, in root: Node) -> Bool {
        var cursor: Node? = node
        while let current = cursor {
            if current === root { return true }
            cursor = current.parent
        }
        return false
    }

    public func beginModal(_ root: Node) {
        guard !scopes.contains(where: { $0.root === root }) else { return }
        scopes.append(Scope(root: root, previous: focused))
        if let focused, !contains(focused, in: root) { focus(nil) }
    }

    public func endModal(_ root: Node) {
        guard let index = scopes.firstIndex(where: { $0.root === root }) else { return }
        let scope = scopes.remove(at: index)
        guard index == scopes.count else { return }
        if let previous = scope.previous, let treeRoot = scope.previousTreeRoot,
           contains(previous, in: treeRoot), previous.isFocusable {
            focus(previous)
        } else {
            focus(nil)
            ensureModalFocus()
        }
    }

    public func ensureModalFocus() {
        guard let root = modalRoot else { return }
        if let focused, contains(focused, in: root), focused.isFocusable { return }
        let candidates = focusables(in: root)
        focus(candidates.first { $0.attachments[TextInputAttachmentKey.focusChangeHandler] != nil } ?? candidates.first)
    }

    public func focus(_ node: Node?) {
        if let node {
            var cursor: Node? = node
            while let current = cursor {
                guard current.isInteractionEnabled else { return }
                cursor = current.parent
            }
        }
        if let node, let root = modalRoot, !contains(node, in: root) { return }
        guard focused !== node else { return }
        let previous = focused
        focused = node
        notifyFocusChange(for: previous, isFocused: false)
        notifyFocusChange(for: node, isFocused: true)
    }

    /// Move focus to the next focusable node in tree order, wrapping around.
    /// Returns the node that received focus, or nil if no focusable nodes exist.
    @discardableResult
    public func focusNext(in root: Node) -> Node? {
        let chain = focusables(in: modalRoot ?? root)
        guard !chain.isEmpty else {
            focus(nil)
            return nil
        }

        guard let cur = focused,
              let i = chain.firstIndex(where: { $0 === cur }) else {
            focus(chain.first)
            return chain.first
        }
        let next = chain[(i + 1) % chain.count]
        focus(next)
        return next
    }

    @discardableResult
    public func focusPrevious(in root: Node) -> Node? {
        let chain = focusables(in: modalRoot ?? root)
        guard !chain.isEmpty else {
            focus(nil)
            return nil
        }

        guard let cur = focused,
              let i = chain.firstIndex(where: { $0 === cur }) else {
            focus(chain.last)
            return chain.last
        }
        let prev = chain[(i - 1 + chain.count) % chain.count]
        focus(prev)
        return prev
    }

    public func clear() {
        focus(nil)
    }

    /// Nil means the focused control does not own text history; false means it
    /// owns history but cannot perform this command (including read-only input).
    public func textEditAvailability(_ command: TextEditCommand) -> Bool? {
        textEditActions?.canPerform(command)
    }

    /// Returns true when text input owns the command, even with empty history,
    /// so callers do not accidentally undo unrelated scene changes.
    @discardableResult
    public func performTextEdit(_ command: TextEditCommand) -> Bool {
        guard let actions = textEditActions else { return false }
        if actions.canPerform(command) { actions.perform(command) }
        return true
    }

    private var textEditActions: TextEditActions? {
        guard let focused else { return nil }
        if let root = modalRoot, !contains(focused, in: root) { return nil }
        var cursor: Node? = focused
        while let node = cursor {
            guard node.isInteractionEnabled else { return nil }
            cursor = node.parent
        }
        return focused.attachments[TextInputAttachmentKey.editActions] as? TextEditActions
    }

    // MARK: - Internal

    private func focusables(in root: Node) -> [Node] {
        var out: [Node] = []
        collect(node: root, into: &out)
        return out
    }

    private func collect(node: Node, into out: inout [Node]) {
        guard node.isInteractionEnabled else { return }
        if node.isFocusable { out.append(node) }
        for c in node.children { collect(node: c, into: &out) }
    }

    private func notifyFocusChange(for node: Node?, isFocused: Bool) {
        guard let handler = node?.attachments[TextInputAttachmentKey.focusChangeHandler]
                as? TextInputFocusChangeHandler else { return }
        handler(isFocused)
    }
}
