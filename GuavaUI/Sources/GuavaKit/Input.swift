// Input model. Handlers live ON the node (`UINode.interaction`), not in a
// process-global registry keyed by node — so they share the node's lifetime and
// can never outlive it or leak across trees.

public enum PointerButton: Sendable { case primary, secondary, middle }

public enum PointerAction: Sendable { case down, up, move }

/// A pointer event in the tree's (window-local) coordinate space.
public struct PointerEvent: Sendable {
    public var position: Point
    public var button: PointerButton
    public var action: PointerAction
    public init(position: Point, button: PointerButton = .primary, action: PointerAction) {
        self.position = position
        self.button = button
        self.action = action
    }
}

/// DOM-style delivery phase: ancestors first (`capture`), then the hit node
/// (`target`), then ancestors again on the way out (`bubble`).
public enum EventPhase: Sendable { case capture, target, bubble }

public enum EventResult: Sendable { case handled, ignored }

/// Per-node interaction config. Plain value-type storage of optional closures —
/// set what you need, leave the rest nil.
public struct Interaction {
    /// Pointer handler. Returns `.handled` to stop propagation in the current
    /// phase. The closure decides whether to acquire pointer capture (via the
    /// context passed in) for drags.
    public var onPointer: ((PointerEvent, EventPhase, UIContext) -> EventResult)?
    public var onHoverEnter: (() -> Void)?
    public var onHoverLeave: (() -> Void)?
    public init() {}

    var isEmpty: Bool { onPointer == nil && onHoverEnter == nil && onHoverLeave == nil }
}

/// Tracks the node that has captured the pointer (e.g. an in-progress drag).
/// Scoped to a `UIContext` — never a global — and released automatically when
/// the owning node leaves the tree. That pairing is what makes the legacy
/// "stuck capture breaks every control" failure unrepresentable here.
public final class PointerCapture {
    public private(set) weak var target: UINode?
    public var isActive: Bool { target != nil }

    public func acquire(_ node: UINode) { target = node }
    public func release() { target = nil }
}
