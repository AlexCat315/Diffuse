import GuavaUIRuntime

/// Soft fills behind every occurrence of the symbol at the caret, drawn under
/// the glyphs on visible lines only.
extension TextField {
    func drawOccurrences(_ layout: TextLayoutResult, textOriginX: Float, textOriginY: Float,
                         lineHeight: Float, node: Node, list: DrawList) {
        let ranges = codeEditing.occurrences
        guard !ranges.isEmpty else { return }
        let color = node.theme.colors.onSurface.multipliedAlpha(node.opacity * 0.1)
        for line in layout.lines {
            let first = Int(line.startCluster), last = Int(line.endCluster)
            for range in ranges where range.lowerBound < last && range.upperBound > first {
                let lower = range.lowerBound <= first ? 0
                    : line.glyphs.last { Int($0.cluster) <= range.lowerBound }?.x ?? 0
                let upper = range.upperBound >= last ? line.width
                    : line.glyphs.first { Int($0.cluster) >= range.upperBound }?.x ?? line.width
                guard upper > lower else { continue }
                list.addRoundedRect(UIRect(x: textOriginX + lower - 1, y: textOriginY + line.topY + 1,
                                           width: upper - lower + 2, height: max(0, lineHeight - 2)),
                                    radius: 3, color: color)
            }
        }
    }
}
