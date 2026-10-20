internal import GuavaUIRuntime

/// Decides what a pointer gesture means on the terminal:
///
/// - The program asked for mouse reports → report it (hold Shift to select instead).
/// - ⌘-click on an OSC 8 hyperlink → open the link.
/// - Otherwise → select text (drag, double-click word, triple-click line).
///
/// The wheel scrolls the scrollback, or is reported/turned into arrow keys
/// for full-screen programs.
final class PointerRouter {
    private enum Gesture { case none, selecting, reporting(TerminalMouseEvent.Button) }
    private var gesture = Gesture.none
    private var wheelRows: Float = 0

    func reset() {
        gesture = .none
        wheelRows = 0
    }

    func down(_ event: MouseButtonEvent, node: Node, state: SurfaceState) -> Bool {
        guard let session = state.session, let pointer = state.gridPointer(x: event.x, y: event.y) else { return false }
        FocusChainHolder.current?.focus(node)
        let modifiers = Self.modifiers(event.modifiers)
        if session.engine.isMouseTracking, !event.modifiers.hasShift, let button = Self.button(event.button) {
            gesture = .reporting(button)
            session.report(session.engine.encode(TerminalMouseEvent(action: .press, button: button,
                x: Float(pointer.x), y: Float(pointer.y), modifiers: modifiers)))
            PointerCaptureHolder.current?.acquire(node)
            return true
        }
        guard event.button == .left else { return true }
        if event.modifiers.hasGui, let link = session.engine.hyperlink(column: pointer.column, row: pointer.row),
           let url = LinkOpener.url(link) {
            state.openLink(url)
            return true
        }
        gesture = .selecting
        if session.engine.select(.press, at: pointer) { session.invalidate() }
        PointerCaptureHolder.current?.acquire(node)
        return true
    }

    func motion(_ event: MouseMotionEvent, node: Node, state: SurfaceState) -> Bool {
        guard let session = state.session, let pointer = state.gridPointer(x: event.x, y: event.y) else { return false }
        switch gesture {
        case .selecting:
            // Dragging past the top or bottom edge scrolls the history.
            let edge = Float(event.y) - Float(node.absoluteOrigin.y)
            if edge < 0 { session.scroll(rows: -1) } else if edge > Float(node.frame.height) { session.scroll(rows: 1) }
            if session.engine.select(.drag, at: pointer) { session.invalidate() }
            return true
        case .reporting(let button):
            report(.motion, button: button, pointer: pointer, session: session)
            return true
        case .none:
            if session.engine.isMouseTracking {
                report(.motion, button: nil, pointer: pointer, session: session)
                node.cursor = .arrow
            } else {
                node.cursor = session.frame[pointer.row, pointer.column].isHyperlink ? .pointer : .ibeam
            }
            return false
        }
    }

    func up(_ event: MouseButtonEvent, node: Node, state: SurfaceState) -> Bool {
        defer {
            gesture = .none
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
        }
        guard let session = state.session, let pointer = state.gridPointer(x: event.x, y: event.y) else { return false }
        switch gesture {
        case .selecting:
            session.engine.select(.release, at: pointer)
        case .reporting(let button):
            report(.release, button: button, pointer: pointer, session: session)
        case .none:
            return false
        }
        return true
    }

    func wheel(_ event: MouseWheelEvent, state: SurfaceState) -> Bool {
        guard let session = state.session, let metrics = state.metrics else { return false }
        wheelRows += event.displacement(lineStep: metrics.height).y / metrics.height
        let rows = Int(wheelRows.rounded(.towardZero))
        guard rows != 0 else { return true }
        wheelRows -= Float(rows)
        let steps = min(abs(rows), 50)
        if session.engine.isMouseTracking,
           let pointer = state.gridPointer(x: event.mouseX ?? 0, y: event.mouseY ?? 0) {
            for _ in 0..<steps {
                report(.press, button: rows > 0 ? .wheelUp : .wheelDown, pointer: pointer, session: session)
            }
        } else if session.isAlternateScreen {
            let key = TerminalKey(scancode: rows > 0 ? 82 : 81)
            for _ in 0..<steps { session.press(key) }
        } else {
            session.scroll(rows: -rows)
        }
        return true
    }

    private func report(_ action: TerminalMouseEvent.Action, button: TerminalMouseEvent.Button?,
                        pointer: TerminalPointer, session: TerminalSession) {
        session.report(session.engine.encode(TerminalMouseEvent(action: action, button: button,
                                                                x: Float(pointer.x), y: Float(pointer.y))))
    }

    private static func button(_ button: MouseButton) -> TerminalMouseEvent.Button? {
        switch button {
        case .left: .left
        case .middle: .middle
        case .right: .right
        case .x1, .x2: nil
        }
    }

    private static func modifiers(_ modifiers: KeyModifiers) -> TerminalKey.Modifiers {
        var result: TerminalKey.Modifiers = []
        if modifiers.hasShift { result.insert(.shift) }
        if modifiers.hasCtrl { result.insert(.control) }
        if modifiers.hasAlt { result.insert(.option) }
        return result
    }
}
