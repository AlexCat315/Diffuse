internal import EditorCore
internal import StudioDocuments
internal import GuavaUI
internal import GuavaUIRuntime

/// What the window is working on: the open document in text Spaces, the
/// selected entity in scene Spaces. The title bar, the ⌘K palette and the
/// Agent composer all read this one value, so their context never disagrees.
struct EditorWorkFocus {
    var rootIcon: BundleImageResource
    var trail: [String]
    var leaf: String?
    var leafIcon: BundleImageResource?
    var isDirty = false

    init(app: EditorApplication, documents snapshot: EditorDocumentSnapshot) {
        guard app.store.workspaceMode.profile.features.contains(.scene) else {
            rootIcon = UIIcons.File.folder
            guard let path = snapshot.selectedPath else {
                trail = [L("Files")]
                return
            }
            let parts = path.split(separator: "/").map(String.init)
            trail = Array(parts.dropLast())
            leaf = parts.last
            leafIcon = DocumentKind(path: path).icon
            isDirty = snapshot.selected?.isDirty == true
            return
        }
        let entity = app.scene.entitySummary(id: app.store.selectedEntityID)
        rootIcon = UIIcons.Shape.globe
        trail = [L("Scene")]
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
            if let icon = focus.leafIcon { Icon(icon, size: 11, color: .accent) }
            Text(leaf, lineLimit: 1).truncated().font(.caption).foregroundColor(.onSurfaceVariant)
                .flex(0, shrink: 1).frame(minWidth: 0)
        }.padding(horizontal: 6, vertical: 3).background(.surfaceVariant).cornerRadius(4)
            .frame(maxWidth: 220).accessibility { $0.label = L("Context") + " " + leaf }
            .debugName("editor-focus-chip")
    }
}
