import GuavaUIScene
import GuavaUIDevToolsProtocol

/// Performs one accessibility action on a live node, exactly as an assistive
/// client would. Unlike pointer input this needs no visible geometry, so an
/// agent can open an offscreen sidebar page or step a virtualized row.
@MainActor
public final class UIAccessibilityActions {
    private let tree: NodeTree

    public init(tree: NodeTree) { self.tree = tree }

    /// Returns nil on success, or why the action could not run.
    public func perform(_ request: MirrorActivatePayload) -> String? {
        guard let node = find(request.nodeID, in: tree.root) else { return "Node is missing or unmounted: \(request.nodeID)" }
        guard node.acceptsSubtreeInput, node.accessibility?.state.isEnabled != false else { return "Node \(request.nodeID) is disabled" }
        let actions = node.accessibilityActions
        let action: (() -> Void)?
        switch request.action {
        case .activate: action = actions.activate
        case .increment: action = actions.increment
        case .decrement: action = actions.decrement
        }
        guard let action else { return "Node \(request.nodeID) has no \(request.action.rawValue) action" }
        action()
        return nil
    }

    private func find(_ id: String, in node: Node?) -> Node? {
        guard let node else { return nil }
        if String(node.id.rawValue) == id { return node }
        for child in node.children { if let match = find(id, in: child) { return match } }
        return nil
    }
}
