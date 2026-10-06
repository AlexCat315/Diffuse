import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct LayoutPresetSelector: View {
    let workspaceMode: EditorWorkspaceMode
    let activePreset: EditorLayoutPreset
    let onSelectPreset: (EditorLayoutPreset) -> Void
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 200) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Layout")).font(.caption).foregroundColor(.onSurfaceVariant)
                Text(L(activePreset.title)).font(.caption).foregroundColor(.onSurface)
                Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(.surfaceSunken).cornerRadius(4)
        } content: {
            Menu(EditorLayoutPreset.presets(for: workspaceMode).map { preset in
                .item(MenuItem(id: preset.rawValue, title: L(preset.title),
                               isSelected: activePreset == preset,
                               action: { onSelectPreset(preset) }))
            }, width: 200, maxVisibleRows: 6, onItemActivated: { isPresented = false })
        }
    }
}
