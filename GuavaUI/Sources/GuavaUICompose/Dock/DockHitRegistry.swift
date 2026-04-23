import Foundation
import GuavaUIRuntime

/// Process-wide registry that maps a `DockNodeID` to the live `Node` that
/// renders that leaf, scoped to a single `DockController`. Drag drop-zone
/// hit-testing walks this map so it can resolve "which leaf is the pointer
/// over right now" without traversing the view tree from the root.
///
/// Lifetime: weak reference; entries are pruned lazily on each lookup so a
/// recompose that replaces a leaf node leaves no stale entry behind.
public final class DockHitRegistry {
    private var entries: [DockNodeID: WeakNodeBox] = [:]
    private var rootEntry: (id: DockNodeID, node: WeakNodeBox)?

    public init() {}

    func register(nodeID: DockNodeID, node: Node) {
        entries[nodeID] = WeakNodeBox(node)
    }

    func registerRoot(nodeID: DockNodeID, node: Node) {
        rootEntry = (nodeID, WeakNodeBox(node))
    }

    /// Walk the registered leaves, return the smallest one whose absolute
    /// frame contains `(x, y)`. Window coordinates.
    public func leafAt(x: Float, y: Float) -> (id: DockNodeID, node: Node, frame: AbsoluteRect)? {
        var hit: (DockNodeID, Node, AbsoluteRect, Float)?
        for (id, box) in entries {
            guard let n = box.node else {
                entries.removeValue(forKey: id)
                continue
            }
            let frame = absoluteRect(of: n)
            guard frame.contains(x: x, y: y) else { continue }
            let area = frame.width * frame.height
            if hit == nil || area < hit!.3 {
                hit = (id, n, frame, area)
            }
        }
        if let h = hit { return (h.0, h.1, h.2) }
        return nil
    }

    public func rootAt(x: Float, y: Float) -> (id: DockNodeID, node: Node, frame: AbsoluteRect)? {
        guard let rootEntry else { return nil }
        guard let node = rootEntry.node.node else {
            self.rootEntry = nil
            return nil
        }
        let frame = absoluteRect(of: node)
        guard frame.contains(x: x, y: y) else { return nil }
        return (rootEntry.id, node, frame)
    }

    func absoluteRect(of node: Node) -> AbsoluteRect {
        var x: Float = 0
        var y: Float = 0
        var cursor: Node? = node
        while let n = cursor {
            x += Float(n.frame.origin.x)
            y += Float(n.frame.origin.y)
            cursor = n.parent
        }
        return AbsoluteRect(x: x, y: y,
                            width: Float(node.frame.width),
                            height: Float(node.frame.height))
    }
}

/// Public so `DockHostCoordinator` (cross-window dock cluster) can return
/// frame information across module boundaries.
public struct AbsoluteRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func contains(x px: Float, y py: Float) -> Bool {
        return px >= x && px < x + width && py >= y && py < y + height
    }
}

private final class WeakNodeBox {
    weak var node: Node?
    init(_ node: Node) { self.node = node }
}
