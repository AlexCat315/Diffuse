import Foundation
import GuavaUIRuntime
import EngineKernel

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
    public let isLoading: Bool
    /// On/off state surfaced to the active style via
    /// `ButtonStyleConfiguration.isSelected` (used by `.toggle` and friends).
    public let isSelected: Bool
    public let tooltip: String?
    public let action: () -> Void
    public let label: Label

    public init(role: ButtonRole = .normal,
                isEnabled: Bool = true,
                isLoading: Bool = false,
                isSelected: Bool = false,
                tooltip: String? = nil,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.role = role
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.isSelected = isSelected
        self.tooltip = tooltip
        self.action = action
        self.label = label()
    }

    public var body: some View {
        _StatefulButton(role: role,
                        isEnabled: isEnabled && !isLoading,
                        isSelected: isSelected,
                        tooltip: tooltip,
                        action: action,
                        label: loadingLabel)
    }
    private var loadingLabel: AnyView {
        guard isLoading else { return AnyView(label) }
        return AnyView(Row(alignment: .center, spacing: 6) { Spinner(size: 14); label })
    }
}

public struct ButtonIcon: View {
    public enum Source {
        /// Pre-registered texture, for callers that already own a renderer texture.
        case texture(TextureID)
        /// File on disk, resolved through `ImageAssetRegistryHolder.current`.
        case file(path: String)
        /// Bundle-packaged image resource resolved by the UI layer.
        case resource(BundleImageResource)
    }

    public let source: Source
    public let size: Float
    public let tint: Color?

    public init(_ source: Source,
                size: Float = 16,
                tint: Color? = nil) {
        self.source = source
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        switch source {
        case .texture(let id):
            Image(textureID: id,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  renderingMode: .alphaMask)
        case .file(let path):
            Image(file: path,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
        case .resource(let resource):
            Image(resource: resource,
                  width: size,
                  height: size,
                  tint: tint ?? .white,
                  contentMode: .fit,
                  renderingMode: .alphaMask)
        }
    }
}

public extension Button where Label == Text {
    /// Title-only convenience initializer.
    init(_ title: String,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
                isLoading: Bool = false,
         isSelected: Bool = false,
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isLoading: isLoading, isSelected: isSelected,
                  tooltip: tooltip, action: action) {
            Text(title)
        }
    }

    /// Localized title convenience initializer.
    init(_ key: LocalizedStringKey,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
                isLoading: Bool = false,
         isSelected: Bool = false,
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isLoading: isLoading, isSelected: isSelected,
                  tooltip: tooltip, action: action) {
            Text(key)
        }
    }
}

public extension Button where Label == ButtonIcon {
    /// Icon-only convenience initializer. Use the regular `Button` style
    /// pipeline; this only supplies a square image label.
    init(icon source: ButtonIcon.Source,
         size: Float = 16,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
                isLoading: Bool = false,
         isSelected: Bool = false,
         tooltip: String? = nil,
         tint: Color? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isLoading: isLoading, isSelected: isSelected,
                  tooltip: tooltip, action: action) {
            ButtonIcon(source, size: size, tint: tint)
        }
    }
}

// MARK: - StatefulButton

/// User-view wrapper around `ButtonHost` that keeps the compatibility state
/// used by custom `ButtonStyle`s. Built-in styles use node-local interaction
/// state instead, so hover / press does not recompose the button subtree.
struct _StatefulButton: View {
    let role: ButtonRole
    let isEnabled: Bool
    let isSelected: Bool
    let tooltip: String?
    let action: () -> Void
    let label: AnyView

    @State var isPressed: Bool = false
    @State var isHovered: Bool = false

    var body: some View {
        ButtonHost(
            role: role,
            isEnabled: isEnabled,
            isSelected: isSelected,
            tooltip: tooltip,
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
            onPressChange: { pressed in
                if isPressed != pressed {
                    isPressed = pressed
                }
            },
            action: { [action] in
                action()
            }
        )
    }
}

// MARK: - ButtonHost

/// The actual primitive node behind `Button`. It owns hit-testing and keeps
/// fast-path interaction state in node attachments for built-in styles.
struct ButtonHost: _PrimitiveView {
    let role: ButtonRole
    let isEnabled: Bool
    let isSelected: Bool
    let tooltip: String?
    let isPressed: Bool
    let isHovered: Bool
    let label: AnyView
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onPressChange: (Bool) -> Void
    let action: () -> Void

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        node.isFocusable = isEnabled
        node.accessibility = AccessibilitySemantics(.button) {
            $0.state.isEnabled = isEnabled; $0.state.isSelected = isSelected
            $0.help = tooltip ?? ""; $0.combinesChildren = true
        }
        node.accessibilityActions = AccessibilityActions()
        if isEnabled { node.accessibilityActions.activate = action }
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] (_: Bool) in
            guard let node else { return }
            updateBuiltinButtonChromeDescendants(of: node, animated: true)
            node.firstResource(TooltipSession.self)?.setFocused(
                FocusChainHolder.current?.focused === node && FocusChainHolder.current?.isFocusVisible == true)
        }
        node.attachments[ButtonHost.markerKey] = true
        let style = node.compositionValue(of: ButtonStyleEnvironment.key)
        let requiresInteractionRecompose = style.requiresInteractionRecompose
        node.attachments[ButtonHost.requiresInteractionRecomposeKey] = requiresInteractionRecompose
        if requiresInteractionRecompose {
            node.attachments[ButtonHost.pressedKey] = isEnabled ? isPressed : false
            node.attachments[ButtonHost.hoveredKey] = isEnabled ? isHovered : false
        } else if isEnabled {
            if node.attachments[ButtonHost.pressedKey] == nil {
                node.attachments[ButtonHost.pressedKey] = false
            }
            if node.attachments[ButtonHost.hoveredKey] == nil {
                node.attachments[ButtonHost.hoveredKey] = false
            }
        } else {
            node.attachments[ButtonHost.pressedKey] = false
            node.attachments[ButtonHost.hoveredKey] = false
        }
        let resolvedTooltip = tooltip?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolvedTooltip, !resolvedTooltip.isEmpty {
            if node.firstResource(PortalResource.self) == nil { node.addResource(PortalResource()) }
            if node.firstResource(TooltipSession.self) == nil { node.addResource(TooltipSession()) }
            var options = TooltipOptions(); options.isEnabled = isEnabled
            node.firstResource(TooltipSession.self)?.configure(content: tooltipDescription(resolvedTooltip), options: options,
                focused: FocusChainHolder.current?.focused === node && FocusChainHolder.current?.isFocusVisible == true)
            node.layoutDidUpdate = { [weak node] _ in node?.firstResource(TooltipSession.self)?.updatePosition() }
        } else {
            node.firstResource(TooltipSession.self)?.dismiss()
        }

        // Default cursor for buttons: `.pointer` when interactive,
        // `.notAllowed` when disabled. Users can override via `.cursor(_:)`
        // applied closer to the leaf — modifier wrappers run after this
        // primitive and therefore win.
        node.cursor = isEnabled ? .pointer : .notAllowed
        if !isEnabled {
            node.attachments.removeValue(forKey: ButtonHost.activePressKey)
            if PointerCaptureHolder.current?.target === node {
                PointerCaptureHolder.current?.release()
            }
        }
        updateBuiltinButtonChromeDescendants(of: node, animated: false)

        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        let hoverChange = onHoverChange
        let down = onDown
        let pressChange = onPressChange
        let activate = action
        registry.setHover(node) { phase in
            node.firstResource(TooltipSession.self)?.setHovered(phase == .enter)
            switch phase {
            case .enter:
                setButtonInteraction(node,
                                     key: ButtonHost.hoveredKey,
                                     value: true,
                                     requiresRecompose: requiresInteractionRecompose,
                                     onChange: hoverChange)
            case .leave:
                setButtonInteraction(node,
                                     key: ButtonHost.hoveredKey,
                                     value: false,
                                     requiresRecompose: requiresInteractionRecompose,
                                     onChange: hoverChange)
            }
        }
        registry.setPointer(node) { event, phase, eventPhase in
            guard eventPhase != .capture else { return .ignored }
            // Buttons handle the primary mouse button only. Right- and
            // middle-clicks bubble so parent chrome can surface context-menu
            // or middle-click semantics.
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
                node.firstResource(TooltipSession.self)?.dismiss()
                node.attachments[ButtonHost.activePressKey] = true
                PointerCaptureHolder.current?.acquire(node)
                if requiresInteractionRecompose {
                    down()
                } else {
                    setButtonInteraction(node,
                                         key: ButtonHost.pressedKey,
                                         value: true,
                                         requiresRecompose: false,
                                         onChange: pressChange)
                }
                return .handled
            case .up:
                let wasActive = node.attachments[ButtonHost.activePressKey] as? Bool == true
                node.attachments.removeValue(forKey: ButtonHost.activePressKey)
                let isInside = isPointInsideButton(event.x, event.y, node: node)
                defer {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                }
                guard wasActive else { return .ignored }
                setButtonInteraction(node,
                                     key: ButtonHost.pressedKey,
                                     value: false,
                                     requiresRecompose: requiresInteractionRecompose,
                                     onChange: pressChange)
                guard isInside else {
                    return .handled
                }
                activate()
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard node.attachments[ButtonHost.activePressKey] as? Bool == true else {
                return .ignored
            }
            let isInside = isPointInsideButton(event.x, event.y, node: node)
            setButtonInteraction(node,
                                 key: ButtonHost.hoveredKey,
                                 value: isInside,
                                 requiresRecompose: requiresInteractionRecompose,
                                 onChange: hoverChange)
            if isInside {
                if requiresInteractionRecompose {
                    down()
                } else {
                    setButtonInteraction(node,
                                         key: ButtonHost.pressedKey,
                                         value: true,
                                         requiresRecompose: false,
                                         onChange: pressChange)
                }
            } else {
                setButtonInteraction(node,
                                     key: ButtonHost.pressedKey,
                                     value: false,
                                     requiresRecompose: requiresInteractionRecompose,
                                     onChange: pressChange)
            }
            return .handled
        }
        registry.setKey(node) { event, _ in
            if event.scancode == Scancode.escape, node.firstResource(TooltipSession.self)?.dismiss() == true { return .handled }
            guard !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
                node.firstResource(TooltipSession.self)?.dismiss()
                activate()
                return .handled
            default:
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
        let isFocused = (FocusChainHolder.current?.focused === node)
        let configPressed = style.requiresInteractionRecompose
            ? isPressed
            : (node.attachments[ButtonHost.pressedKey] as? Bool == true)
        let configHovered = style.requiresInteractionRecompose
            ? isHovered
            : (node.attachments[ButtonHost.hoveredKey] as? Bool == true)
        let config = ButtonStyleConfiguration(
            label:      label,
            role:       role,
            isPressed:  isEnabled ? configPressed : false,
            isHovered:  isEnabled ? configHovered : false,
            isFocused:  isFocused,
            isEnabled:  isEnabled,
            isSelected: isSelected,
            theme:      theme,
            controlSize: node.compositionValue(of: ControlSizeEnvironment.key)
        )
        return [style.makeBody(config)]
    }

    static let markerKey = "__button_host"
    static let pressedKey = "__button_pressed"
    static let hoveredKey = "__button_hovered"
    static let activePressKey = "__button_active_press"
    static let requiresInteractionRecomposeKey = "__button_requires_interaction_recompose"
}

private func isPointInsideButton(_ x: Float, _ y: Float, node: Node) -> Bool {
    node.absoluteFrame.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)))
}

private func setButtonInteraction(_ node: Node,
                                  key: String,
                                  value: Bool,
                                  requiresRecompose: Bool,
                                  onChange: (Bool) -> Void) {
    if requiresRecompose {
        onChange(value)
        return
    }
    if node.attachments[key] as? Bool == value {
        return
    }
    node.attachments[key] = value
    node.markRenderDirty(reason: .styleSet(field: key))
    updateBuiltinButtonChromeDescendants(of: node, animated: true)
}

enum BuiltinButtonChromeKind: Hashable {
    case primary
    case secondary
    case ghost
    case destructive
    case toggle(minWidth: Float, height: Float)
}

struct BuiltinButtonChrome: _PrimitiveView {
    let kind: BuiltinButtonChromeKind
    let isEnabled: Bool
    let isSelected: Bool
    let foreground: SemanticColorRef
    let label: any View
    private let metrics: BuiltinButtonChromeMetrics

    init(kind: BuiltinButtonChromeKind,
         configuration: ButtonStyleConfiguration,
         foreground: SemanticColorRef) {
        self.kind = kind
        self.isEnabled = configuration.isEnabled
        self.isSelected = configuration.isSelected
        self.foreground = foreground
        self.label = configuration.label
        self.metrics = kind.metrics(in: configuration.theme, size: configuration.controlSize)
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[Self.stateKey] = BuiltinButtonChromeState(
            kind: kind,
            isEnabled: isEnabled,
            isSelected: isSelected,
            metrics: metrics
        )
        applyBuiltinButtonChrome(to: node, animated: false)
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .row
        layout.alignItems = .center
        layout.justifyContent = .center
        // The host owns the hit region. Built-in chrome should occupy that
        // same region when a form/toolbar gives the button extra width, while
        // retaining its intrinsic label width when the host is unconstrained.
        layout.flexGrow = 1
        layout.flexShrink = 1
        layout.height = metrics.height
        layout.minWidth = metrics.minWidth
        layout.setPadding(0, edge: .top)
        layout.setPadding(metrics.horizontalPadding, edge: .left)
        layout.setPadding(0, edge: .bottom)
        layout.setPadding(metrics.horizontalPadding, edge: .right)
    }

    func _children(for node: Node) -> [any View] {
        [
            AnyView(label)
                .font(SemanticFontRef.label)
                .foregroundColor(foreground)
        ]
    }

    static let stateKey = "__builtin_button_chrome_state"
}

private struct BuiltinButtonChromeState {
    let kind: BuiltinButtonChromeKind
    let isEnabled: Bool
    let isSelected: Bool
    let metrics: BuiltinButtonChromeMetrics
}

private struct BuiltinButtonChromeMetrics {
    let height: Float
    let minWidth: Float?
    let horizontalPadding: Float
    let radius: Float
}

private struct BuiltinButtonChromeValues {
    let background: Color
    let border: Color
    let borderWidth: Float
    let radius: Float
    let opacity: Float
}

private extension BuiltinButtonChromeKind {
    func metrics(in theme: Theme, size: ControlSize) -> BuiltinButtonChromeMetrics {
        switch self {
        case .primary, .secondary, .ghost, .destructive:
            return BuiltinButtonChromeMetrics(height: size.buttonHeight,
                                              minWidth: nil,
                                              horizontalPadding: size.horizontalPadding,
                                              radius: theme.radius.md)
        case .toggle(let minWidth, let height):
            return BuiltinButtonChromeMetrics(height: height,
                                              minWidth: minWidth,
                                              horizontalPadding: 7,
                                              radius: 6)
        }
    }
}

private func updateBuiltinButtonChromeDescendants(of buttonNode: Node, animated: Bool) {
    for child in buttonNode.children {
        updateBuiltinButtonChromeDescendants(child, animated: animated)
    }
}

private func updateBuiltinButtonChromeDescendants(_ node: Node, animated: Bool) {
    if node.attachments[BuiltinButtonChrome.stateKey] is BuiltinButtonChromeState {
        applyBuiltinButtonChrome(to: node, animated: animated)
    }
    for child in node.children {
        updateBuiltinButtonChromeDescendants(child, animated: animated)
    }
}

private func applyBuiltinButtonChrome(to chromeNode: Node, animated: Bool) {
    guard let state = chromeNode.attachments[BuiltinButtonChrome.stateKey] as? BuiltinButtonChromeState else {
        return
    }
    let buttonNode = nearestButtonHostAncestor(of: chromeNode)
    let values = builtinButtonChromeValues(state: state,
                                           chromeNode: chromeNode,
                                           buttonNode: buttonNode)
    let apply = {
        chromeNode.animatableSet(\.backgroundColor, to: values.background)
        chromeNode.animatableSet(\.borderColor, to: values.border)
        chromeNode.animatableSet(\.borderWidth, to: values.borderWidth)
        chromeNode.animatableSet(\.cornerRadius, to: values.radius)
        chromeNode.animatableSet(\.opacity, to: values.opacity)
    }
    if animated {
        withAnimation(.semantic(.snappy, in: chromeNode.theme), apply)
    } else {
        apply()
    }
}

private func builtinButtonChromeValues(state: BuiltinButtonChromeState,
                                       chromeNode: Node,
                                       buttonNode: Node?) -> BuiltinButtonChromeValues {
    let theme = chromeNode.theme
    let pressed = state.isEnabled && (buttonNode?.attachments[ButtonHost.pressedKey] as? Bool == true)
    let hovered = state.isEnabled && (buttonNode?.attachments[ButtonHost.hoveredKey] as? Bool == true)
    let focused = state.isEnabled && FocusChainHolder.current?.isFocusVisible == true
        && buttonNode.map { FocusChainHolder.current?.focused === $0 } == true
    let metrics = state.metrics
    let clear = Color.clear
    let background: Color
    let border: Color
    let borderWidth: Float

    switch state.kind {
    case .primary:
        if !state.isEnabled {
            background = theme.colors.surfaceVariant
        } else if pressed {
            background = theme.colors.accentPressed
        } else if hovered {
            background = theme.colors.accentHover
        } else {
            background = theme.colors.accent
        }
        border = focused ? theme.colors.focusRing : clear
        borderWidth = focused ? 2 : 0
    case .secondary:
        if !state.isEnabled {
            background = theme.colors.surfaceSunken
        } else {
            let base = theme.colors.surfaceVariant
            if pressed {
                background = base.composited(over: theme.colors.stateLayerPressed)
            } else if hovered {
                background = base.composited(over: theme.colors.stateLayerHover)
            } else {
                background = base
            }
        }
        border = focused ? theme.colors.focusRing : theme.colors.border
        borderWidth = focused ? 2 : 1
    case .ghost:
        if pressed {
            background = theme.colors.stateLayerPressed
        } else if hovered {
            background = theme.colors.stateLayerHover
        } else {
            background = clear
        }
        border = focused ? theme.colors.focusRing : clear
        borderWidth = focused ? 2 : 0
    case .destructive:
        let error = theme.colors.error
        if !state.isEnabled {
            background = theme.colors.surfaceVariant
        } else if pressed {
            background = error.composited(over: theme.colors.stateLayerPressed)
        } else if hovered {
            background = error.composited(over: theme.colors.stateLayerHover)
        } else {
            background = error
        }
        border = focused ? theme.colors.focusRing : clear
        borderWidth = focused ? 2 : 0
    case .toggle:
        // Selection still conveys the current mode when its command cannot
        // be repeated (e.g. Play while already playing). Keep the paired
        // accent/onAccent colors even when disabled.
        if state.isSelected {
            if pressed {
                background = theme.colors.accentPressed
            } else if hovered {
                background = theme.colors.accentHover
            } else {
                background = theme.colors.accent
            }
        } else if pressed {
            background = theme.colors.stateLayerPressed
        } else if hovered {
            background = theme.colors.stateLayerHover
        } else {
            background = clear
        }
        border = focused ? theme.colors.focusRing : clear
        borderWidth = focused ? 2 : 0
    }

    return BuiltinButtonChromeValues(background: background,
                                     border: border,
                                     borderWidth: borderWidth,
                                     radius: metrics.radius,
                                     opacity: state.isEnabled || theme.textEmphasis.disabled != nil ? 1 : (state.isSelected ? 0.75 : 0.55))
}

private func nearestButtonHostAncestor(of node: Node) -> Node? {
    var current = node.parent
    while let candidate = current {
        if candidate.attachments[ButtonHost.markerKey] as? Bool == true {
            return candidate
        }
        current = candidate.parent
    }
    return nil
}
