import GuavaUIRuntime

/// Modifier that resolves a `SemanticColorRef` against the target node's
/// active theme and writes the result into `node.backgroundColor`. Resolution
/// happens at apply-time, so `.theme(_:)` overrides on ancestors take effect
/// without any explicit re-binding by the call site.
public struct SemanticBackgroundModifier: ViewModifier {
    public let ref: SemanticColorRef
    public init(_ ref: SemanticColorRef) { self.ref = ref }
    public func apply(node: Node) {
        node.animatableSet(\.backgroundColor, to: ref.resolve(node.theme))
    }
}

public struct SemanticForegroundColorModifier: ViewModifier {
    public let ref: SemanticColorRef
    public init(_ ref: SemanticColorRef) { self.ref = ref }
    public func apply(node: Node) {
        node.animatableSet(\.foregroundColor, to: ref.resolve(node.theme))
    }
}

public struct SemanticBorderModifier: ViewModifier {
    public let ref: SemanticColorRef
    public let width: Float

    public init(_ ref: SemanticColorRef, width: Float) {
        self.ref = ref
        self.width = max(0, width)
    }

    public func apply(node: Node) {
        node.animatableSet(\.borderColor, to: ref.resolve(node.theme))
        node.animatableSet(\.borderWidth, to: width)
    }
}

/// Resolves a `SemanticFontRef` and writes both the font and its companion
/// line-height into the same attachment slots used by `FontModifier` /
/// `LineHeightModifier`. `Text` and `TextField` already read these slots, so
/// no primitive changes are required.
public struct SemanticFontModifier: ViewModifier {
    public let ref: SemanticFontRef
    public init(_ ref: SemanticFontRef) { self.ref = ref }

    public func apply(node: Node) {
        let token = ref.resolve(node.theme)
        node.attachments[StyleAttachmentKey.font] = token.font
        node.attachments[StyleAttachmentKey.lineHeight] = token.lineHeight
    }

    public func apply(layout: LayoutNode) {
        // Layout-side cache cannot reach `node.theme`. Falls back to the
        // Theme.defaultDark token so undecorated layout passes still get a
        // sensible measure; the node-side apply above will refine it once
        // the node is parented under any `.theme(_:)` provider.
        let token = ref.resolve(.defaultDark)
        layout.attachments[StyleAttachmentKey.font] = token.font
        layout.attachments[StyleAttachmentKey.lineHeight] = token.lineHeight
        // Only nodes with a custom measure function (Text / TextField) may be
        // marked dirty manually — Yoga aborts otherwise. Detect via presence
        // of the `font` attachment slot, which only those primitives populate
        // proactively in their own `_makeLayoutNode` measure callback path.
        if layout.hasMeasureFunc {
            layout.markDirty()
        }
    }
}

public extension View {
    /// Set the background fill from a semantic color slot. Resolves against
    /// the node's active `Theme`.
    func background(_ ref: SemanticColorRef) -> some View {
        modifier(SemanticBackgroundModifier(ref))
    }

    /// Set the foreground tint from a semantic color slot. Resolves against
    /// the node's active `Theme`.
    func foregroundColor(_ ref: SemanticColorRef) -> some View {
        modifier(SemanticForegroundColorModifier(ref))
    }

    /// Set the border stroke from a semantic color slot. Resolves against the
    /// node's active `Theme`.
    func border(_ ref: SemanticColorRef, width: Float = 1) -> some View {
        modifier(SemanticBorderModifier(ref, width: width))
    }

    /// Set both font and line-height from a semantic typography slot.
    func font(_ ref: SemanticFontRef) -> some View {
        modifier(SemanticFontModifier(ref))
    }
}
