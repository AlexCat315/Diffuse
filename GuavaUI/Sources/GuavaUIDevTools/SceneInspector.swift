import Foundation
import GuavaUIRuntime

/// Builds NodeSummary snapshots from a NodeTree.
///
/// Stable id strategy: ObjectIdentifier hex of the Node, valid for the
/// lifetime of the host process. Selection from the client is best-effort —
/// stale ids are ignored by the host.
public final class SceneInspector: @unchecked Sendable {

    private let tree: NodeTree

    public init(tree: NodeTree) {
        self.tree = tree
    }

    /// Capture a snapshot of the current scene. Must run on the same actor
    /// that mutates the tree (i.e. the main actor in AppRuntime).
    public func snapshot() -> TreeSnapshotPayload {
        guard let root = tree.root else {
            return TreeSnapshotPayload(root: nil)
        }
        return TreeSnapshotPayload(root: summarise(root))
    }

    /// Find a node previously reported in a snapshot. Returns nil if the id
    /// no longer corresponds to a live node.
    public func find(id: String) -> Node? {
        guard let root = tree.root else { return nil }
        return search(root, target: id)
    }

    private func search(_ node: Node, target: String) -> Node? {
        if Self.identifier(for: node) == target { return node }
        for child in node.children {
            if let hit = search(child, target: target) { return hit }
        }
        return nil
    }

    private func summarise(_ node: Node) -> NodeSummary {
        NodeSummary(
            id: Self.identifier(for: node),
            viewTag: node.viewTag,
            debugName: nil,
            frame: NodeFrame(
                x: Double(node.frame.origin.x),
                y: Double(node.frame.origin.y),
                w: Double(node.frame.size.width),
                h: Double(node.frame.size.height)
            ),
            flags: NodeFlags(
                hitTestable: node.isHitTestable,
                focusable: node.isFocusable,
                clipsToBounds: node.clipsToBounds,
                hasBackground: node.backgroundColor != nil,
                hasBorder: node.borderColor != nil && node.borderWidth > 0
            ),
            children: node.children.map { summarise($0) }
        )
    }

    static func identifier(for node: Node) -> String {
        let raw = UInt(bitPattern: ObjectIdentifier(node).hashValue)
        return "0x" + String(raw, radix: 16)
    }
}
