import EngineKernel
import GuavaUIRuntime

// MARK: - Primitive host

struct SliderHost: _PrimitiveView {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let isEnabled: Bool
    let onEditingChanged: ((Bool) -> Void)?
    let showsTicks: Bool
    let axis: Slider.Axis

    static let pressedKey = "__slider_pressed"
    static let hoveredKey = "__slider_hovered"
    static let appearanceKey = "__slider_appearance"

    private struct PaintIdentity: Equatable {
        let value: Double
        let lowerBound: Double
        let upperBound: Double
        let isEnabled: Bool
        let axis: Slider.Axis
        let step: Double?
        let showsTicks: Bool
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        node.applyTouchControlExtent()
        if !node.supportsControlHover { node.attachments[Self.hoveredKey] = false }
        node.isFocusable = isEnabled
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.state.isEnabled = isEnabled; $0.value = String(clampedValue(value.wrappedValue))
        }
        node.accessibilityActions = AccessibilityActions()
        if isEnabled {
            node.accessibilityActions.setValue = { if let number = Double($0), number.isFinite { value.wrappedValue = snap(clampedValue(number)) } }
            let increment = step ?? (range.upperBound - range.lowerBound) / 100
            node.accessibilityActions.increment = { value.wrappedValue = snap(clampedValue(value.wrappedValue + increment)) }
            node.accessibilityActions.decrement = { value.wrappedValue = snap(clampedValue(value.wrappedValue - increment)) }
        }
        if !isEnabled {
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
            if node.attachments[Self.pressedKey] as? Bool == true { onEditingChanged?(false) }
        }
        if !isEnabled {
            node.attachments[SliderHost.pressedKey] = false
            node.attachments[SliderHost.hoveredKey] = false
        } else {
            if node.attachments[SliderHost.pressedKey] == nil {
                node.attachments[SliderHost.pressedKey] = false
            }
            if node.attachments[SliderHost.hoveredKey] == nil {
                node.attachments[SliderHost.hoveredKey] = false
            }
        }
        node.cursor = isEnabled ? .pointer : .notAllowed

        // Style lookup walks `compositionValues` so users can swap in a custom
        // `SliderStyle` via `.sliderStyle(_:)`. Interaction flags are read
        // from node attachments in draw, so hover/press can repaint without
        // scheduling a recompose.
        let style = node.compositionValue(of: SliderStyleEnvironment.key)

        // Renderer hook — draws track + filled segment + thumb each frame.
        let snapshot = self
        node.updateDraw(identity: PaintIdentity(value: value.wrappedValue,
                                                lowerBound: range.lowerBound,
                                                upperBound: range.upperBound,
                                                isEnabled: isEnabled, axis: axis,
                                                step: step, showsTicks: showsTicks)) { list, origin in
            snapshot.render(node: node, style: style, origin: origin, list: list)
        }

        // Wire interaction handlers (only when enabled and a registry exists).
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        registry.setHover(node) { phase in
            switch phase {
            case .enter:
                setSliderInteraction(node, key: SliderHost.hoveredKey, value: node.supportsControlHover)
            case .leave:
                setSliderInteraction(node, key: SliderHost.hoveredKey, value: false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                if setSliderInteraction(node, key: SliderHost.pressedKey, value: true) {
                    onEditingChanged?(true)
                }
                snapshot.writeValue(x: event.x, y: event.y, node: node)
                node.markRenderDirty(reason: .styleSet(field: "sliderValue"))
                return .handled
            case .up:
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                if setSliderInteraction(node, key: SliderHost.pressedKey, value: false) {
                    onEditingChanged?(false)
                }
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            // Only consume motion while the thumb is being dragged. The host
            // explicitly acquires pointer capture on `.down`, so motion events
            // outside the node's frame still arrive here during a drag.
            guard node.attachments[SliderHost.pressedKey] as? Bool == true else { return .ignored }
            snapshot.writeValue(x: event.x, y: event.y, node: node)
            node.markRenderDirty(reason: .styleSet(field: "sliderValue"))
            return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target else { return .ignored }
            let increment = step.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
                ?? (range.upperBound - range.lowerBound) / 100
            let next: Double
            switch event.scancode {
            case Scancode.arrowDown: next = value.wrappedValue - increment
            case Scancode.arrowUp: next = value.wrappedValue + increment
            case Scancode.arrowLeft:
                next = value.wrappedValue + (axis == .horizontal && SliderGeometry(node: node, axis: axis).isReversed ? increment : -increment)
            case Scancode.arrowRight:
                next = value.wrappedValue + (axis == .horizontal && SliderGeometry(node: node, axis: axis).isReversed ? -increment : increment)
            case Scancode.pageUp: next = value.wrappedValue + increment * 10
            case Scancode.pageDown: next = value.wrappedValue - increment * 10
            case Scancode.home: next = range.lowerBound
            case Scancode.end: next = range.upperBound
            default: return .ignored
            }
            value.wrappedValue = snapshot.snap(next)
            node.markRenderDirty(reason: .styleSet(field: "sliderValue"))
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        _updateLayout(l)
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.width = axis == .vertical ? 24 : nil
        layout.height = axis == .horizontal ? 24 : nil
        // A width-only frame restores Yoga's auto height. Keep the control's
        // natural size through measurement, including in center-aligned rows.
        layout.setMeasureFunc { width, widthMode, height, heightMode in
            if axis == .vertical {
                return CGSize(width: 24, height: CGFloat(heightMode == .undefined ? 160 : min(160, height)))
            }
            return CGSize(width: CGFloat(widthMode == .undefined ? 160 : min(160, width)), height: 24)
        }
    }

    // MARK: - Value mapping

    func clampedValue(_ raw: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, raw))
    }

    private func snap(_ raw: Double) -> Double {
        guard let step, step > 0 else { return raw }
        let lo = range.lowerBound
        let n = ((raw - lo) / step).rounded()
        return clampedValue(lo + n * step)
    }

    private func writeValue(x: Float, y: Float, node: Node) {
        guard x.isFinite, y.isFinite else { return }
        let geometry = SliderGeometry(node: node, axis: axis)
        let local = axis == .horizontal ? x - Float(node.absoluteOrigin.x) : y - Float(node.absoluteOrigin.y)
        let fraction = Double(geometry.valueFraction(at: local))
        let span = range.upperBound - range.lowerBound
        let raw = range.lowerBound + fraction * span
        let next = snap(raw)
        if next != value.wrappedValue {
            value.wrappedValue = next
        }
    }

}

@discardableResult
private func setSliderInteraction(_ node: Node, key: String, value: Bool) -> Bool {
    let previous = node.attachments[key] as? Bool
    guard previous != value else { return false }
    node.attachments[key] = value
    node.markRenderDirty(reason: .styleSet(field: key))
    return true
}
