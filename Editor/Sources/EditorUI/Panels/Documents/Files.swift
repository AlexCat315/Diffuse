internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// The project's text files as a folder tree. Opening a file here selects it
/// in the editor; open and modified files are marked in place. Given the
/// application, project scripts can also be created and deleted here.
struct DocumentFilesPanel: View {
    let model: EditorDocumentWorkspace
    let app: EditorApplication?
    private var observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private var versionControl: Observed<EditorVersionControl, VersionControlSnapshot>?
    @State private var filter: TextBuffer = ""
    @State private var index = DocumentFileIndex()
    @State private var expanded: Set<String>?
    @State private var focusedFolder: String?
    @State private var renaming: String?
    @State private var renameText: TextBuffer = ""

    init(model: EditorDocumentWorkspace, app: EditorApplication? = nil) {
        self.model = model
        self.app = app
        observed = Observed(\.snapshot, on: model)
        versionControl = app.map { Observed(\.snapshot, on: $0.workstation.versionControl) }
    }

    var body: some View {
        if let app {
            // Script edits live in the script workspace; observing it keeps
            // their modified marks current.
            ScriptWorkspaceReader(app.workstation.scripts) { _ in content }
        } else {
            content
        }
    }

    /// Working-tree states by project path; folders inherit their contents' mark.
    private var fileStates: (files: [String: VersionControlFileState], folders: Set<String>) {
        guard let app, versionControl?.wrappedValue.repository != nil else { return ([:], []) }
        let files = app.workstation.versionControl.projectFileStates
        var folders = Set<String>()
        for path in files.keys {
            var parts = path.split(separator: "/").dropLast()
            while !parts.isEmpty { folders.insert(parts.joined(separator: "/")); parts = parts.dropLast() }
        }
        return (files, folders)
    }

    @ViewBuilder private var content: some View {
        let snapshot = observed.wrappedValue
        let documents = snapshot.documents
        let scriptPaths = app.map { app in app.workstation.scripts.snapshot.documents.map(\.file.url.path) } ?? []
        let tree = index.tree(model, documents: documents, scripts: scriptPaths)
        let keys = DocumentFileNode.keys(in: tree)
        let dirty = Set(documents.filter(\.isDirty).map(\.path)).union(dirtyScripts)
        let open = Set(documents.map(\.path))
        let expandedFolders = expanded ?? DocumentFileNode.defaultExpansion(tree, selected: snapshot.selectedPath)
        let states = fileStates
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelSearchBar(L("Filter files"), text: $filter, summary: "\(index.count)") {
                EditorPanelIconButton(UIIcons.File.filePlus, tooltip: L("New File")) {
                    newFile(in: focusedFolder ?? snapshot.selectedPath.map { parent(of: $0) } ?? "")
                }.debugName("document-files-new-file")
                if let app, allowsScripts {
                    EditorPanelIconButton(UIIcons.File.fileCode, tooltip: L("New Script")) {
                        ScriptFileActions.newScript(app: app)
                        index.invalidate()
                    }.debugName("document-files-new-script")
                }
                EditorPanelIconButton(UIIcons.Navigation.refresh, tooltip: L("Refresh")) {
                    index.invalidate()
                    expanded = expandedFolders
                }
            }
            if tree.isEmpty {
                EditorPanelEmptyState(L("No text files"), detail: L("Add files to the project folder, then refresh."))
                    .flex()
            } else {
                Tree(tree, id: \.path, children: { $0.children }, hasChildren: { $0.isFolder }, configure: { options in
                    options.selection.primaryKey = Binding(
                        get: { (focusedFolder ?? snapshot.selectedPath).flatMap { keys[$0] } },
                        set: { key in
                            guard let path = key?.id else { return }
                            if open.contains(path) || !(index.isFolder(path)) { focusedFolder = nil } else { focusedFolder = path }
                        })
                    options.selection.expandedKeys = Binding(
                        get: { Set(expandedFolders.compactMap { keys[$0] }) },
                        set: { expanded = Set($0.map(\.id)) })
                    options.layout.rowHeight = 26
                    options.layout.rowSpacing = 0
                    options.layout.indentation = 14
                    options.layout.disclosureWidth = 18
                    options.layout.showsIndentGuides = false
                    options.search.query = filter.stringValue
                    options.search.text = { $0.name }
                    options.search.policy = .filterAndAutoExpand
                    options.events.onSelect = { node in
                        guard !node.isFolder else { return }
                        focusedFolder = nil
                        model.open(node.path)
                    }
                }) { node, isSelected, isExpanded, _ in
                    row(node, isSelected: isSelected, isExpanded: isExpanded,
                        isOpen: open.contains(node.path), isDirty: dirty.contains(node.path),
                        state: states.files[node.path], folderChanged: node.isFolder && states.folders.contains(node.path))
                        .contextMenu(entries: { entries(node, isOpen: open.contains(node.path),
                                                        isDirty: dirty.contains(node.path)) })
                }
                .padding(vertical: 4)
                .flex()
                .treeRowStyle(EditorTreeRowStyle(), scope: .row)
            }
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.File.folder, size: 11, color: .onSurfaceMuted)
                Text("\(index.count) \(L("files"))").font(.caption).foregroundColor(.onSurfaceMuted)
                if !dirty.isEmpty {
                    Text("· \(dirty.count) \(L("unsaved"))").font(.caption).foregroundColor(.warning)
                }
            }.padding(horizontal: 10).frame(height: 26).debugName("document-files-summary")
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("document-files")
    }

    /// Unsaved edits are a filled dot; the working-tree state is a coloured
    /// letter, and its colour also tints the name, as in mature editors.
    private func row(_ node: DocumentFileNode, isSelected: Bool, isExpanded: Bool,
                     isOpen: Bool, isDirty: Bool,
                     state: VersionControlFileState?, folderChanged: Bool) -> some View {
        Row(alignment: .center, spacing: 6) {
            FileIcon(path: node.path, isFolder: node.isFolder, isOpen: isExpanded, size: 14)
            if renaming == node.path {
                TextField(L("Name"), text: $renameText) { input in
                    input.decoration.size = .small
                    input.navigation.focusRequestID = node.path
                    input.events.onSubmit = { commitRename(node.path) }
                    input.events.onCancel = { renaming = nil }
                    input.events.onBlur = { commitRename(node.path) }
                }.font(.body).flex(1, shrink: 1).frame(minWidth: 0).debugName("document-files-rename")
            } else {
                Text(node.name, lineLimit: 1).font(.body)
                    .foregroundColor(state?.color ?? (isSelected || isOpen ? .onSurface : .onSurfaceVariant))
                    .flex(1, shrink: 1).frame(minWidth: 0)
            }
            if isDirty {
                Box {}.frame(width: 7, height: 7).background(.onSurfaceVariant).cornerRadius(4)
                    .accessibility { $0.label = L("Unsaved") }
            } else if isOpen && state == nil {
                Box {}.frame(width: 5, height: 5).background(.onSurfaceMuted).cornerRadius(3)
                    .accessibility { $0.label = L("Open") }
            }
            if let state {
                Text(state.badge).font(.caption).foregroundColor(state.color)
                    .accessibility { $0.label = L(state.title) }
            } else if folderChanged {
                Box {}.frame(width: 5, height: 5).background(.warning).cornerRadius(3)
                    .accessibility { $0.label = L("Contains changes") }
            }
        }
    }

    private func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Creates `Untitled.md` (numbered when taken) and starts naming it.
    private func newFile(in folder: String) {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let existing = Set(model.files())
        var name = "Untitled.md", number = 2
        while existing.contains(prefix + name) { name = "Untitled \(number).md"; number += 1 }
        guard model.create(prefix + name, text: "") else { return }
        index.invalidate()
        if !folder.isEmpty { expanded = (expanded ?? []).union([folder]) }
        renameText = TextBuffer(name)
        renaming = prefix + name
    }

    private func commitRename(_ path: String) {
        guard renaming == path else { return }
        renaming = nil
        let name = renameText.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != path.split(separator: "/").last.map(String.init) else { return }
        let folder = parent(of: path)
        if model.move(path, to: folder.isEmpty ? name : folder + "/" + name) { index.invalidate() }
    }

    private var allowsScripts: Bool { app?.store.content.profile.features.contains(.scripting) == true }

    /// Scripts edited without a tab (a rename that touched several files).
    private var dirtyScripts: Set<String> {
        guard let workstation = app?.workstation else { return [] }
        return Set(workstation.scripts.snapshot.documents.filter(\.isDirty)
            .compactMap { workstation.documentPath(forScript: $0.file.identifier) })
    }

    private func entries(_ node: DocumentFileNode, isOpen: Bool, isDirty: Bool) -> [MenuEntry] {
        let manage: [MenuEntry] = [
            .separator("manage-separator"),
            .item(MenuItem(id: "rename", title: L("Rename"), isEnabled: !isDirty) {
                renameText = TextBuffer(node.name); renaming = node.path
            }),
            .item(MenuItem(id: "trash", title: L("Move to Trash"), isEnabled: !isDirty, role: .destructive) {
                if model.remove(node.path) { index.invalidate() }
            }),
        ]
        if node.isFolder {
            var items: [MenuEntry] = [.item(MenuItem(id: "new-file", title: L("New File")) { newFile(in: node.path) })]
            if let app, allowsScripts,
               node.path == app.workstation.documentPath(for: app.dynamicScriptManager.scriptsDirectoryURL) {
                items.append(.item(MenuItem(id: "new-script", title: L("New Script")) {
                    ScriptFileActions.newScript(app: app); index.invalidate()
                }))
                return items
            }
            return items + manage
        }
        let isScript = app?.workstation.scriptID(forDocument: node.path) != nil
        var items: [MenuEntry] = [.item(MenuItem(id: "open", title: L("Open")) { model.open(node.path) })]
        if isDirty {
            items.append(.item(MenuItem(id: "save", title: L("Save")) { save(node.path) }))
            items.append(.item(MenuItem(id: "revert", title: L("Discard Changes"), role: .destructive) { revert(node.path) }))
        }
        if isOpen {
            items.append(.separator("close-separator"))
            items.append(.item(MenuItem(id: "close", title: L("Close"), isEnabled: !isDirty) { model.close(node.path) }))
        }
        if let app, isScript {
            items.append(.separator("script-separator"))
            items.append(.item(MenuItem(id: "delete-script", title: L("Delete Script"), role: .destructive) {
                ScriptFileActions.confirmDelete(app: app, path: node.path)
            }))
        }
        return isScript ? items : items + manage
    }

    private func save(_ path: String) {
        if let app { app.workstation.saveDocument(path) } else { model.save(path) }
    }

    private func revert(_ path: String) {
        if let app { app.workstation.revertDocument(path) } else { model.reload(path, discard: true) }
    }
}

/// One entry of the project tree. Folders use their relative path as identity.
struct DocumentFileNode {
    let path: String
    let name: String
    let isFolder: Bool
    var children: [DocumentFileNode]

    /// Folders first, then files, each in case-insensitive name order.
    static func tree(_ paths: [String]) -> [DocumentFileNode] {
        build(paths.map { ($0, $0.split(separator: "/").map(String.init)) }, prefix: "")
    }

    private static func build(_ entries: [(path: String, parts: [String])], prefix: String) -> [DocumentFileNode] {
        var folders: [String: [(path: String, parts: [String])]] = [:]
        var files: [DocumentFileNode] = []
        for entry in entries {
            guard let first = entry.parts.first else { continue }
            if entry.parts.count == 1 {
                files.append(DocumentFileNode(path: entry.path, name: first, isFolder: false, children: []))
            } else {
                folders[first, default: []].append((entry.path, Array(entry.parts.dropFirst())))
            }
        }
        let sortedFolders = folders.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            let path = prefix + name
            return DocumentFileNode(path: path, name: name, isFolder: true,
                                    children: build(folders[name] ?? [], prefix: path + "/"))
        }
        return sortedFolders + files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Tree keys carry the row's index path, so they are derived per render.
    static func keys(in roots: [DocumentFileNode]) -> [String: TreeNodeKey<String>] {
        var result: [String: TreeNodeKey<String>] = [:]
        func visit(_ nodes: [DocumentFileNode], path: [Int]) {
            for (index, node) in nodes.enumerated() {
                let indexPath = path + [index]
                result[node.path] = TreeNodeKey(id: node.path, path: indexPath)
                visit(node.children, path: indexPath)
            }
        }
        visit(roots, path: [])
        return result
    }

    /// Top-level folders plus every folder on the way to the selected file.
    static func defaultExpansion(_ roots: [DocumentFileNode], selected: String?) -> Set<String> {
        var folders = Set(roots.filter(\.isFolder).map(\.path))
        if let selected {
            var parts = selected.split(separator: "/").dropLast()
            while !parts.isEmpty { folders.insert(parts.joined(separator: "/")); parts = parts.dropLast() }
        }
        return folders
    }
}

/// Listing the project walks the disk, so the tree is cached until refreshed,
/// until a document appears that the listing does not know yet, or until the
/// project's scripts are created or deleted.
final class DocumentFileIndex {
    private var paths: Set<String>?
    private var cached: [DocumentFileNode] = []
    private var folders: Set<String> = []
    private(set) var count = 0
    private var scripts: [String] = []

    func tree(_ model: EditorDocumentWorkspace, documents: [TextDocument], scripts: [String] = []) -> [DocumentFileNode] {
        if scripts != self.scripts { self.scripts = scripts; paths = nil }
        let known = paths ?? []
        if paths == nil || documents.contains(where: { !known.contains($0.path) && $0.existsOnDisk }) {
            let listed = Set(model.files()).union(documents.filter(\.existsOnDisk).map(\.path))
            paths = listed
            count = listed.count
            cached = DocumentFileNode.tree(Array(listed))
            folders = Set(listed.flatMap { path -> [String] in
                var parts = path.split(separator: "/").dropLast()
                var result: [String] = []
                while !parts.isEmpty { result.append(parts.joined(separator: "/")); parts = parts.dropLast() }
                return result
            })
        }
        return cached
    }

    func isFolder(_ path: String) -> Bool { folders.contains(path) }

    func invalidate() { paths = nil }
}
