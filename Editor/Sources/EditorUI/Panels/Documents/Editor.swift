internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// The text and code editor: one tab per open document, a path bar with the
/// document's facts and actions, then the editing surface. Choosing files
/// belongs to the Files panel and the ⌘P palette. Given the application,
/// project scripts get the Swift language tools; without it every file is
/// plain text.
struct DocumentsPanel: View {
    let model: EditorDocumentWorkspace
    let app: EditorApplication?
    var onOpenFile: () -> Void = {}
    private var observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    @State private var swift: ScriptDocumentSessions?
    @State private var confirmingClose: String?
    @State private var hoveredClose: String?
    @State private var hoveredTab: String?

    init(model: EditorDocumentWorkspace, app: EditorApplication? = nil, onOpenFile: @escaping () -> Void = {}) {
        self.model = model
        self.app = app
        self.onOpenFile = onOpenFile
        observed = Observed(\.snapshot, on: model)
        _swift = State(wrappedValue: app.map(ScriptDocumentSessions.init))
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let document = snapshot.selected {
                if let app {
                    // Script edits live in the script workspace; observing it
                    // keeps the tab dots in step with typing.
                    ScriptWorkspaceReader(app.workstation.scripts) { _ in
                        tabs(snapshot.documents, selected: document.path)
                    }
                } else {
                    tabs(snapshot.documents, selected: document.path)
                }
                if let app, let swift, let scriptID = app.workstation.scriptID(forDocument: document.path) {
                    ScriptDocumentBar(app: app, sessions: swift, path: document.path)
                    errorBanner(snapshot.error)
                    ScriptDocumentSurface(app: app, sessions: swift, scriptID: scriptID, path: document.path)
                        .id(document.path).flex()
                } else {
                    pathBar(document)
                    errorBanner(snapshot.error)
                    DocumentEditingSurface(model: model, path: document.path).id(document.path).flex()
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("document-editor")
    }

    private func errorBanner(_ error: String?) -> some View {
        AnimatedVisibility(isVisible: error != nil) {
            Row(alignment: .center, spacing: 8) {
                Icon(UIIcons.Status.alertTriangle, size: 12, color: .error)
                Text(L(error ?? ""), lineLimit: 2).font(.caption).foregroundColor(.error).flex().frame(minWidth: 0)
            }.padding(horizontal: 12, vertical: 6).background(SemanticColorRef.error.opacity(0.10))
                .debugName("document-error")
        }
    }

    // MARK: Tabs

    private func isDirty(_ document: TextDocument) -> Bool {
        app?.workstation.isDocumentDirty(document) ?? document.isDirty
    }

    private func save(_ path: String) -> Bool {
        if let app { return app.workstation.saveDocument(path) }
        model.save(path)
        return model.error == nil
    }

    private func close(_ path: String, discard: Bool = false) {
        if let app { app.workstation.closeDocument(path, discard: discard) } else { model.close(path, discard: discard) }
    }

    private func tabs(_ documents: [TextDocument], selected: String) -> some View {
        Box(direction: .row, alignItems: .center, spacing: 0) {
            Box(direction: .row, alignItems: .center, spacing: 2) {
                for document in documents {
                    AnyView(tab(document, isSelected: document.path == selected))
                }
            }.flex(1, shrink: 1).frame(minWidth: 0).clipped()
        }
        .padding(horizontal: 4)
        .frame(height: 32)
        .background(.surface)
        .debugName("document-tabs")
    }

    private func tab(_ document: TextDocument, isSelected: Bool) -> some View {
        let name = document.path.split(separator: "/").last.map(String.init) ?? document.path
        return Row(alignment: .center, spacing: 0) {
            Button(isSelected: isSelected, tooltip: document.path) {
                model.open(document.path)
            } label: {
                Row(alignment: .center, spacing: 6) {
                    FileIcon(path: document.path, size: 13)
                    Text(name, lineLimit: 1).font(.label)
                        .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(maxWidth: 180)
                }.padding(EdgeInsets(leading: 10, trailing: 4))
            }.buttonStyle(.plain).frame(height: 26)
            closeControl(document, isSelected: isSelected)
        }
        .padding(EdgeInsets(trailing: 4))
        .frame(height: 26)
        .onHover { hoveredTab = $0 ? document.path : (hoveredTab == document.path ? nil : hoveredTab) }
        // A selection pill, like the workbench tabs: no rules between or above tabs.
        .background(isSelected ? .surfaceVariant : .clear)
        .cornerRadius(6)
        .animation(motion: .fast, value: [isSelected, hoveredTab == document.path])
        .accessibility { $0.label = name; $0.state.isSelected = isSelected }
        .debugName("document-tab-" + document.path)
    }

    /// Like VS Code: a modified tab always shows a dot, which turns into the
    /// close mark under the pointer and asks before closing; a clean tab shows
    /// its close mark only while selected or hovered, keeping its width.
    @ViewBuilder
    private func closeControl(_ document: TextDocument, isSelected: Bool) -> some View {
        if isDirty(document) {
            Popover(isPresented: Binding(get: { confirmingClose == document.path },
                                         set: { confirmingClose = $0 ? document.path : nil }),
                    width: 260, placement: .bottom, surface: .bubble, overflow: .constrain) {
                // The unsaved dot turns into the close mark under the pointer.
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    if hoveredClose == document.path {
                        Icon(UIIcons.Action.x, size: 10, color: .onSurfaceVariant)
                    } else {
                        Box {}.frame(width: 7, height: 7).background(.onSurfaceVariant).cornerRadius(4)
                    }
                }.frame(width: 18, height: 18)
                    .background(hoveredClose == document.path ? .stateLayerHover : .clear).cornerRadius(4)
                    .animation(motion: .fast, value: hoveredClose == document.path)
                    .onHover { hoveredClose = $0 ? document.path : (hoveredClose == document.path ? nil : hoveredClose) }
                    .accessibility { $0.label = L("Close") + " " + document.path }
            } content: {
                Column(alignment: .leading, spacing: 10) {
                    Text(L("Save changes before closing?")).font(.bodyStrong)
                    Text(document.path, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceVariant)
                    Row(alignment: .center, spacing: 8) {
                        Spacer(minLength: 0)
                        Button(L("Don't Save")) {
                            confirmingClose = nil
                            close(document.path, discard: true)
                        }.buttonStyle(.ghost)
                        Button(L("Save")) {
                            confirmingClose = nil
                            if save(document.path) { close(document.path) }
                        }.buttonStyle(.primary)
                    }
                }.padding(12)
            }
        } else if isSelected || hoveredTab == document.path {
            Button(icon: .resource(UIIcons.Action.x), size: 10, tooltip: L("Close")) {
                close(document.path)
            }.buttonStyle(EditorChromeButtonStyle(height: 18))
        } else {
            Box {}.frame(width: 18, height: 18)
        }
    }

    // MARK: Path bar

    private func pathBar(_ document: TextDocument) -> some View {
        Row(alignment: .center, spacing: 6) {
            DocumentPathCrumbs(path: document.path)
            Spacer(minLength: 0)
        }
        // Only where the file lives: unsaved state is the tab's dot, saving is
        // ⌘S, discard and close live in the File menu and the Files tree.
        .padding(horizontal: 12)
        .frame(height: 28)
        .debugName("document-path-bar")
    }

    // MARK: Empty state

    private var emptyState: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center, spacing: 10) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Icon(UIIcons.File.fileCode, size: 22, color: .onSurfaceMuted)
            }.frame(width: 48, height: 48).background(.surfaceVariant).cornerRadius(12)
            Text(L("Open a file to start editing")).font(.bodyStrong)
            Text(L("Choose a file in the Files panel, or search the project.")).font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Button(action: onOpenFile) {
                Row(alignment: .center, spacing: 8) {
                    Text(L("Open File..."))
                    Text(EditorShortcut(.letter("p")).label).font(.caption).foregroundColor(.onAccent)
                }
            }.buttonStyle(.primary).padding(EdgeInsets(top: 6)).debugName("document-open-file")
        }
        .flex()
        .frame(width: .percent(100), minWidth: 0, minHeight: 0)
        .debugName("document-empty")
    }
}

/// Folder › folder › file, with the file's icon; shared by plain and Swift bars.
struct DocumentPathCrumbs: View {
    let path: String

    var body: some View {
        let parts = path.split(separator: "/").map(String.init)
        Row(alignment: .center, spacing: 6) {
            for (index, part) in parts.enumerated() {
                if index > 0 { AnyView(Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted)) }
                let isFile = index == parts.count - 1
                AnyView(Row(alignment: .center, spacing: 4) {
                    if isFile { FileIcon(path: path, size: 12) }
                    Text(part, lineLimit: 1).font(.caption).foregroundColor(isFile ? .onSurface : .onSurfaceMuted)
                })
            }
        }
    }
}

/// Re-renders its content whenever the script workspace publishes.
struct ScriptWorkspaceReader<Content: View>: View {
    private let observed: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    private let content: (ScriptWorkspaceSnapshot) -> Content

    init(_ model: ScriptWorkspaceModel, @ViewBuilder content: @escaping (ScriptWorkspaceSnapshot) -> Content) {
        observed = Observed(\.snapshot, on: model)
        self.content = content
    }

    var body: some View { content(observed.wrappedValue) }
}
