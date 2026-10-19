internal import GuavaUIRuntime

/// Guides occupy the leading whitespace of a scope, never its first token.
/// Only visible rows and their bounded indentation prefixes are inspected.
enum TextIndentGuides {
    struct Segment {
        let x: Float
        let top: Float
        var height: Float
    }
    private struct Indent {
        let depth: Int
        let blank: Bool
    }

    static func segments(in layout: TextLayoutResult, source: TextBuffer, tabWidth: Int,
                         spaceWidth: Float, lineHeight: Float, visibleX: Range<Float>) -> [Segment] {
        guard tabWidth > 0, spaceWidth.isFinite, spaceWidth > 0, lineHeight.isFinite, lineHeight > 0,
              visibleX.lowerBound.isFinite, visibleX.upperBound.isFinite, !visibleX.isEmpty else { return [] }
        let step = Float(tabWidth) * spaceWidth
        let firstLevel = Int(min(4096, max(0, visibleX.lowerBound / step)))
        let lastLevel = max(firstLevel, Int(min(4096, max(0, (visibleX.upperBound / step).rounded(.up)))))
        var cache: [Int: Indent] = [:], runs: [Int: Segment] = [:], result: [Segment] = []
        var priorDepth = 0
        if let first = layout.lines.first {
            let logical = source.lineIndex(forCharacterIndex: source.characterIndex(forUTF8Offset: Int(first.startCluster)))
            // Recover context at the top of a scrolled blank run without
            // scanning arbitrarily many lines in a large document.
            for index in (max(0, logical - 64)..<logical).reversed() {
                let value = indentation(source, line: index, tabWidth: tabWidth)
                if !value.blank { priorDepth = value.depth; break }
            }
        }
        for line in layout.lines {
            let logical = source.lineIndex(forCharacterIndex: source.characterIndex(forUTF8Offset: Int(line.startCluster)))
            let start = source.utf8Offset(forCharacterIndex: source.lineRange(forLine: logical).lowerBound)
            let value = cache[logical] ?? indentation(source, line: logical, tabWidth: tabWidth)
            cache[logical] = value
            if !value.blank { priorDepth = value.depth }
            // Soft wraps restart at the text origin. A scope guide there
            // would cross the continued word, so only its authored row draws.
            let depth = Int(line.startCluster) == start ? priorDepth : 0
            let endLevel = max(firstLevel, min(depth, lastLevel))
            for level in Array(runs.keys) where !(firstLevel..<endLevel).contains(level) {
                if let completed = runs.removeValue(forKey: level) { result.append(completed) }
            }
            for level in firstLevel..<endLevel {
                if var run = runs[level], abs(run.top + run.height - line.topY) < 0.5 {
                    run.height = line.topY + lineHeight - run.top; runs[level] = run
                } else {
                    if let completed = runs[level] { result.append(completed) }
                    runs[level] = Segment(x: Float(level) * step + 0.5, top: line.topY, height: lineHeight)
                }
            }
        }
        result.append(contentsOf: runs.values)
        return result.sorted { $0.x == $1.x ? $0.top < $1.top : $0.x < $1.x }
    }

    private static func indentation(_ source: TextBuffer, line: Int, tabWidth: Int) -> Indent {
        let range = source.lineRange(forLine: line)
        let start = source.utf8Offset(forCharacterIndex: range.lowerBound)
        let end = source.utf8Offset(forCharacterIndex: range.upperBound)
        // Extremely long lines remain owned by the document layout. Guide
        // decoration reads at most 4 KiB of their indentation prefix.
        var columns = 0, offset = start
        let limit = min(end, start + 4096)
        while offset < limit {
            let chunkEnd = min(limit, offset + 64)
            for byte in source.utf8Bytes(inUTF8Range: offset..<chunkEnd) {
                switch byte {
                case 32: columns += 1
                case 9: columns += tabWidth - columns % tabWidth
                case 10, 13: return Indent(depth: 0, blank: true)
                default: return Indent(depth: columns / tabWidth, blank: false)
                }
            }
            offset = chunkEnd
        }
        return Indent(depth: columns / tabWidth, blank: offset == end)
    }
}
