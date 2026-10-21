internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct LanguageServerStatus: View {
    let app: EditorApplication
    let snapshot: ScriptWorkspaceSnapshot
    let onCommand: (EditorCommand) -> Void
    @State private var isPresented = false
    @State private var showsLogs = false
    @State private var showsToolchains = false
    @State private var toolchains: LanguageToolchainSession? = nil

    var body: some View {
        Popover(isPresented: Binding(get: { isPresented }, set: { value in
            isPresented = value
            if value && toolchains == nil { toolchains = LanguageToolchainSession(app: app) }
        }), width: 480, placement: .topTrailing, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 5) {
                statusDot
                Text(L(activityTitle)).font(.caption).foregroundColor(.onSurfaceMuted)
            }.padding(horizontal: 6).frame(height: 20)
                .accessibility { $0.label = L("Language Server") + ": Swift · " + L(stateTitle) }
        } content: {
            Column(alignment: .leading, spacing: 6) {
                Row(alignment: .center, spacing: 6) {
                    statusDot
                    Text("Swift · " + L(stateTitle)).font(.caption).foregroundColor(.onSurfaceVariant)
                }.padding(horizontal: 12, vertical: 6)
                if let details = snapshot.languageServiceDetails, snapshot.languageServiceState != .inactive {
                    Text(healthTitle(details.health), lineLimit: 3).font(.caption)
                        .foregroundColor(statusColor).padding(horizontal: 12)
                    if let indexing = details.indexing {
                        Row(spacing: 6) {
                            Spinner(size: 10)
                            Text(indexing.title + (indexing.message.map { " · " + $0 } ?? "")).font(.caption)
                            if let percentage = indexing.percentage { Text("\(percentage)%").font(.caption) }
                        }.padding(horizontal: 12)
                    }
                    if let bytes = details.residentMemoryBytes {
                        Text("SourceKit-LSP · \(bytes / 1_048_576) MB RSS").font(.caption)
                            .foregroundColor(.onSurfaceMuted).padding(horizontal: 12)
                    }
                }
                if let toolchain = snapshot.swiftToolchain {
                    Text(toolchain.version, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceMuted).padding(horizontal: 12)
                }
                Menu(entries, width: 480)
                if showsLogs { LanguageServerLogView(details: snapshot.languageServiceDetails) }
                if showsToolchains, let toolchains {
                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        LanguageToolchainPanel(session: toolchains, snapshot: snapshot)
                    }.frame(height: 340)
                }
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
        if snapshot.toolchainActivity.isBusy { return .warning }
        if case .degraded? = snapshot.languageServiceDetails?.health { return .error }
        switch snapshot.languageServiceState {
        case .ready: return snapshot.languageServiceDetails?.health == .healthy ? .success : .warning
        case .starting: return .warning
        case .unavailable: return .error
        case .inactive: return .onSurfaceMuted
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

    private var activityTitle: String {
        switch snapshot.toolchainActivity {
        case .selecting: "Checking Swift Toolchain…"
        case .installation(.downloading): "Downloading Swift…"
        case .installation(.verifying): "Verifying Swift…"
        case .installation(.installing): "Installing Swift…"
        default: snapshot.swiftToolchain == nil ? "Swift Toolchain Not Installed" : "Language Server"
        }
    }

    private func healthTitle(_ health: ScriptAnalysisHealth) -> String {
        switch health {
        case .checking: L("Checking semantic analysis…")
        case .healthy: L("Semantic analysis healthy")
        case let .degraded(reason): L("Semantic analysis unavailable") + ": " + reason
        }
    }

    private var entries: [MenuEntry] {
        let enabled = app.store.pluginManagement.enabled.contains { $0.id == "studio.swift-support" }
        return [
            .submenu(MenuSubmenu(id: "swift-language-server", title: "SourceKit-LSP", entries: [
                .item(MenuItem(id: "language-server-logs", title: L("View Logs"), action: {
                    showsLogs.toggle()
                    showsToolchains = false
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
            .item(MenuItem(id: "language-server-toolchains", title: L("Swift Toolchains…"), action: {
                if toolchains == nil { toolchains = LanguageToolchainSession(app: app) }
                showsToolchains.toggle()
                showsLogs = false
            })),
            .item(MenuItem(id: "language-server-settings", title: L("Settings..."), action: {
                isPresented = false
                onCommand(.openSettings)
            })),
        ]
    }
}
