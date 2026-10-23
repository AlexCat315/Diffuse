internal import EditorCore
internal import StudioDocuments
internal import GuavaUI

/// Every text format uses the same workspace for open/edit/save/conflicts and
/// the same editing surface: monospaced, line numbers, minimap and wrapping.
/// Language services add colour and folding; they never introduce another
/// editor or another chrome.
struct DocumentEditingSurface: View {
    private let model: EditorDocumentWorkspace
    private let app: EditorApplication?
    private let path: String
    private let session: DocumentWritingSession
    private let observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private let writing: Observed<DocumentWritingSession, DocumentWritingSession.State>
    @State private var source = DocumentBuffer()
    @State private var syntax = ScriptSyntaxSession()
    @State private var documentSyntax: DocumentSyntaxSession

    init(model: EditorDocumentWorkspace, app: EditorApplication?, path: String, session: DocumentWritingSession) {
        self.model = model
        self.app = app
        self.path = path
        self.session = session
        observed = Observed(\.snapshot, on: model)
        writing = Observed(\.state, on: session)
        _documentSyntax = State(wrappedValue: DocumentSyntaxSession(
            languageID: DocumentKind(path: path).languageID
        ))
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
        if kind.languageID == "swift" {
            // Swift files share the script editor's tree-sitter colors and folding.
            ScriptSyntaxReader(syntax) { syntax in
                ThemeReader { theme in
                    let light = theme.colors.surfaceSunken.r > 0.5
                    let _ = syntax.request(text.wrappedValue)
                    self.text(text, wraps: state.wrapsLines) { input in
                        input.codeEditing.syntaxRevision = syntax.revision
                        input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in syntax.color(atUTF8Offset: offset, light: light, palette: theme.extensions[EditorThemeTokens.self].syntax) }
                        input.codeEditing.folding.regions = syntax.foldRegions
                        input.codeEditing.folding.isReady = syntax.parsedBuffer == text.wrappedValue
                    }
                }
            }
        } else if !documentSyntax.isEmpty {
            // Plugin-declared grammar rules: the host matches them; nothing
            // enters the plugin host on the keystroke path.
            DocumentSyntaxReader(documentSyntax) { syntax in
                ThemeReader { theme in
                    let light = theme.colors.surfaceSunken.r > 0.5
                    let _ = syntax.request(text.wrappedValue)
                    self.text(text, wraps: state.wrapsLines) { input in
                        input.codeEditing.syntaxRevision = syntax.revision
                        input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in
                            syntax.color(atUTF8Offset: offset, light: light, palette: theme.extensions[EditorThemeTokens.self].syntax)
                        }
                    }
                }
            }
        } else {
            self.text(text, wraps: state.wrapsLines) { _ in }
        }
    }

    private func text(_ text: Binding<TextBuffer>, wraps: Bool, configure extra: (inout TextField) -> Void) -> some View {
        TextField(L("Start writing…"), text: text) { input in
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
        if kind.isMarkdown {
            input.events.onKeyDown = { event in
                guard let format = MarkdownFormat.allCases.first(where: { format in
                    format.shortcutLetter.map { EditorShortcut(.letter($0)).matches(event) } ?? false
                }) else { return false }
                session.apply(format)
                return true
            }
            return
        }
        guard let app, let languageID = kind.languageID,
              LanguageCatalog.format(forLanguageID: languageID) != nil else { return }
        input.events.onKeyDown = { event in
            guard EditorShortcut(.letter("f"), [.option, .shift]).matches(event) else { return false }
            let text = session.buffer.stringValue
            let caret = session.state.caret.caretIndex
            Task { @MainActor in
                do {
                    guard let formatted = try await app.formatDocument(languageID: languageID,
                                                                       text: text),
                          formatted != text else { return }
                    session.replace(0..<session.buffer.characterCount, with: formatted,
                                    caret: min(caret, formatted.count))
                } catch {
                    app.logConsole("Could not format document",
                                   severity: .error,
                                   detail: error.localizedDescription)
                }
            }
            return true
        }
    }
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
