import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct EditorApplicationMenuBar: View {
    let workspaceMode: EditorWorkspaceMode
    let activeLayoutPreset: EditorLayoutPreset
    let playbackState: PlaybackState
    let onCommand: (EditorMenuCommand) -> Void
    @State private var openMenuIndex: Int? = nil

    init(workspaceMode: EditorWorkspaceMode,
         activeLayoutPreset: EditorLayoutPreset,
         playbackState: PlaybackState,
         onCommand: @escaping (EditorMenuCommand) -> Void) {
        self.workspaceMode = workspaceMode
        self.activeLayoutPreset = activeLayoutPreset
        self.playbackState = playbackState
        self.onCommand = onCommand
        _openMenuIndex = State(wrappedValue: nil)
    }

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            for (index, menu) in Array(menus.enumerated()) {
                menuButton(menu, index: index)
            }
        }
        .frame(height: 28, minWidth: menuBarMinimumWidth)
        .flex(0, shrink: 0)
        .zIndex(20_000)
        .layoutRole("editor-application-menu-bar")
        .debugName("editor-application-menu-bar")
    }

    private func menuButton(_ menu: EditorApplicationMenu, index: Int) -> AnyView {
        let isPresented = Binding<Bool>(
            get: { openMenuIndex == index },
            set: { presented in
                if presented {
                    openMenuIndex = index
                } else if openMenuIndex == index {
                    openMenuIndex = nil
                }
            }
        )

        return AnyView(Popover(isPresented: isPresented,
                               width: 220) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(menu.title)
                    .font(.body)
                    .foregroundColor(openMenuIndex == index ? .onSurface : .onSurfaceVariant)
            }
                .padding(horizontal: 10, vertical: 0)
                .frame(height: 28)
                .background(openMenuIndex == index ? .surfaceVariant : .surface)
                .cornerRadius(4)
        } content: {
            Menu(entries(for: menu),
                 width: 220,
                 maxVisibleRows: 12,
                 onItemActivated: {
                openMenuIndex = nil
            })
        })
    }

    private var menuBarMinimumWidth: Float {
        menus.reduce(Float(0)) { width, menu in
            width + max(44, Float(menu.title.count * 9 + 24))
        } + Float(max(0, menus.count - 1) * 2)
    }

    private func entries(for menu: EditorApplicationMenu) -> [MenuEntry] {
        menu.items.enumerated().map { index, item in
            switch item {
            case .separator:
                return .separator("separator-\(index)")
            case .action(let action):
                return .item(MenuItem(
                    id: "action-\(index)",
                    title: action.isSelected ? "[x] \(action.title)" : action.title,
                    shortcut: shortcutLabel(key: action.keyEquivalent,
                                            modifiers: action.keyModifiers),
                    isEnabled: action.isEnabled,
                    action: {
                        onCommand(action.command)
                    }
                ))
            }
        }
    }

    private func shortcutLabel(key: String, modifiers: EditorMenuKeyModifiers) -> String? {
        guard !key.isEmpty else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.command) { parts.append(commandModifierLabel) }
        parts.append(key.uppercased())
        return parts.joined(separator: "+")
    }

    private var commandModifierLabel: String {
        #if os(macOS)
        "Cmd"
        #else
        "Meta"
        #endif
    }

    private var menus: [EditorApplicationMenu] {
        EditorMenuModel.make(workspaceMode: workspaceMode,
                             activeLayoutPreset: activeLayoutPreset,
                             playbackState: playbackState).menus
    }
}
