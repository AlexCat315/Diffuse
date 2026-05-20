#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

/// Boolean on/off control rendered as a switch track with a movable thumb.
public struct Toggle: View {
    public let isOn: Binding<Bool>
    public let isEnabled: Bool

    public init(isOn: Binding<Bool>,
                isEnabled: Bool = true) {
        self.isOn = isOn
        self.isEnabled = isEnabled
    }

    public var body: some View {
        _StatefulBoolControl(isOn: isOn,
                             isEnabled: isEnabled,
                             variant: .toggle)
    }
}

/// Checkbox visual variant that shares the same bool activation semantics as `Toggle`.
public struct Checkbox: View {
    public let isOn: Binding<Bool>
    public let isEnabled: Bool

    public init(isOn: Binding<Bool>,
                isEnabled: Bool = true) {
        self.isOn = isOn
        self.isEnabled = isEnabled
    }

    public var body: some View {
        _StatefulBoolControl(isOn: isOn,
                             isEnabled: isEnabled,
                             variant: .checkbox)
    }
}

enum _BoolControlVariant: Sendable {
    case toggle
    case checkbox

    var layoutSize: (width: Float, height: Float) {
        switch self {
        case .toggle:
            return (38, 24)
        case .checkbox:
            return (18, 18)
        }
    }
}

struct _StatefulBoolControl: View {
    let isOn: Binding<Bool>
    let isEnabled: Bool
    let variant: _BoolControlVariant

    @State var isPressed: Bool = false
    @State var isHovered: Bool = false

    var body: some View {
        BoolControlHost(
            isOn: isOn,
            isEnabled: isEnabled,
            variant: variant,
            isPressed: isEnabled ? isPressed : false,
            isHovered: isEnabled ? isHovered : false,
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
            onUp: {
                let was = isPressed
                isPressed = false
                if was {
                    isOn.wrappedValue.toggle()
                    return true
                }
                return false
            },
            onActivate: {
                isOn.wrappedValue.toggle()
            }
        )
    }
}

struct BoolControlHost: _PrimitiveView {
    let isOn: Binding<Bool>
    let isEnabled: Bool
    let variant: _BoolControlVariant
    let isPressed: Bool
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onDown: () -> Void
    let onUp: () -> Bool
    let onActivate: () -> Void

    static let pressedKey = "__bool_control_pressed"
    static let hoveredKey = "__bool_control_hovered"
    static let onKey = "__bool_control_on"
    static let variantKey = "__bool_control_variant"

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.attachments[Self.pressedKey] = isPressed
        node.attachments[Self.hoveredKey] = isHovered
        node.attachments[Self.onKey] = isOn.wrappedValue
        node.attachments[Self.variantKey] = variant
        node.cursor = isEnabled ? .pointer : .notAllowed

        let snapshot = self
        node.draw = { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }

        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }

        let hoverChange = onHoverChange
        let down = onDown
        let up = onUp
        let activate = onActivate
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                hoverChange(true)
            case .leave:
                hoverChange(false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
                down()
                return .handled
            case .up:
                return up() ? .handled : .ignored
            }
        }
        registry.setKey(node) { event, _ in
            guard !event.isRepeat else { return .ignored }
            switch event.scancode {
            case 40, 44, 88: // RETURN, SPACE, KP_ENTER
                activate()
                return .handled
            default:
                return .ignored
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        let size = variant.layoutSize
        layout.width = size.width
        layout.height = size.height
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        let size = variant.layoutSize
        layout.width = size.width
        layout.height = size.height
    }

    private func render(node: Node, origin: CGPoint, list: DrawList) {
        switch variant {
        case .toggle:
            renderToggle(node: node, origin: origin, list: list)
        case .checkbox:
            renderCheckbox(node: node, origin: origin, list: list)
        }
    }

    private func renderToggle(node: Node, origin: CGPoint, list: DrawList) {
        let frame = node.frame
        let width = Float(frame.width)
        let height = Float(frame.height)
        guard width > 0, height > 0 else { return }

        let colors = node.theme.colors
        let originX = Float(origin.x)
        let originY = Float(origin.y)
        let trackHeight: Float = 20
        let thumbDiameter: Float = 16
        let thumbInset: Float = 2
        let trackRect = UIRect(x: originX,
                               y: originY + (height - trackHeight) * 0.5,
                               width: width,
                               height: trackHeight)
        list.addRoundedRect(trackRect,
                            radius: trackHeight * 0.5,
                            color: resolvedFillColor(colors: colors))

        let thumbTravel = trackRect.width - 2 * thumbInset - thumbDiameter
        let thumbX = trackRect.minX + thumbInset + (isOn.wrappedValue ? thumbTravel : 0)
        let thumbRect = UIRect(x: thumbX,
                               y: trackRect.minY + (trackRect.height - thumbDiameter) * 0.5,
                               width: thumbDiameter,
                               height: thumbDiameter)

        let isFocused = (FocusChainHolder.current?.focused === node)
        let thumbBorderColor = isFocused ? colors.focusRing : colors.border
        let thumbBorderWidth: Float = isFocused ? 2 : 1
        let outerRect = UIRect(x: thumbRect.minX - thumbBorderWidth,
                               y: thumbRect.minY - thumbBorderWidth,
                               width: thumbRect.width + 2 * thumbBorderWidth,
                               height: thumbRect.height + 2 * thumbBorderWidth)
        list.addRoundedRect(outerRect,
                            radius: outerRect.height * 0.5,
                            color: thumbBorderColor)
        list.addRoundedRect(thumbRect,
                            radius: thumbRect.height * 0.5,
                            color: resolvedToggleThumbColor(colors: colors))
    }

    private func renderCheckbox(node: Node, origin: CGPoint, list: DrawList) {
        let frame = node.frame
        let width = Float(frame.width)
        let height = Float(frame.height)
        guard width > 0, height > 0 else { return }

        let colors = node.theme.colors
        let originX = Float(origin.x)
        let originY = Float(origin.y)
        let edge = min(width, height)
        let boxRect = UIRect(x: originX,
                             y: originY + (height - edge) * 0.5,
                             width: edge,
                             height: edge)
        let isFocused = (FocusChainHolder.current?.focused === node)
        let boxBorderColor = isFocused ? colors.focusRing : colors.border
        let boxBorderWidth: Float = isFocused ? 2 : 1
        let outerRect = UIRect(x: boxRect.minX - boxBorderWidth,
                               y: boxRect.minY - boxBorderWidth,
                               width: boxRect.width + 2 * boxBorderWidth,
                               height: boxRect.height + 2 * boxBorderWidth)
        list.addRoundedRect(outerRect,
                            radius: 5,
                            color: boxBorderColor)
        list.addRoundedRect(boxRect,
                            radius: 4,
                            color: resolvedFillColor(colors: colors))

        if isOn.wrappedValue {
            let inset = max(3, edge * 0.18)
            let x0 = boxRect.minX + inset
            let y0 = boxRect.minY + edge * 0.55
            let x1 = boxRect.minX + edge * 0.42
            let y1 = boxRect.minY + edge - inset
            let x2 = boxRect.minX + edge - inset
            let y2 = boxRect.minY + inset
            let lineColor = isEnabled ? colors.onAccent : colors.onSurfaceMuted
            list.addLine(fromX: x0, fromY: y0,
                         toX: x1, toY: y1,
                         thickness: 2,
                         color: lineColor)
            list.addLine(fromX: x1, fromY: y1,
                         toX: x2, toY: y2,
                         thickness: 2,
                         color: lineColor)
        }
    }

    private func resolvedFillColor(colors: ColorScheme) -> Color {
        if !isEnabled {
            return colors.surfaceVariant
        }
        if isOn.wrappedValue {
            if isPressed { return colors.accentPressed }
            if isHovered { return colors.accentHover }
            return colors.accent
        }

        let base = colors.surfaceVariant
        if isPressed { return base.composited(over: colors.stateLayerPressed) }
        if isHovered { return base.composited(over: colors.stateLayerHover) }
        return base
    }

    private func resolvedToggleThumbColor(colors: ColorScheme) -> Color {
        if !isEnabled {
            return colors.surfaceRaised
        }
        return isOn.wrappedValue ? colors.onAccent : colors.surfaceRaised
    }
}
