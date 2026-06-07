// A minimal primitive set, enough to build and test real declarative trees.
// The full component library (Text/Button/Popover/...) is Stage 6; these prove
// the declarative→retained pipeline end to end.

/// A leaf box with an optional fixed size and background colour.
public struct Element: _PrimitiveView {
    public var width: Float?
    public var height: Float?
    public var color: Color?
    public init(width: Float? = nil, height: Float? = nil, color: Color? = nil) {
        self.width = width; self.height = height; self.color = color
    }
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.modifyLayout {
            $0.width = width.map { .points($0) } ?? .auto
            $0.height = height.map { .points($0) } ?? .auto
        }
        node.setPaint(Paint(background: color))
    }
}

/// A run of text. Measured with a simple monospace approximation for now
/// (8×16 per glyph); a real font-metrics bridge replaces the measurement later
/// without touching anything else (it only feeds `setIntrinsicSize`).
public struct Text: _PrimitiveView {
    public var string: String
    public var color: Color
    public init(_ string: String, color: Color = Color(r: 0, g: 0, b: 0)) {
        self.string = string
        self.color = color
    }
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.setText(string, color: color)
        node.setIntrinsicSize(Size(width: Float(string.count) * 8, height: 16))
    }
}

/// A pressable control. Captures the pointer on press (scoped capture from
/// Stage 3) and fires `action` on release over the button.
public struct Button<Label: View>: _PrimitiveView {
    let action: () -> Void
    let label: Label
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        let action = self.action
        node.interaction.onPointer = { [weak node] event, phase, ctx in
            guard let node, phase == .target else { return .ignored }
            switch event.action {
            case .down:
                ctx.pointerCapture.acquire(node)
                return .handled
            case .up:
                guard ctx.pointerCapture.target === node else { return .ignored }
                ctx.pointerCapture.release()
                action()
                return .handled
            case .move:
                return .ignored
            }
        }
    }
    public var childViews: [any View] { [label] }
}

/// A flexbox container that lays its children out along an axis.
public struct Stack<Content: View>: _PrimitiveView {
    public var direction: Axis
    public var spacing: Float
    private let content: Content
    public init(_ direction: Axis = .column, spacing: Float = 0, @ViewBuilder content: () -> Content) {
        self.direction = direction
        self.spacing = spacing
        self.content = content()
    }
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.modifyLayout { $0.direction = direction; $0.spacing = spacing }
    }
    public var childViews: [any View] { [content] }
}
