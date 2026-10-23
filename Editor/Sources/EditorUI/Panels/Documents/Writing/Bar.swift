internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUIWorkspace

/// Above a text document: where it lives, line wrapping, the AI writing
/// assistant and focus mode. Every text format gets the same bar.
struct DocumentWritingBar: View {
    let app: EditorApplication?
    let path: String
    let session: DocumentWritingSession
    private let writing: Observed<DocumentWritingSession, DocumentWritingSession.State>
    private let layout: Observed<WorkspaceController, UInt64>?

    init(app: EditorApplication?, path: String, session: DocumentWritingSession) {
        self.app = app
        self.path = path
        self.session = session
        writing = Observed(\.state, on: session)
        layout = app.flatMap { EditorWorkbenchLink.of($0).controller }.map { Observed(\.version, on: $0) }
    }

    var body: some View {
        let state = writing.wrappedValue
        let _ = layout?.wrappedValue
        Row(alignment: .center, spacing: 2) {
            DocumentPathCrumbs(path: path).flex(0, shrink: 1).frame(minWidth: 0).clipped()
            Spacer(minLength: 8)
            Button(icon: .resource(UIIcons.Text.wrapText), size: 12, isSelected: state.wrapsLines, tooltip: L("Wrap Lines")) {
                session.update { $0.wrapsLines.toggle() }
            }.buttonStyle(ToggleButtonStyle(height: 22)).debugName("document-wrap")
            if let app {
                separator
                WritingAssistantButton(app: app, path: path, session: session)
                let link = EditorWorkbenchLink.of(app)
                let focused = link.maximizedPanelID == "documents"
                Button(icon: .resource(focused ? UIIcons.Navigation.minimize : UIIcons.Navigation.maximize), size: 12,
                       isSelected: focused, tooltip: focused ? L("Exit Focus Mode") : L("Focus Mode")) {
                    link.toggleMaximize("documents")
                }.buttonStyle(ToggleButtonStyle(height: 22)).debugName("document-focus")
            }
        }
        .padding(horizontal: 10)
        .frame(height: 32)
        .debugName("document-path-bar")
    }

    /// Padding and background share a node, so the gap needs its own wrapper.
    private var separator: some View {
        Box(direction: .row, alignItems: .center, spacing: 0) {
            Box {}.frame(width: 1, height: 14).background(.divider)
        }.padding(horizontal: 4)
    }

}

/// Counts for the open document and the caret, below the editor.
struct DocumentWritingStatus: View {
    let session: DocumentWritingSession
    private let writing: Observed<DocumentWritingSession, DocumentWritingSession.State>
    @State private var cache = StatisticsCache()

    init(session: DocumentWritingSession) {
        self.session = session
        writing = Observed(\.state, on: session)
    }

    var body: some View {
        let state = writing.wrappedValue
        let buffer = session.buffer
        let stats = cache.statistics(for: buffer)
        let position = buffer.lineAndColumn(forCharacterIndex: state.caret.caretIndex)
        let selection = session.selection
        Row(alignment: .center, spacing: 12) {
            Text(String(format: L("%d words"), stats.words)).font(.caption).foregroundColor(.onSurfaceMuted)
            Text(String(format: L("%d characters"), stats.characters)).font(.caption).foregroundColor(.onSurfaceMuted)
            if stats.readingMinutes > 0 {
                Text(String(format: L("%d min read"), stats.readingMinutes)).font(.caption).foregroundColor(.onSurfaceMuted)
            }
            Spacer(minLength: 0)
            if !selection.isEmpty {
                let selected = DocumentStatistics(Substring(buffer.substring(characterRange: selection)))
                Text(String(format: L("%d words selected"), selected.words)).font(.caption).foregroundColor(.accent)
            }
            Text(String(format: L("Ln %d, Col %d"), position.line + 1, position.column + 1))
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 14)
        .frame(height: 24)
        .debugName("document-writing-status")
    }
}

/// Counting walks the whole text, so it runs once per buffer revision.
private final class StatisticsCache {
    private var buffer: TextBuffer?
    private var value = DocumentStatistics(Substring(""))

    func statistics(for buffer: TextBuffer) -> DocumentStatistics {
        if self.buffer != buffer {
            self.buffer = buffer
            value = DocumentStatistics(Substring(buffer.stringValue))
        }
        return value
    }
}
