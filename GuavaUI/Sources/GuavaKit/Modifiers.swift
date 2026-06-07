// Chainable modifiers (`.frame`, `.background`, `.padding`).
//
// The legacy stack expressed these as deeply-nested generic types
// (`ModifiedContent<ModifiedContent<Box, A>, B>`) that were painful to read.
// Here a chain collapses into ONE `_ModifiedView` holding the base primitive
// plus a flat list of `NodeModifier`s — no nesting, applied to the node in order
// right after the base view's own `updateNode`.

public protocol NodeModifier {
    func apply(_ node: UINode)
}

public struct _ModifiedView: _PrimitiveView {
    let content: any _PrimitiveView
    let modifiers: [NodeModifier]

    init(wrapping view: any View, adding modifier: NodeModifier) {
        if let existing = view as? _ModifiedView {
            // Flatten: `.a().b()` → one view, modifiers [a, b].
            content = existing.content
            modifiers = existing.modifiers + [modifier]
        } else if let primitive = view as? any _PrimitiveView {
            content = primitive
            modifiers = [modifier]
        } else {
            // Modifying a composite view: wrap it in a passthrough node the
            // modifiers can target. (Primitives are the common, allocation-free
            // path above.)
            content = _Passthrough(view: view)
            modifiers = [modifier]
        }
    }

    public func makeNode() -> UINode { content.makeNode() }
    public func updateNode(_ node: UINode) {
        content.updateNode(node)
        for modifier in modifiers { modifier.apply(node) }
    }
    public var childViews: [any View] { content.childViews }
}

/// Transparent single-child container, used when a modifier targets a composite.
struct _Passthrough: _PrimitiveView {
    let view: any View
    func makeNode() -> UINode { UINode() }
    func updateNode(_ node: UINode) {}
    var childViews: [any View] { [view] }
}

public extension View {
    func frame(width: Float? = nil, height: Float? = nil) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _FrameModifier(width: width, height: height))
    }
    func background(_ color: Color) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _BackgroundModifier(color: color))
    }
    func padding(_ edges: Edges) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _PaddingModifier(edges: edges))
    }
    func padding(_ all: Float) -> _ModifiedView { padding(.all(all)) }
    func foregroundColor(_ color: Color) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _ForegroundColorModifier(color: color))
    }
    func fontSize(_ size: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _FontSizeModifier(size: size))
    }
    func opacity(_ value: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _OpacityModifier(opacity: value))
    }
    func cornerRadius(_ radius: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _CornerRadiusModifier(radius: radius))
    }
    func clipped() -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _ClippedModifier())
    }
}

struct _FrameModifier: NodeModifier {
    let width: Float?; let height: Float?
    func apply(_ node: UINode) {
        node.modifyLayout {
            if let width { $0.width = .points(width) }
            if let height { $0.height = .points(height) }
        }
    }
}
struct _BackgroundModifier: NodeModifier {
    let color: Color
    func apply(_ node: UINode) { node.modifyPaint { $0.background = color } }
}
struct _PaddingModifier: NodeModifier {
    let edges: Edges
    func apply(_ node: UINode) { node.modifyLayout { $0.padding = edges } }
}
struct _ForegroundColorModifier: NodeModifier {
    let color: Color
    func apply(_ node: UINode) { node.modifyTextColor(color) }
}
struct _FontSizeModifier: NodeModifier {
    let size: Float
    func apply(_ node: UINode) { node.modifyTextSize(size) }
}
struct _OpacityModifier: NodeModifier {
    let opacity: Float
    func apply(_ node: UINode) { node.modifyPaint { $0.opacity = opacity } }
}
struct _CornerRadiusModifier: NodeModifier {
    let radius: Float
    func apply(_ node: UINode) { node.modifyPaint { $0.cornerRadius = radius } }
}
struct _ClippedModifier: NodeModifier {
    func apply(_ node: UINode) { node.setClipsToBounds(true) }
}
