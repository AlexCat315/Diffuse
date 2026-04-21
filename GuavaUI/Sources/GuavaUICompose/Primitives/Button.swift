import GuavaUIRuntime

// NOTE: This file used to host a primitive `Button` that wrapped a label and
// emitted no visual state. Phase 7.5 promotes `Button` to a stateful composite
// that delegates its body to the active `ButtonStyle`. The label is type-
// erased into the configuration so styles can compose it freely.

/// Tappable control. The `label` produces the visual content; the active
/// `ButtonStyle` (defaulting to `PrimaryButtonStyle`) decides how it is
/// painted, padded, and decorated for each interaction state.
///
/// Override the visual style for any subtree:
/// ```swift
/// Column {
///     Button("Save") { … }
///     Button("Discard", role: .destructive) { … }
/// }.buttonStyle(.secondary)
/// ```
public struct Button<Label: View>: View {
    public let role: ButtonRole
    public let isEnabled: Bool
    public let action: () -> Void
    public let label: Label

    public init(role: ButtonRole = .normal,
                isEnabled: Bool = true,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
        self.label = label()
    }

    public var body: some View {
        ButtonHost(role: role,
                   isEnabled: isEnabled,
                   action: action,
                   label: AnyView(label))
    }
}

public extension Button where Label == Text {
    /// Title-only convenience initializer.
    init(_ title: String,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, action: action) {
            Text(title)
        }
    }
}

// MARK: - ButtonHost

/// The actual primitive node behind `Button`. Owns hit-testing and the
/// pressed-state flag; on every `_updateNode` it resolves the configured
/// style + active theme from CompositionLocals and re-derives its child via
/// `style.makeBody(configuration:)`.
struct ButtonHost: _PrimitiveView {
    let role: ButtonRole
    let isEnabled: Bool
    let action: () -> Void
    let label: AnyView

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            // Disabled: clear any prior handler so taps no-op silently.
            InteractionRegistryHolder.current?.remove(node)
            node.attachments[ButtonHost.pressedKey] = false
            return
        }
        let captured = action
        // Pressed flag lives on `node.attachments` so it survives same-shape
        // recompose; flipping it triggers `markDirty()` which the Recomposer
        // collapses into the next frame.
        registry.setPointer(node) { _, phase, _ in
            switch phase {
            case .down:
                node.attachments[ButtonHost.pressedKey] = true
                node.markDirty()
                return .handled
            case .up:
                let wasPressed = (node.attachments[ButtonHost.pressedKey] as? Bool) ?? false
                node.attachments[ButtonHost.pressedKey] = false
                node.markDirty()
                if wasPressed {
                    captured()
                    return .handled
                }
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        // Center the styled body horizontally and vertically. Built-in styles
        // already supply their own padding via the configuration.
        l.flexDirection = .row
        l.alignItems = .center
        l.justifyContent = .center
        return l
    }

    func _children(for node: Node) -> [any View] {
        let style = node.compositionValue(of: ButtonStyleEnvironment.key)
        let theme = node.theme
        let isPressed = (node.attachments[ButtonHost.pressedKey] as? Bool) ?? false
        let isFocused = (FocusChainHolder.current?.focused === node)
        let config = ButtonStyleConfiguration(
            label:      label,
            role:       role,
            isPressed:  isPressed,
            isHovered:  false,         // hover events are not yet plumbed.
            isFocused:  isFocused,
            isEnabled:  isEnabled,
            theme:      theme
        )
        return [style.makeBody(config)]
    }

    static let pressedKey = "__button_pressed"
}
import GuavaUIRuntime
