// Layout *inputs* for a node. `UINode.geometry` is the *output* (frames written
// by the layout engine). Keeping inputs and outputs as distinct values makes the
// data flow obvious: style → engine → geometry → invalidation.

/// A length that may be fixed, a percentage of the parent, or content-driven.
public enum Dimension: Equatable, Sendable {
    case auto
    case points(Float)
    case percent(Float) // 0...100

    /// Resolve against a parent length. `nil` means "auto — ask the content".
    public func resolve(_ parent: Float) -> Float? {
        switch self {
        case .auto:            return nil
        case .points(let p):   return p
        case .percent(let pc): return parent * pc / 100
        }
    }
}

public struct Edges: Equatable, Sendable {
    public var top: Float, left: Float, bottom: Float, right: Float
    public init(top: Float = 0, left: Float = 0, bottom: Float = 0, right: Float = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public static func all(_ v: Float) -> Edges { Edges(top: v, left: v, bottom: v, right: v) }
    public var horizontal: Float { left + right }
    public var vertical: Float { top + bottom }
}

/// Main-axis direction of a container's children.
public enum Axis: Sendable { case row, column }

/// Whether a node participates in its parent's flow, or is placed at a fixed
/// parent-local rect (used by overlays/portals).
public enum LayoutPosition: Equatable, Sendable {
    case flow
    case absolute(Rect)
}

/// Cross-axis alignment of children.
public enum CrossAlign: Sendable { case start, center, end, stretch }

/// Main-axis distribution of children.
public enum MainAlign: Sendable { case start, center, end, spaceBetween }

/// The flexbox subset GuavaKit's built-in engine understands. Deliberately
/// small — it covers stack layouts (the 95% case). A fuller engine (e.g. Yoga)
/// can be plugged in via `LayoutEngine` without changing any of this.
public struct LayoutStyle: Equatable, Sendable {
    public var direction: Axis = .column
    public var width: Dimension = .auto
    public var height: Dimension = .auto
    /// Share of leftover main-axis space this child claims (0 = inflexible).
    public var flexGrow: Float = 0
    /// Shrink ratio when the container overflows (0 = no shrinking).
    public var flexShrink: Float = 0
    /// Minimum width constraint (points). `nil` = no constraint.
    public var minWidth: Float?
    /// Maximum width constraint (points). `nil` = no constraint.
    public var maxWidth: Float?
    /// Minimum height constraint (points). `nil` = no constraint.
    public var minHeight: Float?
    /// Maximum height constraint (points). `nil` = no constraint.
    public var maxHeight: Float?
    public var padding: Edges = Edges()
    /// Gap inserted between consecutive children along the main axis.
    public var spacing: Float = 0
    public var alignItems: CrossAlign = .start
    public var justifyContent: MainAlign = .start
    /// Flow (default) or pinned to a fixed parent-local rect.
    public var position: LayoutPosition = .flow

    public init() {}
}
