internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// The Swift language service in the status bar: a dot for its state, and a
/// card that says why it is in that state, what it covers and how to change it.
struct LanguageServerStatus: View {
    let app: EditorApplication
    let snapshot: ScriptWorkspaceSnapshot
    let onCommand: (EditorCommand) -> Void
    @State private var isPresented = false
    @State private var page = Page.overview
    @State private var toolchains: LanguageToolchainSession? = nil

    enum Page: String, CaseIterable { case overview, logs, toolchains }

    var body: some View {
        Popover(isPresented: Binding(get: { isPresented }, set: { value in
            isPresented = value
            if value && toolchains == nil { toolchains = LanguageToolchainSession(app: app) }
        }), width: 420, placement: .topTrailing, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 5) {
                statusDot
                Text(L(activityTitle)).font(.caption).foregroundColor(.onSurfaceMuted)
            }.padding(horizontal: 6).frame(height: 20)
                .accessibility { $0.label = L("Language Server") + ": Swift · " + L(stateTitle) }
        } content: {
            Column(alignment: .leading, spacing: 0) {
                header
                pages
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    switch page {
                    case .overview: overview
                    case .logs: LanguageServerLogView(details: snapshot.languageServiceDetails)
                    case .toolchains:
                        if let toolchains {
                            ScrollView(.vertical, scrollbarGutter: .stable) {
                                LanguageToolchainPanel(session: toolchains, snapshot: snapshot)
                            }.frame(height: 320)
                        }
                    }
                }.frame(width: .percent(100), minWidth: 0)
                footer
            }.frame(width: .percent(100), minWidth: 0).background(.surface).cornerRadius(12).border(.divider, width: 1)
        }.debugName("editor-status-language-server")
    }

    // MARK: Card

    private var header: some View {
        Row(alignment: .center, spacing: 10) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                FileIcon(path: "Language.swift", size: 18)
            }.frame(width: 34, height: 34).background(.surfaceVariant).cornerRadius(9)
            Column(alignment: .leading, spacing: 2) {
                Text(L("Swift Language Service")).font(.bodyStrong).foregroundColor(.onSurface)
                Text(snapshot.swiftToolchain?.version ?? L("No Swift toolchain"), lineLimit: 1)
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }.flex(1, shrink: 1).frame(minWidth: 0)
            Row(alignment: .center, spacing: 5) {
                statusDot
                Text(L(stateTitle)).font(.caption).foregroundColor(statusColor)
            }.padding(horizontal: 8).frame(height: 22).background(statusColor.opacity(0.12)).cornerRadius(11)
        }.padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14)).frame(width: .percent(100), minWidth: 0)
    }

    private var pages: some View {
        Row(alignment: .center, spacing: 4) {
            for option in Page.allCases {
                AnyView(Button(L(title(option)), isSelected: page == option) { page = option }
                    .buttonStyle(ToggleButtonStyle(height: 24))
                    .accessibility { $0.state.isSelected = page == option }
                    .debugName("language-server-page-" + option.rawValue))
            }
        }.padding(EdgeInsets(leading: 14, bottom: 6, trailing: 14))
    }

    private var overview: some View {
        Column(alignment: .leading, spacing: 10) {
            if let reason {
                Row(alignment: .top, spacing: 8) {
                    Icon(reason.isProblem ? UIIcons.Status.alertTriangle : UIIcons.Status.info, size: 12,
                         color: reason.isProblem ? .warning : .onSurfaceVariant)
                    Text(reason.text, lineLimit: 5).font(.caption).foregroundColor(.onSurfaceVariant)
                        .flex(1, shrink: 1).frame(minWidth: 0)
                }.padding(10).frame(width: .percent(100), minWidth: 0).background(.surfaceVariant).cornerRadius(8)
            }
            fact(L("Analyzes"), snapshot.documents.isEmpty ? L("No open Swift files")
                 : String(format: L("%d open Swift file(s), %d game script(s)"),
                          snapshot.documents.count - snapshot.scripts.count, snapshot.scripts.count))
            if let details = snapshot.languageServiceDetails, snapshot.languageServiceState != .inactive {
                fact(L("Semantic Analysis"), healthTitle(details.health))
                if let indexing = details.indexing {
                    fact(L("Indexing"), indexing.title + (indexing.percentage.map { " · \($0)%" } ?? ""))
                }
                if let bytes = details.residentMemoryBytes {
                    fact(L("Memory"), "SourceKit-LSP · \(bytes / 1_048_576) MB")
                }
            }
            fact(L("Plugin"), isPluginEnabled ? "Swift Support · " + L("Enabled") : "Swift Support · " + L("Disabled"))
        }.padding(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        Row(alignment: .center, spacing: 8) {
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted).frame(width: 96)
            Text(value, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceVariant).flex(1, shrink: 1).frame(minWidth: 0)
        }
    }

    private var footer: some View {
        let running = snapshot.languageServiceState != .inactive
        let canStart = isPluginEnabled && !snapshot.documents.isEmpty && snapshot.swiftToolchain != nil
        return Row(alignment: .center, spacing: 8) {
            Button(L(running ? "Restart Server" : "Start Server"), isEnabled: canStart) {
                isPresented = false
                app.workstation.scripts.stopLanguageService()
                app.workstation.scripts.retryLanguageService()
            }.buttonStyle(.primary).controlSize(.small).debugName("language-server-restart")
            if running {
                Button(L("Stop Server"), isEnabled: isPluginEnabled) {
                    isPresented = false
                    app.workstation.scripts.stopLanguageService()
                }.buttonStyle(.secondary).controlSize(.small).debugName("language-server-stop")
            }
            Spacer(minLength: 0)
            Button(tooltip: L("Settings...")) {
                isPresented = false
                onCommand(.openSettings)
            } label: {
                Icon(UIIcons.Action.settings, size: 14, color: .onSurfaceVariant)
            }.buttonStyle(EditorChromeButtonStyle(height: 26)).debugName("language-server-settings")
        }.padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14)).frame(width: .percent(100), minWidth: 0)
    }

    // MARK: State

    private var isPluginEnabled: Bool {
        app.store.pluginManagement.installed.contains { $0.id == "studio.swift-support" && $0.lifecycle.isEnabled }
    }

    /// Why the service is in its state, most actionable first.
    private var reason: (text: String, isProblem: Bool)? {
        if case let .unavailable(message) = snapshot.languageServiceState { return (message, true) }
        if snapshot.swiftToolchain == nil {
            return (L("No Swift toolchain was found. Choose or install one under Toolchains."), true)
        }
        if !isPluginEnabled {
            return (L("The Swift Support plugin is off. Turn it on in Settings › Extensions."), true)
        }
        if case let .degraded(reason)? = snapshot.languageServiceDetails?.health {
            return (L("Semantic analysis unavailable") + ": " + reason, true)
        }
        if snapshot.documents.isEmpty {
            return (L("Open a Swift file to start the language service."), false)
        }
        if snapshot.languageServiceState == .inactive { return (L("The language service is stopped."), false) }
        return nil
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

    private func title(_ page: Page) -> String {
        switch page {
        case .overview: "Overview"
        case .logs: "Logs"
        case .toolchains: "Toolchains"
        }
    }

    private func healthTitle(_ health: ScriptAnalysisHealth) -> String {
        switch health {
        case .checking: L("Checking semantic analysis…")
        case .healthy: L("Semantic analysis healthy")
        case let .degraded(reason): L("Semantic analysis unavailable") + ": " + reason
        }
    }
}
