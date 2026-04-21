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
        node.draw = { list, origin in
            guard let env = TextEnvironmentHolder.current else { return }
            let fontOverride = node.attachments[StyleAttachmentKey.font] as? Font
            let lineHeightOverride = node.attachments[StyleAttachmentKey.lineHeight] as? Float
            let resolvedFont = env.resolvedFont(fontOverride)
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let result = Text.cachedLayout(
                env: env,
                attachments: { node.attachments[Text.drawCacheKey] },
                store: { node.attachments[Text.drawCacheKey] = $0 },
                text: snapshot.string,
                font: resolvedFont,
                lineHeight: resolvedLineHeight,
                maxWidth: Float(node.frame.width),
                alignment: snapshot.alignment
            )
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
            let result = Text.cachedLayout(
                env: env,
                attachments: { layout?.attachments[Text.measureCacheKey] },
                store: { layout?.attachments[Text.measureCacheKey] = $0 },
                text: snapshot.string,
                font: resolvedFont,
                lineHeight: resolvedLineHeight,
                maxWidth: constraint,
                alignment: snapshot.alignment
            )
            return CGSize(width: CGFloat(result.totalWidth),
                          height: CGFloat(result.totalHeight))
        }
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.markDirty()
    }

    // MARK: - Layout cache

    static let drawCacheKey = "__text_draw_cache"
    static let measureCacheKey = "__text_measure_cache"

    /// Shape + layout cache. The closure-based `attachments` / `store`
    /// accessors keep this helper agnostic to whether the entry lives on a
    /// `Node` (draw path) or `LayoutNode` (measure path).
    static func cachedLayout(
        env: TextEnvironment,
        attachments: () -> Any?,
        store: (Any) -> Void,
        text: String,
        font: Font,
        lineHeight: Float,
        maxWidth: Float,
        alignment: TextAlignment
    ) -> TextLayoutResult {
        let normalizedMaxWidth: Float = (maxWidth.isFinite && maxWidth > 0) ? maxWidth : .infinity
        let key = TextLayoutCacheKey(
            text: text,
            font: font,
            lineHeight: lineHeight,
            alignment: alignment,
            maxWidth: normalizedMaxWidth,
            atlasID: ObjectIdentifier(env.atlas)
        )
        if let cached = attachments() as? TextLayoutCacheEntry, cached.key == key {
            return cached.result
        }
        let glyphs = env.shape(text: text, font: font)
        let result = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: text,
            atlas: env.atlas,
            maxWidth: normalizedMaxWidth,
            lineHeight: lineHeight,
            alignment: alignment
        )
        store(TextLayoutCacheEntry(key: key, result: result))
        return result
    }
}

/// Cache key for the shaped + laid-out form of a `Text`. Equality covers
/// every input that can change the resulting `TextLayoutResult`.
struct TextLayoutCacheKey: Hashable {
    let text: String
    let font: Font
    let lineHeight: Float
    let alignment: TextAlignment
    let maxWidth: Float
    let atlasID: ObjectIdentifier
}

struct TextLayoutCacheEntry {
    let key: TextLayoutCacheKey
    let result: TextLayoutResult
}

/// Thin one-pixel separator. Renders as a coloured rect; defaults to a flexible
/// horizontal line when placed in a Column. When `color` is omitted, the
/// divider resolves `theme.colors.divider` from the active theme so themed
/// scopes paint a coherent rule colour without any plumbing at the call site.
public struct Divider: _PrimitiveView {
    public let color: Color?
    public let thickness: Float
    public let axis: Axis

    public enum Axis { case horizontal, vertical }

    public init(color: Color? = nil,
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
        node.backgroundColor = color ?? node.theme.colors.divider
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
