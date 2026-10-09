import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// The Swift script editing surface.
///
/// Owns exactly one thing: turning text-field signals into requests the panel
/// can act on. The document lives in ScriptWorkspaceModel; this view retains
/// only the parser cache for its current immutable buffer revision.
struct ScriptCodeEditor: View {
    let source: Binding<TextBuffer>
    let hover: Binding<ScriptEditorHoverPresentation>
    let caretLabel: Binding<String>
    let onChange: (TextBuffer) -> Void
    @State private var syntaxSession = ScriptSyntaxSession()
    @State private var diagnosticCache = ScriptCodeEditorDiagnostics()
    @State private var diagnosticHover: ScriptDiagnosticHover?
    var diagnostics: [ScriptLanguageDiagnostic] = []
    var completionProvider: TextCompletionProvider?
    var editHistory: TextEditHistory? = nil
    var navigation: EditorScriptNavigationRequest? = nil
    /// Pointer rests on a character worth documenting.
    let onHover: (TextFieldHoverAnchor) -> Void
    /// Pointer left the field; any pending popup must go away.
    let onHoverEnd: () -> Void

    var body: some View {
        let text = source.wrappedValue
        let mappedDiagnostics = diagnosticCache.synchronize(buffer: text, diagnostics: diagnostics)
        ScriptSyntaxReader(syntaxSession) { syntaxSession in
        ThemeReader { theme in
            let light = theme.colors.surfaceSunken.r > 0.5
            let _ = syntaxSession.request(text)
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                TextField("", text: source) { input in
                    input.layout.axis = .vertical
                    input.layout.wrapsLines = false
                    input.layout.maxVisibleLines = 48
                    input.codeEditing.showsLineNumbers = true
                    input.codeEditing.diagnostics = mappedDiagnostics
                    input.codeEditing.onRequestCompletion = completionProvider
                    input.codeEditing.onRequestHover = { anchor in handleHover(anchor) }
                    input.codeEditing.indentationWidth = 4
                    input.codeEditing.editHistory = editHistory
                    input.codeEditing.lineNumberColor = theme.colors.onSurfaceMuted
                    input.codeEditing.lineNumberGutterColor = theme.colors.surface
                    input.codeEditing.syntaxRevision = syntaxSession.revision
                    input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in syntaxSession.color(atUTF8Offset: offset, light: light) }
                    input.navigation.caretRequestID = navigation.map { AnyHashable($0.id) }
                    input.navigation.caretRequestIndex = navigation.map {
                        ScriptSourceCoordinates.characterIndex(in: text,
                            at: ScriptLanguagePosition(line: $0.line, character: $0.column))
                    }
                    input.events.onChange = onChange
                    input.events.onHoverChange = { anchor in handleHover(anchor) }
                    input.events.onCaretChange = { state in handleCaret(state, in: source.wrappedValue) }
                    input.events.onKeyDown = { event in
                        guard event.scancode == ComposeScancode.escape,
                              diagnosticHover != nil || hover.wrappedValue != .hidden else { return false }
                        handleHover(nil); return true
                    }
                    input.decoration.textColor = theme.colors.onSurface
                    input.decoration.cursorColor = theme.colors.onSurface
                    input.decoration.selectionColor = theme.colors.selection
                }
                .textFieldStyle(ScriptCodeEditorTextFieldStyle())
                .font(.mono)
                .frame(minHeight: 0)
                .padding(horizontal: 4, vertical: 4)
                .background(.surfaceSunken)
                .flex(1, shrink: 1)

                // Contributes no layout; the popup is painted through the tooltip
                // pass so the editor's own clipping never trims it.
                if let diagnosticHover, diagnosticHover.buffer == text {
                    Tooltip(anchor: diagnosticHover.anchor, configure: { $0.maxWidth = 380 }) {
                        Text(diagnosticHover.message).font(.caption).foregroundColor(.onSurface)
                            .padding(10).background(.surfaceFloating).cornerRadius(6).border(.border, width: 1)
                    }
                }
                ScriptHoverOverlay(presentation: hover.wrappedValue)

            }
            .clipped()
        }
    }

    }

    private func handleHover(_ anchor: TextFieldHoverAnchor?) {
        guard let anchor else {
            diagnosticHover = nil
            hover.wrappedValue = .hidden
            onHoverEnd()
            return
        }
        let buffer = source.wrappedValue
        let byte = buffer.utf8Offset(forCharacterIndex: anchor.characterIndex)
        if let diagnostic = diagnosticCache.mapped.overlapping(byte..<(byte + 1)).first {
            diagnosticHover = ScriptDiagnosticHover(buffer: buffer,
                anchor: .point(CGPoint(x: CGFloat(anchor.windowX), y: CGFloat(anchor.windowY))), message: diagnostic.message)
            hover.wrappedValue = .hidden; onHoverEnd()
        } else { diagnosticHover = nil; onHover(anchor) }
    }

    private func handleCaret(_ state: TextFieldCaretState, in text: TextBuffer) {
        if diagnosticHover != nil || hover.wrappedValue != .hidden { handleHover(nil) }
        let position = ScriptSourceCoordinates.position(in: text, atCharacterIndex: state.caretIndex)
        caretLabel.wrappedValue = "Ln \(position.line + 1), Col \(position.character + 1)"
    }

    static func countLines(in text: TextBuffer) -> Int { text.lineCount }
}

private struct ScriptCodeEditorTextFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content
            .background(.surfaceSunken)
    }
}
