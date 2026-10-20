internal import GuavaUICompose
internal import GuavaUIRuntime

/// Paints a `TerminalFrame` into a draw list.
///
/// Glyphs are laid out one cell at a time. Monospaced columns then stay exact
/// even where fallback fonts (CJK, emoji) have other advances, and the shared
/// layout cache is keyed by grapheme, not by ever-changing program output.
struct TerminalPainter {
    let frame: TerminalFrame
    let metrics: CellMetrics
    let environment: TextEnvironment
    let isFocused: Bool
    let opacity: Float
    /// IME composition shown at the cursor until committed.
    var preedit = ""

    /// `bounds` is the whole view: the partial cell left over at the right and
    /// bottom edges still takes the terminal background.
    func paint(into list: DrawList, bounds: UIRect) {
        let originX = bounds.x, originY = bounds.y
        list.addRect(bounds, color: color(frame.background))
        for row in 0..<frame.rows {
            let top = originY + Float(row) * metrics.height
            paintBackgrounds(row: row, top: top, x: originX, into: list)
            paintGlyphs(row: row, top: top, x: originX, into: list)
        }
        paintCursor(x: originX, y: originY, into: list)
    }

    private func paintBackgrounds(row: Int, top: Float, x originX: Float, into list: DrawList) {
        var runStart = 0
        var runColor: TerminalRGB?
        func flush(until end: Int) {
            guard let runColor, end > runStart else { return }
            list.addRect(UIRect(x: originX + Float(runStart) * metrics.width, y: top,
                                width: Float(end - runStart) * metrics.width, height: metrics.height),
                         color: color(runColor))
        }
        for column in 0..<frame.columns {
            let cell = frame[row, column]
            let fill = colors(of: cell).background
            let next = fill == frame.background ? nil : fill
            if next != runColor { flush(until: column); runStart = column; runColor = next }
        }
        flush(until: frame.columns)
    }

    private func paintGlyphs(row: Int, top: Float, x originX: Float, into list: DrawList) {
        for column in 0..<frame.columns {
            let cell = frame[row, column]
            guard cell.width != .spacer, !cell.attributes.contains(.invisible) else { continue }
            let left = originX + Float(column) * metrics.width
            let span = Float(cell.width == .wide ? 2 : 1) * metrics.width
            var foreground = color(colors(of: cell).foreground)
            if cell.attributes.contains(.faint) { foreground = foreground.multipliedAlpha(0.6) }
            if !cell.text.isEmpty, cell.text != " " {
                let layout = environment.cachedLayout(text: cell.text, font: font(for: cell), lineHeight: metrics.height)
                list.addText(layout, origin: (left, top), color: foreground,
                             textureID: environment.atlasTextureID, atlas: environment.atlas)
            }
            if cell.attributes.contains(.underline) {
                list.addRect(UIRect(x: left, y: top + metrics.height - 2, width: span, height: 1), color: foreground)
            }
            if cell.attributes.contains(.strikethrough) {
                list.addRect(UIRect(x: left, y: top + (metrics.height / 2).rounded(), width: span, height: 1),
                             color: foreground)
            }
        }
    }

    private func paintCursor(x originX: Float, y originY: Float, into list: DrawList) {
        let cursor = frame.cursor
        guard cursor.isVisible, cursor.row < frame.rows, cursor.column < frame.columns else { return }
        let cell = frame[cursor.row, cursor.column]
        let left = originX + Float(cursor.column) * metrics.width
        let top = originY + Float(cursor.row) * metrics.height
        let width = Float(cell.width == .wide ? 2 : 1) * metrics.width
        let ink = color(colors(of: cell).foreground)

        if !preedit.isEmpty {
            let layout = environment.cachedLayout(text: preedit, font: metrics.font, lineHeight: metrics.height)
            list.addRect(UIRect(x: left, y: top, width: max(width, layout.totalWidth), height: metrics.height),
                         color: color(frame.background))
            list.addText(layout, origin: (left, top), color: ink,
                         textureID: environment.atlasTextureID, atlas: environment.atlas)
            list.addRect(UIRect(x: left, y: top + metrics.height - 2, width: layout.totalWidth, height: 1), color: ink)
            return
        }
        guard isFocused else {
            list.addRoundedRectStroke(UIRect(x: left, y: top, width: width, height: metrics.height),
                                      radius: 0, width: 1, color: ink)
            return
        }
        switch cursor.shape {
        case .block:
            // The block covers the glyph painted earlier; repaint it inverted.
            list.addRect(UIRect(x: left, y: top, width: width, height: metrics.height), color: ink)
            if !cell.text.isEmpty, cell.text != " " {
                let layout = environment.cachedLayout(text: cell.text, font: font(for: cell), lineHeight: metrics.height)
                list.addText(layout, origin: (left, top), color: color(colors(of: cell).background),
                             textureID: environment.atlasTextureID, atlas: environment.atlas)
            }
        case .hollowBlock:
            list.addRoundedRectStroke(UIRect(x: left, y: top, width: width, height: metrics.height),
                                      radius: 0, width: 1, color: ink)
        case .bar:
            list.addRect(UIRect(x: left, y: top, width: 2, height: metrics.height), color: ink)
        case .underline:
            list.addRect(UIRect(x: left, y: top + metrics.height - 2, width: width, height: 2), color: ink)
        }
    }

    /// Effective colors after defaults, inverse video and selection.
    private func colors(of cell: TerminalCell) -> (foreground: TerminalRGB, background: TerminalRGB) {
        var foreground = cell.foreground ?? frame.foreground
        var background = cell.background ?? frame.background
        if cell.attributes.contains(.inverse) != cell.isSelected { swap(&foreground, &background) }
        return (foreground, background)
    }

    private func font(for cell: TerminalCell) -> Font {
        var font = metrics.font
        if cell.attributes.contains(.bold) { font = font.weight(.bold) }
        if cell.attributes.contains(.italic) { font = font.italic() }
        return font
    }

    private func color(_ rgb: TerminalRGB) -> Color {
        Color(red: rgb.r, green: rgb.g, blue: rgb.b).multipliedAlpha(opacity)
    }
}

