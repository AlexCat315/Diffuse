internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// A text document's body: the editing surface, or a package's view of the
/// document while the path bar has one switched on.
struct DocumentContent: View {
    let model: EditorDocumentWorkspace
    let app: EditorApplication?
    let path: String
    let session: DocumentWritingSession
    private let writing: Observed<DocumentWritingSession, DocumentWritingSession.State>

    init(model: EditorDocumentWorkspace, app: EditorApplication?, path: String, session: DocumentWritingSession) {
        self.model = model
        self.app = app
        self.path = path
        self.session = session
        writing = Observed(\.state, on: session)
    }

    var body: some View {
        let active = writing.wrappedValue.documentView
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let app, let active,
               let view = app.workbenchCatalog.documentViews(forPath: path).first(where: { $0.id == active }) {
                let path = self.path
                PluginView(session: MainActor.assumeIsolated { app.viewSession(for: view, path: path) })
                    .id(view.id + ":" + path).flex()
            } else {
                DocumentEditingSurface(model: model, app: app, path: path, session: session).id(path).flex()
                DocumentWritingStatus(session: session)
            }
        }.frame(minWidth: 0, minHeight: 0)
    }
}
