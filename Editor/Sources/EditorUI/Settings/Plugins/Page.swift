internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime
private import Foundation

/// Installed plugins as one list of rows, a switch each; adding a package
/// opens a review card above the list before anything is loaded.
struct PluginSettings: View {
    let app: EditorApplication
    @State private var category = ""

    init(app: EditorApplication, category: String = "") {
        self.app = app
        _category = State(wrappedValue: category)
    }

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
                        isAlreadyEnabled: management.installed.contains { $0.id == candidate.id && $0.lifecycle.isEnabled }, onEnable: {
                            Task { @MainActor in await app.authorizeAndEnableInspectedPlugin() }
                        }, onCancel: { Task { @MainActor in app.cancelPluginApproval() } })
                }
            }
            Select(selection: $category, options: [.init(value: "", label: L("All"))]
                + PluginCategory.allCases.map { .init(value: $0.rawValue, label: L($0.rawValue)) }, width: 220)
                .debugName("settings-plugin-category")
            SettingsCard(L("Installed")) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    BundledPluginRows(app: app, management: management, isBusy: busy, category: category) { actions(for: $0, isBusy: busy) }
                    for plugin in management.installed where !app.bundledPlugins.contains(where: { $0.id == plugin.id })
                        && (category.isEmpty || plugin.categories.contains { $0.rawValue == category }) {
                        PluginRow(listing: PluginListing(plugin), isEnabled: plugin.lifecycle.isEnabled, isBusy: busy,
                                  onToggle: { on in Task { @MainActor in await app.setInstalledPlugin(id: plugin.id, enabled: on) } },
                                  actions: actions(for: plugin, isBusy: busy))
                    }
                    if management.phase == .inspecting {
                        Row(alignment: .center, spacing: 8) {
                            Spinner(size: 12)
                            Text(L("Inspecting plugin without loading it…")).font(.caption).foregroundColor(.onSurfaceMuted)
                        }.padding(horizontal: 4, vertical: 6)
                    }
                    Button(isEnabled: !busy, action: choosePackage) {
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
            .item(MenuItem(id: "reload", title: L("Reload"), isEnabled: !isBusy && plugin.lifecycle.isEnabled) {
                Task { @MainActor in await app.reloadPluginFromManagement(id: plugin.id) }
            }),
            .separator("plugin-authorization"),
            .item(MenuItem(id: "revoke", title: L("Revoke Authorization"), isEnabled: !isBusy, role: .destructive) {
                Task { @MainActor in await app.revokePluginFromManagement(id: plugin.id) }
            }),
            .item(MenuItem(id: "uninstall", title: L("Uninstall"), isEnabled: !isBusy, role: .destructive) {
                Task { @MainActor in await app.uninstallPluginFromManagement(id: plugin.id) }
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
    let category: String
    let actions: (EditorPluginInspectionSummary) -> [MenuEntry]
    private let versionControl: Observed<EditorVersionControl, VersionControlSnapshot>

    init(app: EditorApplication, management: EditorPluginManagementState, isBusy: Bool, category: String,
         actions: @escaping (EditorPluginInspectionSummary) -> [MenuEntry]) {
        self.app = app
        self.management = management
        self.isBusy = isBusy
        self.category = category
        self.actions = actions
        versionControl = Observed(\.snapshot, on: app.workstation.versionControl)
    }

    var body: some View {
        let snapshot = versionControl.wrappedValue
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            for plugin in app.bundledPlugins where category.isEmpty || plugin.categories.contains(where: { $0.rawValue == category }) {
                let loaded = management.installed.first { $0.id == plugin.id }
                let enabled = loaded?.lifecycle.isEnabled ?? false
                let missing = plugin.categories.contains(.versionControl)
                    && !snapshot.installedSystems.contains(where: { plugin.host == .versionControl($0) })
                    ? plugin.commands.first : nil
                AnyView(PluginRow(listing: PluginListing(bundled: plugin, loaded: loaded, missingCommand: missing),
                                  isEnabled: enabled,
                                  isBusy: isBusy || (plugin.host != .declarative && !app.isPluginHostAvailable)
                                      || (plugin.categories.contains(.versionControl) && snapshot.operation != nil),
                                  onToggle: { on in Task { @MainActor in await app.setBundledPlugin(plugin, enabled: on) } },
                                  actions: loaded.map(actions) ?? []))
            }
        }
    }
}
