import EditorCore
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

/// Editor settings panel: captioned sections of pill choice buttons.
struct SettingsPanel: View {
    let store: EditorStore
    let app: EditorApplication

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        ScrollView(.vertical, scrollbarGutter: .stable) {
            Column(alignment: .leading, spacing: 14) {
                SettingsSection(title: L("Appearance")) {
                    Row(alignment: .center, spacing: 8) {
                        SettingsChoiceButton(title: L("Dark"),
                                             isActive: store.themeMode == .dark) {
                            store.dispatch(.setThemeMode(.dark))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: L("Light"),
                                             isActive: store.themeMode == .light) {
                            store.dispatch(.setThemeMode(.light))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Vertical Sync")) {
                    Row(alignment: .center, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { store.vsyncMode.isEnabled },
                            set: { enabled in
                                let mode: EditorVSyncMode = enabled ? .enabled : .disabled
                                guard store.vsyncMode != mode else { return }
                                store.dispatch(.setVSyncMode(mode))
                                app.applyVSyncMode(mode)
                                applySettingsChange()
                            }
                        ))

                        Text(store.vsyncMode.isEnabled ? L("On") : L("Off"))
                            .font(.caption)
                            .foregroundColor(.onSurface)
                    }
                }

                SettingsSection(title: L("Language")) {
                    Row(alignment: .center, spacing: 8) {
                        SettingsChoiceButton(title: L("System"),
                                             isActive: store.language == .system) {
                            store.dispatch(.setLanguage(.system))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: "English",
                                             isActive: store.language == .english) {
                            store.dispatch(.setLanguage(.english))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: "简体中文",
                                             isActive: store.language == .simplifiedChinese) {
                            store.dispatch(.setLanguage(.simplifiedChinese))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Selection")) {
                    Row(alignment: .center, spacing: 8) {
                        SettingsChoiceButton(title: L("Subtract"),
                                             isActive: store.primarySelectBehavior == .subtract) {
                            store.dispatch(.setPrimarySelectBehavior(.subtract))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: L("Toggle"),
                                             isActive: store.primarySelectBehavior == .toggle) {
                            store.dispatch(.setPrimarySelectBehavior(.toggle))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Capability Gate")) {
                    Row(alignment: .center, spacing: 8) {
                        for phase in EditorCapabilityReleasePhase.allCases {
                            SettingsChoiceButton(title: L(phase.displayName),
                                                 isActive: store.capabilitySettings.releasePhase == phase) {
                                applyCapabilityReleasePhase(phase)
                            }
                        }
                    }
                }

                SettingsSection(title: L("AI Plugins")) {
                    pluginManagementContent
                }
            }
            .padding(horizontal: 12, vertical: 12)
        }
        .flex(1, shrink: 1)
        .frame(minWidth: 220)
    }

    private func applySettingsChange() {
        persistShell()
        app.requestDisplayRefresh()
    }

    private func persistShell() {
        EditorRootViewFactory.saveShellState(mode: store.workspaceMode,
                                             preset: store.activeLayoutPreset,
                                             themeMode: store.themeMode,
                                             language: store.language,
                                             vsyncMode: store.vsyncMode,
                                             primarySelectBehavior: store.primarySelectBehavior,
                                             aiSettings: store.aiSettings,
                                             capabilitySettings: store.capabilitySettings)
    }

    private func applyCapabilityReleasePhase(_ phase: EditorCapabilityReleasePhase) {
        guard store.capabilitySettings.releasePhase != phase else { return }
        app.applyCapabilitySettings(EditorCapabilitySettings(releasePhase: phase))
        applySettingsChange()
    }

    @ViewBuilder
    private var pluginManagementContent: some View {
        let management = store.pluginManagement
        Column(alignment: .leading, spacing: 8) {
            if !app.isPluginHostAvailable {
                Text(L("PluginHost is unavailable. Rebuild or reinstall the Editor."))
                    .font(.caption)
                    .foregroundColor(.warning)
            }

            Button(L("Choose .guavaplugin Folder"),
                   isEnabled: app.isPluginHostAvailable
                       && management.phase != .inspecting
                       && management.phase != .enabling,
                   action: choosePluginPackage)
                .buttonStyle(.secondary)

            if management.phase == .inspecting {
                Text(L("Inspecting plugin without loading it…"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }

            if let message = management.message {
                Text(message, lineLimit: 4)
                    .font(.caption)
                    .foregroundColor(management.phase == .failed ? .warning : .onSurfaceMuted)
            }

            if let candidate = management.candidate {
                PluginInspectionCard(
                    summary: candidate,
                    isBusy: management.phase == .enabling,
                    isAlreadyEnabled: management.enabled.contains { $0.id == candidate.id },
                    onEnable: {
                        Task { @MainActor in
                            await app.authorizeAndEnableInspectedPlugin()
                        }
                    },
                    onCancel: {
                        Task { @MainActor in
                            app.cancelPluginApproval()
                        }
                    }
                )
            }

            if !management.enabled.isEmpty {
                Text(L("Enabled Plugins"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                for plugin in management.enabled {
                    EnabledPluginRow(
                        plugin: plugin,
                        isBusy: management.phase == .enabling,
                        onDisable: {
                            Task { @MainActor in
                                await app.disablePluginFromManagement(id: plugin.id)
                            }
                        },
                        onRevoke: {
                            Task { @MainActor in
                                await app.revokePluginFromManagement(id: plugin.id)
                            }
                        }
                    )
                }
            }
        }
    }

    private func choosePluginPackage() {
        guard let display = AppDisplayHandleHolder.current else { return }
        MainActor.assumeIsolated {
            display.requestOpenFolder(defaultPath: app.projectDirectory) { path in
                guard let path else { return }
                Task { @MainActor in
                    await app.inspectPluginForManagement(
                        at: URL(fileURLWithPath: path, isDirectory: true)
                    )
                }
            }
        }
    }
}

private struct PluginInspectionCard: View {
    let summary: EditorPluginInspectionSummary
    let isBusy: Bool
    let isAlreadyEnabled: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text("\(summary.name) · v\(summary.version)", lineLimit: 1)
                .font(.body)
                .foregroundColor(.onSurface)
            Text(summary.id, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            if !summary.description.isEmpty {
                Text(summary.description, lineLimit: 4)
                    .font(.caption)
                    .foregroundColor(.onSurface)
            }

            PluginInspectionField(label: L("Access"), value: accessLabel(summary.access))
            PluginInspectionField(
                label: L("Imports"),
                value: summary.imports.isEmpty ? L("None") : summary.imports.joined(separator: ", ")
            )
            PluginInspectionField(
                label: L("Host Capabilities"),
                value: summary.composableHostCapabilities.isEmpty
                    ? L("None")
                    : summary.composableHostCapabilities.joined(separator: ", ")
            )
            PluginInspectionField(label: L("Component SHA-256"),
                                  value: summary.componentHash)
            PluginInspectionField(label: L("WIT SHA-256"),
                                  value: summary.witHash)

            Text("\(L("Capabilities")) (\(summary.capabilities.count))")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            for capability in summary.capabilities {
                PluginCapabilitySummaryRow(capability: capability)
            }

            if isAlreadyEnabled {
                Text(L("This plugin is already enabled."))
                    .font(.caption)
                    .foregroundColor(.warning)
            }

            Row(alignment: .center, spacing: 8) {
                Button(summary.hasReusableAuthorization
                           ? L("Enable Authorized Plugin")
                           : L("Authorize & Enable"),
                       isEnabled: !isBusy && !isAlreadyEnabled,
                       action: onEnable)
                    .buttonStyle(.primary)
                Button(L("Cancel"),
                       isEnabled: !isBusy,
                       action: onCancel)
                    .buttonStyle(.ghost)
            }
        }
        .padding(horizontal: 10, vertical: 10)
        .background(.surfaceRaised)
        .cornerRadius(8)
    }
}

private struct PluginCapabilitySummaryRow: View {
    let capability: EditorPluginCapabilitySummary

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(capability.id, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurface)
            Text("\(accessLabel(capability.access)) · \(capability.schemaHash)", lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

private struct PluginInspectionField: View {
    let label: String
    let value: String

    var body: some View {
        Column(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Text(value, lineLimit: 3)
                .font(.caption)
                .foregroundColor(.onSurface)
        }
    }
}

private struct EnabledPluginRow: View {
    let plugin: EditorPluginInspectionSummary
    let isBusy: Bool
    let onDisable: () -> Void
    let onRevoke: () -> Void

    var body: some View {
        Column(alignment: .leading, spacing: 6) {
            Text("\(plugin.name) · v\(plugin.version)", lineLimit: 1)
                .foregroundColor(.onSurface)
            Text("\(plugin.id) · \(accessLabel(plugin.access))", lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Row(alignment: .center, spacing: 8) {
                Button(L("Disable"), isEnabled: !isBusy, action: onDisable)
                    .buttonStyle(.secondary)
                Button(L("Revoke Authorization"),
                       role: .destructive,
                       isEnabled: !isBusy,
                       action: onRevoke)
                    .buttonStyle(.destructive)
            }
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surfaceRaised)
        .cornerRadius(8)
    }
}

private func accessLabel(_ rawValue: String) -> String {
    switch rawValue {
    case "read": return L("Read Only")
    case "reversible_write": return L("Reversible Write")
    case "destructive_write": return L("Destructive Write")
    case "external_side_effect": return L("External Side Effect")
    default: return rawValue
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            content
        }
    }
}

private struct SettingsChoiceButton: View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(isSelected: isActive, action: onClick) {
            Text(title, lineLimit: 1)
        }
        .buttonStyle(ToggleButtonStyle(minWidth: 86, height: 28))
    }
}
