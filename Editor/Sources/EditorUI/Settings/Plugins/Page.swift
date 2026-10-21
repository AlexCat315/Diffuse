internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct PluginSettings: View {
    let app: EditorApplication

    var body: some View {
        let management = app.store.pluginManagement
        let busy = management.phase == .inspecting || management.phase == .enabling
        SettingsCard(L("AI Plugins"), subtitle: L("Review a package and its capabilities before enabling it.")) {
            if !app.isPluginHostAvailable {
                Alert(L("Plugin host unavailable"), message: L("PluginHost is unavailable. Rebuild or reinstall the Editor."), tone: .warning)
            }
            Button(L("Choose .guavaplugin Folder"), isEnabled: app.isPluginHostAvailable && !busy, action: choosePackage)
                .buttonStyle(.primary).debugName("settings-plugin-choose")
            if !management.enabled.contains(where: { $0.id == "studio.swift-support" }) {
                Button(L("Enable Swift Support"), isEnabled: app.isPluginHostAvailable && !busy) {
                    Task { @MainActor in await app.inspectBundledSwiftSupport() }
                }.debugName("settings-plugin-swift-support")
            }
            if management.phase == .inspecting {
                Text(L("Inspecting plugin without loading it…")).font(.body).foregroundColor(.onSurfaceMuted)
            }
            if let message = management.message {
                Alert(message, tone: management.phase == .failed ? .warning : .info)
            }
            if let candidate = management.candidate {
                PluginInspectionCard(summary: candidate, isBusy: management.phase == .enabling,
                    isAlreadyEnabled: management.enabled.contains { $0.id == candidate.id }, onEnable: {
                        Task { @MainActor in await app.authorizeAndEnableInspectedPlugin() }
                    }, onCancel: { Task { @MainActor in app.cancelPluginApproval() } })
            }
            Row(alignment: .center, spacing: 8) {
                Text(L("Enabled Plugins")).font(.label).foregroundColor(.onSurface)
                Text("\(management.enabled.count)").font(.caption).foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 6, vertical: 2).background(.surfaceVariant).cornerRadius(5)
            }
            if management.enabled.isEmpty {
                Column(alignment: .leading, spacing: 6) {
                    Text(L("A focused workspace, ready to extend.")).font(.bodyStrong).foregroundColor(.onSurfaceVariant)
                    Text(L("No extensions are enabled. Choose a package to inspect its access and capabilities."))
                        .font(.body).foregroundColor(.onSurfaceMuted)
                }.padding(16).frame(width: .percent(100), minWidth: 0).background(.surfaceSunken).cornerRadius(7)
            }
            for plugin in management.enabled {
                EnabledPluginRow(plugin: plugin, isBusy: busy,
                    onReload: { Task { @MainActor in await app.reloadPluginFromManagement(id: plugin.id) } },
                    onDisable: { Task { @MainActor in await app.disablePluginFromManagement(id: plugin.id) } },
                    onRevoke: { Task { @MainActor in await app.revokePluginFromManagement(id: plugin.id) } })
            }
        }
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
