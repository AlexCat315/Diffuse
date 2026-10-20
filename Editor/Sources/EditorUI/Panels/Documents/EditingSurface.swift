internal import EditorCore
internal import StudioDocuments
internal import GuavaUI

/// Every text format uses the same workspace for open/edit/save/conflicts.
/// Markdown adds a presentation; it does not own another file lifecycle.
struct DocumentEditingSurface: View {
    private let model: EditorDocumentWorkspace
    private let path: String
    private let observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    @State private var source = DocumentBuffer()
    @State private var syntax = ScriptSyntaxSession()

    init(model: EditorDocumentWorkspace, path: String) {
        self.model = model
        self.path = path
        observed = Observed(\.snapshot, on: model)
    }

    var body: some View {
        let document = observed.wrappedValue.documents.first { $0.path == path }
        let _ = source.synchronize(document?.text ?? "")
        let binding = Binding(get: { source.buffer }, set: { buffer in
            model.edit(path, text: source.edit(buffer))
        })
        return editing(binding).id(source.generation).flex().frame(minWidth: 0, minHeight: 0)
    }

    @ViewBuilder private func editing(_ text: Binding<TextBuffer>) -> some View {
        if path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown") {
            MarkdownEditor(text: text, sourceTitle: L("Source code"), previewTitle: L("Preview"),
                           sourceFont: .monospaced(size: 13), sourceLineHeight: 20)
        } else if DocumentKind(path: path).name == "Swift" {
            // Swift files share the script editor's tree-sitter colors and folding.
            ScriptSyntaxReader(syntax) { syntax in
                ThemeReader { theme in
                    let light = theme.colors.surfaceSunken.r > 0.5
                    let _ = syntax.request(text.wrappedValue)
                    code(text) { input in
                        input.codeEditing.syntaxRevision = syntax.revision
                        input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in syntax.color(atUTF8Offset: offset, light: light) }
                        input.codeEditing.folding.regions = syntax.foldRegions
                        input.codeEditing.folding.isReady = syntax.parsedBuffer == text.wrappedValue
                    }
                }
            }
        } else {
            code(text) { _ in }
        }
    }

    private func code(_ text: Binding<TextBuffer>, configure: (inout TextField) -> Void) -> some View {
        TextField(L("Source code"), text: text) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = false
            input.layout.maxVisibleLines = 80
            input.codeEditing.showsLineNumbers = true
            input.codeEditing.indentationWidth = 4
            configure(&input)
        }.textFieldStyle(.editor).font(.monospaced(size: 13)).lineHeight(20)
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
