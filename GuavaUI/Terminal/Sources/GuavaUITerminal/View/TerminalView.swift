public import GuavaUICompose
internal import GuavaUIRuntime

/// Shows a `TerminalSession`, starting it if it is still idle, and forwards
/// keyboard, IME, paste and wheel input to it. The grid fills the space the
/// view is given; the program is told the new size whenever layout changes.
///
/// Default colors follow the theme's surface colors; programs can still set
/// their own palette. Click to focus. ⌘V pastes; other ⌘ shortcuts stay with
/// the host.
public struct TerminalView: View {
    let session: TerminalSession
    let fontSize: Float

    public init(session: TerminalSession, fontSize: Float = 13) {
        self.session = session
        self.fontSize = fontSize.isFinite ? min(72, max(6, fontSize)) : 13
    }

    public var body: some View {
        TerminalSurface(session: session, font: .monospaced(size: fontSize))
    }
}

private struct TerminalSurface: _PrimitiveView {
    let session: TerminalSession
    let font: Font

    func _makeNode() -> Node {
        let node = Node()
        node.isFocusable = true
        node.clipsToBounds = true
        node.addResource(TerminalLink())
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexGrow = 1
        layout.flexShrink = 1
        layout.minWidth = 0
        layout.minHeight = 0
        return layout
    }

    var _children: [any View] { [] }

    func _updateNode(_ node: Node) {
        let link = node.firstResource(TerminalLink.self)!
        link.bind(session)
        let colors = node.theme.colors
        session.setDefaultColors(foreground: TerminalRGB(colors.onSurface), background: TerminalRGB(colors.surface))
        installInput(on: node, link: link)

        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node, weak link] focused in
            if !focused { link?.preedit = "" }
            node?.markRenderDirty(reason: .focusChange)
        }
        let resolveArea: TextInputAreaResolver = { [weak link] _, origin in
            guard let link, let metrics = link.metrics else { return nil }
            let cursor = link.session?.frame.cursor ?? TerminalCursor()
            let x = Float(origin.x) + Float(cursor.column) * metrics.width
            let y = Float(origin.y) + Float(cursor.row) * metrics.height
            return TextInputArea(x: x, y: y, width: metrics.width, height: metrics.height, cursorX: x)
        }
        node.attachments[TextInputAttachmentKey.areaResolver] = resolveArea

        let font = font
        node.draw = { [weak node, weak link] list, origin in
            guard let node, let link, let session = link.session,
                  let environment = TextEnvironmentHolder.current else { return }
            let metrics = CellMetrics(font: font, environment: environment)
            link.metrics = metrics
            let grid = metrics.grid(width: Float(node.frame.width), height: Float(node.frame.height))
            session.fit(columns: grid.columns, rows: grid.rows,
                        cellWidth: Int(metrics.width.rounded()), cellHeight: Int(metrics.height))
            let painter = TerminalPainter(frame: session.frame, metrics: metrics, environment: environment,
                                          isFocused: FocusChainHolder.current?.focused === node,
                                          opacity: node.opacity, preedit: link.preedit)
            painter.paint(into: list, bounds: UIRect(x: Float(origin.x), y: Float(origin.y),
                                                     width: Float(node.frame.width), height: Float(node.frame.height)))
        }
    }

    private func installInput(on node: Node, link: TerminalLink) {
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { [weak node] event, phase, _ in
            guard phase == .down, event.button == .left, let node else { return .ignored }
            FocusChainHolder.current?.focus(node)
            return .handled
        }
        registry.setKey(node, route: .textInput) { [weak link] event, phase in
            guard phase != .capture, let session = link?.session else { return .ignored }
            switch KeyRouting(event) {
            case .text: return .handled
            case .host: return .ignored
            case .paste:
                if let text = ClipboardHolder.read?(), !text.isEmpty { session.paste(text) }
                return .handled
            case .encode(let key):
                return session.press(key) ? .handled : .ignored
            }
        }
        registry.setText(node, route: .textInput) { [weak node, weak link] text, _ in
            guard let link, let session = link.session else { return .ignored }
            link.preedit = ""
            session.send(text)
            node?.markRenderDirty(reason: .styleSet(field: "terminal.preedit"))
            return .handled
        }
        registry.setEditing(node, route: .textInput) { [weak node, weak link] event, _ in
            guard let link else { return .ignored }
            link.preedit = event.text
            node?.markRenderDirty(reason: .styleSet(field: "terminal.preedit"))
            return .handled
        }
        registry.setWheel(node) { [weak link] event, _ in
            guard let link else { return .ignored }
            return link.scroll(event) ? .handled : .ignored
        }
    }
}

/// Node-owned glue: observes the session while mounted and keeps per-view
/// input state (IME preedit, fractional wheel travel).
private final class TerminalLink: NodeResource {
    private(set) var session: TerminalSession?
    private weak var node: Node?
    var metrics: CellMetrics?
    var preedit = ""
    private var wheelRows: Float = 0

    func mount(node: Node) {
        self.node = node
        observe()
    }

    func unmount(node: Node) {
        session?.removeObserver(self)
        self.node = nil
    }

    func bind(_ session: TerminalSession) {
        guard self.session !== session else { return }
        self.session?.removeObserver(self)
        self.session = session
        preedit = ""
        wheelRows = 0
        observe()
    }

    /// Scrollback on the normal screen; arrow keys for full-screen programs.
    func scroll(_ event: MouseWheelEvent) -> Bool {
        guard let session, let metrics else { return false }
        wheelRows += event.displacement(lineStep: metrics.height).y / metrics.height
        let rows = Int(wheelRows.rounded(.towardZero))
        guard rows != 0 else { return true }
        wheelRows -= Float(rows)
        if session.isAlternateScreen {
            let key = TerminalKey(scancode: rows > 0 ? 82 : 81)
            for _ in 0..<min(abs(rows), 50) { session.press(key) }
        } else {
            session.scroll(rows: -rows)
        }
        return true
    }

    private func observe() {
        guard let node, let session else { return }
        // Failures land in `status` and on screen; nothing to rethrow here.
        if session.status == .idle { try? session.start() }
        session.observe(self) { [weak node] in node?.markRenderDirty(reason: .styleSet(field: "terminal.frame")) }
        node.markRenderDirty(reason: .styleSet(field: "terminal.session"))
    }
}

private extension TerminalRGB {
    init(_ color: Color) {
        func channel(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        self.init(r: channel(color.r), g: channel(color.g), b: channel(color.b))
    }
}
