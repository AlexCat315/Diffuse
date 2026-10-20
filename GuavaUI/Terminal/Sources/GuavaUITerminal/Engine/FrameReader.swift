internal import GhosttyVt

/// Copies one updated Ghostty render state into a `TerminalFrame`.
///
/// Ghostty "sized" structs are rejected unless their `size` field matches the
/// Swift layout, so every such struct is initialised through `sized(_:)`.
struct FrameReader {
    let renderState: GhosttyRenderState
    let rowIterator: GhosttyRenderStateRowIterator
    let rowCells: GhosttyRenderStateRowCells

    func read(columns: Int, rows: Int) -> TerminalFrame {
        var frame = TerminalFrame(columns: columns, rows: rows)
        var colors = sized(GhosttyRenderStateColors())
        if ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) == GHOSTTY_SUCCESS {
            frame.foreground = rgb(colors.foreground)
            frame.background = rgb(colors.background)
        }
        frame.cursor = cursor()

        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS
        else { return frame }
        var y = 0
        while y < rows, ghostty_render_state_row_iterator_next(rowIterator) {
            readRow(y, into: &frame)
            y += 1
        }
        return frame
    }

    private func readRow(_ y: Int, into frame: inout TerminalFrame) {
        var cells: GhosttyRenderStateRowCells? = rowCells
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
        else { return }
        var selection = sized(GhosttyRenderStateRowSelection())
        let selected: ClosedRange<Int>? =
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
            ? Int(selection.start_x)...Int(selection.end_x) : nil
        var x = 0
        while x < frame.columns, ghostty_render_state_row_cells_next(rowCells) {
            var cell = readCell()
            cell.isSelected = selected?.contains(x) ?? false
            frame.cells[y * frame.columns + x] = cell
            x += 1
        }
    }

    private func readCell() -> TerminalCell {
        var cell = TerminalCell()
        var raw: GhosttyCell = 0
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
            var wide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            var link = false
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &link)
            cell.isHyperlink = link
            switch wide {
            case GHOSTTY_CELL_WIDE_WIDE: cell.width = .wide
            case GHOSTTY_CELL_WIDE_SPACER_TAIL, GHOSTTY_CELL_WIDE_SPACER_HEAD: cell.width = .spacer
            default: cell.width = .narrow
            }
        }
        cell.text = graphemes()

        var color = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS {
            cell.foreground = rgb(color)
        }
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == GHOSTTY_SUCCESS {
            cell.background = rgb(color)
        }

        var styled = false
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
        guard styled else { return cell }
        var style = sized(GhosttyStyle())
        guard ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS
        else { return cell }
        if style.bold { cell.attributes.insert(.bold) }
        if style.italic { cell.attributes.insert(.italic) }
        if style.faint { cell.attributes.insert(.faint) }
        if style.underline != 0 { cell.attributes.insert(.underline) }
        if style.strikethrough { cell.attributes.insert(.strikethrough) }
        if style.inverse { cell.attributes.insert(.inverse) }
        if style.invisible { cell.attributes.insert(.invisible) }
        return cell
    }

    private func graphemes() -> String {
        var count: UInt32 = 0
        ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &count)
        guard count > 0 else { return "" }
        var codepoints = [UInt32](repeating: 0, count: Int(count))
        let result = codepoints.withUnsafeMutableBufferPointer {
            ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress)
        }
        guard result == GHOSTTY_SUCCESS else { return "" }
        var text = String.UnicodeScalarView()
        for codepoint in codepoints { if let scalar = Unicode.Scalar(codepoint) { text.append(scalar) } }
        return String(text)
    }

    private func cursor() -> TerminalCursor {
        var state = sized(GhosttyRenderStateCursor())
        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR, &state) == GHOSTTY_SUCCESS else {
            return TerminalCursor(isVisible: false)
        }
        let shape: TerminalCursor.Shape
        switch state.visual_style {
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR: shape = .bar
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE: shape = .underline
        case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW: shape = .hollowBlock
        default: shape = .block
        }
        return TerminalCursor(isVisible: state.visible && state.viewport_has_value,
                              column: Int(state.viewport_x), row: Int(state.viewport_y),
                              shape: shape, isBlinking: state.blinking)
    }

    private func rgb(_ color: GhosttyColorRgb) -> TerminalRGB {
        TerminalRGB(r: color.r, g: color.g, b: color.b)
    }
}
