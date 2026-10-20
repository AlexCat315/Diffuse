internal import Foundation
internal import GuavaUIRuntime

/// Node-owned glue between one terminal surface and its session: observes
/// the session while mounted and keeps per-view state (IME preedit, pointer
/// gestures, cursor blink, image textures).
final class SurfaceState: NodeResource {
    private(set) var session: TerminalSession?
    private(set) weak var node: Node?
    /// Cell size of the last paint; input waits for it.
    var metrics: CellMetrics?
    /// IME composition shown at the cursor until committed.
    var preedit = "" { didSet { if preedit != oldValue { redraw() } } }
    var openLink: (URL) -> Void = LinkOpener.open
    let pointer = PointerRouter()
    let blink = CursorBlink()
    let textures = ImageTextures()

    func mount(node: Node) {
        self.node = node
        blink.onToggle = { [weak self] in self?.redraw() }
        observe()
    }

    func unmount(node: Node) {
        session?.removeObserver(self)
        blink.stop()
        textures.removeAll()
        self.node = nil
    }

    func bind(_ session: TerminalSession) {
        guard self.session !== session else { return }
        self.session?.removeObserver(self)
        self.session = session
        preedit = ""
        pointer.reset()
        textures.removeAll()
        observe()
    }

    /// Grid position under a window-space point, clamped to the grid.
    func gridPointer(x: Float, y: Float) -> TerminalPointer? {
        guard let node, let metrics, let session else { return nil }
        let origin = node.absoluteOrigin
        let localX = Double(x) - Double(origin.x), localY = Double(y) - Double(origin.y)
        let frame = session.frame
        let column = min(frame.columns - 1, max(0, Int(localX / Double(metrics.width))))
        let row = min(frame.rows - 1, max(0, Int(localY / Double(metrics.height))))
        // Ghostty measures in the integer cell size it was given.
        let scaleX = Double(session.engine.cellSize.width) / Double(metrics.width)
        let scaleY = Double(session.engine.cellSize.height) / Double(metrics.height)
        return TerminalPointer(column: column, row: row, x: localX * scaleX, y: localY * scaleY,
                               nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func redraw() {
        node?.markRenderDirty(reason: .styleSet(field: "terminal.surface"))
    }

    private func observe() {
        guard node != nil, let session else { return }
        // Failures land in `status` and on screen; nothing to rethrow here.
        if session.status == .idle { try? session.start() }
        session.observe(self) { [weak self] in
            self?.blink.restart()
            self?.redraw()
        }
        redraw()
    }
}
