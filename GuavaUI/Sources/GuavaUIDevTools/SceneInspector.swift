import Foundation
import GuavaUIRuntime

/// Builds NodeSummary snapshots from a NodeTree.
///
/// Stable id strategy: ObjectIdentifier hex of the Node, valid for the
/// lifetime of the host process. Selection from the client is best-effort —
/// stale ids are ignored by the host.
public final class SceneInspector: @unchecked Sendable {

    private let tree: NodeTree
    /// Optional log to attach to snapshots. Populated by the host so DevTools
    /// can show recent dirty-propagation events alongside the tree.
    public var invalidationLog: InvalidationLog?
    /// Optional render-side mirror, surfaced as `renderInventory` in the
    /// snapshot. Populated by the host once the ViewGraph is created.
    public var renderTree: RenderTree?
    /// Optional input-side mirror, surfaced as `inputInventory` in the
    /// snapshot.
    public var inputScene: InputScene?

    public init(tree: NodeTree,
                invalidationLog: InvalidationLog? = nil,
                renderTree: RenderTree? = nil,
                inputScene: InputScene? = nil) {
        self.tree = tree
        self.invalidationLog = invalidationLog
        self.renderTree = renderTree
        self.inputScene = inputScene
    }

    /// Capture a snapshot of the current scene. Must run on the same actor
    /// that mutates the tree (i.e. the main actor in AppRuntime).
    public func snapshot() -> TreeSnapshotPayload {
        let invalidations = invalidationLog?.snapshot(limit: 64).map(Self.encode(reason:))
        let inventory = renderTree.map { tree -> RenderInventoryPayload in
            RenderInventoryPayload(
                objectCount: tree.objectCount,
                layerRoots: tree.layerRoots().map { String($0.elementID.rawValue) }
            )
        }
        let inputInventoryPayload = inputScene.map { scene -> InputInventoryPayload in
            InputInventoryPayload(
                nodeCount: scene.nodeCount,
                focusables: scene.focusables().map { String($0.elementID.rawValue) },
                hitTestables: scene.hitTestables().map { String($0.elementID.rawValue) }
            )
        }
        guard let root = tree.root else {
            return TreeSnapshotPayload(root: nil,
                                       invalidations: invalidations,
                                       renderInventory: inventory,
                                       inputInventory: inputInventoryPayload)
        }
        return TreeSnapshotPayload(root: summarise(root),
                                   invalidations: invalidations,
                                   renderInventory: inventory,
                                   inputInventory: inputInventoryPayload)
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
            children: node.children.map { summarise($0) },
            elementID: String(node.id.rawValue)
        )
    }

    static func identifier(for node: Node) -> String {
        let raw = UInt(bitPattern: ObjectIdentifier(node).hashValue)
        return "0x" + String(raw, radix: 16)
    }

    private static func encode(reason: DirtyReason) -> InvalidationRecord {
        InvalidationRecord(
            target: String(reason.target.rawValue),
            source: describe(source: reason.source),
            phase: reason.phase.rawValue,
            timestamp: reason.timestamp
        )
    }

    private static func describe(source: InvalidationSource) -> String {
        switch source {
        case .stateWrite(let scope): return "stateWrite(\(scope))"
        case .styleSet(let field):   return "styleSet(\(field))"
        case .layoutChange:          return "layoutChange"
        case .structuralChange:      return "structuralChange"
        case .focusChange:           return "focusChange"
        case .platformResize:        return "platformResize"
        case .unknown:               return "unknown"
        }
    }
}
