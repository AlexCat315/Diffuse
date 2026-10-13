import GuavaUICore
public enum WheelRoutingPriority: Sendable {
    /// Prefer the focused editor while it contains the pointer, or when no
    /// pointer position is available. A phased stream retains its consumer.
    case preferFocused
    /// A transient overlay under the pointer takes precedence over a text
    /// editor retaining focus behind it. May be attached to an ancestor.
    case preferHit
}

/// Controls whether a wheel handler should consume an event after applying
/// scroll math.
public enum ScrollConsumePolicy: Sendable {
    /// Consume any wheel delta routed to this node, even if clamping prevents
    /// a visible offset change.
    case always
    /// Consume input for an overflowing axis, including at its boundary.
    /// Input on an axis without overflow can continue to an ancestor.
    case whenScrollable
    /// Consume only when the effective scroll offset changed.
    case whenOffsetChanged
    /// Never consume. Useful for diagnostics or explicit pass-through.
    case never

    public func result(didScroll: Bool, canScroll: Bool) -> EventResult {
        switch self {
        case .always:
            return .handled
        case .whenScrollable:
            return canScroll ? .handled : .ignored
        case .whenOffsetChanged:
            return didScroll ? .handled : .ignored
        case .never:
            return .ignored
        }
    }
}

public enum WheelRoutingAttachmentKey {
    /// `Node.attachments` entry carrying the wheel-routing priority for a node.
    public static let priority = "__wheel_routing_priority"
}
