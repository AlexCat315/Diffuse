import Foundation
import GuavaUIRuntime

/// Stable identifier for a node inside a `DockLayoutNode` tree.
///
/// Generated when a node is constructed and preserved across operations so
/// that `DockOperation` can reference targets by ID rather than by tree path.
public struct DockNodeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }

    public var description: String { raw.uuidString }
}

/// Stable identifier for a tab within the dock layout. Tabs may be reordered
/// or migrated between leaves; the ID stays constant.
public struct DockTabID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) { self.raw = raw }

    public var description: String { raw.uuidString }
}

/// A tab entry. `userKey` is the lookup key used by the `DockContainer` view
/// factory to obtain the actual content view; the dock layer never holds a
/// `View` reference itself, which keeps the model `Sendable` and serialisable.
public struct DockTab: Hashable, Sendable, Codable {
    public let id: DockTabID
    public var userKey: String
    public var title: String
    /// When `false`, the tab strip skips rendering the close button and
    /// `controller.apply(.closeTab(id))` becomes a caller-side responsibility
    /// (e.g. via the context menu callback). Defaults to `true`.
    public var isClosable: Bool
    /// Optional small bitmap rendered before the title in the tab strip.
    /// `nil` means "no icon"; the strip lays out the label flush against the
    /// horizontal padding instead.
    public var icon: DockTabIcon?

    public init(id: DockTabID = DockTabID(),
                userKey: String,
                title: String,
                isClosable: Bool = true,
                icon: DockTabIcon? = nil) {
        self.id = id
        self.userKey = userKey
        self.title = title
        self.isClosable = isClosable
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case id, userKey, title, isClosable, icon
    }

    /// Custom decoder so pre-D9 snapshots (which only carry `id` /
    /// `userKey` / `title`) round-trip with the modern defaults instead
    /// of raising `keyNotFound`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(DockTabID.self, forKey: .id)
        self.userKey = try c.decode(String.self, forKey: .userKey)
        self.title = try c.decode(String.self, forKey: .title)
        self.isClosable = try c.decodeIfPresent(Bool.self, forKey: .isClosable) ?? true
        self.icon = try c.decodeIfPresent(DockTabIcon.self, forKey: .icon)
    }
}

/// Tiny value carrier for a tab icon: a renderer-registered texture plus
/// the on-screen size to draw it at. Hosts call
/// `DrawListRenderer.registerColorTexture(...)` once at startup and stash
/// the resulting `TextureID` here. `Codable` is implemented by skipping
/// the live texture id (which is process-local) and persisting only a
/// caller-supplied `assetKey` string the host can resolve back on load.
public struct DockTabIcon: Hashable, Sendable, Codable {
    public var assetKey: String
    public var textureID: TextureID
    public var width: Float
    public var height: Float

    public init(assetKey: String,
                textureID: TextureID,
                width: Float = 14,
                height: Float = 14) {
        self.assetKey = assetKey
        self.textureID = textureID
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case assetKey, width, height
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.assetKey = try c.decode(String.self, forKey: .assetKey)
        self.width = try c.decodeIfPresent(Float.self, forKey: .width) ?? 14
        self.height = try c.decodeIfPresent(Float.self, forKey: .height) ?? 14
        // Texture id is process-local; the host must re-resolve on load.
        self.textureID = .none
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(assetKey, forKey: .assetKey)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

/// Split orientation. `.horizontal` places `first` on the left and `second`
/// on the right; `.vertical` places `first` on top.
public enum DockSplitAxis: String, Sendable, Codable {
    case horizontal
    case vertical
}

/// A 5-direction drop edge inside a leaf. `.center` collapses to "drop into
/// this leaf as a new tab"; the four cardinal edges trigger a split.
public enum DockEdge: String, Sendable, Codable {
    case left, right, top, bottom, center
}

/// Recursive layout description.
///
/// `.empty` is a placeholder kept around so an otherwise-collapsing tree
/// always has a well-defined root. Empty leaves are valid drop targets but
/// render as a blank surface.
///
/// Invariants enforced by every mutating helper in `DockController`:
/// - All `DockNodeID` values within one tree are unique.
/// - All `DockTabID` values within one tree are unique.
/// - `.split` always has two non-`.empty` children where possible — when one
///   side becomes empty after a tab move/close, the parent collapses to the
///   surviving child.
/// - `fraction` is clamped to `[0.05, 0.95]`.
public indirect enum DockLayoutNode: Sendable, Codable {
    case empty(id: DockNodeID)
    case tabs(id: DockNodeID, tabs: [DockTab], activeTabID: DockTabID?)
    case split(id: DockNodeID,
               axis: DockSplitAxis,
               fraction: Float,
               first: DockLayoutNode,
               second: DockLayoutNode)

    public var id: DockNodeID {
        switch self {
        case .empty(let id):                   return id
        case .tabs(let id, _, _):              return id
        case .split(let id, _, _, _, _):       return id
        }
    }
}

// MARK: - Convenience constructors

public extension DockLayoutNode {
    /// Build an empty placeholder leaf with a fresh ID.
    static func empty() -> DockLayoutNode { .empty(id: DockNodeID()) }

    /// Build a tabs leaf. `active` defaults to the first tab when omitted.
    static func tabs(_ tabs: [DockTab], active: DockTabID? = nil) -> DockLayoutNode {
        let resolved = active ?? tabs.first?.id
        return .tabs(id: DockNodeID(), tabs: tabs, activeTabID: resolved)
    }

    /// Build a horizontal split (`first` on the left).
    static func hsplit(fraction: Float = 0.5,
                       first: DockLayoutNode,
                       second: DockLayoutNode) -> DockLayoutNode {
        .split(id: DockNodeID(),
               axis: .horizontal,
               fraction: clampFraction(fraction),
               first: first,
               second: second)
    }

    /// Build a vertical split (`first` on top).
    static func vsplit(fraction: Float = 0.5,
                       first: DockLayoutNode,
                       second: DockLayoutNode) -> DockLayoutNode {
        .split(id: DockNodeID(),
               axis: .vertical,
               fraction: clampFraction(fraction),
               first: first,
               second: second)
    }
}

// MARK: - Search helpers

public extension DockLayoutNode {
    /// Walk the tree and return the leaf or split node with `id`.
    func find(_ id: DockNodeID) -> DockLayoutNode? {
        if self.id == id { return self }
        if case .split(_, _, _, let f, let s) = self {
            return f.find(id) ?? s.find(id)
        }
        return nil
    }

    /// Walk the tree and return the leaf containing the tab with `tabID`.
    func leafContainingTab(_ tabID: DockTabID) -> DockLayoutNode? {
        switch self {
        case .empty:
            return nil
        case .tabs(_, let tabs, _):
            return tabs.contains(where: { $0.id == tabID }) ? self : nil
        case .split(_, _, _, let f, let s):
            return f.leafContainingTab(tabID) ?? s.leafContainingTab(tabID)
        }
    }

    /// Collect every tab ID currently present in the tree (depth-first).
    func collectTabIDs() -> [DockTabID] {
        switch self {
        case .empty:
            return []
        case .tabs(_, let tabs, _):
            return tabs.map { $0.id }
        case .split(_, _, _, let f, let s):
            return f.collectTabIDs() + s.collectTabIDs()
        }
    }

    /// Collect every node ID currently present in the tree (depth-first).
    func collectNodeIDs() -> [DockNodeID] {
        switch self {
        case .empty(let id):
            return [id]
        case .tabs(let id, _, _):
            return [id]
        case .split(let id, _, _, let f, let s):
            return [id] + f.collectNodeIDs() + s.collectNodeIDs()
        }
    }
}

// MARK: - Equatable (structural)

extension DockLayoutNode: Equatable {
    public static func == (lhs: DockLayoutNode, rhs: DockLayoutNode) -> Bool {
        switch (lhs, rhs) {
        case (.empty(let a), .empty(let b)):
            return a == b
        case (.tabs(let aID, let aTabs, let aActive),
              .tabs(let bID, let bTabs, let bActive)):
            return aID == bID && aTabs == bTabs && aActive == bActive
        case (.split(let aID, let aAxis, let aFrac, let aF, let aS),
              .split(let bID, let bAxis, let bFrac, let bF, let bS)):
            return aID == bID
                && aAxis == bAxis
                && aFrac == bFrac
                && aF == bF
                && aS == bS
        default:
            return false
        }
    }
}

// MARK: - Internal utilities

@inlinable
func clampFraction(_ raw: Float) -> Float {
    max(0.05, min(0.95, raw))
}
