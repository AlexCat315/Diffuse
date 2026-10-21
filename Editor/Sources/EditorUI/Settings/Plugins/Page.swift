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
            if let message = management.message {
                Alert(message, tone: management.phase == .failed ? .warning : .info)
            }
            if let candidate = management.candidate {
                PluginReviewCard(summary: candidate, isBusy: management.phase == .enabling,
                    isAlreadyEnabled: management.enabled.contains { $0.id == candidate.id }, onEnable: {
                        Task { @MainActor in await app.authorizeAndEnableInspectedPlugin() }
                    }, onCancel: { Task { @MainActor in app.cancelPluginApproval() } })
            }
            SettingsCard(L("Installed"), subtitle: L("Plugins run isolated and only get the access you approve.")) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    swiftSupportRow(management: management, isBusy: busy || !available)
                    for plugin in management.enabled where plugin.id != PluginRow.swiftSupportID {
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

    /// The bundled plugin stays listed while disabled, so it can be switched
    /// back on without hunting for its package.
    private func swiftSupportRow(management: EditorPluginManagementState, isBusy: Bool) -> some View {
        let enabled = management.enabled.first { $0.id == PluginRow.swiftSupportID }
        return PluginRow(listing: enabled.map(PluginListing.init) ?? .swiftSupport, isEnabled: enabled != nil, isBusy: isBusy,
            onToggle: { on in
                Task { @MainActor in
                    if on { await app.inspectBundledSwiftSupport() }
                    else { await app.disablePluginFromManagement(id: PluginRow.swiftSupportID) }
                }
            },
            actions: enabled.map { actions(for: $0, isBusy: isBusy) } ?? [])
            .debugName("settings-plugin-swift-support")
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
