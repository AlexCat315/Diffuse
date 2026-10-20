import GuavaUIRuntime

/// A GFM table: columns sized to their content within a readable range,
/// a tinted header, row rules, and horizontal scrolling when the table is
/// wider than its container.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let onOpenLink: ((String) -> Void)?

    var body: some View {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        let rows = [table.header] + table.rows
        return ScrollView(.horizontal, accessibilityLabel: "Table") {
            LayoutContainer(MarkdownTableLayout(columns: columns, rows: rows.count)) {
                Box(direction: .column) {}.frame(width: .percent(100), height: .percent(100)).background(.surfaceVariant)
                for cell in cells(rows, columns: columns) { cell }
                for _ in 0..<max(0, rows.count - 1) { Divider() }
            }
            .cornerRadius(8)
            .border(.border, width: 1)
            .clipped()
        }
    }

    private func cells(_ rows: [[[RichTextRun]]], columns: Int) -> [AnyView] {
        rows.enumerated().flatMap { rowIndex, row in
            (0..<columns).map { column in
                AnyView(cell(column < row.count ? row[column] : [], column: column, isHeader: rowIndex == 0))
            }
        }
    }

    private func cell(_ runs: [RichTextRun], column: Int, isHeader: Bool) -> some View {
        let alignment: TextAlignment = switch column < table.alignments.count ? table.alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let content = isHeader ? runs.map { RichTextRun($0.text, traits: $0.traits.union(.bold), link: $0.link) } : runs
        // The cell fills its column so centred and trailing alignment apply.
        return Box(direction: .column, alignItems: .stretch) {
            RichText(content, alignment: alignment, onOpenLink: onOpenLink)
        }
        .padding(horizontal: 12, vertical: 8)
        .frame(width: .percent(100), height: .percent(100))
    }
}

/// Subviews: the header tint, then `rows × columns` cells in row order, then
/// one rule under every row but the last.
struct MarkdownTableLayout: Layout {
    let columns: Int
    let rows: Int
    static let minimumColumn: CGFloat = 56
    static let maximumColumn: CGFloat = 320

    private struct Geometry {
        var widths: [CGFloat]
        var heights: [CGFloat]
        var size: CGSize { CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +)) }
    }

    private func geometry(_ subviews: [LayoutSubview]) -> Geometry {
        guard columns > 0, subviews.count >= 1 + rows * columns else { return Geometry(widths: [], heights: []) }
        let cell = { (row: Int, column: Int) in subviews[1 + row * columns + column] }
        let widths = (0..<columns).map { column in
            let natural = (0..<rows).map { cell($0, column).sizeThatFits(.unspecified).width }.max() ?? 0
            return min(Self.maximumColumn, max(Self.minimumColumn, natural.rounded(.up)))
        }
        let heights = (0..<rows).map { row in
            (0..<columns).map { cell(row, $0).sizeThatFits(ProposedViewSize(width: widths[$0])).height }.max() ?? 0
        }
        return Geometry(widths: widths, heights: heights.map { $0.rounded(.up) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        geometry(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let geometry = geometry(subviews)
        guard !geometry.widths.isEmpty else { return }
        let total = geometry.size.width
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: total, height: geometry.heights[0]))
        var y = bounds.minY
        for row in 0..<rows {
            var x = bounds.minX
            for column in 0..<columns {
                // The leading/trailing columns follow the reading direction.
                let rtl = subviews[0].layoutDirection == .rtl
                let index = rtl ? columns - 1 - column : column
                subviews[1 + row * columns + index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: geometry.widths[index], height: geometry.heights[row]))
                x += geometry.widths[index]
            }
            y += geometry.heights[row]
            let rule = 1 + rows * columns + row
            if row < rows - 1, rule < subviews.count {
                subviews[rule].place(at: CGPoint(x: bounds.minX, y: y - 1), proposal: ProposedViewSize(width: total, height: 1))
            }
        }
    }
}
