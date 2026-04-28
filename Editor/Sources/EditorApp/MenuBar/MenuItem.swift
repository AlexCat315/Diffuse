import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import Foundation

struct EditorMenuItem: View {
    let title: String
    let menuWidth: Float
    let entries: [EditorMenuEntry]
    let onCommand: (EditorMenuCommand) -> Void
    @State private var isPresented: Bool = false

    init(title: String,
         menuWidth: Float,
         entries: [EditorMenuEntry],
         onCommand: @escaping (EditorMenuCommand) -> Void) {
        self.title = title
        self.menuWidth = menuWidth
        self.entries = entries
        self.onCommand = onCommand
        _isPresented = State(wrappedValue: false)
    }

    var body: some View {
        Popover(isPresented: $isPresented,
                width: menuWidth) {
            Row(alignment: .center, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(isPresented ? .onSurface : .onSurfaceVariant)
                Text("▾")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 8, vertical: 6)
            .background(isPresented ? .surfaceSunken : .surface)
            .cornerRadius(4)
        } content: {
            Menu(menuEntries,
                 width: menuWidth,
                 maxVisibleRows: 10,
                 onItemActivated: {
                isPresented = false
            })
        }
    }

    private var menuEntries: [MenuEntry] {
        entries.map { entry in
            switch entry {
            case .separator(let id):
                return .separator(id)
            case .item(let id, let label, let shortcut, let command):
                return .item(MenuItem(id: id,
                                      title: label,
                                      shortcut: shortcut,
                                      action: {
                    onCommand(command)
                }))
            }
        }
    }
}

enum EditorMenuCommand {
    case newScene
    case openScene
    case saveScene
    case importAssets
    case undo
    case redo
    case setWorkspaceMode(EditorWorkspaceMode)
    case setLayoutPreset(EditorLayoutPreset)
    case resetLayout
    case setPlaybackState(PlaybackState)
    case openSettings
    case toggleTheme
    case buildProject
    case buildAndRun
    case openDocumentation
    case about
}

enum EditorMenuEntry {
    case item(String, String, String?, EditorMenuCommand)
    case separator(String)
}