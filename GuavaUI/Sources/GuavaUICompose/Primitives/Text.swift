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
    public var defaultFont: Font
    public var fontResolver: TextFontResolver?

    public init(atlas: FontAtlas,
                shaper: TextShaper,
                atlasTextureID: TextureID,
                defaultLineHeight: Float,
                defaultColor: Color = .white,
                defaultFont: Font? = nil,
                fontResolver: TextFontResolver? = nil) {
        self.atlas = atlas
        self.shaper = shaper
        self.atlasTextureID = atlasTextureID
        self.defaultLineHeight = defaultLineHeight
        self.defaultColor = defaultColor
        let fallbackSize = atlas.fontSize > 0 ? atlas.fontSize : max(1, defaultLineHeight)
        self.defaultFont = defaultFont ?? Font.system(size: fallbackSize)
        self.fontResolver = fontResolver
    }

    public func resolvedFont(_ override: Font?) -> Font {
        override ?? defaultFont
    }

    public func resolvedLineHeight(font: Font, override: Float?) -> Float {
        if let override {
            return override
        }
        guard defaultFont.size > 0 else { return defaultLineHeight }
        return defaultLineHeight * (font.size / defaultFont.size)
    }

    public func shape(text: String, font: Font?) -> [ShapedGlyph] {
        let resolved = resolvedFont(font)
        if let fontResolver {
            let glyphs = fontResolver.shape(text: text, font: resolved)
            if !glyphs.isEmpty || text.isEmpty {
                return glyphs
            }
        }
        return shaper.shape(text: text)
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
            let fontOverride = node.attachments[StyleAttachmentKey.font] as? Font
            let lineHeightOverride = node.attachments[StyleAttachmentKey.lineHeight] as? Float
            let resolvedFont = env.resolvedFont(fontOverride)
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let result = snapshot.shape(in: env,
                                        maxWidth: Float(node.frame.width),
                                        font: resolvedFont,
                                        lineHeight: resolvedLineHeight)
            let baseColor = snapshot.color ?? node.foregroundColor ?? env.defaultColor
            let drawColor = baseColor.multipliedAlpha(node.opacity)
            list.addText(result,
                         origin: (Float(origin.x), Float(origin.y)),
                         color: drawColor,
                         textureID: env.atlasTextureID)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        let snapshot = self
        layout.setMeasureFunc { [weak layout] width, widthMode, _, _ in
            guard let env = TextEnvironmentHolder.current else {
                return CGSize(width: 0, height: 0)
            }
            let constraint: Float = (widthMode == .undefined) ? .infinity : width
            let fontOverride = layout?.attachments[StyleAttachmentKey.font] as? Font
            let lineHeightOverride = layout?.attachments[StyleAttachmentKey.lineHeight] as? Float
            let resolvedFont = env.resolvedFont(fontOverride)
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let result = snapshot.shape(in: env,
                                        maxWidth: constraint,
                                        font: resolvedFont,
                                        lineHeight: resolvedLineHeight)
            return CGSize(width: CGFloat(result.totalWidth),
                          height: CGFloat(result.totalHeight))
        }
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.markDirty()
    }

    private func shape(in env: TextEnvironment,
                       maxWidth: Float,
                       font: Font,
                       lineHeight: Float) -> TextLayoutResult {
        let glyphs = env.shape(text: string, font: font)
        return TextLayout.layout(
            shapedGlyphs: glyphs,
            text: string,
            atlas: env.atlas,
            maxWidth: maxWidth.isFinite && maxWidth > 0 ? maxWidth : .infinity,
            lineHeight: lineHeight,
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
