import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

/// Two-thumb range control. The active thumb is chosen by pointer proximity,
/// then moved with pointer drag, arrow keys, Home/End or accessibility
/// increment/decrement. Values are clamped to `range` and kept at least
/// `minimumSpan` apart.
public struct RangeSlider: View {
    public let values: Binding<ClosedRange<Double>>
    public let range: ClosedRange<Double>
    public let step: Double?
    public let minimumSpan: Double
    public let isEnabled: Bool
    public let onEditingChanged: ((Bool) -> Void)?

    public init(values: Binding<ClosedRange<Double>>,
                in range: ClosedRange<Double> = 0...1,
                step: Double? = nil,
                minimumSpan: Double = 0,
                isEnabled: Bool = true,
                onEditingChanged: ((Bool) -> Void)? = nil) {
        self.values = values
        self.range = range
        self.step = step.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.minimumSpan = minimumSpan.isFinite ? max(0, minimumSpan) : 0
        self.isEnabled = isEnabled
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        RangeSliderHost(values: values, range: range, step: step,
                        minimumSpan: minimumSpan, isEnabled: isEnabled,
                        onEditingChanged: onEditingChanged)
    }
}

private enum RangeThumb: String {
    case lower
    case upper
}

private struct RangeSliderHost: _PrimitiveView {
    let values: Binding<ClosedRange<Double>>
    let range: ClosedRange<Double>
    let step: Double?
    let minimumSpan: Double
    let isEnabled: Bool
    let onEditingChanged: ((Bool) -> Void)?

    static let pressedKey = "__range_slider_pressed"
    static let hoveredKey = "__range_slider_hovered"
    static let activeKey = "__range_slider_active"

    private struct PaintIdentity: Equatable {
        let values: ClosedRange<Double>
        let range: ClosedRange<Double>
        let isEnabled: Bool
        let active: RangeThumb
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        return node
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        if !node.supportsControlHover { node.attachments[Self.hoveredKey] = false }
        node.isFocusable = isEnabled
        updateAccessibility(node)
        node.accessibilityActions = AccessibilityActions()
        if isEnabled {
            let increment = step ?? (range.upperBound - range.lowerBound) / 100
            node.accessibilityActions.increment = { moveActive(by: increment, node: node) }
            node.accessibilityActions.decrement = { moveActive(by: -increment, node: node) }
        } else {
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
            node.attachments[Self.pressedKey] = false
            node.attachments[Self.hoveredKey] = false
        }
        if node.attachments[Self.activeKey] == nil {
            node.attachments[Self.activeKey] = RangeThumb.lower.rawValue
        }
        node.cursor = isEnabled ? .pointer : .notAllowed

        let style = node.compositionValue(of: SliderStyleEnvironment.key)
        let current = normalized(values.wrappedValue)
        let snapshot = self
        node.updateDraw(identity: PaintIdentity(values: current, range: range,
                                                isEnabled: isEnabled,
                                                active: activeThumb(node))) { list, origin in
            snapshot.render(node: node, style: style, origin: origin, list: list)
        }

        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                setInteraction(node, key: Self.hoveredKey, value: node.supportsControlHover)
            case .leave:
                setInteraction(node, key: Self.hoveredKey, value: false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                if setInteraction(node, key: Self.pressedKey, value: true) {
                    onEditingChanged?(true)
                }
                chooseThumb(at: event.x, node: node)
                writeActiveValue(forWindowX: event.x, node: node)
                node.markRenderDirty(reason: .styleSet(field: "rangeSliderValue"))
                return .handled
            case .up:
                if PointerCaptureHolder.current?.target === node {
                    PointerCaptureHolder.current?.release()
                }
                if setInteraction(node, key: Self.pressedKey, value: false) {
                    onEditingChanged?(false)
                }
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            guard node.attachments[Self.pressedKey] as? Bool == true else { return .ignored }
            snapshot.writeActiveValue(forWindowX: event.x, node: node)
            node.markRenderDirty(reason: .styleSet(field: "rangeSliderValue"))
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target else { return .ignored }
            let increment = step ?? (range.upperBound - range.lowerBound) / 100
            switch event.scancode {
            case Scancode.arrowLeft, Scancode.arrowDown:
                snapshot.moveActive(by: -increment, node: node)
            case Scancode.arrowRight, Scancode.arrowUp:
                snapshot.moveActive(by: increment, node: node)
            case Scancode.home:
                snapshot.moveActive(to: range.lowerBound, node: node)
            case Scancode.end:
                snapshot.moveActive(to: range.upperBound, node: node)
            default:
                return .ignored
            }
            node.markRenderDirty(reason: .styleSet(field: "rangeSliderValue"))
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = 24
        layout.setMeasureFunc { width, widthMode, _, _ in
            CGSize(width: CGFloat(widthMode == .undefined ? 160 : min(160, width)), height: 24)
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.height = 24
    }

    // MARK: - Values

    private func activeThumb(_ node: Node) -> RangeThumb {
        RangeThumb(rawValue: node.attachments[Self.activeKey] as? String ?? "") ?? .lower
    }

    private func normalized(_ raw: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = min(max(range.lowerBound, raw.lowerBound), range.upperBound)
        let upper = min(max(range.lowerBound, raw.upperBound), range.upperBound)
        guard lower <= upper else { return range.lowerBound...range.upperBound }
        return lower...upper
    }

    private func snap(_ raw: Double) -> Double {
        guard let step, step > 0 else { return raw }
        let lo = range.lowerBound
        let n = ((raw - lo) / step).rounded()
        return min(range.upperBound, max(range.lowerBound, lo + n * step))
    }

    private func chooseThumb(at windowX: Float, node: Node) {
        let local = localFraction(windowX: windowX, node: node)
        let current = normalized(values.wrappedValue)
        let lower = fraction(current.lowerBound)
        let upper = fraction(current.upperBound)
        let thumb: RangeThumb = abs(local - lower) <= abs(local - upper) ? .lower : .upper
        node.attachments[Self.activeKey] = thumb.rawValue
    }

    private func localFraction(windowX: Float, node: Node) -> Double {
        let width = max(1, Float(node.frame.width))
        let local = Float(windowX) - Float(node.absoluteOrigin.x)
        return Double(min(max(0, local / width), 1))
    }

    private func fraction(_ value: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    private func writeActiveValue(forWindowX windowX: Float, node: Node) {
        let fraction = localFraction(windowX: windowX, node: node)
        let span = range.upperBound - range.lowerBound
        moveActive(to: range.lowerBound + fraction * span, node: node)
    }

    private func moveActive(to raw: Double, node: Node) {
        let active = activeThumb(node)
        let current = normalized(values.wrappedValue)
        let target = snap(raw)
        var lower = current.lowerBound
        var upper = current.upperBound
        switch active {
        case .lower:
            lower = min(target, upper - minimumSpan)
            lower = max(range.lowerBound, lower)
        case .upper:
            upper = max(target, lower + minimumSpan)
            upper = min(range.upperBound, upper)
        }
        if lower > upper {
            lower = upper
        }
        let next = lower...upper
        if next != current {
            values.wrappedValue = next
            updateAccessibility(node)
        }
    }

    private func updateAccessibility(_ node: Node) {
        let current = normalized(values.wrappedValue)
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.state.isEnabled = isEnabled
            $0.value = "\(format(current.lowerBound)) – \(format(current.upperBound))"
        }
    }

    private func moveActive(by delta: Double, node: Node) {
        let active = activeThumb(node)
        let current = normalized(values.wrappedValue)
        moveActive(to: active == .lower ? current.lowerBound + delta : current.upperBound + delta,
                   node: node)
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Rendering

    private func render(node: Node,
                        style: AnySliderStyle,
                        origin: CGPoint,
                        list: DrawList) {
        let current = normalized(values.wrappedValue)
        let active = activeThumb(node)
        let appearance = style.resolve(SliderStyleConfiguration(
            value: active == .lower ? current.lowerBound : current.upperBound,
            range: range,
            isPressed: node.attachments[Self.pressedKey] as? Bool ?? false,
            isHovered: node.attachments[Self.hoveredKey] as? Bool ?? false,
            isFocused: FocusChainHolder.current?.focused === node,
            isEnabled: isEnabled,
            theme: node.theme))
        let frame = node.frame
        let width = Float(frame.width)
        let height = Float(frame.height)
        guard width > 0, height > 0 else { return }

        let originX = Float(origin.x)
        let originY = Float(origin.y)
        let trackY = originY + (height - appearance.trackHeight) * 0.5
        let trackRect = UIRect(x: originX, y: trackY, width: width,
                               height: appearance.trackHeight)
        list.addRoundedRect(trackRect, radius: appearance.trackCornerRadius,
                            color: appearance.trackColor)

        let lowerX = originX + Float(fraction(current.lowerBound)) * width
        let upperX = originX + Float(fraction(current.upperBound)) * width
        let fillWidth = max(0, upperX - lowerX)
        if fillWidth > 0 {
            list.addRoundedRect(UIRect(x: lowerX, y: trackY, width: fillWidth,
                                       height: appearance.trackHeight),
                                radius: appearance.trackCornerRadius,
                                color: appearance.fillColor)
        }

        let half = appearance.thumbDiameter * 0.5
        let focus = FocusChainHolder.current?.focused === node
        for (thumb, centreX) in [(RangeThumb.lower, lowerX), (.upper, upperX)] {
            let clamped = min(max(originX + half, centreX), originX + width - half)
            let rect = UIRect(x: clamped - half,
                              y: originY + (height - appearance.thumbDiameter) * 0.5,
                              width: appearance.thumbDiameter,
                              height: appearance.thumbDiameter)
            if focus && thumb == active {
                list.addRoundedRect(UIRect(x: rect.minX - 2, y: rect.minY - 2,
                                           width: rect.width + 4, height: rect.height + 4),
                                    radius: (rect.height + 4) * 0.5,
                                    color: node.theme.colors.focusRing)
            } else if let border = appearance.thumbBorderColor, appearance.thumbBorderWidth > 0 {
                let bw = appearance.thumbBorderWidth
                list.addRoundedRect(UIRect(x: rect.minX - bw, y: rect.minY - bw,
                                           width: rect.width + 2 * bw, height: rect.height + 2 * bw),
                                    radius: (rect.height + 2 * bw) * 0.5,
                                    color: border)
            }
            list.addRoundedRect(rect, radius: appearance.thumbDiameter * 0.5,
                                color: appearance.thumbColor)
        }
    }
}

@discardableResult
private func setInteraction(_ node: Node, key: String, value: Bool) -> Bool {
    let previous = node.attachments[key] as? Bool
    guard previous != value else { return false }
    node.attachments[key] = value
    node.markRenderDirty(reason: .styleSet(field: key))
    return true
}
