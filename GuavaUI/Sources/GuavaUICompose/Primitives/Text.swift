import Foundation
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
    let shapeCache: SharedTextShapeCache
    let layoutCache: SharedTextLayoutCache

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
        self.shapeCache = SharedTextShapeCache()
        self.layoutCache = SharedTextLayoutCache()
    }

    public static func bootstrapped(atlasTextureID: TextureID,
                                    primaryFontName: String,
                                    defaultFont: Font = .system(size: 18),
                                    defaultLineHeight: Float = 22,
                                    defaultColor: Color = .white,
                                    rasterScale: Float = 1,
                                    atlasEdge: Int? = nil) -> TextEnvironment {
        let scale = max(1, rasterScale)
        let resolvedAtlasEdge = atlasEdge ?? max(1024, Int((1024 * scale).rounded(.up)))
        let atlas = FontAtlas(width: resolvedAtlasEdge, height: resolvedAtlasEdge)
        let shaper = TextShaper()
        let resolver = TextFontResolver(primaryFontName: primaryFontName,
                                        atlas: atlas,
                                        rasterScale: scale)

        if let primaryFont = resolver.preparePrimaryFont(defaultFont) {
            shaper.setFont(ftFace: primaryFont.rawFace,
                           size: defaultFont.size,
                           rasterScale: scale)
        }

        return TextEnvironment(
            atlas: atlas,
            shaper: shaper,
            atlasTextureID: atlasTextureID,
            defaultLineHeight: defaultLineHeight,
            defaultColor: defaultColor,
            defaultFont: defaultFont,
            fontResolver: resolver
        )
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
        return shapeCache.value(text: text, font: resolved) {
            if let fontResolver {
                let glyphs = fontResolver.shape(text: text, font: resolved)
                if !glyphs.isEmpty || text.isEmpty {
                    return glyphs
                }
            }
            return shaper.shape(text: text)
        }
    }

    public func cachedLayout(text: String,
                             font: Font? = nil,
                             lineHeight: Float? = nil,
                             maxWidth: Float = .infinity,
                             alignment: TextAlignment = .leading) -> TextLayoutResult {
        let resolvedFont = resolvedFont(font)
        let resolvedLineHeight = resolvedLineHeight(font: resolvedFont, override: lineHeight)
        let normalizedMaxWidth: Float = (maxWidth.isFinite && maxWidth > 0) ? maxWidth : .infinity
        let key = SharedTextLayoutCache.Key(
            text: text,
            font: resolvedFont,
            lineHeight: resolvedLineHeight,
            alignment: alignment,
            maxWidth: normalizedMaxWidth
        )
        return layoutCache.value(for: key) {
            let glyphs = shape(text: text, font: resolvedFont)
            return TextLayout.layout(
                shapedGlyphs: glyphs,
                text: text,
                atlas: atlas,
                maxWidth: normalizedMaxWidth,
                lineHeight: resolvedLineHeight,
                alignment: alignment
            )
        }
    }

    public func prewarmGlyphs(text: String, fonts: [Font]) {
        for font in Set(fonts) {
            prewarmGlyphs(text: text, font: font)
        }
    }

    public func prewarmGlyphs(text: String, font: Font? = nil) {
        let glyphs = shape(text: text, font: font)
        for glyph in glyphs {
            _ = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID, fontID: glyph.fontID)
        }
    }
}

final class SharedTextShapeCache {
    struct Key: Hashable {
        let text: String
        let font: Font
    }

    private let lock = NSLock()
    private var table: [Key: [ShapedGlyph]] = [:]

    func value(text: String, font: Font, build: () -> [ShapedGlyph]) -> [ShapedGlyph] {
        let key = Key(text: text, font: font)
        if let cached = lock.withLock({ table[key] }) {
            return cached
        }
        let result = build()
        return lock.withLock {
            if let cached = table[key] {
                return cached
            }
            table[key] = result
            return result
        }
    }
}

final class SharedTextLayoutCache {
    struct Key: Hashable {
        let text: String
        let font: Font
        let lineHeight: Float
        let alignment: TextAlignment
        let maxWidth: Float
    }

    private let lock = NSLock()
    private var table: [Key: TextLayoutResult] = [:]

    func value(for key: Key, build: () -> TextLayoutResult) -> TextLayoutResult {
        if let cached = lock.withLock({ table[key] }) {
            return cached
        }
        let result = build()
        return lock.withLock {
            if let cached = table[key] {
                return cached
            }
            table[key] = result
            return result
        }
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
    public let lineLimit: Int?

    public init(_ string: String,
                alignment: TextAlignment = .leading,
                color: Color? = nil,
                lineLimit: Int? = nil) {
        self.string = string
        self.alignment = alignment
        self.color = color
        self.lineLimit = lineLimit
    }

    public init(_ key: LocalizedStringKey,
                alignment: TextAlignment = .leading,
                color: Color? = nil,
                lineLimit: Int? = nil) {
        self.init(key.resolved, alignment: alignment, color: color, lineLimit: lineLimit)
    }

    public func lineLimit(_ limit: Int?) -> Text {
        Text(string, alignment: alignment, color: color, lineLimit: limit)
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
                layout: node.layoutNode,
                text: snapshot.string,
                font: resolvedFont,
                lineHeight: resolvedLineHeight,
                maxWidth: snapshot.resolvedMaxWidth(Float(node.frame.width)),
                alignment: snapshot.alignment
            )
            let baseColor = snapshot.color ?? node.foregroundColor ?? env.defaultColor
            let drawColor = baseColor.multipliedAlpha(node.opacity)
            list.addText(result,
                         origin: (Float(origin.x), Float(origin.y)),
                         color: drawColor,
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        Text.installMeasureFunc(on: layout, snapshot: self)
        layout.textInputs = TextMeasureInputs(
            text: string,
            alignment: alignment,
            lineLimit: lineLimit
        )
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        Text.installMeasureFunc(on: layout, snapshot: self)
        let next = TextMeasureInputs(text: string,
                                     alignment: alignment,
                                     lineLimit: lineLimit)
        let previous = layout.textInputs
        layout.textInputs = next
        if previous != nil, previous != next {
            layout.markDirty()
        }
    }

    // MARK: - Layout cache

    static func installMeasureFunc(on layout: LayoutNode, snapshot: Text) {
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
                layout: layout,
                text: snapshot.string,
                font: resolvedFont,
                lineHeight: resolvedLineHeight,
                maxWidth: snapshot.resolvedMaxWidth(constraint),
                alignment: snapshot.alignment
            )
            return CGSize(width: CGFloat(result.totalWidth),
                          height: CGFloat(result.totalHeight))
        }
    }

    /// Shape + layout cache. Phase 6: per-`LayoutNode` cache lives directly
    /// on `LayoutNode.textMeasure` (a typed stored property in Runtime).
    /// Falls through to the process-wide cache on `TextEnvironment` when no
    /// LayoutNode is supplied (unit tests without a host).
    static func cachedLayout(
        env: TextEnvironment,
        layout: LayoutNode?,
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
        if let layout, let cached = layout.textMeasure, cached.key == key {
            return cached.result
        }
        let result = env.cachedLayout(
            text: text,
            font: font,
            lineHeight: lineHeight,
            maxWidth: normalizedMaxWidth,
            alignment: alignment
        )
        if let layout {
            layout.textMeasure = TextLayoutCacheEntry(key: key, result: result)
        }
        return result
    }

    private func resolvedMaxWidth(_ maxWidth: Float) -> Float {
        guard let lineLimit, lineLimit == 1 else {
            return maxWidth
        }
        return .infinity
    }
}

// Phase 6: TextLayoutCacheKey / TextLayoutCacheEntry / TextMeasureInputs
// moved to GuavaUIRuntime (`Text/TextMeasureSlot.swift`) so the typed
// measure slot can live on `LayoutNode` directly.

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
        node.animatableSet(\.backgroundColor, to: color ?? node.theme.colors.divider)
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
