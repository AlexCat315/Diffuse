import CoreGraphics
import GuavaUIRuntime

/// Process-wide text rendering context. The Compose layer asks the host to
/// install a `TextEnvironment` once at startup; primitives (`Text`) read from
/// it during materialisation. Decoupled so the runtime tests do not need a
/// real FreeType font loaded.
public struct TextEnvironment {
    public let atlas: FontAtlas
    public let shaper: TextShaper
    public let atlasTextureID: TextureID
    public var defaultLineHeight: Float
    public var defaultColor: Color

    public init(atlas: FontAtlas,
                shaper: TextShaper,
                atlasTextureID: TextureID,
                defaultLineHeight: Float,
                defaultColor: Color = .white) {
        self.atlas = atlas
        self.shaper = shaper
        self.atlasTextureID = atlasTextureID
        self.defaultLineHeight = defaultLineHeight
        self.defaultColor = defaultColor
    }
}

/// Holder so views can reach the environment without threading it through every
/// builder. Set by `SDL3PlatformHost` (or any other shell) before the first
/// `materialise` call.
public enum TextEnvironmentHolder {
    nonisolated(unsafe) public static var current: TextEnvironment?
}

/// Static text primitive. Participates in flexbox layout via Yoga's measure
/// callback so a label sized by its parent will wrap; an unconstrained label
/// reports its natural single-line width.
public struct Text: _PrimitiveView {
    public let string: String
    public let alignment: TextAlignment
    public let color: Color?

    public init(_ string: String,
                alignment: TextAlignment = .leading,
                color: Color? = nil) {
        self.string = string
        self.alignment = alignment
        self.color = color
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    public func _updateNode(_ node: Node) {
        // Bind the draw callback. Captures `string` etc by value.
        let snapshot = self
        let env = TextEnvironmentHolder.current
        node.draw = { list, origin in
            guard let env else { return }
            let result = snapshot.shape(in: env, maxWidth: Float(node.frame.width))
            let drawColor = snapshot.color ?? node.foregroundColor ?? env.defaultColor
            list.addText(result,
                         origin: (Float(origin.x), Float(origin.y)),
                         color: drawColor,
                         textureID: env.atlasTextureID)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        let snapshot = self
        layout.setMeasureFunc { width, widthMode, _, _ in
            guard let env = TextEnvironmentHolder.current else {
                return CGSize(width: 0, height: 0)
            }
            let constraint: Float = (widthMode == .undefined) ? .infinity : width
            let result = snapshot.shape(in: env, maxWidth: constraint)
            return CGSize(width: CGFloat(result.totalWidth),
                          height: CGFloat(result.totalHeight))
        }
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.markDirty()
    }

    private func shape(in env: TextEnvironment, maxWidth: Float) -> TextLayoutResult {
        let glyphs = env.shaper.shape(text: string)
        return TextLayout.layout(
            shapedGlyphs: glyphs,
            text: string,
            atlas: env.atlas,
            maxWidth: maxWidth.isFinite && maxWidth > 0 ? maxWidth : .infinity,
            lineHeight: env.defaultLineHeight,
            alignment: alignment
        )
    }
}

/// Thin one-pixel separator. Renders as a coloured rect; defaults to a flexible
/// horizontal line when placed in a Column.
public struct Divider: _PrimitiveView {
    public let color: Color
    public let thickness: Float
    public let axis: Axis

    public enum Axis { case horizontal, vertical }

    public init(color: Color = Color(r: 0.7, g: 0.7, b: 0.7),
                thickness: Float = 1,
                axis: Axis = .horizontal) {
        self.color = color
        self.thickness = thickness
        self.axis = axis
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    public func _updateNode(_ node: Node) {
        node.backgroundColor = color
    }

    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateLayout(_ layout: LayoutNode) {
        switch axis {
        case .horizontal:
            layout.height = thickness
            layout.setWidthPercent(100)
        case .vertical:
            layout.width = thickness
            layout.setHeightPercent(100)
        }
    }
}
