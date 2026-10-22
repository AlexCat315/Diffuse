internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

/// Installed plugins as one list of rows, a switch each; adding a package
/// opens a review card above the list before anything is loaded.
struct PluginSettings: View {
    let app: EditorApplication

    var body: some View {
        let management = app.store.pluginManagement
        let busy = management.phase == .inspecting || management.phase == .enabling
        let available = app.isPluginHostAvailable
        Box(direction: .column, alignItems: .stretch, spacing: 16) {
            if !available {
                Alert(L("Plugin host unavailable"), message: L("PluginHost is unavailable. Rebuild or reinstall the Editor."), tone: .warning)
            }
            AnimatedVisibility(isVisible: management.message != nil) {
                Alert(management.message ?? "", tone: management.phase == .failed ? .warning : .info)
            }
            // The review card eases in above the list, where the decision is made.
            AnimatedVisibility(isVisible: management.candidate != nil) {
                if let candidate = management.candidate {
                    PluginReviewCard(summary: candidate, isBusy: management.phase == .enabling,
                        isAlreadyEnabled: management.enabled.contains { $0.id == candidate.id }, onEnable: {
                            Task { @MainActor in await app.authorizeAndEnableInspectedPlugin() }
                        }, onCancel: { Task { @MainActor in app.cancelPluginApproval() } })
                }
            }
            SettingsCard(L("Installed"), subtitle: L("Plugins run isolated and only get the access you approve.")) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    BundledPluginRows(app: app, management: management, isBusy: busy || !available) { actions(for: $0, isBusy: busy) }
                    for plugin in management.enabled where !app.bundledPlugins.contains(where: { $0.id == plugin.id }) {
                        PluginRow(listing: PluginListing(plugin), isEnabled: true, isBusy: busy,
                                  onToggle: { _ in Task { @MainActor in await app.disablePluginFromManagement(id: plugin.id) } },
                                  actions: actions(for: plugin, isBusy: busy))
                    }
                    if management.phase == .inspecting {
                        Row(alignment: .center, spacing: 8) {
                            Spinner(size: 12)
                            Text(L("Inspecting plugin without loading it…")).font(.caption).foregroundColor(.onSurfaceMuted)
                        }.padding(horizontal: 4, vertical: 6)
                    }
                    Button(isEnabled: available && !busy, action: choosePackage) {
                        Row(alignment: .center, spacing: 8) {
                            Icon(UIIcons.File.folderPlus, size: 13, color: .onSurfaceVariant)
                            Text(L("Add from Folder…")).font(.label)
                        }
                    }.buttonStyle(.secondary).debugName("settings-plugin-choose")
                }
            }
        }
    }

    private func actions(for plugin: EditorPluginInspectionSummary, isBusy: Bool) -> [MenuEntry] {
        [
            .item(MenuItem(id: "reload", title: L("Reload"), isEnabled: !isBusy) {
                Task { @MainActor in await app.reloadPluginFromManagement(id: plugin.id) }
            }),
            .separator("plugin-authorization"),
            .item(MenuItem(id: "revoke", title: L("Revoke Authorization"), isEnabled: !isBusy, role: .destructive) {
                Task { @MainActor in await app.revokePluginFromManagement(id: plugin.id) }
            }),
        ]
    }

    private func choosePackage() {
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Plugin picker is unavailable", severity: .error,
                           detail: "No active display is available to present the folder picker.")
            return
        }
        MainActor.assumeIsolated {
            display.requestOpenFolder(defaultPath: app.projectDirectory) { path in
                guard let path else { return }
                Task { @MainActor in await app.inspectPluginForManagement(at: URL(fileURLWithPath: path, isDirectory: true)) }
            }
        }
    }
}

/// Every plugin that ships with the editor, listed whether on or off, wherever
/// it runs. Its switch is the project's choice.
private struct BundledPluginRows: View, @unchecked Sendable {
    let app: EditorApplication
    let management: EditorPluginManagementState
    let isBusy: Bool
    let actions: (EditorPluginInspectionSummary) -> [MenuEntry]
    private let versionControl: Observed<EditorVersionControl, VersionControlSnapshot>

    init(app: EditorApplication, management: EditorPluginManagementState, isBusy: Bool,
         actions: @escaping (EditorPluginInspectionSummary) -> [MenuEntry]) {
        self.app = app
        self.management = management
        self.isBusy = isBusy
        self.actions = actions
        versionControl = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    var body: some View {
        let snapshot = versionControl.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            for plugin in app.bundledPlugins {
                let loaded = management.enabled.first { $0.id == plugin.id }
                let state: (enabled: Bool, missing: String?) = switch plugin.host {
                case .application: (loaded != nil, nil)
                case let .versionControl(system):
                    (!snapshot.disabledSystems.contains(system), snapshot.installedSystems.contains(system) ? nil : plugin.commands.first)
                }
                AnyView(PluginRow(listing: PluginListing(bundled: plugin, loaded: loaded, missingCommand: state.missing),
                                  isEnabled: state.enabled, isBusy: isBusy || snapshot.operation != nil,
                                  onToggle: { on in Task { @MainActor in await app.setBundledPlugin(plugin, enabled: on) } },
                                  actions: loaded.map(actions) ?? []))
            }
        }
    }
}
