internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// The text and code editor: one tab per open document, a path bar with the
/// document's facts and actions, then the editing surface. Choosing files
/// belongs to the Files panel and the ⌘P palette.
struct DocumentsPanel: View {
    let model: EditorDocumentWorkspace
    var onOpenFile: () -> Void = {}
    private var observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    @State private var confirmingClose: String?
    @State private var isMorePresented = false

    init(model: EditorDocumentWorkspace, onOpenFile: @escaping () -> Void = {}) {
        self.model = model
        self.onOpenFile = onOpenFile
        observed = Observed(\.snapshot, on: model)
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        let documents = snapshot.documents
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let document = snapshot.selected {
                tabs(documents, selected: document.path)
                Divider()
                pathBar(document)
                Divider()
                if let error = snapshot.error {
                    Row(alignment: .center, spacing: 8) {
                        Icon(UIIcons.Status.alertTriangle, size: 12, color: .error)
                        Text(L(error), lineLimit: 2).font(.caption).foregroundColor(.error).flex().frame(minWidth: 0)
                    }.padding(horizontal: 12, vertical: 6).background(SemanticColorRef.error.opacity(0.10))
                        .debugName("document-error")
                }
                DocumentEditingSurface(model: model, path: document.path).id(document.path).flex()
            } else {
                emptyState
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("document-editor")
    }

    // MARK: Tabs

    private func tabs(_ documents: [TextDocument], selected: String) -> some View {
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                for document in documents {
                    AnyView(tab(document, isSelected: document.path == selected))
                }
            }.flex(1, shrink: 1).frame(minWidth: 0).clipped()
        }
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
                    Icon(DocumentKind(path: document.path).icon, size: 12, color: isSelected ? .accent : .onSurfaceMuted)
                    Text(name, lineLimit: 1).font(.label)
                        .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(maxWidth: 180)
                }.padding(EdgeInsets(leading: 12, trailing: 4))
            }.buttonStyle(.plain).frame(height: 32)
            closeControl(document)
        }
        .padding(EdgeInsets(trailing: 6))
        .frame(height: 32)
        .background(isSelected ? .background : .clear)
        .overlay(alignment: .top) {
            Box {}.frame(width: .percent(100), height: .points(2)).background(isSelected ? .accent : .clear)
        }
        .overlay(alignment: .trailing) { Box {}.frame(width: .points(1), height: .percent(100)).background(.divider) }
        .accessibility { $0.label = name; $0.state.isSelected = isSelected }
        .debugName("document-tab-" + document.path)
    }

    /// A clean document closes at once. A modified one shows a dot that asks
    /// whether to save before closing.
    @ViewBuilder
    private func closeControl(_ document: TextDocument) -> some View {
        if document.isDirty {
            Popover(isPresented: Binding(get: { confirmingClose == document.path },
                                         set: { confirmingClose = $0 ? document.path : nil }),
                    width: 260, placement: .bottom, surface: .bubble, overflow: .constrain) {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Box {}.frame(width: 7, height: 7).background(.warning).cornerRadius(4)
                }.frame(width: 18, height: 18)
                    .accessibility { $0.label = L("Close") + " " + document.path }
            } content: {
                Column(alignment: .leading, spacing: 10) {
                    Text(L("Save changes before closing?")).font(.bodyStrong)
                    Text(document.path, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceVariant)
                    Row(alignment: .center, spacing: 8) {
                        Spacer(minLength: 0)
                        Button(L("Don't Save")) {
                            confirmingClose = nil
                            model.close(document.path, discard: true)
                        }.buttonStyle(.ghost)
                        Button(L("Save")) {
                            confirmingClose = nil
                            model.save(document.path)
                            if model.error == nil { model.close(document.path) }
                        }.buttonStyle(.primary)
                    }
                }.padding(12)
            }
        } else {
            Button(icon: .resource(UIIcons.Action.x), size: 10, tooltip: L("Close")) {
                model.close(document.path)
            }.buttonStyle(EditorChromeButtonStyle(height: 18))
        }
    }

    // MARK: Path bar

    private func pathBar(_ document: TextDocument) -> some View {
        let parts = document.path.split(separator: "/").map(String.init)
        let kind = DocumentKind(path: document.path)
        return Row(alignment: .center, spacing: 6) {
            for (index, part) in parts.enumerated() {
                if index > 0 { AnyView(Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted)) }
                let isFile = index == parts.count - 1
                AnyView(Row(alignment: .center, spacing: 4) {
                    if isFile { Icon(kind.icon, size: 11, color: .onSurfaceVariant) }
                    Text(part, lineLimit: 1).font(.caption).foregroundColor(isFile ? .onSurface : .onSurfaceMuted)
                })
            }
            Spacer(minLength: 8)
            if document.isDirty {
                Text(L("Unsaved")).font(.caption).foregroundColor(.warning)
            }
            Text(kind.name).font(.caption).foregroundColor(.onSurfaceMuted)
            Text("UTF-8").font(.caption).foregroundColor(.onSurfaceMuted)
            Text(document.text.contains("\r\n") ? "CRLF" : "LF").font(.caption).foregroundColor(.onSurfaceMuted)
            Button(isEnabled: document.isDirty, tooltip: L("Save") + " " + EditorShortcut(.letter("s")).label) {
                model.save(document.path)
            } label: {
                Row(alignment: .center, spacing: 5) {
                    Icon(UIIcons.File.save, size: 11)
                    Text(L("Save"))
                }
            }.buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("document-save")
            Popover(isPresented: $isMorePresented, width: 220, surface: .content, overflow: .flip) {
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    Icon(UIIcons.Action.moreHorizontal, size: 13, color: .onSurfaceVariant)
                }.frame(width: 24, height: 22).accessibility { $0.label = L("More") }
            } content: {
                Menu([
                    .item(MenuItem(id: "revert", title: L("Discard Changes"), isEnabled: document.isDirty,
                                   role: .destructive) { model.reload(document.path, discard: true) }),
                    .separator("close"),
                    .item(MenuItem(id: "close", title: L("Close"), isEnabled: !document.isDirty) {
                        model.close(document.path)
                    }),
                ], width: 220, onItemActivated: { isMorePresented = false })
            }
        }
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
