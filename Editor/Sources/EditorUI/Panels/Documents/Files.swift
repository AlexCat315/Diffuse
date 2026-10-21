internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// The project's text files as a folder tree. Opening a file here selects it
/// in the editor; open and modified files are marked in place.
struct DocumentFilesPanel: View {
    let model: EditorDocumentWorkspace
    private var observed: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    @State private var filter: TextBuffer = ""
    @State private var index = DocumentFileIndex()
    @State private var expanded: Set<String>?
    @State private var focusedFolder: String?

    init(model: EditorDocumentWorkspace) {
        self.model = model
        observed = Observed(\.snapshot, on: model)
    }

    var body: some View {
        let snapshot = observed.wrappedValue
        let documents = snapshot.documents
        let tree = index.tree(model, documents: documents)
        let keys = DocumentFileNode.keys(in: tree)
        let dirty = Set(documents.filter(\.isDirty).map(\.path))
        let open = Set(documents.map(\.path))
        let expandedFolders = expanded ?? DocumentFileNode.defaultExpansion(tree, selected: snapshot.selectedPath)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelSearchBar(L("Filter files"), text: $filter, summary: "\(index.count)") {
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
                        isOpen: open.contains(node.path), isDirty: dirty.contains(node.path))
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

    private func row(_ node: DocumentFileNode, isSelected: Bool, isExpanded: Bool,
                     isOpen: Bool, isDirty: Bool) -> some View {
        Row(alignment: .center, spacing: 6) {
            Icon(node.isFolder ? (isExpanded ? UIIcons.File.folderOpen : UIIcons.File.folder) : DocumentKind(path: node.path).icon,
                 size: 13, color: node.isFolder ? .onSurfaceMuted : isSelected ? .accent : .onSurfaceVariant)
            Text(node.name, lineLimit: 1).font(.body)
                .foregroundColor(isSelected || isOpen ? .onSurface : .onSurfaceVariant)
                .flex(1, shrink: 1).frame(minWidth: 0)
            if isDirty {
                Text("M").font(.caption).foregroundColor(.warning)
                    .accessibility { $0.label = L("Unsaved") }
            } else if isOpen {
                Box {}.frame(width: 5, height: 5).background(.onSurfaceMuted).cornerRadius(3)
                    .accessibility { $0.label = L("Open") }
            }
        }
    }

    private func entries(_ node: DocumentFileNode, isOpen: Bool, isDirty: Bool) -> [MenuEntry] {
        guard !node.isFolder else { return [] }
        var items: [MenuEntry] = [.item(MenuItem(id: "open", title: L("Open")) { model.open(node.path) })]
        if isDirty {
            items.append(.item(MenuItem(id: "save", title: L("Save")) { model.save(node.path) }))
            items.append(.item(MenuItem(id: "revert", title: L("Discard Changes"), role: .destructive) {
                model.reload(node.path, discard: true)
            }))
        }
        if isOpen {
            items.append(.separator("close-separator"))
            items.append(.item(MenuItem(id: "close", title: L("Close"), isEnabled: !isDirty) { model.close(node.path) }))
        }
        return items
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

/// Listing the project walks the disk, so the tree is cached until refreshed
/// or until a document appears that the listing does not know yet.
final class DocumentFileIndex {
    private var paths: Set<String>?
    private var cached: [DocumentFileNode] = []
    private var folders: Set<String> = []
    private(set) var count = 0

    func tree(_ model: EditorDocumentWorkspace, documents: [TextDocument]) -> [DocumentFileNode] {
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
