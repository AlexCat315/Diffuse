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

/// A scroll-wheel event. Delta values are in logical pixels; positive Y is
/// the platform's natural scroll direction (may be inverted by OS settings).
public struct WheelEvent: Sendable {
    public var deltaX: Float
    public var deltaY: Float
    /// Cursor position at the moment of the wheel event, in window-local coords.
    public var position: Point
    public init(deltaX: Float = 0, deltaY: Float = 0, position: Point = .zero) {
        self.deltaX = deltaX; self.deltaY = deltaY; self.position = position
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
    /// Scroll wheel handler. Called on the deepest hit node; returning
    /// `.handled` consumes the event so ancestor scroll views don't double-scroll.
    public var onWheel: ((WheelEvent) -> EventResult)?
    public var onHoverEnter: (() -> Void)?
    public var onHoverLeave: (() -> Void)?
    /// Keyboard handler. Only the focused node receives key events.
    public var onKeyDown: ((KeyboardEvent) -> EventResult)?
    public init() {}

    var isEmpty: Bool {
        onPointer == nil && onWheel == nil && onHoverEnter == nil
        && onHoverLeave == nil && onKeyDown == nil
    }
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

// MARK: - Keyboard

public struct KeyboardEvent: Sendable {
    /// Platform-independent key name (e.g. "a", "Enter", "Backspace", "Escape").
    public var key: String
    /// Insertable character, nil for non-printable keys.
    public var character: String?
    /// True on key-down repeat.
    public var isRepeat: Bool
    public var modifiers: KeyModifiers

    public init(key: String, character: String? = nil,
                isRepeat: Bool = false, modifiers: KeyModifiers = []) {
        self.key = key; self.character = character
        self.isRepeat = isRepeat; self.modifiers = modifiers
    }
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let alt     = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}
