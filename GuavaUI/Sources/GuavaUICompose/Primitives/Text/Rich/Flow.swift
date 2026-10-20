import Foundation
import GuavaUIRuntime

/// A paragraph with every run resolved to a concrete font. Equal paragraphs
/// share layouts through `RichTextFlow.cache`.
struct RichParagraph: Hashable {
    struct Span: Hashable {
        var text: String
        var font: Font
        var lineHeight: Float
        var traits: RichTextTraits
        /// Index into the paragraph's link destinations.
        var link: Int?
    }

    var spans: [Span]
    var alignment: TextAlignment = .leading
    /// Code listings keep authored lines and scroll instead of wrapping.
    var wraps = true

    var text: String { spans.map(\.text).joined() }
}

/// Measured lines, glyphs and span fragments of one paragraph at one width.
/// Offsets are UTF-8 byte offsets into the paragraph text.
struct RichTextFlow {
    struct Caret: Equatable {
        var offset: Int
        var x: Float
    }

    struct Line {
        var top: Float
        var height: Float
        var baseline: Float
        var width: Float
        var startOffset: Int
        var endOffset: Int
        /// Sorted by offset; the last entry is the visual end of the line.
        var carets: [Caret]
        /// Base direction of the paragraph this line belongs to.
        var isRightToLeft = false
    }

    /// One span's extent on one line.
    struct Fragment {
        var span: Int
        var line: Int
        var minX: Float
        var maxX: Float
        var ascent: Float
        var descent: Float
    }

    var text: String
    var lines: [Line]
    var fragments: [Fragment]
    var glyphs: TextLayoutResult
    var spanStarts: [Int]
    var width: Float
    var height: Float

    func span(atOffset offset: Int) -> Int? {
        guard !spanStarts.isEmpty else { return nil }
        var low = 0, high = spanStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spanStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func fragment(at x: Float, _ y: Float) -> Fragment? {
        guard let line = lineIndex(atY: y), y >= 0, y < height else { return nil }
        return fragments.first { $0.line == line && x >= $0.minX && x < $0.maxX }
    }

    func lineIndex(atY y: Float) -> Int? {
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex { $0.top <= y } ?? 0
    }

    /// The caret offset nearest to a point, clamped to the paragraph.
    func offset(at x: Float, _ y: Float) -> Int {
        guard let index = lineIndex(atY: y) else { return 0 }
        if y < 0 { return 0 }
        if y >= height { return text.utf8.count }
        let carets = lines[index].carets
        guard var best = carets.first else { return lines[index].startOffset }
        for caret in carets where abs(caret.x - x) < abs(best.x - x) { best = caret }
        return best.offset
    }

    func caretX(_ offset: Int, line index: Int) -> Float {
        let carets = lines[index].carets
        return carets.last { $0.offset <= offset }?.x ?? carets.first?.x ?? 0
    }

    /// Highlight rectangles (x, y, width, height) for a UTF-8 range.
    func selectionRects(_ range: Range<Int>) -> [(Float, Float, Float, Float)] {
        guard !range.isEmpty else { return [] }
        return lines.indices.compactMap { index in
            let line = lines[index]
            let lower = max(range.lowerBound, line.startOffset)
            let upper = min(range.upperBound, line.endOffset)
            guard lower < upper || (range.contains(line.startOffset) && line.startOffset == line.endOffset) else { return nil }
            let start = caretX(lower, line: index)
            var end = upper >= line.endOffset ? (line.carets.last?.x ?? start) : caretX(upper, line: index)
            // A selected line break shows as a short tail, as in text editors.
            if range.upperBound > line.endOffset, index + 1 < lines.count { end += line.height * 0.3 }
            return (start, line.top, max(end - start, 2), line.height)
        }
    }

    // MARK: - Layout

    static func layout(_ paragraph: RichParagraph, maxWidth: Float, env: TextEnvironment) -> RichTextFlow {
        let limit = paragraph.wraps && maxWidth.isFinite && maxWidth > 0 ? maxWidth : .infinity
        let key = CacheKey(paragraph: paragraph, maxWidth: limit, atlas: ObjectIdentifier(env.atlas))
        return cache.value(for: key) { Builder(paragraph: paragraph, maxWidth: limit, env: env).build() }
    }

    struct CacheKey: Hashable {
        let paragraph: RichParagraph
        let maxWidth: Float
        let atlas: ObjectIdentifier
    }

    static let cache = RichTextFlowCache()
}

/// Lock-protected; layouts are immutable values once stored.
final class RichTextFlowCache: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [RichTextFlow.CacheKey: RichTextFlow] = [:]

    func value(for key: RichTextFlow.CacheKey, build: () -> RichTextFlow) -> RichTextFlow {
        if let hit = lock.withLock({ table[key] }) { return hit }
        let result = build()
        lock.withLock {
            // Widths change continuously while a window resizes; a bounded
            // table keeps that from growing without limit.
            if table.count >= 512 { table.removeAll(keepingCapacity: true) }
            table[key] = result
        }
        return result
    }
}

private struct Builder {
    struct Item {
        var glyph: ShapedGlyph?
        var span: Int
        var cluster: Int
        var advance: Float
        var padBefore: Float = 0
        var padAfter: Float = 0
        var isSpace = false
        var breakBefore = false
        var isHardBreak: Bool { glyph == nil }
        var extent: Float { padBefore + advance + padAfter }
    }

    let paragraph: RichParagraph
    let maxWidth: Float
    let env: TextEnvironment

    func build() -> RichTextFlow {
        let text = paragraph.text
        let bidi: BidiParagraphs? = BidiParagraphs.containsRightToLeft(text) ? BidiParagraphs(text) : nil
        var starts: [Int] = []
        var offset = 0
        for span in paragraph.spans { starts.append(offset); offset += span.text.utf8.count }
        let items = makeItems(text: text, starts: starts, bidi: bidi)
        var lines: [RichTextFlow.Line] = []
        var fragments: [RichTextFlow.Fragment] = []
        var glyphLines: [TextLine] = []
        var top: Float = 0
        for range in wrap(items) {
            let line = place(items, range: range, text: text, top: top, index: lines.count, bidi: bidi)
            lines.append(line.line)
            fragments += line.fragments
            glyphLines.append(line.glyphs)
            top += line.line.height
        }
        if lines.isEmpty, let first = paragraph.spans.first {
            let empty = RichTextFlow.Line(top: 0, height: first.lineHeight, baseline: first.lineHeight * 0.75,
                                          width: 0, startOffset: 0, endOffset: 0,
                                          carets: [.init(offset: 0, x: 0)])
            lines.append(empty)
            top = first.lineHeight
        }
        let width = lines.map(\.width).max() ?? 0
        let alignedLines = align(lines, glyphs: glyphLines, fragments: fragments, width: width)
        return RichTextFlow(text: text, lines: alignedLines.lines, fragments: alignedLines.fragments,
                            glyphs: TextLayoutResult(lines: alignedLines.glyphs, totalWidth: width, totalHeight: top),
                            spanStarts: starts, width: width, height: top)
    }

    private func makeItems(text: String, starts: [Int], bidi: BidiParagraphs?) -> [Item] {
        let breaks = RichTextBreaks.opportunities(in: text)
        var items: [Item] = []
        for (index, span) in paragraph.spans.enumerated() {
            let pad: Float = span.traits.contains(.code) ? (span.font.size * 0.32).rounded() : 0
            let firstItem = items.count
            var segmentStart = starts[index]
            let segments = span.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (segmentIndex, segment) in segments.enumerated() {
                if segmentIndex > 0 {
                    items.append(Item(glyph: nil, span: index, cluster: segmentStart - 1, advance: 0))
                }
                let string = String(segment)
                let utf8 = Array(string.utf8)
                var segment: [Item] = []
                for glyph in env.shape(text: string, font: span.font) {
                    let local = Int(glyph.cluster)
                    let byte = local < utf8.count ? utf8[local] : 0
                    var item = Item(glyph: glyph, span: index, cluster: segmentStart + local, advance: glyph.xAdvance)
                    item.isSpace = byte == 0x20 || byte == 0x09
                    item.breakBefore = breaks.contains(item.cluster)
                    segment.append(item)
                }
                // Wrapping works in logical order; right-to-left runs arrive visual.
                if let bidi {
                    segment = segment.enumerated().sorted { lhs, rhs in
                        if lhs.element.cluster != rhs.element.cluster { return lhs.element.cluster < rhs.element.cluster }
                        return bidi.level(atByte: lhs.element.cluster) & 1 == 1 ? lhs.offset > rhs.offset : lhs.offset < rhs.offset
                    }.map(\.element)
                }
                items += segment
                segmentStart += utf8.count + 1
            }
            if pad > 0, items.count > firstItem {
                if let first = items[firstItem...].firstIndex(where: { !$0.isHardBreak }) { items[first].padBefore = pad }
                if let last = items[firstItem...].lastIndex(where: { !$0.isHardBreak }) { items[last].padAfter = pad }
            }
        }
        // Runs shape separately, so a break between runs comes from the text.
        for index in items.indices.dropFirst() where items[index].cluster != items[index - 1].cluster {
            items[index].breakBefore = items[index].breakBefore || breaks.contains(items[index].cluster)
        }
        return items
    }

    /// Greedy wrapping into item ranges; hard breaks end a line and are
    /// represented by the range that follows them.
    private func wrap(_ items: [Item]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var width: Float = 0
        var index = 0
        while index < items.count {
            let item = items[index]
            if item.isHardBreak {
                ranges.append(start..<index)
                start = index + 1
                width = 0
                index += 1
                if start == items.count { ranges.append(start..<start) }
                continue
            }
            let breaksHere = index > start && items[index - 1].cluster != item.cluster
            if width + item.extent > maxWidth, breaksHere, !item.isSpace {
                if let soft = (start + 1...index).last(where: { items[$0].breakBefore && !items[$0].isSpace }), soft > start {
                    ranges.append(start..<soft)
                    start = soft
                    width = items[soft..<index].reduce(0) { $0 + $1.extent }
                } else {
                    ranges.append(start..<index)
                    start = index
                    width = 0
                }
            }
            width += item.extent
            index += 1
        }
        if start < items.count || ranges.isEmpty && !items.isEmpty { ranges.append(start..<items.count) }
        return ranges
    }

    private struct PlacedLine {
        var line: RichTextFlow.Line
        var fragments: [RichTextFlow.Fragment]
        var glyphs: TextLine
    }

    private func place(_ items: [Item], range: Range<Int>, text: String, top: Float, index: Int,
                       bidi: BidiParagraphs?) -> PlacedLine {
        let logical = items[range]
        let lineStart = logical.first?.cluster ?? (range.lowerBound > 0 ? items[range.lowerBound - 1].cluster + 1 : 0)
        let rightToLeft = bidi?.paragraph(atByte: lineStart).isRightToLeft == true
        let content = bidi.map { visualOrder(logical, bidi: $0) } ?? Array(logical)
        let levels = content.map { bidi?.level(atByte: $0.cluster) ?? 0 }
        let fallbackSpan = content.first?.span ?? (range.lowerBound > 0 ? items[range.lowerBound - 1].span : 0)
        var ascent: Float = 0, descent: Float = 0, height: Float = 0
        var metricsBySpan: [Int: (Float, Float)] = [:]
        for item in content {
            let span = paragraph.spans[item.span]
            height = max(height, span.lineHeight)
            if metricsBySpan[item.span] == nil, let glyph = item.glyph {
                let metrics = env.atlas.lineMetrics(fontID: glyph.fontID)
                metricsBySpan[item.span] = (metrics?.ascent ?? span.font.size * 0.8,
                                            metrics?.descent ?? span.font.size * 0.2)
            }
            if let (a, d) = metricsBySpan[item.span] { ascent = max(ascent, a); descent = max(descent, d) }
        }
        if height == 0 {
            let span = paragraph.spans[fallbackSpan]
            height = span.lineHeight
            ascent = span.font.size * 0.8
            descent = span.font.size * 0.2
        }
        let baseline = (top + (height - ascent - descent) / 2 + ascent).rounded()

        var pen: Float = 0
        var visibleWidth: Float = 0
        var carets: [RichTextFlow.Caret] = []
        var positioned: [PositionedGlyph] = []
        var fragments: [RichTextFlow.Fragment] = []
        for (position, item) in content.enumerated() {
            guard let glyph = item.glyph else { continue }
            if carets.last?.offset != item.cluster {
                // A right-to-left character starts at its right edge.
                let odd = levels[position] & 1 == 1
                carets.append(.init(offset: item.cluster, x: odd ? pen + item.extent - item.padAfter : pen + item.padBefore))
            }
            let (a, d) = metricsBySpan[item.span] ?? (ascent, descent)
            if fragments.last?.span == item.span {
                fragments[fragments.count - 1].maxX = pen + item.extent
            } else {
                fragments.append(.init(span: item.span, line: index, minX: pen, maxX: pen + item.extent,
                                       ascent: a, descent: d))
            }
            positioned.append(PositionedGlyph(glyphID: glyph.glyphID, fontID: glyph.fontID,
                                              cluster: UInt32(item.cluster),
                                              x: pen + item.padBefore + glyph.xOffset,
                                              y: baseline + glyph.yOffset, atlasInfo: nil))
            pen += item.extent
            if !item.isSpace { visibleWidth = pen }
        }
        let startOffset = lineStart
        let endOffset = range.upperBound < items.count ? items[range.upperBound].cluster : text.utf8.count
        carets.append(.init(offset: endOffset, x: rightToLeft ? 0 : pen))
        if bidi != nil { carets.sort { $0.offset < $1.offset } }
        if carets.first?.offset != startOffset { carets.insert(.init(offset: startOffset, x: rightToLeft ? pen : 0), at: 0) }
        let line = RichTextFlow.Line(top: top, height: height, baseline: baseline, width: visibleWidth,
                                     startOffset: startOffset, endOffset: endOffset, carets: carets,
                                     isRightToLeft: rightToLeft)
        return PlacedLine(line: line, fragments: fragments,
                          glyphs: TextLine(glyphs: positioned, baselineY: baseline, topY: top, width: visibleWidth,
                                           startCluster: UInt32(startOffset), endCluster: UInt32(endOffset)))
    }

    /// L1 returns trailing whitespace to the paragraph level; L2 then reverses
    /// runs from the highest level down to the lowest odd one.
    private func visualOrder(_ items: ArraySlice<Item>, bidi: BidiParagraphs) -> [Item] {
        let line = Array(items)
        guard let first = line.first else { return line }
        let base = bidi.paragraph(atByte: first.cluster).baseLevel
        var levels = line.map { bidi.level(atByte: $0.cluster) }
        var index = line.count - 1
        while index >= 0, line[index].isSpace || bidi.isTrailingWhitespace(atByte: line[index].cluster) {
            levels[index] = base; index -= 1
        }
        return BidiParagraphs.visualOrder(levels).map { line[$0] }
    }

    private func align(_ lines: [RichTextFlow.Line], glyphs: [TextLine], fragments: [RichTextFlow.Fragment],
                       width: Float) -> (lines: [RichTextFlow.Line], glyphs: [TextLine], fragments: [RichTextFlow.Fragment]) {
        let box = maxWidth.isFinite ? maxWidth : width
        // Leading and trailing follow each line's paragraph direction.
        func factor(_ line: RichTextFlow.Line) -> Float {
            switch paragraph.alignment {
            case .leading: line.isRightToLeft ? 1 : 0
            case .center: 0.5
            case .trailing: line.isRightToLeft ? 0 : 1
            }
        }
        guard lines.contains(where: { factor($0) > 0 }) else { return (lines, glyphs, fragments) }
        let shifts = lines.map { ((box - $0.width) * factor($0)).rounded() }
        let shiftedLines = zip(lines, shifts).map { line, shift in
            var copy = line
            copy.carets = line.carets.map { .init(offset: $0.offset, x: $0.x + shift) }
            return copy
        }
        let shiftedGlyphs = zip(glyphs, shifts).map { line, shift in
            TextLine(glyphs: line.glyphs.map {
                PositionedGlyph(glyphID: $0.glyphID, fontID: $0.fontID, cluster: $0.cluster,
                                x: $0.x + shift, y: $0.y, atlasInfo: $0.atlasInfo)
            }, baselineY: line.baselineY, topY: line.topY, width: line.width,
                     startCluster: line.startCluster, endCluster: line.endCluster)
        }
        let shiftedFragments = fragments.map { fragment in
            var copy = fragment
            copy.minX += shifts[fragment.line]
            copy.maxX += shifts[fragment.line]
            return copy
        }
        return (shiftedLines, shiftedGlyphs, shiftedFragments)
    }
}
