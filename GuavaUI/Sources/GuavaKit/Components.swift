// Higher-level components built on top of the primitive set.

// MARK: - Image

/// A placeholder image rendered as a filled rect with an optional tint.
/// Real texture sampling is deferred to a later integration step.
public struct Image: _PrimitiveView {
    public var width: Float
    public var height: Float
    public var tint: Color?

    public init(width: Float, height: Float, tint: Color? = nil) {
        self.width = width; self.height = height; self.tint = tint
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.setPaint(Paint(background: tint ?? Color(r: 0.2, g: 0.2, b: 0.25)))
        node.modifyLayout {
            $0.width = .points(width)
            $0.height = .points(height)
        }
    }
}

// MARK: - Toggle

public struct Toggle: _PrimitiveView {
    private let isOn: Bool
    private let onChange: (Bool) -> Void

    public init(isOn: Bool = false, onChange: @escaping (Bool) -> Void = { _ in }) {
        self.isOn = isOn; self.onChange = onChange
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        let on = isOn
        let onChange = self.onChange
        let trackColor = on ? Color(r: 0.3, g: 0.6, b: 1) : Color(r: 0.25, g: 0.25, b: 0.3)
        node.setPaint(Paint(background: trackColor, cornerRadius: 10))
        node.modifyLayout { $0.width = .points(40); $0.height = .points(22) }
        node.interaction.onPointer = { [weak node] event, phase, ctx in
            guard let node, phase == .target else { return .ignored }
            if event.action == .down { ctx.pointerCapture.acquire(node); return .handled }
            if event.action == .up, ctx.pointerCapture.target === node {
                ctx.pointerCapture.release()
                onChange(!on)
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - Checkbox

public struct Checkbox<Label: View>: _PrimitiveView {
    private let isChecked: Bool
    private let onChange: (Bool) -> Void
    private let label: Label

    public init(isChecked: Bool = false, onChange: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder label: () -> Label) {
        self.isChecked = isChecked; self.onChange = onChange; self.label = label()
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        let checked = isChecked
        let onChange = self.onChange
        node.interaction.onPointer = { [weak node] event, phase, ctx in
            guard let node, phase == .target else { return .ignored }
            if event.action == .down { ctx.pointerCapture.acquire(node); return .handled }
            if event.action == .up, ctx.pointerCapture.target === node {
                ctx.pointerCapture.release()
                onChange(!checked)
                return .handled
            }
            return .ignored
        }
        node.modifyLayout { $0.direction = .row; $0.spacing = 8; $0.alignItems = .center }
    }
    public var childViews: [any View] {
        [
            Element(width: 18, height: 18,
                    color: isChecked ? Color(r: 0.3, g: 0.6, b: 1) : Color(r: 0.15, g: 0.15, b: 0.2))
                .cornerRadius(3),
            AnyView(label),
        ]
    }
}

// MARK: - Slider

public struct Slider: _PrimitiveView {
    private let value: Float
    private let range: ClosedRange<Float>
    private let onChange: (Float) -> Void

    public init(value: Float = 0, in range: ClosedRange<Float> = 0...1,
                onChange: @escaping (Float) -> Void = { _ in }) {
        self.value = value; self.range = range; self.onChange = onChange
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        let range = self.range
        let onChange = self.onChange
        node.setPaint(Paint(background: Color(r: 0.15, g: 0.15, b: 0.2), cornerRadius: 3))
        node.modifyLayout { $0.height = .points(20) }
        node.interaction.onPointer = { [weak node] event, phase, ctx in
            guard let node, phase == .target else { return .ignored }
            switch event.action {
            case .down: ctx.pointerCapture.acquire(node); fallthrough
            case .move:
                guard ctx.pointerCapture.target === node else { return .ignored }
                let w = node.geometry.frame.size.width
                guard w > 0 else { return .ignored }
                let localX = event.position.x - node.geometry.frame.minX
                let t = max(0, min(1, localX / w))
                onChange(range.lowerBound + t * (range.upperBound - range.lowerBound))
                return .handled
            case .up: ctx.pointerCapture.release(); return .handled
            }
        }
    }
}

// MARK: - TextField

public struct TextField: _PrimitiveView {
    private let text: String
    private let placeholder: String

    public init(text: String = "", placeholder: String = "") {
        self.text = text; self.placeholder = placeholder
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        let display = text.isEmpty ? placeholder : text
        let displayColor = text.isEmpty ? Color(r: 0.4, g: 0.4, b: 0.45) : Color(r: 1, g: 1, b: 1)
        node.setText(display, color: displayColor, size: 13)
        let measurer = node.context?.textMeasurer ?? ApproxTextMeasurer()
        node.setIntrinsicSize(measurer.measure(display, fontSize: 13))
        node.setPaint(Paint(
            background: Color(r: 0.1, g: 0.1, b: 0.15),
            border: Border(color: Color(r: 0.25, g: 0.25, b: 0.3), width: 1),
            cornerRadius: 4
        ))
        node.modifyLayout {
            $0.padding = Edges(top: 6, left: 8, bottom: 6, right: 8)
        }
    }
}
