import Foundation

/// Tracks the currently focused node and provides tab-order traversal.
///
/// Focus chain order = depth-first, in tree order, including only nodes with
/// `isFocusable == true`. Recomputed lazily when callers ask for next/previous
/// by walking the live `Node` tree (Phase 7: the input mirror was removed).
public final class FocusChain {

    public private(set) weak var focused: Node?
    /// Pointer focus keeps keyboard routing without leaving a persistent ring.
    public private(set) var isFocusVisible = true

    private final class Scope {
        weak var root: Node?
        weak var previous: Node?
        let visible: Bool
        let restoresCommands: Bool
        init(root: Node, previous: Node?, visible: Bool, restoresCommands: Bool) {
            self.root = root; self.previous = previous; self.visible = visible; self.restoresCommands = restoresCommands
        }
    }
    private var scopes: [Scope] = []
    private let registrar = ObservableStateRegistrar()
    public var activeScopeRoot: Node? { scopes.last?.root }
    public var hasModalScope: Bool { scopes.contains { !$0.restoresCommands && $0.root != nil } }

    public init() {}

    /// Menus keep text editing commands directed at the control they cover.
    public var commandTarget: Node? {
        registrar.access("focus")
        var target = focused
        for scope in scopes.reversed() {
            guard scope.restoresCommands else { break }
            target = scope.previous
        }
        return target
    }

    public func permitsInput(_ node: Node) -> Bool {
        if let active = scopes.last, active.restoresCommands, let root = active.root,
           isDescendant(node, of: root) { return true }
        guard let root = scopes.last(where: { !$0.restoresCommands })?.root else { return true }
        return isDescendant(node, of: root)
    }

    public func permitsKeyboardInput(_ node: Node) -> Bool {
        guard let root = activeScopeRoot else { return true }
        return isDescendant(node, of: root)
    }

    public func pushScope(_ root: Node, restoresCommands: Bool = false) {
        guard !scopes.contains(where: { $0.root === root }) else { return }
        scopes.append(Scope(root: root, previous: focused, visible: isFocusVisible, restoresCommands: restoresCommands))
        focus(focusables(in: root).first ?? root)
    }

    public func settleScope(_ root: Node) {
        guard activeScopeRoot === root else { return }
        if focused == nil || focused === root {
            let candidates = focusables(in: root).filter { $0 !== root }
            if let first = candidates.first(where: { $0.attachments[TextInputAttachmentKey.areaResolver] != nil }) ?? candidates.first { focus(first) }
        }
    }

    public func popScope(_ root: Node) {
        guard let index = scopes.firstIndex(where: { $0.root === root }) else { return }
        let shouldRestore = focused == nil || focused.map { isDescendant($0, of: root) } == true
        let scope = scopes.remove(at: index)
        // If an outer scope disappears first, transfer its restoration target
        // to the next scope rather than retaining a detached modal control.
        if index < scopes.count {
            if let previous = scopes[index].previous, isDescendant(previous, of: root) {
                scopes[index].previous = scope.previous
            }
            return
        }
        if !shouldRestore, let focused, focused.parent != nil, permitsInput(focused) { return }
        if let previous = scope.previous, previous.parent != nil,
           previous.isFocusable, previous.acceptsSubtreeInput, permitsInput(previous) {
            focus(previous, visible: scope.visible)
        } else if let active = activeScopeRoot {
            focus(focusables(in: active).first ?? active)
        } else { focus(nil) }
    }

    private func isDescendant(_ node: Node, of root: Node) -> Bool {
        var current: Node? = node
        while let candidate = current { if candidate === root { return true }; current = candidate.parent }
        return false
    }

    public func focus(_ node: Node?, visible: Bool = true) {
        if let node, !permitsInput(node) || !node.acceptsSubtreeInput { return }
        let visibilityChanged = isFocusVisible != visible
        isFocusVisible = visible
        guard focused !== node else {
            if visibilityChanged { notifyFocusChange(for: node, isFocused: true) }
            return
        }
        let previous = focused
        focused = node
        registrar.invalidate("focus")
        notifyFocusChange(for: previous, isFocused: false)
        notifyFocusChange(for: node, isFocused: true)
    }

    /// Move focus to the next focusable node in tree order, wrapping around.
    /// Returns the node that received focus, or nil if no focusable nodes exist.
    @discardableResult
    public func focusNext(in root: Node) -> Node? {
        let chain = focusables(in: activeScopeRoot ?? root)
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
        let chain = focusables(in: activeScopeRoot ?? root)
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

    // MARK: - Internal

    private func focusables(in root: Node) -> [Node] {
        var out: [Node] = []
        collect(node: root, into: &out)
        return out
    }

    private func collect(node: Node, into out: inout [Node]) {
        guard node.acceptsSubtreeInput else { return }
        if node.isFocusable { out.append(node) }
        for c in node.children { collect(node: c, into: &out) }
    }

    private func notifyFocusChange(for node: Node?, isFocused: Bool) {
        guard let handler = node?.attachments[TextInputAttachmentKey.focusChangeHandler]
                as? TextInputFocusChangeHandler else { return }
        handler(isFocused)
    }
}
