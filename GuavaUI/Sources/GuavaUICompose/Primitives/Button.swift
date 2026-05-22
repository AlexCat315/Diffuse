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
    public let tooltip: String?
    public let action: () -> Void
    public let label: Label

    public init(role: ButtonRole = .normal,
                isEnabled: Bool = true,
                tooltip: String? = nil,
                action: @escaping () -> Void,
                @ViewBuilder label: () -> Label) {
        self.role = role
        self.isEnabled = isEnabled
        self.tooltip = tooltip
        self.action = action
        self.label = label()
    }

    public var body: some View {
        _StatefulButton(role: role,
                        isEnabled: isEnabled,
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
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, tooltip: tooltip, action: action) {
            Text(title)
        }
    }

    /// Localized title convenience initializer.
    init(_ key: LocalizedStringKey,
         role: ButtonRole = .normal,
         isEnabled: Bool = true,
         tooltip: String? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, tooltip: tooltip, action: action) {
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
         tooltip: String? = nil,
         tint: Color? = nil,
         action: @escaping () -> Void) {
        self.init(role: role, isEnabled: isEnabled, tooltip: tooltip, action: action) {
            ButtonIcon(source, size: size, tint: tint)
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
    let tooltip: String?
    let action: () -> Void
    let label: AnyView

    @State var isPressed: Bool = false
    @State var isHovered: Bool = false

    // SDL scancodes used across compose controls.
    private static let returnScancode: UInt32 = 40
    private static let spaceScancode: UInt32 = 44
    private static let keypadEnterScancode: UInt32 = 88

    var body: some View {
        ButtonHost(
            role: role,
            isEnabled: isEnabled,
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
            onUp: { [action] in
                isPressed = false
                action()
                return true
            },
            onCancel: {
                if isPressed {
                    isPressed = false
                }
            },
            onKey: { [action] scancode, isRepeat in
                guard !isRepeat else { return EventResult.ignored }
                switch scancode {
                case Self.returnScancode,
                    Self.spaceScancode,
                    Self.keypadEnterScancode:
                    action()
                    return EventResult.handled
                default:
                    return EventResult.ignored
                }
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
    let tooltip: String?
    let isPressed: Bool
    let isHovered: Bool
    let label: AnyView
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onUp: () -> Bool
    let onCancel: () -> Void
    let onKey: (UInt32, Bool) -> EventResult

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        node.attachments[ButtonHost.pressedKey] = isPressed
        node.attachments[ButtonHost.hoveredKey] = isHovered
        node.attachments[ButtonHost.tooltipKey] = tooltip

        let resolvedTooltip = tooltip?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEnabled, let resolvedTooltip, !resolvedTooltip.isEmpty {
            let draw: (DrawList) -> Void = { [weak node] list in
                guard let node else { return }
                let isFocused = (FocusChainHolder.current?.focused === node)
                guard isHovered || isFocused else { return }
                guard let env = TextEnvironmentHolder.current else { return }

                let origin = absoluteOrigin(of: node)

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

            TooltipOverlayRegistry.register(node, draw: draw)
        } else {
            TooltipOverlayRegistry.unregister(node)
        }

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
        let cancel = onCancel
        let key = onKey
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
            // middle-clicks bubble so parent chrome can surface context-menu
            // or middle-click semantics.
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
                node.attachments[ButtonHost.activePressKey] = ActiveButtonPress(onUp: up)
                PointerCaptureHolder.current?.acquire(node)
                down()
                return .handled
            case .up:
                let activePress = node.attachments[ButtonHost.activePressKey] as? ActiveButtonPress
                node.attachments.removeValue(forKey: ButtonHost.activePressKey)
                let isInside = isPointInsideButton(event.x, event.y, node: node)
                defer {
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                }
                guard let activePress else { return .ignored }
                guard isInside else {
                    cancel()
                    return .handled
                }
                return activePress.onUp() ? .handled : .ignored
            }
        }
        registry.setMotion(node) { event, _ in
            guard node.attachments[ButtonHost.activePressKey] is ActiveButtonPress else {
                return .ignored
            }
            let isInside = isPointInsideButton(event.x, event.y, node: node)
            hoverChange(isInside)
            if isInside {
                down()
            } else {
                cancel()
            }
            return .handled
        }
        registry.setKey(node) { event, _ in
            key(event.scancode, event.isRepeat)
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
    static let tooltipKey = "__button_tooltip"
    static let activePressKey = "__button_active_press"
}

private final class ActiveButtonPress {
    let onUp: () -> Bool

    init(onUp: @escaping () -> Bool) {
        self.onUp = onUp
    }
}

private func absoluteOrigin(of node: Node) -> CGPoint {
    var x: Float = 0
    var y: Float = 0
    var current: Node? = node
    while let n = current {
        x += Float(n.frame.origin.x)
        y += Float(n.frame.origin.y)
        current = n.parent
    }
    return CGPoint(x: Double(x), y: Double(y))
}

private func isPointInsideButton(_ x: Float, _ y: Float, node: Node) -> Bool {
    let origin = absoluteOrigin(of: node)
    let px = CGFloat(x)
    let py = CGFloat(y)
    return px >= origin.x
        && py >= origin.y
        && px < origin.x + node.frame.width
        && py < origin.y + node.frame.height
}
