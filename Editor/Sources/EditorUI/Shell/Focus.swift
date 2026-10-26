internal import EditorCore
internal import StudioDocuments
internal import CoveUI
internal import CoveUIRuntime

/// What the window is working on: the open document in text Spaces, the
/// selected entity in scene Spaces. The title bar, the ⌘K palette and the
/// Agent composer all read this one value, so their context never disagrees.
struct EditorWorkFocus {
    var trail: [String] = []
    var leaf: String?
    var leafIcon: BundleImageResource?
    /// Set for a document leaf: its file icon replaces `leafIcon`.
    var leafPath: String?
    var isDirty = false

    init(app: EditorApplication, documents snapshot: EditorDocumentSnapshot) {
        guard app.store.content == .scene else {
            guard let path = snapshot.selectedPath else { return }
            let parts = path.split(separator: "/").map(String.init)
            trail = Array(parts.dropLast())
            leaf = parts.last
            leafPath = path
            isDirty = snapshot.selected?.isDirty == true
            return
        }
        let entity = app.scene.entitySummary(id: app.store.selectedEntityID)
        leaf = entity?.name
        leafIcon = entity == nil ? nil : UIIcons.Editor.box
    }
}

/// Compact chip naming the focus leaf, used beside text inputs. Callers decide
/// whether it shows: a body that appears later would be appended out of order.
struct EditorFocusChip: View {
    let focus: EditorWorkFocus

    var body: some View {
        let leaf = focus.leaf ?? ""
        return Row(alignment: .center, spacing: 5) {
            if let path = focus.leafPath { FileIcon(path: path, size: 12) }
            else if let icon = focus.leafIcon { Icon(icon, size: 11, color: .accent) }
            Text(leaf, lineLimit: 1).truncated().font(.caption).foregroundColor(.onSurfaceVariant)
                .flex(0, shrink: 1).frame(minWidth: 0)
        }.padding(horizontal: 6, vertical: 3).background(.surfaceVariant).cornerRadius(4)
            .frame(maxWidth: 220).accessibility { $0.label = L("Context") + " " + leaf }
            .debugName("editor-focus-chip")
    }
}
