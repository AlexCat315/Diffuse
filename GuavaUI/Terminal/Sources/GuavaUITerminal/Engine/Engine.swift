// The only file family that talks to libghostty-vt. Ghostty types never cross
// the module boundary; callers see `TerminalFrame` snapshots and byte arrays.
//
// The engine is confined to one thread (the UI thread in production). Ghostty
// callbacks run synchronously inside `feed`, so they can safely reach `self`
// through the unretained userdata pointer.

internal import GhosttyVt

final class TerminalEngine {
    /// Bytes the terminal answers on its own (DSR, DA, mode reports...).
    var onReply: (([UInt8]) -> Void)?
    var onBell: (() -> Void)?
    var onTitleChange: ((String) -> Void)?

    private(set) var columns: Int
    private(set) var rows: Int
    /// Cell size in points, as last reported to Ghostty (image and mouse geometry).
    private(set) var cellSize = (width: 8, height: 16)

    /// Shared with the `TerminalEngine` extensions in this directory.
    let terminal: GhosttyTerminal
    let selection: SelectionGesture
    let mouse = MouseEncoder()
    private let renderState: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    private let keys: KeyEncoder

    init(columns: Int, rows: Int, scrollbackLines: Int) {
        self.columns = Self.clampDimension(columns)
        self.rows = Self.clampDimension(rows)
        var terminal: GhosttyTerminal?
        var renderState: GhosttyRenderState?
        var rowIterator: GhosttyRenderStateRowIterator?
        var rowCells: GhosttyRenderStateRowCells?
        Self.check(ghostty_terminal_new(nil, &terminal, UInt16(self.columns), UInt16(self.rows)), "terminal")
        Self.check(ghostty_render_state_new(nil, &renderState), "render state")
        Self.check(ghostty_render_state_row_iterator_new(nil, &rowIterator), "row iterator")
        Self.check(ghostty_render_state_row_cells_new(nil, &rowCells), "row cells")
        self.terminal = terminal!
        self.renderState = renderState!
        self.rowIterator = rowIterator!
        self.rowCells = rowCells!
        keys = KeyEncoder()
        selection = SelectionGesture()

        var lines = max(0, scrollbackLines)
        ghostty_terminal_set(self.terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        var blink = true
        ghostty_terminal_set(self.terminal, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink)
        enableImages()
        installCallbacks()
    }

    deinit {
        selection.free(terminal: terminal)
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    // MARK: Input

    /// Feed program output.
    func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let columns = Self.clampDimension(columns), rows = Self.clampDimension(rows)
        let cell = (width: max(1, cellWidth), height: max(1, cellHeight))
        guard columns != self.columns || rows != self.rows || cell != cellSize else { return }
        self.columns = columns
        self.rows = rows
        cellSize = cell
        ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows), UInt32(cell.width), UInt32(cell.height))
    }

    /// Bytes for a key press in the terminal's current keyboard modes.
    func encode(_ key: TerminalKey) -> [UInt8] {
        keys.encode(key, terminal: terminal)
    }

    /// Paste payload framed for the current bracketed-paste mode, with
    /// control bytes that could escape the paste neutralised.
    func encodePaste(_ text: String) -> [UInt8] {
        var data = Array(text.utf8)
        guard !data.isEmpty else { return [] }
        let bracketed = isModeSet(2004)
        var needed = 0
        return data.withUnsafeMutableBufferPointer { input -> [UInt8] in
            input.withMemoryRebound(to: CChar.self) { chars in
                _ = ghostty_paste_encode(chars.baseAddress, chars.count, bracketed, nil, 0, &needed)
                var output = [CChar](repeating: 0, count: needed)
                var written = 0
                guard ghostty_paste_encode(chars.baseAddress, chars.count, bracketed,
                                           &output, output.count, &written) == GHOSTTY_SUCCESS else { return [] }
                return output.prefix(written).map { UInt8(bitPattern: $0) }
            }
        }
    }

    // MARK: Viewport

    func scroll(rows delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Full-screen programs (vim, less, htop) run on the alternate screen,
    /// which has no scrollback; wheel input then belongs to the program.
    var isAlternateScreen: Bool { isModeSet(1049) || isModeSet(1047) || isModeSet(47) }

    var title: String {
        var value = GhosttyString()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS,
              let pointer = value.ptr, value.len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: value.len), as: UTF8.self)
    }

    func setDefaultColors(foreground: TerminalRGB, background: TerminalRGB) {
        var fg = GhosttyColorRgb(r: foreground.r, g: foreground.g, b: foreground.b)
        var bg = GhosttyColorRgb(r: background.r, g: background.g, b: background.b)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
    }

    // MARK: Snapshot

    func snapshot() -> TerminalFrame {
        Self.check(ghostty_render_state_update(renderState, terminal), "render update")
        let reader = FrameReader(renderState: renderState, rowIterator: rowIterator, rowCells: rowCells)
        var frame = reader.read(columns: columns, rows: rows)
        frame.scroll = scrollPosition()
        frame.images = imagePlacements() + placeholderPlacements(frame.placeholders)
        var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
        return frame
    }

    private func scrollPosition() -> TerminalScrollPosition {
        var bar = GhosttyTerminalScrollbar()
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar) == GHOSTTY_SUCCESS else {
            return TerminalScrollPosition(total: rows, offset: 0, visible: rows)
        }
        return TerminalScrollPosition(total: Int(bar.total), offset: Int(bar.offset), visible: Int(bar.len))
    }

    // MARK: Private

    func isModeSet(_ number: UInt16, ansi: Bool = false) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(number, ansi), value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    private func installCallbacks() {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata)

        let reply: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            let engine = Unmanaged<TerminalEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.onReply?(Array(UnsafeBufferPointer(start: data, count: length)))
        }
        let bell: GhosttyTerminalBellFn = { _, userdata in
            guard let userdata else { return }
            Unmanaged<TerminalEngine>.fromOpaque(userdata).takeUnretainedValue().onBell?()
        }
        let title: GhosttyTerminalTitleChangedFn = { _, userdata in
            guard let userdata else { return }
            let engine = Unmanaged<TerminalEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.onTitleChange?(engine.title)
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(reply, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
    }

    private static func clampDimension(_ value: Int) -> Int {
        min(Int(UInt16.max), max(1, value))
    }

    private static func check(_ result: GhosttyResult, _ what: StaticString) {
        precondition(result == GHOSTTY_SUCCESS, "libghostty-vt: \(what) failed (\(result.rawValue))")
    }
}
