internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct LanguageServerStatus: View {
    let app: EditorApplication
    let snapshot: ScriptWorkspaceSnapshot
    let onCommand: (EditorCommand) -> Void
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 250, placement: .topTrailing, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 5) {
                statusDot
                Text(L("Language Server")).font(.caption).foregroundColor(.onSurfaceMuted)
            }.padding(horizontal: 6).frame(height: 20)
                .accessibility { $0.label = L("Language Server") + ": Swift · " + L(stateTitle) }
        } content: {
            Column(alignment: .leading, spacing: 6) {
                Row(alignment: .center, spacing: 6) {
                    statusDot
                    Text("Swift · " + L(stateTitle)).font(.caption).foregroundColor(.onSurfaceVariant)
                }.padding(horizontal: 12, vertical: 6)
                Menu(entries, width: 250)
                if case let .unavailable(message) = snapshot.languageServiceState {
                    Text(message, lineLimit: 4).font(.caption).foregroundColor(.warning)
                        .padding(horizontal: 12, vertical: 6)
                }
            }.background(.surface).cornerRadius(8).border(.divider, width: 1)
        }.debugName("editor-status-language-server")
    }

    private var statusDot: some View {
        Box { EmptyView() }.frame(width: 6, height: 6).background(statusColor).cornerRadius(3)
    }

    private var statusColor: SemanticColorRef {
        switch snapshot.languageServiceState {
        case .ready: .success
        case .starting: .warning
        case .unavailable: .error
        case .inactive: .onSurfaceMuted
        }
    }

    private var stateTitle: String {
        switch snapshot.languageServiceState {
        case .ready: "Running"
        case .starting: "Starting"
        case .inactive: "Stopped"
        case .unavailable: "Unavailable"
        }
    }

    private var entries: [MenuEntry] {
        let enabled = app.store.pluginManagement.enabled.contains { $0.id == "studio.swift-support" }
        return [
            .submenu(MenuSubmenu(id: "swift-language-server", title: "SourceKit-LSP", entries: [
                .item(MenuItem(id: "language-server-logs", title: L("View Logs"), action: {
                    isPresented = false
                    if case let .unavailable(message) = snapshot.languageServiceState {
                        app.logConsole("Swift language server", severity: .warning, detail: message)
                    } else {
                        app.logConsole("Swift language server", detail: L(stateTitle))
                    }
                    onCommand(.showPanel("console"))
                })),
                .item(MenuItem(id: "language-server-restart", title: L(snapshot.languageServiceState == .inactive ? "Start Server" : "Restart Server"),
                    isEnabled: enabled && !snapshot.documents.isEmpty, action: {
                        isPresented = false
                        app.workstation.scripts.stopLanguageService()
                        app.workstation.scripts.retryLanguageService()
                    })),
                .item(MenuItem(id: "language-server-stop", title: L("Stop Server"),
                    isEnabled: enabled && snapshot.languageServiceState != .inactive, action: {
                        isPresented = false
                        app.workstation.scripts.stopLanguageService()
                    })),
                .separator(id: "language-server-state-separator"),
                .label(id: "language-server-state", title: L(stateTitle)),
            ]) { $0.width = 230 }),
            .item(MenuItem(id: "language-server-settings", title: L("Settings..."), action: {
                isPresented = false
                onCommand(.openSettings)
            })),
        ]
    }
}
