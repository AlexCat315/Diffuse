/// 8-bit sRGB color as resolved by the VT engine.
struct TerminalRGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// SGR attributes that change how a cell is painted.
struct TerminalCellAttributes: OptionSet, Equatable, Sendable {
    let rawValue: UInt8
    static let bold = TerminalCellAttributes(rawValue: 1 << 0)
    static let italic = TerminalCellAttributes(rawValue: 1 << 1)
    static let faint = TerminalCellAttributes(rawValue: 1 << 2)
    static let underline = TerminalCellAttributes(rawValue: 1 << 3)
    static let strikethrough = TerminalCellAttributes(rawValue: 1 << 4)
    static let inverse = TerminalCellAttributes(rawValue: 1 << 5)
    static let invisible = TerminalCellAttributes(rawValue: 1 << 6)
    /// SGR 5/6: the text blinks (the cell background does not).
    static let blink = TerminalCellAttributes(rawValue: 1 << 7)
}

/// One grid column. A wide glyph occupies its own cell plus a following
/// `spacer` cell, so column indices always equal grid positions.
struct TerminalCell: Equatable, Sendable {
    enum Width: UInt8, Sendable { case narrow, wide, spacer }

    /// Full grapheme cluster; empty for blank cells.
    var text: String = ""
    var width: Width = .narrow
    /// `nil` means the terminal default color.
    var foreground: TerminalRGB?
    var background: TerminalRGB?
    var attributes: TerminalCellAttributes = []
    var isSelected = false
    /// Part of an OSC 8 hyperlink.
    var isHyperlink = false

    static let blank = TerminalCell()
}

struct TerminalCursor: Equatable, Sendable {
    enum Shape: Equatable, Sendable { case bar, block, underline, hollowBlock }

    /// False when hidden by the program (DECTCEM) or scrolled out of view.
    var isVisible = true
    var column = 0
    var row = 0
    var shape: Shape = .block
    var isBlinking = false
}

/// Viewport position inside the scrollback, in rows.
struct TerminalScrollPosition: Equatable, Sendable {
    var total = 0
    var offset = 0
    var visible = 0

    var isAtBottom: Bool { offset + visible >= total }
}

/// Render-ready snapshot of the viewport. Captured on the UI thread after the
/// engine consumed output, then painted without touching the engine again.
struct TerminalFrame: Equatable, Sendable {
    var columns: Int
    var rows: Int
    /// Row-major cells, `columns * rows` long.
    var cells: [TerminalCell]
    var cursor = TerminalCursor()
    var foreground = TerminalRGB(r: 0xFF, g: 0xFF, b: 0xFF)
    var background = TerminalRGB(r: 0, g: 0, b: 0)
    var scroll = TerminalScrollPosition()
    /// Kitty graphics placements in draw order.
    var images: [TerminalImagePlacement] = []
    /// Kitty Unicode placeholder cells; their images are part of `images`.
    var placeholders: [PlaceholderCell] = []

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        cells = Array(repeating: .blank, count: columns * rows)
    }

    subscript(row: Int, column: Int) -> TerminalCell {
        cells[row * columns + column]
    }

    func row(_ index: Int) -> ArraySlice<TerminalCell> {
        cells[index * columns ..< (index + 1) * columns]
    }

    /// Plain text of one row with trailing blanks trimmed.
    func text(ofRow index: Int) -> String {
        var result = ""
        for cell in row(index) where cell.width != .spacer {
            result += cell.text.isEmpty ? " " : cell.text
        }
        while result.last == " " { result.removeLast() }
        return result
    }
}
