import EditorCore
import StudioDocuments
import GuavaUI

/// Every text format uses the same workspace for open/edit/save/conflicts.
/// Markdown adds a presentation; it does not own another file lifecycle.
struct DocumentEditingSurface: View {
    private let model: EditorDocumentWorkspace
    private let path: String
    private let observed: Observed<EditorDocumentWorkspace, [TextDocument]>
    @State private var source = DocumentBuffer()

    init(model: EditorDocumentWorkspace, path: String) {
        self.model = model
        self.path = path
        observed = Observed(\.documents, on: model)
    }

    var body: some View {
        let document = observed.wrappedValue.first { $0.path == path }
        let _ = source.synchronize(document?.text ?? "")
        let binding = Binding(get: { source.buffer }, set: { buffer in
            model.edit(path, text: source.edit(buffer))
        })
        return editing(binding).id(source.generation).flex().frame(minWidth: 0, minHeight: 0)
    }

    @ViewBuilder private func editing(_ text: Binding<TextBuffer>) -> some View {
        if path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown") {
            MarkdownEditor(text: text, sourceTitle: L("Source code"), previewTitle: L("Preview"))
        } else {
            TextField(L("Source code"), text: text) { input in
                input.layout.axis = .vertical
                input.layout.wrapsLines = false
                input.layout.maxVisibleLines = 80
                input.codeEditing.showsLineNumbers = true
                input.codeEditing.indentationWidth = 4
            }.textFieldStyle(.editor).font(.monospaced(size: 15)).lineHeight(24)
        }
    }
}

/// Adapts the workspace's String boundary to the shared Rope editor. External
/// reloads reset the editing session; save/status updates keep its identity.
private final class DocumentBuffer {
    private var text: String?
    private(set) var buffer = TextBuffer.empty
    private(set) var generation = 0

    func synchronize(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        buffer = TextBuffer(text)
        generation += 1
    }

    func edit(_ buffer: TextBuffer) -> String {
        self.buffer = buffer
        let text = buffer.stringValue
        self.text = text
        return text
    }
}
