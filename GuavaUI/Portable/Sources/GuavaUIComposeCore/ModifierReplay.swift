import GuavaUIScene

/// Modifiers applied by the caller of a transparent component must run after
/// that component rebuilds its own body. Otherwise internal primitive updates
/// overwrite the caller's frame, flex, style and event configuration.
final class ModifierReplay {
    private var entries: [() -> Void] = []
    private static let key = "GuavaUI.component.modifiers"

    /// A parent update reaches the content boundary before unwinding its
    /// modifiers. Replace that declaration's list; local body updates keep it.
    static func reset(on node: Node) { node.attachments[key] = nil }

    static func install(on node: Node, apply: @escaping () -> Void) {
        let replay: ModifierReplay
        if let existing = node.attachments[key] as? ModifierReplay { replay = existing }
        else { replay = ModifierReplay(); node.attachments[key] = replay }
        // AnyView can erase several declarations to the same generic type.
        // Preserve every declaration in order instead of deduplicating by type.
        replay.entries.append(apply)
    }

    static func apply(from anchor: Node, graph: ViewGraph) {
        var current: Node? = anchor
        // All these transparent anchors share the same materialized layout
        // roots. Replay the nearest caller first, then its enclosing caller.
        while let node = current, graph.layoutNode(for: node) == nil {
            if let replay = node.attachments[key] as? ModifierReplay {
                for entry in replay.entries { entry() }
            }
            current = node.parent
        }
    }
}
