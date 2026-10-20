internal import GuavaUI
internal import GuavaUIRuntime

/// Where the command tree appears. macOS owns a native menu bar. Windows and
/// Linux windows draw an immersive title bar in the client area, where a
/// platform menu strip would sit below it, so they show the same tree from a
/// title-bar button instead.
enum EditorMenuPresentation {
    case native
    case titleBar

    static var current: Self {
        #if os(macOS)
        .native
        #else
        .titleBar
        #endif
    }
}

/// The command catalog as one compact title-bar menu; each top-level menu is a
/// submenu, so the title bar keeps its width at every window size.
struct EditorTitleMenu: View {
    let catalog: EditorCommandCatalog
    let onCommand: (EditorCommand) -> Void
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 236, surface: .content, overflow: .flip) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Icon(UIIcons.Navigation.menu, size: 14, color: isPresented ? .onSurface : .onSurfaceVariant)
            }
            .frame(width: 28, height: 26)
            .background(isPresented ? .surfaceVariant : .clear)
            .cornerRadius(6)
            .accessibility { $0.label = L("Application Menu"); $0.state.isExpanded = isPresented }
        } content: {
            Menu(catalog.menusWithApplicationItems.map { menu in
                .submenu(MenuSubmenu(id: menu.id, title: menu.title, entries: entries(menu.items)) { $0.width = 260 })
            }, width: 200, maxVisibleRows: 12, onItemActivated: { isPresented = false })
        }
        .debugName("editor-title-menu")
    }

    private func entries(_ items: [EditorCommandItem]) -> [MenuEntry] {
        items.enumerated().map { index, item in
            switch item {
            case .separator:
                return .separator("separator-\(index)")
            case let .submenu(menu):
                return .submenu(MenuSubmenu(id: menu.id, title: menu.title, entries: entries(menu.items)))
            case let .entry(entry):
                return .item(MenuItem(id: entry.id,
                                      title: entry.title,
                                      shortcut: entry.shortcut?.label,
                                      isEnabled: EditorCommandDispatcher.isEnabled(entry.command,
                                                                                   sceneCommandEnabled: entry.isEnabled),
                                      isSelected: entry.isSelected,
                                      action: { onCommand(entry.command) }))
            }
        }
    }
}
