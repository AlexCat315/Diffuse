internal import GhosttyVt

/// A pointer event as reported to the program (xterm mouse tracking).
struct TerminalMouseEvent: Equatable, Sendable {
    enum Action: Equatable, Sendable { case press, release, motion }
    enum Button: Equatable, Sendable { case left, middle, right, wheelUp, wheelDown, wheelLeft, wheelRight }

    var action: Action
    /// `nil` for motion with no button held.
    var button: Button?
    /// Points from the grid's top-left corner.
    var x: Float
    var y: Float
    var modifiers: TerminalKey.Modifiers = []
}

/// Wraps Ghostty's mouse encoder; the tracking mode and wire format (X10,
/// UTF-8, SGR, urxvt, SGR-pixels) come from the terminal's live modes.
final class MouseEncoder {
    private let encoder: GhosttyMouseEncoder
    private let event: GhosttyMouseEvent

    init() {
        var encoder: GhosttyMouseEncoder?
        var event: GhosttyMouseEvent?
        precondition(ghostty_mouse_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS, "libghostty-vt: mouse encoder failed")
        precondition(ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS, "libghostty-vt: mouse event failed")
        self.encoder = encoder!
        self.event = event!
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    func encode(_ mouse: TerminalMouseEvent, terminal: GhosttyTerminal,
                columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) -> [UInt8] {
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
        var size = sized(GhosttyMouseEncoderSize())
        size.screen_width = UInt32(columns * cellWidth)
        size.screen_height = UInt32(rows * cellHeight)
        size.cell_width = UInt32(cellWidth)
        size.cell_height = UInt32(cellHeight)
        ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)

        switch mouse.action {
        case .press: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS)
        case .release: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_RELEASE)
        case .motion: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_MOTION)
        }
        if let button = mouse.button {
            ghostty_mouse_event_set_button(event, Self.button(button))
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        var mods: GhosttyMods = 0
        if mouse.modifiers.contains(.shift) { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if mouse.modifiers.contains(.control) { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if mouse.modifiers.contains(.option) { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        ghostty_mouse_event_set_mods(event, mods)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: mouse.x, y: mouse.y))

        var buffer = [CChar](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &written) == GHOSTTY_SUCCESS else { return [] }
        return buffer.prefix(written).map { UInt8(bitPattern: $0) }
    }

    private static func button(_ button: TerminalMouseEvent.Button) -> GhosttyMouseButton {
        switch button {
        case .left: GHOSTTY_MOUSE_BUTTON_LEFT
        case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
        case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
        case .wheelUp: GHOSTTY_MOUSE_BUTTON_FOUR
        case .wheelDown: GHOSTTY_MOUSE_BUTTON_FIVE
        case .wheelLeft: GHOSTTY_MOUSE_BUTTON_SIX
        case .wheelRight: GHOSTTY_MOUSE_BUTTON_SEVEN
        }
    }
}

extension TerminalEngine {
    /// Whether the program asked for mouse reports (modes 9/1000/1002/1003).
    var isMouseTracking: Bool {
        var tracking = false
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) == GHOSTTY_SUCCESS && tracking
    }

    func encode(_ event: TerminalMouseEvent) -> [UInt8] {
        mouse.encode(event, terminal: terminal, columns: columns, rows: rows,
                     cellWidth: cellSize.width, cellHeight: cellSize.height)
    }
}
