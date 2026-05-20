#if os(Windows)
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
            Spacer()
        }
        .padding(horizontal: 6, vertical: 3)
        .frame(height: 30)
        .background(.surface)
        .zIndex(20_000)
        .layoutRole("editor-application-menu-bar")
        .debugName("editor-application-menu-bar")
    }

    private func menuButton(_ menu: ApplicationMenu, index: Int) -> AnyView {
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
            Text(menu.title)
                .font(.body)
                .foregroundColor(openMenuIndex == index ? .onSurface : .onSurfaceVariant)
                .padding(horizontal: 10, vertical: 5)
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

    private func entries(for menu: ApplicationMenu) -> [MenuEntry] {
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

    private func shortcutLabel(key: String, modifiers: MenuKeyModifiers) -> String? {
        guard !key.isEmpty else { return nil }
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.command) { parts.append("Meta") }
        parts.append(key.uppercased())
        return parts.joined(separator: "+")
    }

    private var menus: [ApplicationMenu] {
        [
            ApplicationMenu(title: L("File"), items: [
                action(L("New Scene"), key: "n", command: .newScene),
                action(L("Open Scene..."), key: "o", command: .openScene),
                action(L("Save Scene"), key: "s", command: .saveScene),
                .separator,
                action(L("Import Assets..."), key: "", command: .importAssets),
            ]),
            ApplicationMenu(title: L("Edit"), items: [
                action(L("Undo"), key: "z", command: .undo),
                action(L("Redo"), key: "z", modifiers: [.control, .shift], command: .redo),
                .separator,
                action(L("Settings"), key: ",", command: .openSettings),
            ]),
            ApplicationMenu(title: L("Window"), items: [
                action(L("Workspace: Level"), key: "", selected: workspaceMode == .level,
                       command: .setWorkspaceMode(.level)),
                action(L("Workspace: Modeling"), key: "", selected: workspaceMode == .modeling,
                       command: .setWorkspaceMode(.modeling)),
                action(L("Workspace: Animation"), key: "", selected: workspaceMode == .animation,
                       command: .setWorkspaceMode(.animation)),
                .separator,
                action(presetTitle(.levelDefault), key: "", selected: activeLayoutPreset == .levelDefault,
                       command: .setLayoutPreset(.levelDefault)),
                action(presetTitle(.levelCinematics), key: "", selected: activeLayoutPreset == .levelCinematics,
                       command: .setLayoutPreset(.levelCinematics)),
                action(presetTitle(.modelingDefault), key: "", selected: activeLayoutPreset == .modelingDefault,
                       command: .setLayoutPreset(.modelingDefault)),
                action(presetTitle(.modelingSculpt), key: "", selected: activeLayoutPreset == .modelingSculpt,
                       command: .setLayoutPreset(.modelingSculpt)),
                action(presetTitle(.animationDefault), key: "", selected: activeLayoutPreset == .animationDefault,
                       command: .setLayoutPreset(.animationDefault)),
                action(presetTitle(.animationSequencer), key: "", selected: activeLayoutPreset == .animationSequencer,
                       command: .setLayoutPreset(.animationSequencer)),
                .separator,
                action(L("Reset Layout"), key: "", command: .resetLayout),
            ]),
            ApplicationMenu(title: L("Tools"), items: [
                action(L("Play"), key: "", selected: playbackState == .playing,
                       command: .setPlaybackState(.playing)),
                action(L("Pause"), key: "", selected: playbackState == .paused,
                       command: .setPlaybackState(.paused)),
                action(L("Stop"), key: "", selected: playbackState == .stopped,
                       command: .setPlaybackState(.stopped)),
                .separator,
                action(L("Toggle Theme"), key: "", command: .toggleTheme),
            ]),
            ApplicationMenu(title: L("Build"), items: [
                action(L("Build Editor"), key: "b", command: .buildProject),
                action(L("Build and Run"), key: "r", command: .buildAndRun),
            ]),
            ApplicationMenu(title: L("Help"), items: [
                action(L("Documentation"), key: "", command: .openDocumentation),
                .separator,
                action(L("About Guava"), key: "", command: .about),
            ]),
        ]
    }

    private func action(_ title: String,
                        key: String,
                        modifiers: MenuKeyModifiers = [.control],
                        selected: Bool = false,
                        command: EditorMenuCommand) -> ApplicationMenuItem {
        .action(ApplicationMenuAction(title: title,
                                      keyEquivalent: key,
                                      keyModifiers: modifiers,
                                      isSelected: selected,
                                      command: command))
    }

    private func presetTitle(_ preset: EditorLayoutPreset) -> String {
        switch preset {
        case .levelDefault:
            return L("Level: Default")
        case .levelCinematics:
            return L("Level: Cinematics")
        case .modelingDefault:
            return L("Modeling: Default")
        case .modelingSculpt:
            return L("Modeling: Sculpt")
        case .animationDefault:
            return L("Animation: Default")
        case .animationSequencer:
            return L("Animation: Sequencer")
        }
    }
}

private struct ApplicationMenu {
    let title: String
    let items: [ApplicationMenuItem]
}

private enum ApplicationMenuItem {
    case action(ApplicationMenuAction)
    case separator
}

private struct ApplicationMenuAction {
    let title: String
    let keyEquivalent: String
    let keyModifiers: MenuKeyModifiers
    var isEnabled: Bool = true
    var isSelected: Bool = false
    let command: EditorMenuCommand
}

private struct MenuKeyModifiers: OptionSet {
    let rawValue: UInt8

    static let command = MenuKeyModifiers(rawValue: 1 << 0)
    static let shift = MenuKeyModifiers(rawValue: 1 << 1)
    static let option = MenuKeyModifiers(rawValue: 1 << 2)
    static let control = MenuKeyModifiers(rawValue: 1 << 3)
}
#endif
