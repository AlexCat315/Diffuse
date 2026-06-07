/// What changed about a node, expressed as a set so one mutation can dirty
/// several downstream stages at once. `UIContext.invalidate` is the *only*
/// consumer — every cache subscribes there, so adding a new cache means adding
/// one subscription in one place, not threading a new hook through the tree.
public struct DirtyFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Children were added/removed/reordered under this node.
    public static let hierarchy = DirtyFlags(rawValue: 1 << 0)
    /// The node moved/resized/changed clip/z/hit-testability. Drives hit-test
    /// cache invalidation — the invariant the legacy `frame.didSet` forgot.
    public static let geometry  = DirtyFlags(rawValue: 1 << 1)
    /// The node needs to be (re)laid out.
    public static let layout    = DirtyFlags(rawValue: 1 << 2)
    /// The node needs to be repainted.
    public static let paint     = DirtyFlags(rawValue: 1 << 3)

    public static let all: DirtyFlags = [.hierarchy, .geometry, .layout, .paint]
}
