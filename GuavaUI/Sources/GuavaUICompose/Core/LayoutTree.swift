import Foundation
import GuavaUIRuntime

/// Phase 3 wrapper around the Yoga-backed layout tree. Phase 6 dropped the
/// auxiliary `TextMeasureCache` (NSMapTable) — the per-`LayoutNode` text
/// measure cache now lives directly on `LayoutNode.textMeasure` as a typed
/// stored property in Runtime. Phase 7 removed the `LayoutTreeHolder` shim
/// because no primitive reads the active LayoutTree by global lookup any
/// more.
public final class LayoutTree {
    public let root: LayoutNode

    public init() {
        self.root = LayoutNode()
    }

    /// Drop every cached text layout entry. Used by tests + DevTools when
    /// the font atlas / measurement environment changes wholesale.
    public func resetCaches() {
        clearTextMeasureCache(root)
    }

    private func clearTextMeasureCache(_ node: LayoutNode) {
        node.textMeasure = nil
        for c in node.children { clearTextMeasureCache(c) }
    }
}

// MARK: - Per-node text measure cache moved to `LayoutNode.textMeasure`
// in Phase 6. See `GuavaUI/Sources/GuavaUIRuntime/Text/TextMeasureSlot.swift`.
