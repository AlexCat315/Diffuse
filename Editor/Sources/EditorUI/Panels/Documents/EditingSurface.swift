internal import EditorCore
internal import StudioDocuments
internal import GuavaUI

/// Every text format uses the same workspace for open/edit/save/conflicts.
/// Markdown adds a presentation; it does not own another file lifecycle.
/// Prose (Markdown source, plain text) gets a centred, wrapped writing column;
/// code keeps line numbers and a monospaced face.
struct DocumentEditingSurface: View {
    private let model: EditorDocumentWorkspace
    private let path: String
    private let session: DocumentWritingSession
    private let observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private let writing: Observed<DocumentWritingSession, DocumentWritingSession.State>
    @State private var source = DocumentBuffer()
    @State private var syntax = ScriptSyntaxSession()
    @State private var preview = DocumentPreviewSource()

    init(model: EditorDocumentWorkspace, path: String, session: DocumentWritingSession) {
        self.model = model
        self.path = path
        self.session = session
        observed = Observed(\.snapshot, on: model)
        writing = Observed(\.state, on: session)
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        let state = writing.wrappedValue
        let document = snapshot.documents.first { $0.path == path }
        let _ = source.synchronize(document?.text ?? "")
        let _ = source.navigate(reveal: snapshot.reveal?.path == path ? snapshot.reveal : nil, request: state.caretRequest)
        let model = model, path = path, source = source
        let _ = session.attach(buffer: source.buffer) { buffer in model.edit(path, text: source.edit(buffer)) }
        let binding = Binding(get: { source.buffer }, set: { buffer in
            model.edit(path, text: source.edit(buffer))
        })
        return editing(binding, state: state).id(source.generation).flex().frame(minWidth: 0, minHeight: 0)
    }

    private var kind: DocumentKind { DocumentKind(path: path) }

    @ViewBuilder private func editing(_ text: Binding<TextBuffer>, state: DocumentWritingSession.State) -> some View {
        if kind.isMarkdown {
            switch state.markdownLayout {
            case .split:
                MarkdownEditor(text: text, sourceTitle: L("Source code"), previewTitle: L("Preview"),
                               sourceFont: .monospaced(size: 13), sourceLineHeight: 20,
                               configureSource: { configure(&$0) })
            case .source:
                prose(text, state: state)
            case .preview:
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .row, alignItems: .flexStart, justifyContent: .center) {
                        MarkdownView(preview.string(for: text.wrappedValue))
                            .padding(horizontal: 32, vertical: 28).frame(minWidth: 0, maxWidth: 820).flex(1, shrink: 1)
                    }.frame(width: .percent(100), minWidth: 0)
                }.accessibility { $0.label = L("Preview") }.debugName("document-preview")
            }
        } else if kind.isProse {
            prose(text, state: state)
        } else if kind.name == "Swift" {
            // Swift files share the script editor's tree-sitter colors and folding.
            ScriptSyntaxReader(syntax) { syntax in
                ThemeReader { theme in
                    let light = theme.colors.surfaceSunken.r > 0.5
                    let _ = syntax.request(text.wrappedValue)
                    code(text, wraps: state.wrapsLines) { input in
                        input.codeEditing.syntaxRevision = syntax.revision
                        input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in syntax.color(atUTF8Offset: offset, light: light) }
                        input.codeEditing.folding.regions = syntax.foldRegions
                        input.codeEditing.folding.isReady = syntax.parsedBuffer == text.wrappedValue
                    }
                }
            }
        } else {
            code(text, wraps: state.wrapsLines) { _ in }
        }
    }

    /// A readable measure: wrapped lines no wider than a book page, centred.
    private func prose(_ text: Binding<TextBuffer>, state: DocumentWritingSession.State) -> some View {
        Box(direction: .row, alignItems: .stretch, justifyContent: .center) {
            TextField(L("Start writing…"), text: text) { input in
                input.layout.axis = .vertical
                input.layout.wrapsLines = true
                input.layout.maxVisibleLines = 80
                input.codeEditing.indentationWidth = 2
                configure(&input)
            }.textFieldStyle(.editor).font(.system(size: 15)).lineHeight(26)
                .padding(horizontal: 24, vertical: 20)
                .flex(1, shrink: 1).frame(minWidth: 0, minHeight: 0, maxWidth: 820)
                .debugName("document-prose")
        }.flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
    }

    private func code(_ text: Binding<TextBuffer>, wraps: Bool, configure extra: (inout TextField) -> Void) -> some View {
        TextField(L("Source code"), text: text) { input in
            input.layout.axis = .vertical
            input.layout.wrapsLines = wraps
            input.layout.maxVisibleLines = 80
            input.codeEditing.showsLineNumbers = true
            input.codeEditing.showsMinimap = true
            input.codeEditing.indentationWidth = 4
            configure(&input)
            extra(&input)
        }.textFieldStyle(.editor).font(.monospaced(size: 13)).lineHeight(20)
    }

    /// Caret reporting, outline jumps and formatting shortcuts for any field.
    private func configure(_ input: inout TextField) {
        let session = session
        input.events.onCaretChange = { caret in session.update { $0.caret = caret } }
        if let request = source.caretRequest {
            input.navigation.caretRequestID = request.id
            input.navigation.caretRequestIndex = request.index
        }
        guard kind.isMarkdown else { return }
        input.events.onKeyDown = { event in
            guard let format = MarkdownFormat.allCases.first(where: { format in
                format.shortcutLetter.map { EditorShortcut(.letter($0)).matches(event) } ?? false
            }) else { return false }
            session.apply(format)
            return true
        }
    }
}

extension DocumentKind {
    /// Formats written as prose rather than code.
    var isProse: Bool { isMarkdown || name == "Plain Text" || name == "LaTeX" }
}

/// Adapts the workspace's String boundary to the shared Rope editor. External
/// reloads reset the editing session; save/status updates keep its identity.
private final class DocumentBuffer {
    private var text: String?
    private(set) var buffer = TextBuffer.empty
    private(set) var generation = 0
    private var revealID: Int?
    private var requestID: Int?
    /// The newest caret placement from the outline or a writing command.
    private(set) var caretRequest: (id: String, index: Int)?

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

    func navigate(reveal: EditorDocumentReveal?, request: DocumentWritingSession.CaretRequest?) {
        if let reveal, reveal.id != revealID {
            revealID = reveal.id
            caretRequest = ("reveal-\(reveal.id)", reveal.characterIndex)
        }
        if let request, request.id != requestID {
            requestID = request.id
            caretRequest = ("write-\(request.id)", request.index)
        }
    }
}

/// Materializes the Rope for the preview only when its revision changes.
private final class DocumentPreviewSource {
    private var buffer: TextBuffer?
    private var source = ""

    func string(for buffer: TextBuffer) -> String {
        if self.buffer != buffer {
            self.buffer = buffer
            source = buffer.stringValue
        }
        return source
    }
}
