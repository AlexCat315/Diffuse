import GuavaUIRuntime

/// Additional logical space between shaped clusters, shared by measure and draw.
public struct LetterSpacingModifier: ViewModifier {
    public let value: Float
    public init(_ value: Float) { self.value = value.isFinite ? value : 0 }

    public func apply(node: Node) {
        guard node.attachments[StyleAttachmentKey.letterSpacing] as? Float != value else { return }
        node.attachments[StyleAttachmentKey.letterSpacing] = value
        node.invalidateTextStyle()
    }

    public func apply(layout: LayoutNode) {
        guard layout.attachments[StyleAttachmentKey.letterSpacing] as? Float != value else { return }
        layout.attachments[StyleAttachmentKey.letterSpacing] = value
        layout.invalidateTextMeasurements()
    }
}
