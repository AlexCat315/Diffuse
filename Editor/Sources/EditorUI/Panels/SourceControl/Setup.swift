internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Shown when the project has no working tree, or its tool is not installed:
/// start a Git repository here, or create a Lore repository on a server.
struct SourceControlSetup: View, @unchecked Sendable {
    let app: EditorApplication
    let snapshot: VersionControlSnapshot
    @State private var loreRemote: TextBuffer = "lore://127.0.0.1:41337/"

    private var model: EditorVersionControl { app.workstation.versionControl }

    var body: some View {
        ScrollView(.vertical, scrollbarGutter: .stable) {
            Column(alignment: .leading, spacing: 14) {
                Icon(UIIcons.Editor.gitBranch, size: 20, color: .onSurfaceVariant)
                    .frame(width: 40, height: 40).background(.surfaceVariant).cornerRadius(10)
                if case let .toolMissing(system) = snapshot.availability {
                    Text(String(format: L("%@ is not installed"), system.title)).font(.headline)
                    Text(installHint(system)).font(.caption).foregroundColor(.onSurfaceVariant)
                    Button(L("Check Again")) { Task { await model.refresh() } }.buttonStyle(.secondary)
                } else {
                    Text(L("Track your project's history")).font(.headline)
                    Text(L("Version control records every change, lets you go back, and shares work with others."))
                        .font(.caption).foregroundColor(.onSurfaceVariant)
                    option(title: "Git", detail: L("Best for text, code and small assets. Works offline in this folder."),
                           installed: snapshot.installedSystems.contains(.git)) {
                        Button(L("Initialize Git Repository")) { Task { await model.initialize(.git) } }
                            .buttonStyle(.primary).controlSize(.small).debugName("source-control-init-git")
                    }
                    option(title: "Lore", detail: L("Epic Games' version control for large binary assets, with file locking. Needs a Lore server."),
                           installed: snapshot.installedSystems.contains(.lore)) {
                        Column(alignment: .leading, spacing: 6) {
                            TextField(L("Repository URL"), text: $loreRemote) { $0.decoration.size = .small }
                                .font(.caption).frame(width: .percent(100))
                            Button(L("Create Lore Repository")) {
                                let remote = loreRemote.stringValue.trimmingCharacters(in: .whitespaces)
                                Task { await model.initialize(.lore, loreRemote: remote) }
                            }.buttonStyle(.secondary).controlSize(.small).debugName("source-control-init-lore")
                        }
                    }
                }
                if let error = snapshot.error {
                    Text(error, lineLimit: 6).font(.caption).foregroundColor(.error)
                }
                if snapshot.operation != nil { Spinner(size: 12) }
            }.padding(16).frame(width: .percent(100), minWidth: 0)
        }.debugName("source-control-setup")
    }

    private func option<Action: View>(title: String, detail: String, installed: Bool,
                                      @ViewBuilder action: () -> Action) -> some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 6) {
                Text(title).font(.bodyStrong)
                if !installed { EditorPanelBadge(L("Not installed"), foreground: .warning) }
            }
            Text(detail).font(.caption).foregroundColor(.onSurfaceMuted)
            if installed { action() } else {
                Text(installHint(title == "Git" ? .git : .lore)).font(.caption).foregroundColor(.onSurfaceVariant)
            }
        }.padding(12).frame(width: .percent(100), minWidth: 0).background(.surfaceRaised).cornerRadius(10)
    }

    private func installHint(_ system: VersionControlSystem) -> String {
        switch system {
        case .git: L("Install Git (on macOS: xcode-select --install), then check again.")
        case .lore: L("Install the Lore CLI from github.com/EpicGames/lore (it installs to ~/.local/bin), then check again.")
        }
    }
}
