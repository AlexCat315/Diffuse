/// Text alignment for multi-line layout.
public enum TextAlignment {
    case leading, center, trailing
}

/// A single line of laid-out text.
public struct TextLine {
    /// Shaped glyphs on this line with lazily-resolved atlas info.
    public let glyphs: [PositionedGlyph]
    /// Baseline Y position relative to the text block origin.
    public let baselineY: Float
    /// Total width of this line.
    public let width: Float
    /// UTF-8 byte offset of the first character shown on this line.
    public let startCluster: UInt32
    /// UTF-8 byte offset of the first character not shown on this line.
    public let endCluster: UInt32
}

/// A shaped glyph combined with its atlas UV and screen position.
public struct PositionedGlyph {
    public let glyphID: UInt32
    public let fontID: Int
    public let cluster: UInt32
    /// Position relative to the text block origin.
    public let x: Float
    public let y: Float
    /// Atlas info when the glyph was already rasterized before draw.
    public let atlasInfo: FontAtlas.GlyphInfo?
}

/// Result of text layout.
public struct TextLayoutResult {
    public let lines: [TextLine]
    public let totalWidth: Float
    public let totalHeight: Float

    public init(lines: [TextLine], totalWidth: Float, totalHeight: Float) {
        self.lines = lines
        self.totalWidth = totalWidth
        self.totalHeight = totalHeight
    }
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
        var currentLineGlyphs: [(ShapedGlyph, FontAtlas.GlyphMetrics?)] = []
        var currentLineStartCluster: UInt32 = 0
        var penX: Float = 0
        var lastBreakIndex: Int? = nil
        var penXAtLastBreak: Float = 0

        for (_, glyph) in shapedGlyphs.enumerated() {
            let clusterByte: UInt8 = Int(glyph.cluster) < utf8.count
                ? utf8[Int(glyph.cluster)] : 0

            // Explicit newline → flush current line immediately, skip glyph.
            let isNewline = clusterByte == UInt8(ascii: "\n") || clusterByte == UInt8(ascii: "\r")
            if isNewline {
                let baselineY = centeredBaselineY(
                    glyphs: currentLineGlyphs,
                    atlas: atlas,
                    lineTop: Float(lines.count) * lineHeight,
                    lineHeight: lineHeight
                )
                let line = buildLine(
                    glyphs: currentLineGlyphs,
                    baselineY: baselineY,
                    startCluster: currentLineStartCluster,
                    endCluster: glyph.cluster,
                    maxWidth: maxWidth,
                    alignment: alignment
                )
                lines.append(line)
                currentLineGlyphs = []
                currentLineStartCluster = glyph.cluster + 1
                penX = 0
                lastBreakIndex = nil
                penXAtLastBreak = 0
                continue
            }

            let metrics = atlas.glyphMetrics(glyphIndex: glyph.glyphID, fontID: glyph.fontID)

            // Is this a whitespace cluster? Check source text.
            let isSpace = clusterByte == UInt8(ascii: " ") || clusterByte == UInt8(ascii: "\t")

            if isSpace {
                lastBreakIndex = currentLineGlyphs.count
                penXAtLastBreak = penX
            }

            var nextPenX = penX + glyph.xAdvance

            // Line break needed?
            if nextPenX > maxWidth && !currentLineGlyphs.isEmpty {
                if let breakIdx = lastBreakIndex, breakIdx > 0 {
                    // Break at last whitespace
                    let lineGlyphs = Array(currentLineGlyphs.prefix(breakIdx))
                    let remaining = Array(currentLineGlyphs.suffix(from: breakIdx))
                    let nextLineStartCluster = remaining.first?.0.cluster ?? glyph.cluster
                    let baselineY = centeredBaselineY(
                        glyphs: lineGlyphs,
                        atlas: atlas,
                        lineTop: Float(lines.count) * lineHeight,
                        lineHeight: lineHeight
                    )

                    let line = buildLine(
                        glyphs: lineGlyphs,
                        baselineY: baselineY,
                        startCluster: currentLineStartCluster,
                        endCluster: nextLineStartCluster,
                        maxWidth: maxWidth,
                        alignment: alignment
                    )
                    lines.append(line)

                    // Re-layout remaining glyphs
                    currentLineGlyphs = remaining
                    currentLineStartCluster = nextLineStartCluster
                    penX = nextPenX - penXAtLastBreak
                    nextPenX = penX
                    lastBreakIndex = nil
                } else {
                    // No break point; force break here
                    let nextLineStartCluster = glyph.cluster
                    let baselineY = centeredBaselineY(
                        glyphs: currentLineGlyphs,
                        atlas: atlas,
                        lineTop: Float(lines.count) * lineHeight,
                        lineHeight: lineHeight
                    )
                    let line = buildLine(
                        glyphs: currentLineGlyphs,
                        baselineY: baselineY,
                        startCluster: currentLineStartCluster,
                        endCluster: nextLineStartCluster,
                        maxWidth: maxWidth,
                        alignment: alignment
                    )
                    lines.append(line)
                    currentLineGlyphs = []
                    currentLineStartCluster = nextLineStartCluster
                    penX = 0
                    nextPenX = glyph.xAdvance
                    lastBreakIndex = nil
                }
            }

            if currentLineGlyphs.isEmpty {
                currentLineStartCluster = glyph.cluster
            }
            currentLineGlyphs.append((glyph, metrics))
            penX = nextPenX
        }

        // Flush remaining glyphs
        if !currentLineGlyphs.isEmpty {
            let baselineY = centeredBaselineY(
                glyphs: currentLineGlyphs,
                atlas: atlas,
                lineTop: Float(lines.count) * lineHeight,
                lineHeight: lineHeight
            )
            let line = buildLine(
                glyphs: currentLineGlyphs,
                baselineY: baselineY,
                startCluster: currentLineStartCluster,
                endCluster: UInt32(text.utf8.count),
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
        glyphs: [(ShapedGlyph, FontAtlas.GlyphMetrics?)],
        baselineY: Float,
        startCluster: UInt32,
        endCluster: UInt32,
        maxWidth: Float,
        alignment: TextAlignment
    ) -> TextLine {
        var positioned: [PositionedGlyph] = []
        positioned.reserveCapacity(glyphs.count)

        var penX: Float = 0
        var lineWidth: Float = 0

        for (shaped, _) in glyphs {
            positioned.append(PositionedGlyph(
                glyphID: shaped.glyphID,
                fontID: shaped.fontID,
                cluster: shaped.cluster,
                x: penX + shaped.xOffset,
                y: baselineY + shaped.yOffset,
                atlasInfo: nil
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
                    fontID: g.fontID,
                    cluster: g.cluster,
                    x: g.x + offset,
                    y: g.y,
                    atlasInfo: g.atlasInfo
                )
            }
        }

        return TextLine(glyphs: positioned,
                        baselineY: baselineY,
                        width: lineWidth,
                        startCluster: startCluster,
                        endCluster: endCluster)
    }

    private static func centeredBaselineY(
        glyphs: [(ShapedGlyph, FontAtlas.GlyphMetrics?)],
        atlas: FontAtlas,
        lineTop: Float,
        lineHeight: Float
    ) -> Float {
        var maxAscent: Float = 0
        var maxDescent: Float = 0

        for (shaped, info) in glyphs {
            if let lineMetrics = atlas.lineMetrics(fontID: shaped.fontID) {
                maxAscent = max(maxAscent, lineMetrics.ascent)
                maxDescent = max(maxDescent, lineMetrics.descent)
                continue
            }
            guard let info, info.height > 0 else { continue }
            let top = shaped.yOffset - info.bearingY
            let bottom = top + info.height
            maxAscent = max(maxAscent, -top)
            maxDescent = max(maxDescent, bottom)
        }

        guard maxAscent > 0 || maxDescent > 0 else {
            return lineTop + lineHeight
        }

        let contentHeight = maxAscent + maxDescent
        let topInset = max(0, (lineHeight - contentHeight) * 0.5)
        return lineTop + topInset + maxAscent
    }
}
