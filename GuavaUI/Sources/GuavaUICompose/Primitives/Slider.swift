import CoreGraphics
import EngineKernel
import GuavaUIRuntime

// MARK: - Public API

/// Continuous, single-thumb slider bound to a `Double` value within a range.
///
/// ```swift
/// @State var volume: Double = 0.5
/// Slider(value: $volume, range: 0...1)
/// ```
///
/// Mirrors the `Button` pattern: the public struct delegates to a stateful
/// composite (`_StatefulSlider`) whose `@State` writes drive recompose, while
/// the actual hit-testing and drawing live in a leaf `_PrimitiveView`
/// (`SliderHost`).
public struct Slider: View {
    public let value: Binding<Double>
    public let range: ClosedRange<Double>
    public let step: Double?
    public let isEnabled: Bool
    public let onEditingChanged: ((Bool) -> Void)?

    public init(value: Binding<Double>,
                range: ClosedRange<Double> = 0...1,
                step: Double? = nil,
                isEnabled: Bool = true,
                onEditingChanged: ((Bool) -> Void)? = nil) {
        self.value = value
        self.range = range
        self.step = step
        self.isEnabled = isEnabled
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        _StatefulSlider(value: value,
                        range: range,
                        step: step,
                        isEnabled: isEnabled,
                        onEditingChanged: onEditingChanged)
    }
}

// MARK: - Stateful wrapper

struct _StatefulSlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let isEnabled: Bool
    let onEditingChanged: ((Bool) -> Void)?

    @State var isPressed: Bool = false
    @State var isHovered: Bool = false

    var body: some View {
        SliderHost(
            value: value,
            range: range,
            step: step,
            isEnabled: isEnabled,
            isPressed: isEnabled ? isPressed : false,
            isHovered: isEnabled ? isHovered : false,
            onHoverChange: { hovered in
                if isHovered != hovered { isHovered = hovered }
            },
            onPressChange: { [onEditingChanged] pressed in
                if isPressed != pressed {
                    isPressed = pressed
                    onEditingChanged?(pressed)
                }
            }
        )
    }
}

// MARK: - Primitive host

struct SliderHost: _PrimitiveView {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let isEnabled: Bool
    let isPressed: Bool
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onPressChange: (Bool) -> Void

    static let pressedKey = "__slider_pressed"
    static let hoveredKey = "__slider_hovered"
    static let appearanceKey = "__slider_appearance"

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    func _updateNode(_ node: Node) {
        node.attachments[SliderHost.pressedKey] = isPressed
        node.attachments[SliderHost.hoveredKey] = isHovered

        // Resolve the active style and store the appearance for `draw` to
        // consume. Style lookup walks `compositionValues` so users can swap in
        // a custom `SliderStyle` via `.sliderStyle(_:)`.
        let style = node.compositionValue(of: SliderStyleEnvironment.key)
        let theme = node.theme
        let isFocused = (FocusChainHolder.current?.focused === node)
        let config = SliderStyleConfiguration(
            value: clampedValue(value.wrappedValue),
            range: range,
            isPressed: isPressed,
            isHovered: isHovered,
            isFocused: isFocused,
            isEnabled: isEnabled,
            theme: theme
        )
        let appearance = style.resolve(config)
        node.attachments[SliderHost.appearanceKey] = appearance

        // Renderer hook — draws track + filled segment + thumb each frame.
        let snapshot = self
        node.draw = { list, origin in
            snapshot.render(node: node, origin: origin, list: list)
        }

        // Wire interaction handlers (only when enabled and a registry exists).
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        let hover = onHoverChange
        let press = onPressChange
        registry.setHover(node) { phase in
            switch phase {
            case .enter: hover(true)
            case .leave: hover(false)
            }
        }
        registry.setPointer(node) { event, phase, _ in
            switch phase {
            case .down:
                PointerCaptureHolder.current?.acquire(node)
                press(true)
                snapshot.writeValue(forWindowX: event.x, node: node)
                return .handled
            case .up:
                PointerCaptureHolder.current?.release()
                press(false)
                return .handled
            }
        }
        registry.setMotion(node) { event, _ in
            // Only consume motion while the thumb is being dragged. The host
            // explicitly acquires pointer capture on `.down`, so motion events
            // outside the node's frame still arrive here during a drag.
            guard snapshot.isPressed else { return .ignored }
            snapshot.writeValue(forWindowX: event.x, node: node)
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.height = 24
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.height = 24
    }

    // MARK: - Value mapping

    private func clampedValue(_ raw: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, raw))
    }

    private func snap(_ raw: Double) -> Double {
        guard let step, step > 0 else { return raw }
        let lo = range.lowerBound
        let n = ((raw - lo) / step).rounded()
        return clampedValue(lo + n * step)
    }

    private func writeValue(forWindowX windowX: Float, node: Node) {
        let absX = absoluteOriginX(of: node)
        let width = max(1, Float(node.frame.width))
        let local = Float(windowX) - absX
        let fraction = Double(min(max(0, local / width), 1))
        let span = range.upperBound - range.lowerBound
        let raw = range.lowerBound + fraction * span
        let next = snap(raw)
        if next != value.wrappedValue {
            value.wrappedValue = next
        }
    }

    private func absoluteOriginX(of node: Node) -> Float {
        // Frames are parent-local (set by `LayoutPass` from Yoga output). Walk
        // up the chain to compose the window-space origin x.
        var x: CGFloat = 0
        var cursor: Node? = node
        while let n = cursor {
            x += n.frame.origin.x
            cursor = n.parent
        }
        return Float(x)
    }

    // MARK: - Rendering

    private func render(node: Node, origin: CGPoint, list: DrawList) {
        guard let appearance = node.attachments[SliderHost.appearanceKey] as? SliderAppearance else {
            return
        }
        let frame = node.frame
        let width = Float(frame.width)
        let height = Float(frame.height)
        guard width > 0, height > 0 else { return }

        let originX = Float(origin.x)
        let originY = Float(origin.y)

        // Track centred vertically.
        let trackY = originY + (height - appearance.trackHeight) * 0.5
        let trackRect = UIRect(x: originX,
                               y: trackY,
                               width: width,
                               height: appearance.trackHeight)
        list.addRoundedRect(trackRect,
                            radius: appearance.trackCornerRadius,
                            color: appearance.trackColor)

        // Filled portion from the leading edge to the thumb centre.
        let v = clampedValue(value.wrappedValue)
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? Float((v - range.lowerBound) / span) : 0
        let thumbCentreX = originX + fraction * width

        let fillWidth = max(0, thumbCentreX - originX)
        if fillWidth > 0 {
            let fillRect = UIRect(x: originX,
                                  y: trackY,
                                  width: fillWidth,
                                  height: appearance.trackHeight)
            list.addRoundedRect(fillRect,
                                radius: appearance.trackCornerRadius,
                                color: appearance.fillColor)
        }

        // Thumb — clamp the centre so the circle stays inside the host frame
        // even at the extremes.
        let half = appearance.thumbDiameter * 0.5
        let clampedCentre = min(max(originX + half, thumbCentreX), originX + width - half)
        let thumbRect = UIRect(x: clampedCentre - half,
                               y: originY + (height - appearance.thumbDiameter) * 0.5,
                               width: appearance.thumbDiameter,
                               height: appearance.thumbDiameter)

        if let border = appearance.thumbBorderColor, appearance.thumbBorderWidth > 0 {
            // Outer ring rendered slightly larger; inner fill drawn on top.
            let bw = appearance.thumbBorderWidth
            let outerRect = UIRect(x: thumbRect.minX - bw,
                                   y: thumbRect.minY - bw,
                                   width: thumbRect.width + 2 * bw,
                                   height: thumbRect.height + 2 * bw)
            list.addRoundedRect(outerRect,
                                radius: outerRect.height * 0.5,
                                color: border)
        }
        list.addRoundedRect(thumbRect,
                            radius: appearance.thumbDiameter * 0.5,
                            color: appearance.thumbColor)
    }
}
