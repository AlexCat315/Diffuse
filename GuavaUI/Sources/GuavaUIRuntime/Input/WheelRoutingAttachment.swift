public enum WheelRoutingPriority: Sendable {
    case preferFocused
}

/// Controls whether a wheel handler should consume an event after applying
/// scroll math.
public enum ScrollConsumePolicy: Sendable {
    /// Consume any wheel delta routed to this node, even if clamping prevents
    /// a visible offset change.
    case always
    /// Consume only when the effective scroll offset changed.
    case whenOffsetChanged
    /// Never consume. Useful for diagnostics or explicit pass-through.
    case never

    public func result(didScroll: Bool) -> EventResult {
        switch self {
        case .always:
            return .handled
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