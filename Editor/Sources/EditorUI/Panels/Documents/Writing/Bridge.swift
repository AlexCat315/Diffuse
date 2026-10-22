internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// How a Markdown document is shown: source only, side by side, or preview.
enum MarkdownLayout: String, CaseIterable {
    case source, split, preview

    var title: String {
        switch self {
        case .source: "Source"
        case .split: "Split"
        case .preview: "Preview"
        }
    }
}

/// Connects the writing bar, the status line and the AI actions to the open
/// editor. The editing surface reports its buffer, caret and commit path here;
/// commands edit through it so the editor keeps its undo history and caret.
final class DocumentWritingSession: _ObservableObject {
    struct State: Equatable {
        var caret = TextFieldCaretState.initial
        var markdownLayout = MarkdownLayout.split
        var wrapsLines = true
        /// A one-shot caret placement; the id makes repeats distinct.
        var caretRequest: CaretRequest?
    }

    struct CaretRequest: Equatable {
        let id: Int
        let index: Int
    }

    private let publisher = _ObservablePublisher<DocumentWritingSession>()
    private(set) var state = State()
    /// The open editor's text and the way to replace it, installed by the surface.
    private(set) var buffer = TextBuffer.empty
    private var commit: ((TextBuffer) -> Void)?

    private var path: String?

    /// Called while rendering the front document: a different document starts
    /// with its caret at the top. Layout choices carry over between documents.
    func show(_ path: String) {
        guard path != self.path else { return }
        self.path = path
        state.caret = .initial
        state.caretRequest = nil
    }

    func attach(buffer: TextBuffer, commit: @escaping (TextBuffer) -> Void) {
        self.buffer = buffer
        self.commit = commit
    }

    func update(_ change: (inout State) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        publisher.send()
    }

    /// The selection, or an empty range at the caret.
    var selection: Range<Int> {
        let count = buffer.characterCount
        if let range = state.caret.selectedRange, !range.isEmpty {
            return min(range.lowerBound, count)..<min(range.upperBound, count)
        }
        let caret = min(state.caret.caretIndex, count)
        return caret..<caret
    }

    var selectedText: String { buffer.substring(characterRange: selection) }

    func apply(_ format: MarkdownFormat) {
        let edit = format.edit(in: buffer, selection: selection)
        replace(edit.range, with: edit.replacement, caret: edit.caret)
    }

    /// Replaces `range` and places the caret, as one undoable edit.
    func replace(_ range: Range<Int>, with text: String, caret: Int? = nil) {
        guard let commit else { return }
        let next = buffer.replace(characterRange: range, with: text)
        buffer = next
        commit(next)
        moveCaret(to: caret ?? range.lowerBound + text.count)
    }

    func moveCaret(to index: Int) {
        update { $0.caretRequest = CaretRequest(id: ($0.caretRequest?.id ?? 0) + 1, index: index) }
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
