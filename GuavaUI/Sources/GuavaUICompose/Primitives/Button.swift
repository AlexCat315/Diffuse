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
        _StatefulButton(role: role,
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

// MARK: - StatefulButton

/// User-view wrapper around `ButtonHost` that owns `@State` for press / hover.
/// Press transitions go through `Recomposer.invalidate` (because `@State`
/// writes do), which is what lets `.animation(_:value:)` inside the active
/// `ButtonStyle` body see a value change and animate the colour swap.
struct _StatefulButton: View {
    let role: ButtonRole
    let isEnabled: Bool
    let action: () -> Void
    let label: AnyView

    @State var isPressed: Bool = false
    @State var isHovered: Bool = false

    var body: some View {
        ButtonHost(
            role: role,
            isEnabled: isEnabled,
            isPressed: isEnabled ? isPressed : false,
            isHovered: isEnabled ? isHovered : false,
            label: label,
            onHoverChange: { hovered in
                if isHovered != hovered {
                    isHovered = hovered
                }
            },
            onDown: {
                if !isPressed {
                    isPressed = true
                }
            },
            onUp: { [action] in
                // Capture-then-clear so the pointer handler can both report
                // whether the gesture completed (action fires only on a true
                // down → up sequence) and update `isPressed` in one mutation.
                let was = isPressed
                isPressed = false
                if was { action(); return true }
                return false
            }
        )
    }
}

// MARK: - ButtonHost

/// The actual primitive node behind `Button`. Owns hit-testing; the
/// `isPressed` flag is now passed in by `_StatefulButton` (driven by
/// `@State`) so press transitions invalidate the owning scope and
/// re-evaluate `_children(for:)` with the new configuration.
struct ButtonHost: _PrimitiveView {
    let role: ButtonRole
    let isEnabled: Bool
    let isPressed: Bool
    let isHovered: Bool
    let label: AnyView
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onUp: () -> Bool

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        // Mirror the latest `isPressed` onto attachments so external test
        // helpers and inspectors that walked the tree under the old contract
        // can still read it. Production read path is the `_children(for:)`
        // configuration field.
        node.attachments[ButtonHost.pressedKey] = isPressed
        node.attachments[ButtonHost.hoveredKey] = isHovered

        // Default cursor for buttons: `.pointer` when interactive,
        // `.notAllowed` when disabled. Users can override via `.cursor(_:)`
        // applied closer to the leaf — modifier wrappers run after this
        // primitive and therefore win.
        node.cursor = isEnabled ? .pointer : .notAllowed

        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        let hoverChange = onHoverChange
        let down = onDown
        let up = onUp
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                hoverChange(true)
            case .leave:
                hoverChange(false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            // Buttons handle the primary mouse button only. Right- and
            // middle-clicks bubble so parents (e.g. a DockTab wrapping
            // the close button) can surface their own context-menu /
            // middle-click semantics.
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
                down()
                return .handled
            case .up:
                return up() ? .handled : .ignored
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
        let isFocused = (FocusChainHolder.current?.focused === node)
        let config = ButtonStyleConfiguration(
            label:      label,
            role:       role,
            isPressed:  isPressed,
            isHovered:  isHovered,
            isFocused:  isFocused,
            isEnabled:  isEnabled,
            theme:      theme
        )
        return [style.makeBody(config)]
    }

    static let pressedKey = "__button_pressed"
    static let hoveredKey = "__button_hovered"
}
