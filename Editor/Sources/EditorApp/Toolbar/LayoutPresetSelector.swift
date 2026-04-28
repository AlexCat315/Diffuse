import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct LayoutPresetSelector: View {
    let workspaceMode: EditorWorkspaceMode
    let activePreset: EditorLayoutPreset
    let onSelectPreset: (EditorLayoutPreset) -> Void
    @State private var isPresented: Bool = false

    init(workspaceMode: EditorWorkspaceMode,
         activePreset: EditorLayoutPreset,
         onSelectPreset: @escaping (EditorLayoutPreset) -> Void) {
        self.workspaceMode = workspaceMode
        self.activePreset = activePreset
        self.onSelectPreset = onSelectPreset
        _isPresented = State(wrappedValue: false)
    }

    var body: some View {
        Popover(isPresented: $isPresented,
                width: 132) {
            Row(alignment: .center, spacing: 6) {
                Text(L("Preset"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceVariant)

                Text(shortLabel(for: activePreset))
                    .font(.caption)
                    .foregroundColor(.onSurface)

                Text("▼")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(.surfaceSunken)
            .cornerRadius(4)
        } content: {
            Menu(menuEntries,
                 width: 132,
                 maxVisibleRows: 6,
                 onItemActivated: {
                isPresented = false
            })
        }
    }

    private var menuEntries: [MenuEntry] {
        switch workspaceMode {
        case .level:
            return [
                .item(MenuItem(id: "level-default",
                               title: L("Default"),
                               action: { onSelectPreset(.levelDefault) })),
                .item(MenuItem(id: "level-cine",
                               title: L("Cine"),
                               action: { onSelectPreset(.levelCinematics) })),
            ]
        case .modeling:
            return [
                .item(MenuItem(id: "modeling-default",
                               title: L("Default"),
                               action: { onSelectPreset(.modelingDefault) })),
                .item(MenuItem(id: "modeling-sculpt",
                               title: L("Sculpt"),
                               action: { onSelectPreset(.modelingSculpt) })),
            ]
        case .animation:
            return [
                .item(MenuItem(id: "animation-default",
                               title: L("Default"),
                               action: { onSelectPreset(.animationDefault) })),
                .item(MenuItem(id: "animation-seq",
                               title: L("Seq"),
                               action: { onSelectPreset(.animationSequencer) })),
            ]
        }
    }

    private func shortLabel(for preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault, .modelingDefault, .animationDefault:
            return L("Default")
        case .levelCinematics:
            return L("Cine")
        case .modelingSculpt:
            return L("Sculpt")
        case .animationSequencer:
            return L("Seq")
        }
    }
}