public import Foundation
public import GuavaUICompose
internal import GuavaUIRuntime

/// Shows a `TerminalSession`, starting it if it is still idle. The grid fills
/// the space the view is given; the program is told the new size whenever
/// layout changes.
///
/// - Keyboard and IME text go to the program; ⌘C copies the selection and ⌘V
///   pastes. Other ⌘ shortcuts stay with the host.
/// - Drag selects (double-click a word, triple-click a line). Programs that
///   ask for mouse reports receive the pointer instead; hold Shift to select.
/// - ⌘-click opens OSC 8 hyperlinks with `onOpenLink`, by default the system.
/// - Kitty graphics images are drawn in place; the cursor blinks while focused.
///
/// Default colors follow the theme's surface colors; programs can still set
/// their own palette.
public struct TerminalView: View {
    let session: TerminalSession
    let fontSize: Float
    let onOpenLink: ((URL) -> Void)?

    public init(session: TerminalSession, fontSize: Float = 13, onOpenLink: ((URL) -> Void)? = nil) {
        self.session = session
        self.fontSize = fontSize.isFinite ? min(72, max(6, fontSize)) : 13
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        TerminalSurface(session: session, font: .monospaced(size: fontSize), onOpenLink: onOpenLink)
    }
}

private struct TerminalSurface: _PrimitiveView {
    let session: TerminalSession
    let font: Font
    let onOpenLink: ((URL) -> Void)?

    func _makeNode() -> Node {
        let node = Node()
        node.isFocusable = true
        node.clipsToBounds = true
        node.cursor = .ibeam
        node.addResource(SurfaceState())
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        // Fill both axes of any stack: grow along it, stretch across it.
        layout.flexGrow = 1
        layout.flexShrink = 1
        layout.alignSelf = .stretch
        // Without a sized container the terminal still shows a few rows.
        layout.minWidth = 0
        layout.minHeight = (font.size * 1.3 * 4).rounded(.up)
        return layout
    }

    var _children: [any View] { [] }

    func _updateNode(_ node: Node) {
        let state = node.firstResource(SurfaceState.self)!
        state.bind(session)
        state.openLink = onOpenLink ?? LinkOpener.open
        let colors = node.theme.colors
        session.setDefaultColors(foreground: TerminalRGB(colors.onSurface), background: TerminalRGB(colors.surface))
        installInput(on: node, state: state)

        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak state] focused in
            if !focused { state?.preedit = "" }
            state?.blink.restart()
            state?.redraw()
        }
        let resolveArea: TextInputAreaResolver = { [weak state] _, origin in
            guard let state, let metrics = state.metrics else { return nil }
            let cursor = state.session?.frame.cursor ?? TerminalCursor()
            let x = Float(origin.x) + Float(cursor.column) * metrics.width
            let y = Float(origin.y) + Float(cursor.row) * metrics.height
            return TextInputArea(x: x, y: y, width: metrics.width, height: metrics.height, cursorX: x)
        }
        node.attachments[TextInputAttachmentKey.areaResolver] = resolveArea

        let font = font
        node.draw = { [weak node, weak state] list, origin in
            guard let node, let state, let session = state.session,
                  let environment = TextEnvironmentHolder.current else { return }
            let metrics = CellMetrics(font: font, environment: environment)
            state.metrics = metrics
            let grid = metrics.grid(width: Float(node.frame.width), height: Float(node.frame.height))
            session.fit(columns: grid.columns, rows: grid.rows,
                        cellWidth: Int(metrics.width.rounded()), cellHeight: Int(metrics.height))
            let frame = session.frame
            let isFocused = FocusChainHolder.current?.focused === node
            state.blink.update(active: isFocused && frame.cursor.isBlinking && !node.prefersReducedMotion)
            let images = state.textures.resolve(frame.images) { session.engine.imagePixels($0) }
            for (_, asset) in images { list.retainResource(asset) }
            let painter = TerminalPainter(frame: frame, metrics: metrics, environment: environment,
                                          isFocused: isFocused, opacity: node.opacity, preedit: state.preedit,
                                          isCursorShown: state.blink.isVisible,
                                          images: images.map { ($0.0, $0.1.textureID) },
                                          cellPixels: session.engine.cellSize)
            painter.paint(into: list, bounds: UIRect(x: Float(origin.x), y: Float(origin.y),
                                                     width: Float(node.frame.width), height: Float(node.frame.height)))
        }
    }

    private func installInput(on node: Node, state: SurfaceState) {
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { [weak node, weak state] event, phase, _ in
            guard let node, let state else { return .ignored }
            let handled = phase == .down ? state.pointer.down(event, node: node, state: state)
                                         : state.pointer.up(event, node: node, state: state)
            return handled ? .handled : .ignored
        }
        registry.setMotion(node) { [weak node, weak state] event, _ in
            guard let node, let state else { return .ignored }
            return state.pointer.motion(event, node: node, state: state) ? .handled : .ignored
        }
        registry.setWheel(node) { [weak state] event, _ in
            guard let state else { return .ignored }
            return state.pointer.wheel(event, state: state) ? .handled : .ignored
        }
        registry.setKey(node, route: .textInput) { [weak state] event, phase in
            guard phase != .capture, let state, let session = state.session else { return .ignored }
            // While an input method composes, Return, Backspace and arrows
            // edit the composition; the program must not see them.
            guard state.preedit.isEmpty else { return .handled }
            state.blink.restart()
            switch KeyRouting(event) {
            case .text: return .handled
            case .host: return .ignored
            case .paste:
                if let text = ClipboardHolder.read?(), !text.isEmpty { session.paste(text) }
                return .handled
            case .copy:
                guard let text = session.engine.selectedText, !text.isEmpty else { return .ignored }
                ClipboardHolder.write?(text)
                return .handled
            case .encode(let key):
                return session.press(key) ? .handled : .ignored
            }
        }
        registry.setText(node, route: .textInput) { [weak state] text, _ in
            guard let state, let session = state.session else { return .ignored }
            state.preedit = ""
            state.blink.restart()
            session.send(text)
            return .handled
        }
        registry.setEditing(node, route: .textInput) { [weak state] event, _ in
            guard let state else { return .ignored }
            state.preedit = event.text
            return .handled
        }
    }
}

private extension TerminalRGB {
    init(_ color: Color) {
        func channel(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        self.init(r: channel(color.r), g: channel(color.g), b: channel(color.b))
    }
}
