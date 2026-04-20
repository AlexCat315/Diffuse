import CoreGraphics
import EngineKernel
import GuavaUIRuntime

/// Single-line text input. Routes IME / printable text through the
/// `textInput` handler, and routes editing keys (backspace, delete, arrows,
/// home/end) through the `key` handler. Auto-focuses on click.
///
/// v1 limitations:
/// - Single line only (Enter fires `onSubmit` but is otherwise ignored).
/// - Cursor is rendered as a 1px vertical line; no selection range.
/// - State (cursor index, scroll offset) lives in a captured reference and
///   is lost on recompose; an explicit `@State` cursor is a Phase 6.4c task.
/// - Reads from `TextEnvironment` for shaping; without one installed the
///   field still accepts input but renders no glyphs.
public struct TextField: _PrimitiveView {

    public let text: Binding<String>
    public let placeholder: String
    public let onSubmit: (() -> Void)?
    public let textColor: Color?
    public let placeholderColor: Color
    public let cursorColor: Color

    public init(_ placeholder: String = "",
                text: Binding<String>,
                onSubmit: (() -> Void)? = nil,
                textColor: Color? = nil,
                placeholderColor: Color = Color(r: 0.55, g: 0.55, b: 0.6),
                cursorColor: Color = Color.white) {
        self.text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.cursorColor = cursorColor
    }

    /// Per-instance editing state. Lives on the captured closures so it
    /// persists across redraws without recompose.
    final class FieldState {
        /// Cursor index measured in `Character` units from the start of `text`.
        var cursorIndex: Int = 0
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    public func _updateNode(_ node: Node) {
        let state = FieldState()
        let snapshot = self
        // Initial cursor at end of current text.
        state.cursorIndex = snapshot.text.wrappedValue.count

        // ── Text input (IME / printable characters) ──
        if let registry = InteractionRegistryHolder.current {
            registry.setText(node) { incoming, _ in
                snapshot.insert(incoming, state: state)
                return .handled
            }

            // ── Editing keys ──
            registry.setKey(node) { event, _ in
                snapshot.handleKey(event, state: state) ? .handled : .ignored
            }
        }

        // ── Custom draw ──
        node.draw = { list, origin in
            snapshot.render(node: node, state: state, list: list, origin: origin)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = 28
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.height = 28
    }

    // MARK: - Editing

    private func insert(_ s: String, state: FieldState) {
        guard !s.isEmpty else { return }
        var current = text.wrappedValue
        let idx = current.index(current.startIndex,
                                offsetBy: clamp(state.cursorIndex, 0, current.count))
        current.insert(contentsOf: s, at: idx)
        text.wrappedValue = current
        state.cursorIndex += s.count
    }

    private func handleKey(_ event: KeyEvent, state: FieldState) -> Bool {
        // Only act on key-down and key-repeat. Up events are inert here.
        // (EventDispatcher delivers both as `.key` — we use `isRepeat` only
        // to allow held-down editing keys to repeat, not to filter ups.)
        var current = text.wrappedValue
        let count = current.count
        // SDL3 SDL_Scancode values for editing keys.
        switch event.scancode {
        case 42: // BACKSPACE
            guard state.cursorIndex > 0 else { return true }
            let removeAt = current.index(current.startIndex, offsetBy: state.cursorIndex - 1)
            current.remove(at: removeAt)
            text.wrappedValue = current
            state.cursorIndex -= 1
            return true
        case 76: // DELETE
            guard state.cursorIndex < count else { return true }
            let removeAt = current.index(current.startIndex, offsetBy: state.cursorIndex)
            current.remove(at: removeAt)
            text.wrappedValue = current
            return true
        case 80: // LEFT
            state.cursorIndex = max(0, state.cursorIndex - 1)
            return true
        case 79: // RIGHT
            state.cursorIndex = min(count, state.cursorIndex + 1)
            return true
        case 74: // HOME
            state.cursorIndex = 0
            return true
        case 77: // END
            state.cursorIndex = count
            return true
        case 40, 88: // RETURN, KP_ENTER
            onSubmit?()
            return true
        default:
            return false
        }
    }

    // MARK: - Render

    private func render(node: Node, state: FieldState, list: DrawList, origin: CGPoint) {
        guard let env = TextEnvironmentHolder.current else { return }
        let isFocused = (FocusChainHolder.current?.focused === node)
        let current = text.wrappedValue
        let displayText = current.isEmpty ? placeholder : current
        let renderColor: Color =
            current.isEmpty
                ? placeholderColor
                : (textColor ?? node.foregroundColor ?? env.defaultColor)

        let glyphs = env.shaper.shape(text: displayText)
        let result = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: displayText,
            atlas: env.atlas,
            maxWidth: .infinity,
            lineHeight: env.defaultLineHeight,
            alignment: .leading
        )

        list.addText(result,
                     origin: (Float(origin.x), Float(origin.y)),
                     color: renderColor,
                     textureID: env.atlasTextureID)

        // Cursor — only when focused and editing real (not placeholder) text.
        guard isFocused else { return }
        let cursorX = self.cursorX(in: current,
                                   upTo: clamp(state.cursorIndex, 0, current.count),
                                   env: env)
        let cursorRect = UIRect(
            x: Float(origin.x) + cursorX,
            y: Float(origin.y),
            width: 1,
            height: env.defaultLineHeight
        )
        list.addRect(cursorRect, color: cursorColor)
    }

    /// Width of `text` shaped from index 0 up to `count` characters. Used to
    /// place the cursor. Re-shapes each frame; v1 simplicity over caching.
    private func cursorX(in text: String, upTo count: Int, env: TextEnvironment) -> Float {
        guard count > 0 else { return 0 }
        let endIdx = text.index(text.startIndex, offsetBy: count)
        let prefix = String(text[text.startIndex..<endIdx])
        let glyphs = env.shaper.shape(text: prefix)
        let layout = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: prefix,
            atlas: env.atlas,
            maxWidth: .infinity,
            lineHeight: env.defaultLineHeight,
            alignment: .leading
        )
        return layout.totalWidth
    }
}

@inline(__always)
private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}
