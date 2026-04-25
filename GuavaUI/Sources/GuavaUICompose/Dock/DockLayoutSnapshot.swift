import Foundation

/// Codable bundle that captures the full layout state of a `DockController`:
/// its main `root` tree plus any detached satellite leaves and their stable
/// ordering. Used by demo / editor persistence to round-trip the layout to
/// disk.
public struct DockLayoutSnapshot: Codable, Equatable, Sendable {
    public var root: DockLayoutNode
    /// Detached leaves keyed by their original `DockNodeID`. Each entry must
    /// be a `.tabs` (or `.empty`) leaf — splits are not legal satellites.
    public var satellites: [DockNodeID: DockLayoutNode]
    /// Insertion order for `satellites`. Filtered against the dictionary on
    /// decode so callers get a deterministic, dict-aligned sequence.
    public var satelliteOrder: [DockNodeID]
    /// Leaves minimized onto edge rails, keyed by their original node id.
    public var minimizedLeaves: [DockNodeID: DockMinimizedLeaf]
    /// Insertion order for minimized leaves.
    public var minimizedOrder: [DockNodeID]
    /// Schema version. Bump when fields change shape.
    public var schemaVersion: Int

    public static let currentSchemaVersion = 2

    public init(root: DockLayoutNode,
                satellites: [DockNodeID: DockLayoutNode] = [:],
                satelliteOrder: [DockNodeID] = [],
                minimizedLeaves: [DockNodeID: DockMinimizedLeaf] = [:],
                minimizedOrder: [DockNodeID] = [],
                schemaVersion: Int = currentSchemaVersion) {
        self.root = root
        self.satellites = satellites
        self.satelliteOrder = satelliteOrder.isEmpty
            ? Array(satellites.keys)
            : satelliteOrder.filter { satellites[$0] != nil }
        self.minimizedLeaves = minimizedLeaves
        self.minimizedOrder = minimizedOrder.isEmpty
            ? Array(minimizedLeaves.keys)
            : minimizedOrder.filter { minimizedLeaves[$0] != nil }
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case root, satellites, satelliteOrder, minimizedLeaves, minimizedOrder, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRoot = try c.decode(DockLayoutNode.self, forKey: .root)
        let decodedSats = try c.decodeIfPresent([DockNodeID: DockLayoutNode].self,
                                                 forKey: .satellites) ?? [:]
        let order = try c.decodeIfPresent([DockNodeID].self,
                                          forKey: .satelliteOrder) ?? []
        let normalisedOrder = order.isEmpty
            ? Array(decodedSats.keys)
            : order.filter { decodedSats[$0] != nil }
        let decodedMinimized = try c.decodeIfPresent([DockNodeID: DockMinimizedLeaf].self,
                                                      forKey: .minimizedLeaves) ?? [:]
        let minimizedOrder = try c.decodeIfPresent([DockNodeID].self,
                                                   forKey: .minimizedOrder) ?? []
        let normalisedMinimizedOrder = minimizedOrder.isEmpty
            ? Array(decodedMinimized.keys)
            : minimizedOrder.filter { decodedMinimized[$0] != nil }
        self.root = decodedRoot
        self.satellites = decodedSats
        self.satelliteOrder = normalisedOrder
        self.minimizedLeaves = decodedMinimized
        self.minimizedOrder = normalisedMinimizedOrder
        self.schemaVersion = try c.decodeIfPresent(Int.self,
                                                    forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
    }
}

public extension DockController {
    /// Capture the current layout into a `DockLayoutSnapshot`.
    func snapshot() -> DockLayoutSnapshot {
        DockLayoutSnapshot(root: root,
                           satellites: satellites,
                           satelliteOrder: satelliteOrder,
                           minimizedLeaves: minimizedLeaves,
                           minimizedOrder: minimizedOrder)
    }

    /// Replace the current layout with the contents of `snapshot`.
    /// Bumps `version`; subscribers are notified once.
    func load(_ snapshot: DockLayoutSnapshot) {
        replace(root: snapshot.root,
                satellites: snapshot.satellites,
                satelliteOrder: snapshot.satelliteOrder,
                minimizedLeaves: snapshot.minimizedLeaves,
                minimizedOrder: snapshot.minimizedOrder)
    }
}
