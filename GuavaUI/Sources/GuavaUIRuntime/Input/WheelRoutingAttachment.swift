public enum WheelRoutingPriority: Sendable {
    case preferFocused
}

public enum WheelRoutingAttachmentKey {
    /// `Node.attachments` entry carrying the wheel-routing priority for a node.
    public static let priority = "__wheel_routing_priority"
}