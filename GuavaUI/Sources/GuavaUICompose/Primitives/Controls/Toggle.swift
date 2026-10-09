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

public enum CheckboxState: Sendable, Equatable { case off, on, mixed }

/// Mixed state represents a partially selected collection. Activation selects it fully.
public struct Checkbox: View {
    public let state: Binding<CheckboxState>
    public let isEnabled: Bool

    public init(state: Binding<CheckboxState>, isEnabled: Bool = true) {
        self.state = state
        self.isEnabled = isEnabled
    }

    public init(isOn: Binding<Bool>,
                isEnabled: Bool = true) {
        self.state = Binding(get: { isOn.wrappedValue ? .on : .off },
                             set: { isOn.wrappedValue = $0 == .on })
        self.isEnabled = isEnabled
    }

    public var body: some View {
        _StatefulBoolControl(isOn: Binding(get: { state.wrappedValue == .on },
                                          set: { state.wrappedValue = $0 ? .on : .off }),
                             isEnabled: isEnabled,
                             variant: state.wrappedValue == .mixed ? .mixedCheckbox : .checkbox)
    }
}

enum _BoolControlVariant: Sendable, Equatable {
    case toggle
    case checkbox
    case mixedCheckbox

    var layoutSize: (width: Float, height: Float) {
        switch self {
        case .toggle:
            return (38, 24)
        case .checkbox, .mixedCheckbox:
            return (18, 18)
        }
    }
}

struct _StatefulBoolControl: View {
    let isOn: Binding<Bool>
    let isEnabled: Bool
    let variant: _BoolControlVariant

    var body: some View {
        BoolControlHost(
            isOn: isOn,
            isEnabled: isEnabled,
            variant: variant
        )
    }
}

struct BoolControlHost: _PrimitiveView {
    let isOn: Binding<Bool>
    let isEnabled: Bool
    let variant: _BoolControlVariant

    static let pressedKey = "__bool_control_pressed"
    static let hoveredKey = "__bool_control_hovered"
    static let onKey = "__bool_control_on"
    static let variantKey = "__bool_control_variant"

    private struct PaintIdentity: Equatable {
        let isOn: Bool
        let isEnabled: Bool
        let variant: _BoolControlVariant
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.isFocusable = isEnabled
        node.accessibility = AccessibilitySemantics(variant == .toggle ? .toggle : .checkbox) {
            $0.state.isEnabled = isEnabled; $0.state.isSelected = isOn.wrappedValue
            $0.value = variant == .mixedCheckbox ? "mixed" : isOn.wrappedValue ? "1" : "0"
        }
        node.accessibilityActions = AccessibilityActions()
        if isEnabled { node.accessibilityActions.activate = { isOn.wrappedValue.toggle() } }
        if !isEnabled {
            node.attachments[Self.pressedKey] = false
            node.attachments[Self.hoveredKey] = false
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
        } else {
            if node.attachments[Self.pressedKey] == nil {
                node.attachments[Self.pressedKey] = false
            }
            if node.attachments[Self.hoveredKey] == nil {
                node.attachments[Self.hoveredKey] = false
            }
        }
        node.attachments[Self.onKey] = isOn.wrappedValue || variant == .mixedCheckbox
        node.attachments[Self.variantKey] = variant
        node.cursor = isEnabled ? .pointer : .notAllowed

        updateBoolControlAppearance(node, isOn: isOn.wrappedValue || variant == .mixedCheckbox, isEnabled: isEnabled)
        let snapshot = self
        node.updateDraw(identity: PaintIdentity(isOn: isOn.wrappedValue,
                                                isEnabled: isEnabled,
                                                variant: variant)) { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }

        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }

        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                setBoolControlInteraction(node, key: Self.hoveredKey, value: true)
            case .leave:
                setBoolControlInteraction(node, key: Self.hoveredKey, value: false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            if event.button != .left { return .ignored }
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                setBoolControlInteraction(node, key: Self.pressedKey, value: true)
                return .handled
            case .up:
                let wasPressed = node.attachments[Self.pressedKey] as? Bool ?? false
                setBoolControlInteraction(node, key: Self.pressedKey, value: false)
                guard wasPressed else { return .ignored }
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                guard node.absoluteFrame.contains(CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))) else { return .handled }
                isOn.wrappedValue.toggle()
                node.attachments[Self.onKey] = isOn.wrappedValue
                updateBoolControlAppearance(node, isOn: isOn.wrappedValue, isEnabled: isEnabled)
                node.markRenderDirty(reason: .styleSet(field: "boolControlValue"))
                return .handled
            }
        }
        registry.setKey(node) { event, phase in
            guard phase == .target, !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.return, Scancode.space, Scancode.keypadEnter:
                isOn.wrappedValue.toggle()
                node.attachments[Self.onKey] = isOn.wrappedValue
                updateBoolControlAppearance(node, isOn: isOn.wrappedValue, isEnabled: isEnabled)
                node.markRenderDirty(reason: .styleSet(field: "boolControlValue"))
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
        case .checkbox, .mixedCheckbox:
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
                            color: resolvedFillColor(node: node, colors: colors))

        let thumbTravel = trackRect.width - 2 * thumbInset - thumbDiameter
        let progress = node.attachments["__bool_visual_progress"] as? Float ?? (isOn.wrappedValue ? 1 : 0)
        let thumbX = trackRect.minX + thumbInset + thumbTravel * progress
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
                            color: resolvedFillColor(node: node, colors: colors))

        let checkProgress = node.attachments["__bool_visual_progress"] as? Float ?? (isOn.wrappedValue ? 1 : 0)
        if checkProgress > 0 {
            let inset = max(3, edge * 0.18)
            let x0 = boxRect.minX + inset
            let y0 = boxRect.minY + edge * 0.55
            let x1 = boxRect.minX + edge * 0.42
            let y1 = boxRect.minY + edge - inset
            let x2 = boxRect.minX + edge - inset
            let y2 = boxRect.minY + inset
            let lineColor = (isEnabled ? colors.onAccent : colors.onSurfaceMuted).multipliedAlpha(checkProgress * node.opacity)
            if variant == .mixedCheckbox {
                list.addLine(fromX: x0, fromY: boxRect.minY + edge / 2,
                             toX: x2, toY: boxRect.minY + edge / 2, thickness: 2, color: lineColor)
                return
            }
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

    private func resolvedFillColor(node: Node, colors: ColorScheme) -> Color {
        if let fill = node.attachments["__bool_visual_fill"] as? Color { return fill.multipliedAlpha(node.opacity) }
        if !isEnabled {
            return colors.surfaceVariant
        }
        let isPressed = node.attachments[Self.pressedKey] as? Bool ?? false
        let isHovered = node.attachments[Self.hoveredKey] as? Bool ?? false
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

private func setBoolControlInteraction(_ node: Node, key: String, value: Bool) {
    let previous = node.attachments[key] as? Bool
    guard previous != value else { return }
    node.attachments[key] = value
    updateBoolControlAppearance(node, isOn: node.attachments[BoolControlHost.onKey] as? Bool == true,
                                isEnabled: node.cursor != .notAllowed)
    node.markRenderDirty(reason: .styleSet(field: key))
}

private func updateBoolControlAppearance(_ node: Node, isOn: Bool, isEnabled: Bool) {
    let colors = node.theme.colors
    let pressed = node.attachments[BoolControlHost.pressedKey] as? Bool == true
    let hovered = node.attachments[BoolControlHost.hoveredKey] as? Bool == true
    let base = !isEnabled ? colors.surfaceVariant : isOn ? colors.accent : colors.surfaceVariant
    let fill = !isEnabled ? base : pressed ? (isOn ? colors.accentPressed : base.composited(over: colors.stateLayerPressed))
        : hovered ? (isOn ? colors.accentHover : base.composited(over: colors.stateLayerHover)) : base
    let previous = node.attachments["__bool_visual_progress"] as? Float
    let apply = { [node] in
        node.animatableSet(propertyKey: "bool.progress", current: previous ?? (isOn ? 1 : 0), to: Float(isOn ? 1 : 0)) { [weak node] value in
            node?.attachments["__bool_visual_progress"] = value
            node?.markRenderDirty(reason: .styleSet(field: "bool.progress"))
        }
        node.animatableSet(propertyKey: "bool.fill", current: node.attachments["__bool_visual_fill"] as? Color ?? fill, to: fill) { [weak node] value in
            node?.attachments["__bool_visual_fill"] = value
            node?.markRenderDirty(reason: .styleSet(field: "bool.fill"))
        }
    }
    if previous != nil { withAnimation(.semantic(.fast, in: node.theme), apply) } else { apply() }
}
