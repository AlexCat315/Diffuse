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
