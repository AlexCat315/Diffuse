internal import GhosttyVt

/// Grid position in the visible viewport plus the surface point it came from.
struct TerminalPointer: Equatable, Sendable {
    var column: Int
    var row: Int
    /// Points from the grid's top-left corner.
    var x: Double
    var y: Double
    /// Monotonic time; lets Ghostty recognise double and triple clicks.
    var nanoseconds: UInt64 = 0
}

/// Ghostty's selection gesture state machine: single click places an anchor,
/// drag extends it, double click selects a word and triple click a line.
final class SelectionGesture {
    private let gesture: GhosttySelectionGesture
    private let press: GhosttySelectionGestureEvent
    private let drag: GhosttySelectionGestureEvent
    private let release: GhosttySelectionGestureEvent

    init() {
        func event(_ type: GhosttySelectionGestureEventType) -> GhosttySelectionGestureEvent {
            var event: GhosttySelectionGestureEvent?
            precondition(ghostty_selection_gesture_event_new(nil, &event, type) == GHOSTTY_SUCCESS,
                         "libghostty-vt: selection event failed")
            return event!
        }
        var gesture: GhosttySelectionGesture?
        precondition(ghostty_selection_gesture_new(nil, &gesture) == GHOSTTY_SUCCESS, "libghostty-vt: selection gesture failed")
        self.gesture = gesture!
        press = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS)
        drag = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG)
        release = event(GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE)
        var interval: UInt64 = 500_000_000
        ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
    }

    /// The gesture borrows terminal state, so the engine frees it first.
    func free(terminal: GhosttyTerminal) {
        ghostty_selection_gesture_event_free(release)
        ghostty_selection_gesture_event_free(drag)
        ghostty_selection_gesture_event_free(press)
        ghostty_selection_gesture_free(gesture, terminal)
    }

    /// Feeds one pointer phase; returns the selection to install, `.clear`
    /// when the gesture removes it, or `nil` when nothing changes.
    func apply(_ phase: Phase, at pointer: TerminalPointer, rectangle: Bool, columns: Int, rows: Int,
               cellWidth: Int, cellHeight: Int, terminal: GhosttyTerminal) -> Outcome? {
        var ref = sized(GhosttyGridRef())
        let point = GhosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT,
                                 value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(
                                    x: UInt16(clamping: min(max(0, pointer.column), columns - 1)),
                                    y: UInt32(clamping: min(max(0, pointer.row), rows - 1)))))
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var position = GhosttySurfacePosition(x: pointer.x, y: pointer.y)
        let event: GhosttySelectionGestureEvent
        switch phase {
        case .press:
            event = press
            var time = pointer.nanoseconds
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            var distance = Double(max(cellWidth, cellHeight))
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        case .drag:
            event = drag
            var geometry = GhosttySelectionGestureGeometry(columns: UInt32(columns), cell_width: UInt32(cellWidth),
                                                           padding_left: 0, screen_height: UInt32(rows * cellHeight))
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
            var block = rectangle
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &block)
        case .release:
            event = release
        }
        ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
        if phase != .release {
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
        }
        var selection = sized(GhosttySelection())
        switch ghostty_selection_gesture_event(gesture, terminal, event, &selection) {
        case GHOSTTY_SUCCESS: return .select(selection)
        case GHOSTTY_NO_VALUE: return phase == .press ? .clear : nil
        default: return nil
        }
    }

    enum Phase { case press, drag, release }

    enum Outcome {
        case select(GhosttySelection)
        case clear
    }
}

extension TerminalEngine {
    /// Applies a pointer phase to the selection; returns whether it changed.
    /// `rectangle` selects a block of columns instead of running text.
    @discardableResult
    func select(_ phase: SelectionGesture.Phase, at pointer: TerminalPointer, rectangle: Bool = false) -> Bool {
        guard let outcome = selection.apply(phase, at: pointer, rectangle: rectangle, columns: columns, rows: rows,
                                            cellWidth: cellSize.width, cellHeight: cellSize.height,
                                            terminal: terminal) else { return false }
        switch outcome {
        case .select(var range):
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &range)
            return true
        case .clear:
            return clearSelection()
        }
    }

    @discardableResult
    func clearSelection() -> Bool {
        guard hasSelection else { return false }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        return true
    }

    var hasSelection: Bool {
        var range = sized(GhosttySelection())
        return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &range) == GHOSTTY_SUCCESS
    }

    /// Plain text of the selection, soft wraps joined and trailing blanks trimmed.
    var selectedText: String? {
        var range = sized(GhosttySelection())
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &range) == GHOSTTY_SUCCESS else { return nil }
        return withUnsafePointer(to: &range) { pointer -> String? in
            var options = sized(GhosttyTerminalSelectionFormatOptions())
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            options.selection = pointer
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, options, &bytes, &length) == GHOSTTY_SUCCESS
            else { return nil }
            defer { ghostty_free(nil, bytes, length) }
            guard let bytes, length > 0 else { return "" }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        }
    }
}
