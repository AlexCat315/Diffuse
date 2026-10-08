/// Text alignment for multi-line layout.
public enum TextAlignment: Equatable, Sendable {
    case leading, center, trailing
}

/// A single line of laid-out text.
public struct TextLine {
    /// Shaped glyphs on this line with lazily-resolved atlas info.
    public let glyphs: [PositionedGlyph]
    /// Baseline Y position relative to the text block origin.
    public let baselineY: Float
    /// Top of the visual row, independent of the font baseline and leading.
    public let topY: Float
    /// Total width of this line.
    public let width: Float
    /// UTF-8 byte offset of the first character shown on this line.
    public let startCluster: UInt32
    /// UTF-8 byte offset of the first character not shown on this line.
    public let endCluster: UInt32
    public init(glyphs: [PositionedGlyph], baselineY: Float, topY: Float, width: Float, startCluster: UInt32, endCluster: UInt32) {
        self.glyphs = glyphs
        self.baselineY = baselineY
        self.topY = topY
        self.width = width
        self.startCluster = startCluster
        self.endCluster = endCluster
    }

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
    public let atlasInfo: GlyphAtlasInfo?
    public init(glyphID: UInt32, fontID: Int, cluster: UInt32, x: Float, y: Float, atlasInfo: GlyphAtlasInfo?) {
        self.glyphID = glyphID
        self.fontID = fontID
        self.cluster = cluster
        self.x = x
        self.y = y
        self.atlasInfo = atlasInfo
    }

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
        atlas: any GlyphMetricsProvider,
        maxWidth: Float = .infinity,
        lineHeight: Float,
        alignment: TextAlignment = .leading,
        letterSpacing: Float = 0
    ) -> TextLayoutResult {
        guard !shapedGlyphs.isEmpty else {
            return TextLayoutResult(lines: [], totalWidth: 0, totalHeight: 0)
        }

        let utf8 = Array(text.utf8)
        var lineBreaks: [UInt32: UInt32] = [:], sourceOffset: UInt32 = 0
        for character in text {
            let length = UInt32(character.utf8.count)
            if character.isNewline { lineBreaks[sourceOffset] = length }
            sourceOffset += length
        }
        let spacing = letterSpacing.isFinite ? letterSpacing : 0
        // All lines in a text block share the same font metrics, including empty lines.
        let baselineOffset = centeredBaselineY(glyphs: shapedGlyphs.map { ($0, atlas.glyphMetrics(glyphIndex: $0.glyphID, fontID: $0.fontID)) }, atlas: atlas, lineTop: 0, lineHeight: lineHeight)
        var lastWasNewline = false

        var lines: [TextLine] = []
        var currentLineGlyphs: [(ShapedGlyph, GlyphMetrics?)] = []
        var currentLineStartCluster: UInt32 = 0
        var penX: Float = 0
        var lastBreakIndex: Int? = nil

        for (_, glyph) in shapedGlyphs.enumerated() {
            let clusterByte: UInt8 = Int(glyph.cluster) < utf8.count
                ? utf8[Int(glyph.cluster)] : 0

            // Explicit newline → flush current line immediately, skip glyph.
            let isNewline = lineBreaks[glyph.cluster] != nil || clusterByte == UInt8(ascii: "\n") || clusterByte == UInt8(ascii: "\r")
            if isNewline {
                // HarfBuzz may emit both control glyphs, or one shared CRLF cluster.
                if glyph.cluster < currentLineStartCluster { continue }
                lastWasNewline = true
                let baselineY = Float(lines.count) * lineHeight + baselineOffset
                let line = buildLine(
                    glyphs: currentLineGlyphs,
                    baselineY: baselineY,
                        topY: Float(lines.count) * lineHeight,
                    startCluster: currentLineStartCluster,
                    endCluster: glyph.cluster,
                    maxWidth: maxWidth,
                    alignment: alignment,
                    letterSpacing: spacing
                )
                lines.append(line)
                currentLineGlyphs = []
                let newlineLength = lineBreaks[glyph.cluster] ?? 1
                currentLineStartCluster = glyph.cluster + newlineLength
                penX = 0
                lastBreakIndex = nil
                continue
            }

            lastWasNewline = false
            let metrics = atlas.glyphMetrics(glyphIndex: glyph.glyphID, fontID: glyph.fontID)

            // Is this a whitespace cluster? Check source text.
            let isSpace = clusterByte == UInt8(ascii: " ") || clusterByte == UInt8(ascii: "\t")

            if isSpace {
                lastBreakIndex = currentLineGlyphs.count
            }

            let gap = currentLineGlyphs.last.map { $0.0.cluster != glyph.cluster ? spacing : 0 } ?? 0
            var nextPenX = penX + gap + glyph.xAdvance

            // Line break needed?
            if nextPenX > maxWidth && !currentLineGlyphs.isEmpty && currentLineGlyphs.last?.0.cluster != glyph.cluster {
                if let breakIdx = lastBreakIndex, breakIdx > 0 {
                    // Break at last whitespace
                    let lineGlyphs = Array(currentLineGlyphs.prefix(breakIdx))
                    let remaining = Array(currentLineGlyphs.suffix(from: breakIdx).drop(while: { value in
                        let index = Int(value.0.cluster)
                        return index < utf8.count && (utf8[index] == 32 || utf8[index] == 9)
                    }))
                    let nextLineStartCluster = remaining.first?.0.cluster ?? glyph.cluster
                    let baselineY = Float(lines.count) * lineHeight + baselineOffset

                    let line = buildLine(
                        glyphs: lineGlyphs,
                        baselineY: baselineY,
                        topY: Float(lines.count) * lineHeight,
                        startCluster: currentLineStartCluster,
                        endCluster: nextLineStartCluster,
                        maxWidth: maxWidth,
                        alignment: alignment,
                        letterSpacing: spacing
                    )
                    lines.append(line)

                    // Re-layout remaining glyphs
                    currentLineGlyphs = remaining
                    currentLineStartCluster = nextLineStartCluster
                    penX = width(of: remaining, letterSpacing: spacing)
                    let remainingGap = remaining.last.map { $0.0.cluster != glyph.cluster ? spacing : 0 } ?? 0
                    nextPenX = penX + remainingGap + glyph.xAdvance
                    lastBreakIndex = nil
                } else {
                    // No break point; force break here
                    let nextLineStartCluster = glyph.cluster
                    let baselineY = Float(lines.count) * lineHeight + baselineOffset
                    let line = buildLine(
                        glyphs: currentLineGlyphs,
                        baselineY: baselineY,
                        topY: Float(lines.count) * lineHeight,
                        startCluster: currentLineStartCluster,
                        endCluster: nextLineStartCluster,
                        maxWidth: maxWidth,
                        alignment: alignment,
                        letterSpacing: spacing
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
        if !currentLineGlyphs.isEmpty || lastWasNewline {
            let baselineY = Float(lines.count) * lineHeight + baselineOffset
            let line = buildLine(
                glyphs: currentLineGlyphs,
                baselineY: baselineY,
                        topY: Float(lines.count) * lineHeight,
                startCluster: currentLineStartCluster,
                endCluster: UInt32(text.utf8.count),
                maxWidth: maxWidth,
                alignment: alignment,
                letterSpacing: spacing
            )
            lines.append(line)
        }

        let totalWidth = lines.map(\.width).max() ?? 0
        let totalHeight = Float(lines.count) * lineHeight

        return TextLayoutResult(lines: lines, totalWidth: totalWidth, totalHeight: totalHeight)
    }

    // MARK: - Internal

    private static func buildLine(
        glyphs: [(ShapedGlyph, GlyphMetrics?)],
        baselineY: Float,
        topY: Float,
        startCluster: UInt32,
        endCluster: UInt32,
        maxWidth: Float,
        alignment: TextAlignment,
        letterSpacing: Float
    ) -> TextLine {
        var positioned: [PositionedGlyph] = []
        positioned.reserveCapacity(glyphs.count)

        var penX: Float = 0
        var lineWidth: Float = 0

        var previousCluster: UInt32?
        for (shaped, _) in glyphs {
            if let previousCluster, previousCluster != shaped.cluster { penX += letterSpacing }
            previousCluster = shaped.cluster
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
                        topY: topY,
                        width: lineWidth,
                        startCluster: startCluster,
                        endCluster: endCluster)
    }

    private static func width(of glyphs: [(ShapedGlyph, GlyphMetrics?)], letterSpacing: Float) -> Float {
        var result: Float = 0
        var previousCluster: UInt32?
        for (glyph, _) in glyphs {
            if let previousCluster, previousCluster != glyph.cluster { result += letterSpacing }
            previousCluster = glyph.cluster
            result += glyph.xAdvance
        }
        return result
    }

    private static func centeredBaselineY(
        glyphs: [(ShapedGlyph, GlyphMetrics?)],
        atlas: any GlyphMetricsProvider,
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
        let topInset = (lineHeight - contentHeight) * 0.5
        return lineTop + topInset + maxAscent
    }
}
