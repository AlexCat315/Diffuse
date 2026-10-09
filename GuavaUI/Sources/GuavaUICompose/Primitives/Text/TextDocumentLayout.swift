import GuavaUIRuntime

struct TextLineGeometry: Equatable {
    let font: Font
    let lineHeight: Float
    let letterSpacing: Float
    let atlas: ObjectIdentifier
    let width: Float
    let secure: Bool
}

/// Owns bounded line shaping and an incremental height index for one surface.
/// The cached Strings contain individual lines, never the complete document.
final class TextDocumentLayout {
    private(set) var buffer: TextBuffer
    private(set) var geometry: TextLineGeometry
    private(set) var index: TextVisualLineIndex
    private var lines: [Int: MeasuredTextLine] = [:]
    private var accessOrder: [Int: UInt64] = [:]
    private var clock: UInt64 = 0
    private(set) var shapedLineCount = 0
    private(set) var shapedUTF8Count = 0

    init(buffer: TextBuffer, geometry: TextLineGeometry) {
        self.buffer = buffer; self.geometry = geometry
        index = TextVisualLineIndex(lineCount: buffer.lineCount)
    }
    func update(buffer next: TextBuffer, geometry nextGeometry: TextLineGeometry) {
        if geometry != nextGeometry {
            geometry = nextGeometry; buffer = next
            index = TextVisualLineIndex(lineCount: next.lineCount)
            lines.removeAll(); accessOrder.removeAll(); return
        }
        guard next != buffer else { return }
        if let delta = next.editDelta(from: buffer) {
            let first = buffer.lineIndex(forCharacterIndex: delta.characterRange.lowerBound)
            let last = buffer.lineIndex(forCharacterIndex: delta.characterRange.upperBound)
            let newLast = next.lineIndex(forCharacterIndex: next.characterIndex(forUTF8Offset: delta.newEndUTF8Offset))
            let shift = next.lineCount - buffer.lineCount
            index.replace(lines: first..<(last + 1), withLineCount: newLast - first + 1)
            // At most 256 retained entries are rebased; work is independent of
            // document length. The persistent row index splices in O(log n).
            var kept: [Int: MeasuredTextLine] = [:], order: [Int: UInt64] = [:]
            for (line, entry) in lines where line < first || line > last {
                let key = line > last ? line + shift : line
                kept[key] = entry; order[key] = accessOrder[line]
            }
            lines = kept; accessOrder = order
        }
        buffer = next
    }
    func measuredLine(_ line: Int, environment env: TextEnvironment) -> MeasuredTextLine {
        let row = min(buffer.lineCount - 1, max(0, line))
        clock &+= 1; accessOrder[row] = clock
        if let entry = lines[row] { return entry }
        let source = buffer.substring(characterRange: buffer.lineRange(forLine: row))
        let text = geometry.secure ? String(repeating: "•", count: source.count) : source
        let result = env.cachedLayout(text: text, font: geometry.font, lineHeight: geometry.lineHeight,
                                      maxWidth: geometry.width, alignment: .leading, letterSpacing: geometry.letterSpacing)
        let entry = MeasuredTextLine(source: source, display: text, layout: result, lineHeight: geometry.lineHeight)
        lines[row] = entry; index.measure(line: row, rows: entry.rows.count)
        shapedLineCount += 1; shapedUTF8Count += text.utf8.count
        if lines.count > 256, let oldest = accessOrder.min(by: { $0.value < $1.value })?.key {
            lines.removeValue(forKey: oldest); accessOrder.removeValue(forKey: oldest)
        }
        return entry
    }
    /// Only logical lines intersecting this row window are shaped. Learning a
    /// wrapped line's height can only reduce the remaining work in the window.
    func visibleLayout(firstRow: Int, rowCount: Int, environment env: TextEnvironment) -> TextLayoutResult {
        let first = index.location(atRow: firstRow).line
        var result: [TextLine] = [], line = first, width: Float = 0
        let endRow = max(0, firstRow) + max(1, rowCount)
        while line < buffer.lineCount, index.firstRow(ofLine: line) < endRow {
            let entry = measuredLine(line, environment: env)
            let firstVisualRow = index.firstRow(ofLine: line)
            let range = buffer.lineRange(forLine: line), byteStart = buffer.utf8Offset(forCharacterIndex: range.lowerBound)
            for (subrow, local) in entry.rows.enumerated() {
                let visualRow = firstVisualRow + subrow
                guard visualRow >= firstRow, visualRow < endRow else { continue }
                let y = Float(firstVisualRow) * geometry.lineHeight
                func global(_ offset: UInt32) -> UInt32 {
                    if geometry.secure {
                        let character = entry.displayCharacterIndex(forByte: Int(offset))
                        return UInt32(clamping: buffer.utf8Offset(forCharacterIndex: range.lowerBound + character))
                    }
                    return UInt32(clamping: byteStart + Int(offset))
                }
                let glyphs = local.glyphs.map {
                    PositionedGlyph(glyphID: $0.glyphID, fontID: $0.fontID, cluster: global($0.cluster),
                                    x: $0.x, y: $0.y + y, atlasInfo: $0.atlasInfo)
                }
                result.append(TextLine(glyphs: glyphs, baselineY: local.baselineY + y, topY: local.topY + y, width: local.width,
                                       startCluster: global(local.startCluster), endCluster: global(local.endCluster)))
                width = max(width, local.width)
            }
            line += 1
        }
        return TextLayoutResult(lines: result, totalWidth: width, totalHeight: Float(index.rowCount) * geometry.lineHeight)
    }
    func caret(atCharacter cursor: Int, lineEndAffinity: Bool = false, environment env: TextEnvironment) -> (x: Float, row: Int) {
        let position = buffer.lineAndColumn(forCharacterIndex: cursor)
        let line = measuredLine(position.line, environment: env)
        let local = line.caret(atCharacter: position.column, lineEndAffinity: lineEndAffinity)
        return (local.x, index.firstRow(ofLine: position.line) + local.row)
    }
    func character(atRow row: Int, x: Float, environment env: TextEnvironment) -> Int {
        var location = index.location(atRow: row)
        let line = measuredLine(location.line, environment: env)
        location = index.location(atRow: row)
        // Measuring can reveal more subrows of the same logical line.
        let column = line.character(atRow: location.subrow, x: x)
        return buffer.characterIndex(forLine: location.line, character: column)
    }
}

/// A bounded line and its glyph-cluster caret map. Multiple glyphs in an emoji
/// or combining cluster cannot create extra cursor stops. Ligatures interpolate
/// across their constituent Character boundaries.
struct MeasuredTextLine {
    let rows: [TextLine]
    private let boundaries: [Int]
    private let carets: [[TextCharacterCaret]]
    init(source: String, display: String, layout: TextLayoutResult, lineHeight: Float) {
        var boundaries = [0], offset = 0
        for character in display { offset += character.utf8.count; boundaries.append(offset) }
        self.boundaries = boundaries
        rows = layout.lines.isEmpty
            ? [TextLine(glyphs: [], baselineY: lineHeight * 0.8, topY: 0, width: 0, startCluster: 0, endCluster: 0)]
            : layout.lines
        carets = rows.map { row in
            var clusters: [(byte: Int, x: Float)] = []
            for glyph in row.glyphs where clusters.last?.byte != Int(glyph.cluster) {
                clusters.append((Int(glyph.cluster), glyph.x))
            }
            clusters.append((Int(row.endCluster), row.width))
            var positions: [TextCharacterCaret] = []
            var cluster = 0
            for (character, byte) in boundaries.enumerated() where byte >= Int(row.startCluster) && byte <= Int(row.endCluster) {
                while cluster + 1 < clusters.count, clusters[cluster + 1].byte <= byte { cluster += 1 }
                let current = clusters[cluster]
                var x = current.x
                if cluster + 1 < clusters.count, byte > current.byte {
                    let next = clusters[cluster + 1]
                    let covered = boundaries.filter { $0 >= current.byte && $0 <= next.byte }
                    let fraction = Float(covered.firstIndex(of: byte) ?? 0) / Float(max(1, covered.count - 1))
                    x += (next.x - x) * fraction
                }
                positions.append(TextCharacterCaret(character: character, x: x))
            }
            return positions.isEmpty ? [TextCharacterCaret(character: 0, x: 0)] : positions
        }
    }
    func displayCharacterIndex(forByte byte: Int) -> Int {
        var lower = 0, upper = boundaries.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if boundaries[middle] < byte { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    func caret(atCharacter character: Int, lineEndAffinity: Bool = false) -> (x: Float, row: Int) {
        let cursor = min(boundaries.count - 1, max(0, character))
        for (row, positions) in carets.enumerated() {
            if let position = positions.first(where: { $0.character == cursor }),
               cursor < positions.last!.character || row == carets.count - 1 || lineEndAffinity { return (position.x, row) }
        }
        // A wrapping separator can be omitted by the shaper; attach it to the
        // next row, preserving a deterministic stop rather than inventing one.
        for (row, positions) in carets.enumerated() {
            if let position = positions.first(where: { $0.character >= cursor }) { return (position.x, row) }
        }
        return (rows.last?.width ?? 0, max(0, rows.count - 1))
    }
    func character(atRow row: Int, x: Float) -> Int {
        let positions = carets[min(carets.count - 1, max(0, row))]
        for index in 0..<max(0, positions.count - 1) {
            if x < (positions[index].x + positions[index + 1].x) / 2 { return positions[index].character }
        }
        return positions.last?.character ?? 0
    }
}

private struct TextCharacterCaret {
    let character: Int
    let x: Float
}
