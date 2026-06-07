// Chainable modifiers (`.frame`, `.background`, `.padding`).
//
// The legacy stack expressed these as deeply-nested generic types
// (`ModifiedContent<ModifiedContent<Box, A>, B>`) that were painful to read.
// Here a chain collapses into ONE `_ModifiedView` holding the base primitive
// plus a flat list of `NodeModifier`s — no nesting, applied to the node in order
// right after the base view's own `updateNode`.

// MARK: - Core infrastructure

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

// MARK: - EdgeInsets

/// Per-edge lengths for padding (and later insets). Uses physical names
/// (top/left/bottom/right) to match the coordinate system.
public struct EdgeInsets: Equatable, Sendable {
    public var top: Float, left: Float, bottom: Float, right: Float
    public init(top: Float = 0, left: Float = 0, bottom: Float = 0, right: Float = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }
    public static func all(_ v: Float) -> EdgeInsets { EdgeInsets(top: v, left: v, bottom: v, right: v) }
    public static let zero = EdgeInsets()
    public var horizontal: Float { left + right }
    public var vertical: Float { top + bottom }
}

// MARK: - View extensions (alphabetical)

public extension View {
    func background(_ color: Color) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _BackgroundModifier(color: color))
    }
    func border(_ color: Color, width: Float = 1) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _BorderModifier(color: color, width: width))
    }
    func clipped() -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _ClippedModifier())
    }
    func cornerRadius(_ radius: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _CornerRadiusModifier(radius: radius))
    }
    func flex(_ grow: Float = 1, shrink: Float = 1) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _FlexModifier(grow: grow, shrink: shrink))
    }
    func fontSize(_ size: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _FontSizeModifier(size: size))
    }
    func foregroundColor(_ color: Color) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _ForegroundColorModifier(color: color))
    }
    func frame(width: Float? = nil, height: Float? = nil) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _FrameModifier(width: width, height: height))
    }
    func lineLimit(_ limit: Int?) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _LineLimitModifier(limit: limit))
    }
    func opacity(_ value: Float) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _OpacityModifier(opacity: value))
    }

    // -- padding -----------------------------------------------------------

    /// Uniform padding on all sides.
    func padding(_ all: Float) -> _ModifiedView { padding(Edges.all(all)) }

    /// Padding using the legacy `Edges` type (kept for source compat).
    func padding(_ edges: Edges) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _PaddingModifier(edges: edges))
    }

    /// Padding using `EdgeInsets`.
    func padding(_ insets: EdgeInsets) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _EdgeInsetsPaddingModifier(insets: insets))
    }

    /// Symmetric padding by axis.
    func padding(horizontal: Float = 0, vertical: Float = 0) -> _ModifiedView {
        padding(EdgeInsets(top: vertical, left: horizontal,
                           bottom: vertical, right: horizontal))
    }
}

// MARK: - Modifier implementations

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

struct _BorderModifier: NodeModifier {
    let color: Color; let width: Float
    func apply(_ node: UINode) {
        node.modifyPaint { $0.border = Border(color: color, width: width) }
    }
}

struct _PaddingModifier: NodeModifier {
    let edges: Edges
    func apply(_ node: UINode) { node.modifyLayout { $0.padding = edges } }
}

struct _EdgeInsetsPaddingModifier: NodeModifier {
    let insets: EdgeInsets
    func apply(_ node: UINode) {
        node.modifyLayout {
            $0.padding = Edges(top: insets.top, left: insets.left,
                               bottom: insets.bottom, right: insets.right)
        }
    }
}

struct _FlexModifier: NodeModifier {
    let grow: Float; let shrink: Float
    func apply(_ node: UINode) {
        node.modifyLayout { $0.flexGrow = grow; $0.flexShrink = shrink }
    }
}

struct _LineLimitModifier: NodeModifier {
    let limit: Int?
    func apply(_ node: UINode) { node.setTextLineLimit(limit) }
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

// MARK: - Semantic modifiers (resolve against UIContext.theme)

struct _SemanticBackgroundModifier: NodeModifier {
    let ref: SemanticColorRef
    func apply(_ node: UINode) {
        guard let theme = node.context?.theme else { return }
        node.modifyPaint { $0.background = ref.resolve(theme.colors) }
    }
}

struct _SemanticForegroundColorModifier: NodeModifier {
    let ref: SemanticColorRef
    func apply(_ node: UINode) {
        guard let theme = node.context?.theme else { return }
        let color = ref.resolve(theme.colors)
        node.modifyTextColor(color)
    }
}

struct _SemanticBorderModifier: NodeModifier {
    let ref: SemanticColorRef
    let width: Float
    func apply(_ node: UINode) {
        guard let theme = node.context?.theme else { return }
        node.modifyPaint { $0.border = Border(color: ref.resolve(theme.colors), width: width) }
    }
}

struct _SemanticFontModifier: NodeModifier {
    let ref: SemanticFontRef
    func apply(_ node: UINode) {
        guard let theme = node.context?.theme else { return }
        let token = ref.resolve(theme.typography)
        node.modifyTextSize(token.fontSize)
        node.setTextLineLimit(nil) // font slot resets any prior lineLimit
    }
}

// MARK: - Semantic View extensions

public extension View {
    func background(_ ref: SemanticColorRef) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _SemanticBackgroundModifier(ref: ref))
    }
    func foregroundColor(_ ref: SemanticColorRef) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _SemanticForegroundColorModifier(ref: ref))
    }
    func border(_ ref: SemanticColorRef, width: Float = 1) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _SemanticBorderModifier(ref: ref, width: width))
    }
    func font(_ ref: SemanticFontRef) -> _ModifiedView {
        _ModifiedView(wrapping: self, adding: _SemanticFontModifier(ref: ref))
    }
}
