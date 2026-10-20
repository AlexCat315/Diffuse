import Foundation

/// Cells a grid child covers. Spans are clamped to the resolved column count;
/// named field columns ignore spans because hiding a field column would
/// otherwise move every spanning cell.
public struct GridSpan: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int = 1, rows: Int = 1) {
        self.columns = max(1, columns); self.rows = max(1, rows)
    }
    public static let single = GridSpan()
}

struct GridSpanKey: LayoutValueKey {
    static let defaultValue = GridSpan.single
}

public extension View {
    /// Let this child cover several `Grid` columns and/or rows. Placement is
    /// row-major: a cell that does not fit the remaining columns of a row
    /// starts the next free row.
    func gridCellSpan(columns: Int = 1, rows: Int = 1) -> some View {
        layoutValue(key: GridSpanKey.self, value: GridSpan(columns: columns, rows: rows))
    }
}

/// Row-major auto placement with an occupancy table, as in CSS grid's sparse
/// flow. Heights grow so every multi-row cell fits its spanned rows.
struct GridSpanPlacement: Equatable {
    struct Cell: Equatable {
        let row: Int
        let column: Int
        let span: GridSpan
    }
    let cells: [Cell]
    let rowCount: Int

    init(spans: [GridSpan], columnCount: Int) {
        let columns = max(1, columnCount)
        var occupied: [[Bool]] = []
        var cells: [Cell] = []
        cells.reserveCapacity(spans.count)
        var row = 0, column = 0
        func isFree(_ row: Int, _ column: Int, _ span: GridSpan) -> Bool {
            guard column + span.columns <= columns else { return false }
            for r in row..<(row + span.rows) where r < occupied.count {
                for c in column..<(column + span.columns) where occupied[r][c] { return false }
            }
            return true
        }
        for raw in spans {
            let span = GridSpan(columns: min(columns, raw.columns), rows: raw.rows)
            while !isFree(row, column, span) {
                column += 1
                if column + span.columns > columns { column = 0; row += 1 }
            }
            while occupied.count < row + span.rows { occupied.append(Array(repeating: false, count: columns)) }
            for r in row..<(row + span.rows) { for c in column..<(column + span.columns) { occupied[r][c] = true } }
            cells.append(Cell(row: row, column: column, span: span))
            column += span.columns
            if column >= columns { column = 0; row += 1 }
        }
        self.cells = cells
        rowCount = occupied.count
    }

    /// Single-row cells set row heights first; a taller multi-row cell then
    /// adds its deficit to the last row it spans.
    func rowHeights(itemHeights: [CGFloat], rowSpacing: CGFloat) -> [CGFloat] {
        var heights = Array(repeating: CGFloat.zero, count: rowCount)
        for (index, cell) in cells.enumerated() where cell.span.rows == 1 {
            heights[cell.row] = max(heights[cell.row], itemHeights[index])
        }
        for (index, cell) in cells.enumerated() where cell.span.rows > 1 {
            let rows = cell.row..<(cell.row + cell.span.rows)
            let available = rows.reduce(0) { $0 + heights[$1] } + rowSpacing * CGFloat(cell.span.rows - 1)
            if itemHeights[index] > available { heights[rows.upperBound - 1] += itemHeights[index] - available }
        }
        return heights
    }
}
