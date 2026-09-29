#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

/// Where the pointer is resting inside a ``TextField``, in editor terms.
///
/// A text input measures offsets in `Character` units; higher layers (language
/// servers, for example) need line/UTF-16 columns and a screen position has to
/// be known before anything can anchor a popup. Both are reported here so each
/// consumer converts once rather than guessing at another layer's unit.
public struct TextFieldHoverAnchor: Hashable, Sendable {
    /// Offset in `Character` units from the start of the bound text.
    public let characterIndex: Int
    /// Window-space pointer position, matching the coordinate space used for
    /// overlay drawing.
    public let windowX: Float
    public let windowY: Float

    public init(characterIndex: Int, windowX: Float, windowY: Float) {
        self.characterIndex = characterIndex
        self.windowX = windowX
        self.windowY = windowY
    }
}

/// Current caret and selection, reported whenever either moves.
public struct TextFieldCaretState: Hashable, Sendable {
    /// Caret offset in `Character` units; for a selection this is the moving end.
    public let caretIndex: Int
    /// Half-open `[low, high)` selection, or `nil` when collapsed.
    public let selectedRange: Range<Int>?

    public init(caretIndex: Int, selectedRange: Range<Int>?) {
        self.caretIndex = caretIndex
        self.selectedRange = selectedRange
    }

    public static let initial = TextFieldCaretState(caretIndex: 0, selectedRange: nil)
}

extension TextField {
    /// Publishes a hover position change. `nil` clears the hover so any popup
    /// anchored to the previous position can dismiss itself.
    func reportHover(_ anchor: TextFieldHoverAnchor?) {
        onHoverChange?(anchor)
    }

    /// Publishes caret / selection movement.
    ///
    /// Indices are re-clamped first: the bound text can be rewritten from
    /// outside an interaction (switching edits another file, for instance), and
    /// forwarding a stale offset would crash downstream index math.
    func notifyCaretChange(_ state: FieldState) {
        guard let handler = onCaretChange else { return }
        normalizeIndices(state)
        handler(TextFieldCaretState(caretIndex: state.cursorIndex,
                                    selectedRange: selectionRange(state)))
    }
}
