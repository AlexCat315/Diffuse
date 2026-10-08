/// Persistent run tree mapping logical lines to visual rows. Unmeasured lines
/// start at one row; measuring a wrapped line replaces only its search path.
/// Text edits splice the affected lines, retaining measurements on both sides.
struct TextVisualLineIndex {
    private var root: VisualLineNode
    init(lineCount: Int) { root = VisualLineNode(lines: max(1, lineCount), rowsPerLine: 1) }
    var lineCount: Int { root.lines }
    var rowCount: Int { root.rows }
    var height: Int { root.height }

    func firstRow(ofLine index: Int) -> Int { root.rows(beforeLine: min(lineCount, max(0, index))) }
    func location(atRow row: Int) -> (line: Int, subrow: Int) {
        root.location(atRow: min(rowCount - 1, max(0, row)))
    }
    mutating func measure(line: Int, rows: Int) {
        guard line >= 0, line < lineCount else { return }
        let count = max(1, rows)
        if firstRow(ofLine: line + 1) - firstRow(ofLine: line) == count { return }
        replace(lines: line..<(line + 1), withLineCount: 1, rowsPerLine: count)
    }
    mutating func replace(lines range: Range<Int>, withLineCount count: Int) {
        replace(lines: range, withLineCount: max(1, count), rowsPerLine: 1)
    }
    private mutating func replace(lines range: Range<Int>, withLineCount count: Int, rowsPerLine: Int) {
        let lower = min(lineCount, max(0, range.lowerBound))
        let upper = min(lineCount, max(lower, range.upperBound))
        let (before, rest) = root.split(atLine: lower)
        let (_, after) = rest.split(atLine: upper - lower)
        root = VisualLineNode.join(VisualLineNode.join(before, VisualLineNode(lines: count, rowsPerLine: rowsPerLine)), after)
    }
}

private final class VisualLineNode: Sendable {
    private enum Storage: Sendable {
        case run(rowsPerLine: Int)
        case branch(VisualLineNode, VisualLineNode)
    }
    private let storage: Storage
    let lines: Int
    let rows: Int
    let height: Int
    private static let empty = VisualLineNode(lines: 0, rowsPerLine: 1)

    init(lines: Int, rowsPerLine: Int) {
        storage = .run(rowsPerLine: rowsPerLine)
        self.lines = lines; rows = lines * rowsPerLine; height = lines == 0 ? 0 : 1
    }
    private init(_ left: VisualLineNode, _ right: VisualLineNode) {
        storage = .branch(left, right); lines = left.lines + right.lines
        rows = left.rows + right.rows; height = max(left.height, right.height) + 1
    }
    func rows(beforeLine index: Int) -> Int {
        switch storage {
        case .run(let count): return index * count
        case .branch(let left, let right):
            return index <= left.lines ? left.rows(beforeLine: index) : left.rows + right.rows(beforeLine: index - left.lines)
        }
    }
    func location(atRow row: Int) -> (line: Int, subrow: Int) {
        switch storage {
        case .run(let count): return (row / count, row % count)
        case .branch(let left, let right):
            if row < left.rows { return left.location(atRow: row) }
            let result = right.location(atRow: row - left.rows)
            return (left.lines + result.line, result.subrow)
        }
    }
    func split(atLine index: Int) -> (VisualLineNode, VisualLineNode) {
        if index <= 0 { return (.empty, self) }
        if index >= lines { return (self, .empty) }
        switch storage {
        case .run(let count): return (VisualLineNode(lines: index, rowsPerLine: count), VisualLineNode(lines: lines - index, rowsPerLine: count))
        case .branch(let left, let right):
            if index < left.lines {
                let (first, rest) = left.split(atLine: index)
                return (first, Self.join(rest, right))
            }
            let (first, rest) = right.split(atLine: index - left.lines)
            return (Self.join(left, first), rest)
        }
    }
    static func join(_ left: VisualLineNode, _ right: VisualLineNode) -> VisualLineNode {
        if left.lines == 0 { return right }
        if right.lines == 0 { return left }
        if case .run(let a) = left.storage, case .run(let b) = right.storage, a == b {
            return VisualLineNode(lines: left.lines + right.lines, rowsPerLine: a)
        }
        if left.height > right.height + 1, case .branch(let a, let b) = left.storage { return balanced(a, join(b, right)) }
        if right.height > left.height + 1, case .branch(let a, let b) = right.storage { return balanced(join(left, a), b) }
        return VisualLineNode(left, right)
    }
    private static func balanced(_ left: VisualLineNode, _ right: VisualLineNode) -> VisualLineNode {
        if left.height > right.height + 1, case .branch(let a, let b) = left.storage {
            if a.height >= b.height { return VisualLineNode(a, VisualLineNode(b, right)) }
            if case .branch(let c, let d) = b.storage { return VisualLineNode(VisualLineNode(a, c), VisualLineNode(d, right)) }
        }
        if right.height > left.height + 1, case .branch(let a, let b) = right.storage {
            if b.height >= a.height { return VisualLineNode(VisualLineNode(left, a), b) }
            if case .branch(let c, let d) = a.storage { return VisualLineNode(VisualLineNode(left, c), VisualLineNode(d, b)) }
        }
        return VisualLineNode(left, right)
    }
}
