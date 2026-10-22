import EditorCore
import Foundation
import GuavaUI
import GuavaUIRuntime

/// The Swift script editing surface.
///
/// Owns exactly one thing: turning text-field signals into requests the panel
/// can act on. The document lives in ScriptWorkspaceModel; this view retains
/// only the parser cache for its current immutable buffer revision.
struct ScriptCodeEditor: View {
    let source: Binding<TextBuffer>
    let annotations: Binding<TextEditorAnnotations>
    let hover: Binding<ScriptEditorHoverPresentation>
    let caretLabel: Binding<String>
    let onChange: (TextBuffer) -> Void
    @State private var syntaxSession = ScriptSyntaxSession()
    @State private var diagnosticCache = ScriptCodeEditorDiagnostics()
    @State private var diagnosticHover: ScriptDiagnosticHover?
    @State private var gutterNavigation = ScriptGutterNavigation()
    var diagnostics: [ScriptLanguageDiagnostic] = []
    var completionProvider: TextCompletionProvider?
    var completionResolver: TextCompletionResolver?
    var editHistory: TextEditHistory? = nil
    var navigation: EditorScriptNavigationRequest? = nil
    /// Pointer rests on a character worth documenting.
    let onHover: (TextFieldHoverAnchor) -> Void
    /// Pointer left the field; any pending popup must go away.
    let onHoverEnd: () -> Void
    var onCaret: ((TextFieldCaretState) -> Void)?
    var onKey: ((KeyEvent) -> Bool)?
    var languageEntries: [MenuEntry] = []
    var occurrences: [Range<Int>] = []
    var isReadOnly = false
    /// Language markers (hierarchy arrows, the bulb). Each takes its line
    /// from a diagnostic marker, whose message stays on the underline.
    var markers: [TextGutterMarker] = []

    var body: some View {
        let text = source.wrappedValue
        let mappedDiagnostics = diagnosticCache.synchronize(buffer: text, diagnostics: diagnostics)
        ScriptSyntaxReader(syntaxSession) { syntaxSession in
        ThemeReader { theme in
            let light = theme.colors.surfaceSunken.r > 0.5
            let _ = syntaxSession.request(text)
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                TextField("", text: source) { input in
                    input.behavior.readOnly = isReadOnly
                    input.layout.axis = .vertical
                    input.layout.wrapsLines = false
                    input.layout.maxVisibleLines = 48
                    input.codeEditing.showsLineNumbers = true
                    input.codeEditing.showsMinimap = true
                    input.codeEditing.gutter.labels = scriptGutterLabels()
                    input.codeEditing.folding.labels = scriptFoldingLabels()
                    input.codeEditing.gutter.breakpoints = Binding(get: { annotations.wrappedValue.breakpoints },
                        set: { annotations.wrappedValue.breakpoints = $0 })
                    // Runtime verification is not available yet. Retain the
                    // user's enabled intent without claiming a bound breakpoint.
                    input.codeEditing.gutter.onBreakpointsChange = { points in
                        annotations.wrappedValue.breakpoints = points.map {
                            TextBreakpoint(line: $0.line, state: $0.state == .enabled ? .unverified : $0.state)
                        }
                    }
                    input.codeEditing.folding.collapsedLines = Binding(get: { annotations.wrappedValue.collapsedLines },
                        set: { annotations.wrappedValue.collapsedLines = $0 })
                    let markedLines = Set(markers.map(\.line))
                    input.codeEditing.gutter.markers = markers + mappedDiagnostics.overlapping(0..<max(1, text.utf8Length)).enumerated().map { index, diagnostic in
                        TextGutterMarker("diagnostic-\(index)-\(diagnostic.utf8Range.lowerBound)-\(diagnostic.utf8Range.upperBound)-\(diagnostic.severity)-\(diagnostic.message)",
                            line: text.lineIndex(forCharacterIndex: text.characterIndex(forUTF8Offset: diagnostic.utf8Range.lowerBound)),
                            label: L("Go to diagnostic") + ": " + diagnostic.message,
                            icon: UIIcons.Status.alertTriangle,
                            color: diagnostic.severity == .error ? theme.colors.error : theme.colors.warning) {
                                gutterNavigation = ScriptGutterNavigation(externalID: navigation?.id,
                                    characterIndex: text.characterIndex(forUTF8Offset: diagnostic.utf8Range.lowerBound))
                            }
                    }.filter { !markedLines.contains($0.line) }
                    input.codeEditing.folding.regions = syntaxSession.foldRegions
                    input.codeEditing.folding.isReady = syntaxSession.parsedBuffer == text
                    input.codeEditing.diagnostics = mappedDiagnostics
                    input.codeEditing.occurrences = occurrences
                    input.codeEditing.onRequestCompletion = completionProvider
                    input.codeEditing.onResolveCompletion = completionResolver
                    input.codeEditing.onRequestHover = { anchor in handleHover(anchor) }
                    input.codeEditing.indentationWidth = 4
                    input.codeEditing.editHistory = editHistory
                    input.codeEditing.syntaxRevision = syntaxSession.revision
                    input.codeEditing.syntaxColorAtUTF8Offset = { _, offset in syntaxSession.color(atUTF8Offset: offset, light: light) }
                    input.navigation.caretRequestID = navigation.map { AnyHashable($0.id) }
                    input.navigation.caretRequestIndex = navigation.map {
                        ScriptSourceCoordinates.characterIndex(in: text,
                            at: ScriptLanguagePosition(line: $0.line, character: $0.column))
                    }
                    if let index = gutterNavigation.characterIndex, gutterNavigation.externalID == navigation?.id {
                        input.navigation.caretRequestID = gutterNavigation.id
                        input.navigation.caretRequestIndex = index
                    }
                    input.events.onChange = onChange
                    input.events.onHoverChange = { anchor in handleHover(anchor) }
                    input.events.onCaretChange = { state in handleCaret(state, in: source.wrappedValue) }
                    input.events.onKeyDown = { event in
                        if onKey?(event) == true { return true }
                        guard event.scancode == ComposeScancode.escape,
                              diagnosticHover != nil || hover.wrappedValue != .hidden else { return false }
                        handleHover(nil); return true
                    }
                    input.decoration.textColor = theme.colors.onSurface
                    input.decoration.cursorColor = theme.colors.onSurface
                    input.decoration.selectionColor = theme.colors.selection
                }
                .textFieldStyle(.editor)
                .flex(1, shrink: 1, basis: 0)
                .contextMenu(entries: { languageEntries })
                .font(.monospaced(size: 13)).lineHeight(20)
                .accessibilityLabel(L("Source code"))
                .frame(minHeight: 0)
                .flex(1, shrink: 1)

                // Contributes no layout; the popup is painted through the tooltip
                // pass so the editor's own clipping never trims it.
                if let diagnosticHover, diagnosticHover.buffer == text {
                    Tooltip(anchor: diagnosticHover.anchor, configure: { $0.maxWidth = 380 }) {
                        Text(diagnosticHover.message).font(.caption).foregroundColor(.onSurface)
                            .padding(10).floatingSurface(6)
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
        onCaret?(state)
    }

    static func countLines(in text: TextBuffer) -> Int { text.lineCount }
}
