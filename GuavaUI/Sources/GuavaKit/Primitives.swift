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
    public var fontSize: Float
    public init(_ string: String, color: Color = Color(r: 0, g: 0, b: 0), fontSize: Float = 16) {
        self.string = string
        self.color = color
        self.fontSize = fontSize
    }
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.setText(string, color: color, size: fontSize)
        let measurer = node.context?.textMeasurer ?? ApproxTextMeasurer()
        node.setIntrinsicSize(measurer.measure(string, fontSize: fontSize))
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

// MARK: - Spacer

/// Fills available space along the flex direction. Has zero intrinsic size;
/// flexGrow = 1 means it consumes leftover space after fixed-size siblings.
public struct Spacer: _PrimitiveView {
    public init() {}
    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.modifyLayout { $0.flexGrow = 1 }
    }
}

// MARK: - Divider

/// A thin visual separator. Renders as a filled rect; defaults to a flexible
/// horizontal line when placed in a `Column`, or a vertical line in a `Row`.
public struct Divider: _PrimitiveView {
    public var color: Color
    public var thickness: Float

    public init(color: Color = Color(r: 0.3, g: 0.3, b: 0.3), thickness: Float = 1) {
        self.color = color
        self.thickness = max(1, thickness)
    }

    public func makeNode() -> UINode { UINode() }
    public func updateNode(_ node: UINode) {
        node.setPaint(Paint(background: color))
        node.modifyLayout {
            $0.height = .points(thickness)
            $0.flexGrow = 0
        }
    }
}

// MARK: - ScrollView

/// A scrollable container. Clips overflowing content and updates `contentOffset`
/// in response to wheel events. The parent must constrain the ScrollView's size
/// (via `.frame()` or a fixed container); the content is laid out naturally and
/// scrolls when it overflows the viewport.
///
/// Direction `.column` scrolls vertically; `.row` scrolls horizontally.
public struct ScrollView<Content: View>: _PrimitiveView {
    public var direction: Axis
    private let content: Content

    public init(_ direction: Axis = .column, @ViewBuilder content: () -> Content) {
        self.direction = direction
        self.content = content()
    }

    public func makeNode() -> UINode { UINode() }

    public func updateNode(_ node: UINode) {
        node.setClipsToBounds(true)
        node.interaction.onWheel = { [weak node] event in
            guard let node else { return .ignored }
            var offset = node.geometry.contentOffset
            switch node.layoutStyle.direction {
            case .column:
                offset.y += event.deltaY
            case .row:
                offset.x += event.deltaX
            }
            // Clamp to prevent scrolling past content bounds.
            // (Content size tracking is a future refinement.)
            if offset.y < 0 { offset.y = 0 }
            if offset.x < 0 { offset.x = 0 }
            node.setContentOffset(offset)
            return .handled
        }
    }

    public var childViews: [any View] { [content] }
}

// Convenience aliases.
public struct VScroll<Content: View>: _PrimitiveView {
    private let inner: ScrollView<Content>
    public init(@ViewBuilder content: () -> Content) {
        inner = ScrollView(.column, content: content)
    }
    public func makeNode() -> UINode { inner.makeNode() }
    public func updateNode(_ node: UINode) { inner.updateNode(node) }
    public var childViews: [any View] { inner.childViews }
}

public struct HScroll<Content: View>: _PrimitiveView {
    private let inner: ScrollView<Content>
    public init(@ViewBuilder content: () -> Content) {
        inner = ScrollView(.row, content: content)
    }
    public func makeNode() -> UINode { inner.makeNode() }
    public func updateNode(_ node: UINode) { inner.updateNode(node) }
    public var childViews: [any View] { inner.childViews }
}
