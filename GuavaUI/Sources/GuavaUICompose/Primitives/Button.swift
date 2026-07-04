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
    /// On/off state surfaced to the active style via
    /// `ButtonStyleConfiguration.isSelected` (used by `.toggle` and friends).
    public let isSelected: Bool
    public let tooltip: String?
    public let action: () -> Void
    public let label: Label

    public init(role: ButtonRole = .normal,
                isEnabled: Bool = true,
                isSelected: Bool = false,
                tooltip: String? = nil,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.role = role
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.tooltip = tooltip
        self.action = action
        self.label = label()
    }

    public var body: some View {
        _StatefulButton(role: role,
                        isEnabled: isEnabled,
                        isSelected: isSelected,
                        tooltip: tooltip,
                        action: action,
                        label: AnyView(label))
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
         isSelected: Bool = false,
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isSelected: isSelected,
                  tooltip: tooltip, action: action) {
            Text(title)
        }
    }

    /// Localized title convenience initializer.
    init(_ key: LocalizedStringKey,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
         isSelected: Bool = false,
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isSelected: isSelected,
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
         isSelected: Bool = false,
         tooltip: String? = nil,
         tint: Color? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, isSelected: isSelected,
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
        node.attachments[ButtonHost.tooltipKey] = tooltip

        let resolvedTooltip = tooltip?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEnabled, let resolvedTooltip, !resolvedTooltip.isEmpty {
            let draw: (DrawList) -> Void = { [weak node] list in
                guard let node else { return }
                // Hover only. Clicking focuses the button, and a focus-driven
                // tooltip would outlive the pointer leaving the control.
                guard node.attachments[ButtonHost.hoveredKey] as? Bool == true else { return }
                guard let env = TextEnvironmentHolder.current else { return }

                let origin = node.absoluteOrigin

                let theme = node.theme
                let tooltipFont = theme.typography.caption.font
                let lineHeight = theme.typography.caption.lineHeight
                let layout = env.cachedLayout(text: resolvedTooltip,
                                              font: tooltipFont,
                                              lineHeight: lineHeight,
                                              maxWidth: .infinity,
                                              alignment: .leading)

                let padX = max(6, theme.spacing.sm)
                let padY = max(3, theme.spacing.xs)
                let offset = max(4, theme.spacing.xs)
                let width = layout.totalWidth + padX * 2
                let height = lineHeight + padY * 2
                let centerX = Float(origin.x) + Float(node.frame.width) * 0.5
                var x = centerX - width * 0.5
                var y = Float(origin.y) - height - offset

                if let bounds = list.viewportBounds {
                    let inset: Float = 2
                    let minX = bounds.x + inset
                    let maxX = bounds.x + bounds.width - width - inset
                    if maxX >= minX {
                        x = min(max(x, minX), maxX)
                    }
                    let topY = bounds.y + inset
                    let bottomY = bounds.y + bounds.height - height - inset
                    let belowY = Float(origin.y) + Float(node.frame.height) + offset
                    if y < topY, belowY <= bottomY {
                        y = belowY
                    } else if y < topY {
                        y = topY
                    } else if y > bottomY {
                        y = max(topY, bottomY)
                    }
                }

                let bg = theme.colors.surfaceFloating
                    .composited(over: Color.black.multipliedAlpha(0.22))
                    .multipliedAlpha(node.opacity)
                let border = theme.colors.border.multipliedAlpha(node.opacity)
                let textColor = theme.colors.onSurface.multipliedAlpha(node.opacity)
                let bubble = UIRect(x: x, y: y, width: width, height: height)
                list.addRoundedRect(bubble, radius: max(4, theme.radius.sm), color: bg)
                list.addRect(UIRect(x: bubble.x, y: bubble.y, width: bubble.width, height: 1),
                             color: border)
                list.addRect(UIRect(x: bubble.x,
                                    y: bubble.y + bubble.height - 1,
                                    width: bubble.width,
                                    height: 1),
                             color: border)
                list.addRect(UIRect(x: bubble.x, y: bubble.y, width: 1, height: bubble.height),
                             color: border)
                list.addRect(UIRect(x: bubble.x + bubble.width - 1,
                                    y: bubble.y,
                                    width: 1,
                                    height: bubble.height),
                             color: border)
                list.addText(layout,
                             origin: (x: x + padX, y: y + padY),
                             color: textColor,
                             textureID: env.atlasTextureID,
                             atlas: env.atlas)
            }

            TooltipStoreHolder.current.register(node, draw: draw)
        } else {
            TooltipStoreHolder.current.unregister(node)
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
        registry.setPointer(node) { event, phase, _ in
            // Buttons handle the primary mouse button only. Right- and
            // middle-clicks bubble so parent chrome can surface context-menu
            // or middle-click semantics.
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
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
            guard !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
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
            theme:      theme
        )
        return [style.makeBody(config)]
    }

    static let markerKey = "__button_host"
    static let pressedKey = "__button_pressed"
    static let hoveredKey = "__button_hovered"
    static let tooltipKey = "__button_tooltip"
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
        self.metrics = kind.metrics(in: configuration.theme)
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
    func metrics(in theme: Theme) -> BuiltinButtonChromeMetrics {
        switch self {
        case .primary, .secondary, .ghost, .destructive:
            return BuiltinButtonChromeMetrics(height: 28,
                                              minWidth: nil,
                                              horizontalPadding: theme.spacing.md,
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
    let focused = state.isEnabled && buttonNode.map { FocusChainHolder.current?.focused === $0 } == true
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
        if !state.isEnabled {
            background = clear
        } else if state.isSelected {
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
                                     opacity: state.isEnabled ? 1 : 0.55)
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
