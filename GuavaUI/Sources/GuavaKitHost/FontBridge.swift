import GuavaKit
import GuavaUIRuntime

/// Bridges the backend-agnostic `DisplayList.text` command into the full
/// GuavaUIRuntime text pipeline (shape → layout → rasterize → glyph quads).
///
/// Owns a `FontAtlas` and `TextShaper`; loads one font at one size. The bridge
/// is designed to be held by the renderer host and injected into
/// `DisplayListRenderer`. Multi-font / multi-size support is deferred to a
/// later integration step (following the same phased approach as the legacy
/// `TextEnvironment` → `FontProvider` layering).
public final class FontBridge {
    public let atlas: FontAtlas
    public let shaper: TextShaper

    /// Size the currently loaded font was opened at (points).
    public private(set) var loadedSize: Float = 0
    /// Raster scale for HiDPI (1 = standard, 2 = Retina, etc.).
    public private(set) var rasterScale: Float = 1

    public init(atlasWidth: Int = 1024, atlasHeight: Int = 1024) {
        atlas = FontAtlas(width: atlasWidth, height: atlasHeight)
        shaper = TextShaper()
    }

    // MARK: - Font loading

    /// Loads a font file at the given point size.
    ///
    /// When `rasterScale` > 1 the atlas bitmap is sized up so glyphs remain
    /// crisp on HiDPI displays.
    @discardableResult
    public func loadFont(path: String, size: Float, rasterScale: Float = 1) -> Bool {
        guard atlas.loadFont(path: path, size: size, rasterScale: rasterScale) else {
            return false
        }
        if let ftFace = atlas.freetypeFace {
            shaper.setFont(ftFace: ftFace, size: size, rasterScale: rasterScale)
        }
        loadedSize = size
        self.rasterScale = max(1, rasterScale)
        return true
    }

    // MARK: - Shaping

    /// Shapes a string into positioned glyphs using HarfBuzz.
    public func shape(text: String) -> [ShapedGlyph] {
        shaper.shape(text: text)
    }

    // MARK: - Layout

    /// Shapes and lays out text into lines.
    ///
    /// - Parameters:
    ///   - text: The input string.
    ///   - maxWidth: Maximum line width in pixels (`.infinity` = single line).
    ///   - alignment: Horizontal alignment within the line.
    /// - Returns: Laid-out glyphs with positions and atlas metadata.
    public func layout(
        text: String,
        maxWidth: Float = .infinity,
        alignment: TextAlignment = .leading
    ) -> TextLayoutResult {
        let glyphs = shape(text: text)
        let lineHeight = loadedSize > 0 ? loadedSize * 1.2 : 1
        return TextLayout.layout(
            shapedGlyphs: glyphs,
            text: text,
            atlas: atlas,
            maxWidth: maxWidth,
            lineHeight: lineHeight,
            alignment: alignment
        )
    }

    // MARK: - Measurement

    /// Pixel size of the laid-out text at the currently loaded font size.
    ///
    /// The `fontSize` parameter is accepted for `TextMeasuring` conformance but
    /// is ignored when the loaded size is already set. This matches the single-
    /// font assumption of the current bridge.
    public func measure(text: String, fontSize: Float = 0) -> Size {
        let size = fontSize > 0 ? fontSize : loadedSize
        guard size > 0, loadedSize > 0 else {
            // No font loaded; fall back to monospace approximation so the
            // layout system still produces reasonable frames.
            return Size(width: Float(text.count) * 14 * 0.5, height: 16)
        }
        let result = layout(text: text)
        return Size(width: result.totalWidth, height: result.totalHeight)
    }

    // MARK: - Render

    /// Renders a string into the draw list at the given origin, using the
    /// specified atlas texture ID. Glyphs are rasterized on demand (lazily, by
    /// the atlas) and quad UVs reference the atlas texture.
    public func render(
        text: String,
        maxWidth: Float = .infinity,
        color: RuntimeColor,
        origin: (x: Float, y: Float),
        textureID: TextureID,
        into draw: DrawList
    ) {
        let result = layout(text: text, maxWidth: maxWidth)
        draw.addText(
            result,
            origin: origin,
            color: color,
            textureID: textureID,
            atlas: atlas
        )
    }
}

// MARK: - TextMeasuring conformance

/// A `TextMeasuring` implementation backed by a real `FontBridge`.
///
/// Drop this into `UIContext.textMeasurer` to replace the default monospace
/// approximation with accurate font metrics from the shaping + layout pipeline.
public struct FontBridgeMeasurer: TextMeasuring {
    private let bridge: FontBridge

    public init(bridge: FontBridge) {
        self.bridge = bridge
    }

    public func measure(_ string: String, fontSize: Float) -> Size {
        bridge.measure(text: string, fontSize: fontSize)
    }
}
