/// Text alignment for multi-line layout.
public enum TextAlignment {
    case leading, center, trailing
}

/// A single line of laid-out text.
public struct TextLine {
    /// Shaped glyphs on this line with atlas info attached.
    public let glyphs: [PositionedGlyph]
    /// Baseline Y position relative to the text block origin.
    public let baselineY: Float
    /// Total width of this line.
    public let width: Float
}

/// A shaped glyph combined with its atlas UV and screen position.
public struct PositionedGlyph {
    public let glyphID: UInt32
    /// Position relative to the text block origin.
    public let x: Float
    public let y: Float
    /// Atlas info (nil if the glyph wasn't rasterized, e.g. space).
    public let atlasInfo: FontAtlas.GlyphInfo?
}

/// Result of text layout.
public struct TextLayoutResult {
    public let lines: [TextLine]
    public let totalWidth: Float
    public let totalHeight: Float
}

/// Performs multi-line text layout by combining shaping results with font atlas metrics.
///
/// Word-wraps at whitespace boundaries when `maxWidth` is exceeded.
public struct TextLayout {

    /// Lays out shaped glyphs into lines.
    ///
    /// - Parameters:
    ///   - shapedGlyphs: Output from `TextShaper.shape()`.
    ///   - text: Original source text (for whitespace detection).
    ///   - atlas: Font atlas to query glyph metrics from.
    ///   - maxWidth: Maximum line width in pixels (`Float.infinity` = single line).
    ///   - lineHeight: Line height in pixels.
    ///   - alignment: Horizontal alignment (default `.leading`).
    /// - Returns: Layout result with positioned glyphs.
    public static func layout(
        shapedGlyphs: [ShapedGlyph],
        text: String,
        atlas: FontAtlas,
        maxWidth: Float = .infinity,
        lineHeight: Float,
        alignment: TextAlignment = .leading
    ) -> TextLayoutResult {
        guard !shapedGlyphs.isEmpty else {
            return TextLayoutResult(lines: [], totalWidth: 0, totalHeight: 0)
        }

        let utf8 = Array(text.utf8)

        var lines: [TextLine] = []
        var currentLineGlyphs: [(ShapedGlyph, FontAtlas.GlyphInfo?)] = []
        var penX: Float = 0
        var lastBreakIndex: Int? = nil
        var penXAtLastBreak: Float = 0

        for (i, glyph) in shapedGlyphs.enumerated() {
            let info = atlas.rasterizeGlyph(glyphIndex: glyph.glyphID)

            // Is this a whitespace cluster? Check source text.
            let isSpace = Int(glyph.cluster) < utf8.count &&
                          (utf8[Int(glyph.cluster)] == UInt8(ascii: " ") ||
                           utf8[Int(glyph.cluster)] == UInt8(ascii: "\t"))

            if isSpace {
                lastBreakIndex = currentLineGlyphs.count
                penXAtLastBreak = penX
            }

            let nextPenX = penX + glyph.xAdvance

            // Line break needed?
            if nextPenX > maxWidth && !currentLineGlyphs.isEmpty {
                if let breakIdx = lastBreakIndex, breakIdx > 0 {
                    // Break at last whitespace
                    let lineGlyphs = Array(currentLineGlyphs.prefix(breakIdx))
                    let remaining = Array(currentLineGlyphs.suffix(from: breakIdx))

                    let line = buildLine(
                        glyphs: lineGlyphs,
                        baselineY: Float(lines.count) * lineHeight + lineHeight,
                        maxWidth: maxWidth,
                        alignment: alignment
                    )
                    lines.append(line)

                    // Re-layout remaining glyphs
                    currentLineGlyphs = remaining
                    penX = nextPenX - penXAtLastBreak
                    lastBreakIndex = nil
                } else {
                    // No break point; force break here
                    let line = buildLine(
                        glyphs: currentLineGlyphs,
                        baselineY: Float(lines.count) * lineHeight + lineHeight,
                        maxWidth: maxWidth,
                        alignment: alignment
                    )
                    lines.append(line)
                    currentLineGlyphs = []
                    penX = 0
                    lastBreakIndex = nil
                }
            }

            currentLineGlyphs.append((glyph, info))
            penX = nextPenX
        }

        // Flush remaining glyphs
        if !currentLineGlyphs.isEmpty {
            let line = buildLine(
                glyphs: currentLineGlyphs,
                baselineY: Float(lines.count) * lineHeight + lineHeight,
                maxWidth: maxWidth,
                alignment: alignment
            )
            lines.append(line)
        }

        let totalWidth = lines.map(\.width).max() ?? 0
        let totalHeight = Float(lines.count) * lineHeight

        return TextLayoutResult(lines: lines, totalWidth: totalWidth, totalHeight: totalHeight)
    }

    // MARK: - Internal

    private static func buildLine(
        glyphs: [(ShapedGlyph, FontAtlas.GlyphInfo?)],
        baselineY: Float,
        maxWidth: Float,
        alignment: TextAlignment
    ) -> TextLine {
        var positioned: [PositionedGlyph] = []
        positioned.reserveCapacity(glyphs.count)

        var penX: Float = 0
        var lineWidth: Float = 0

        for (shaped, info) in glyphs {
            positioned.append(PositionedGlyph(
                glyphID: shaped.glyphID,
                x: penX + shaped.xOffset,
                y: baselineY + shaped.yOffset,
                atlasInfo: info
            ))
            penX += shaped.xAdvance
            lineWidth = penX
        }

        // Apply alignment offset
        let offset: Float
        switch alignment {
        case .leading: offset = 0
        case .center:  offset = (maxWidth - lineWidth) / 2
        case .trailing: offset = maxWidth - lineWidth
        }

        if offset != 0 && offset.isFinite {
            positioned = positioned.map { g in
                PositionedGlyph(
                    glyphID: g.glyphID,
                    x: g.x + offset,
                    y: g.y,
                    atlasInfo: g.atlasInfo
                )
            }
        }

        return TextLine(glyphs: positioned, baselineY: baselineY, width: lineWidth)
    }
}
