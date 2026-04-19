import Foundation

public struct PanelDescriptor: Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var closable: Bool

    public init(id: String, title: String, closable: Bool = true) {
        self.id = id
        self.title = title
        self.closable = closable
    }
}

public enum DockNodeKind: String, Codable, Sendable {
    case row
    case column
    case tabset
}

public struct DockNode: Codable, Sendable {
    public var kind: DockNodeKind
    public var weight: Double
    public var panelIDs: [String]
    public var children: [DockNode]

    public init(kind: DockNodeKind, weight: Double = 1.0, panelIDs: [String] = [], children: [DockNode] = []) {
        self.kind = kind
        self.weight = weight
        self.panelIDs = panelIDs
        self.children = children
    }
}

public struct DockLayout: Codable, Sendable {
    public var root: DockNode

    public init(root: DockNode) {
        self.root = root
    }

    public static func `default`(panelIDs: [String]) -> DockLayout {
        let viewport = DockNode(kind: .tabset, weight: 0.6, panelIDs: panelIDs.filter { $0 == "viewport" })
        let left = DockNode(kind: .tabset, weight: 0.2, panelIDs: panelIDs.filter { $0 == "hierarchy" })
        let right = DockNode(kind: .tabset, weight: 0.2, panelIDs: panelIDs.filter { $0 == "inspector" })

        return DockLayout(
            root: DockNode(kind: .row, children: [left, viewport, right])
        )
    }
}
