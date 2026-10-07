import EditorCore
import Foundation
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime

/// Editor settings panel: captioned sections of pill choice buttons.
struct SettingsPanel: View {
    let store: EditorStore
    let app: EditorApplication
    @State private var aiDraft: EditorAISettingsDraft
    @State private var aiStatusMessage: String?
    @State private var aiStatusIsError: Bool
    @State private var isConfirmingAIKeyRemoval: Bool

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
        _aiDraft = State(wrappedValue: EditorAISettingsDraft(settings: app.store.aiSettings))
        _aiStatusMessage = State(wrappedValue: nil)
        _aiStatusIsError = State(wrappedValue: false)
        _isConfirmingAIKeyRemoval = State(wrappedValue: false)
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
                        SettingsChoiceButton(title: L("Light Theme"),
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

                SettingsSection(title: L("AI Assistant")) {
                    aiProviderContent
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
        EditorRootViewFactory.saveShellState(workspace: store.state.workspace,
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
    private var aiProviderContent: some View {
        Column(alignment: .leading, spacing: 8) {
            Row(alignment: .center, spacing: 8) {
                aiProviderButton(.none)
                aiProviderButton(.anthropic)
            }
            Row(alignment: .center, spacing: 8) {
                aiProviderButton(.openai)
                aiProviderButton(.deepseek)
            }

            if aiDraft.provider != .none {
                let credentialSource = app.aiCredentialSource(for: aiDraft.provider)
                TextField(L("Model"), text: aiModelBinding, clearable: true,
                          onSubmit: applyAIProviderSettings)
                TextField(
                    credentialSource != nil
                        ? L("API key (leave blank to use the available credential)")
                        : L("API key"),
                    text: aiKeyBinding,
                    secure: true,
                    clearable: true,
                    onSubmit: applyAIProviderSettings
                )
                Text(aiCredentialStatus(credentialSource))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)

                Row(alignment: .center, spacing: 8) {
                    Toggle(isOn: aiAutoApproveBinding)
                    Column(alignment: .leading, spacing: 2) {
                        Text(L("Automatically apply safe AI changes"))
                            .font(.caption)
                            .foregroundColor(.onSurface)
                        Text(L("Operations that require confirmation will still wait for approval."))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
            }

            Row(alignment: .center, spacing: 8) {
                Button(L("Apply AI Settings"), action: applyAIProviderSettings)
                    .buttonStyle(.primary)
                if store.aiSettings.provider != .none,
                   app.aiCredentialSource(for: store.aiSettings.provider)
                    == .operatingSystemStore {
                    if isConfirmingAIKeyRemoval {
                        Button(L("Confirm Remove Key"),
                               role: .destructive,
                               action: removeStoredAIKey)
                            .buttonStyle(.destructive)
                        Button(L("Keep Key"),
                               action: { isConfirmingAIKeyRemoval = false })
                            .buttonStyle(.secondary)
                    } else {
                        Button(L("Remove Stored Key"),
                               action: { isConfirmingAIKeyRemoval = true })
                            .buttonStyle(.secondary)
                    }
                }
            }

            if isConfirmingAIKeyRemoval {
                Text(L("Removing the stored key disables this provider until you add a credential again."))
                    .font(.caption)
                    .foregroundColor(.warning)
            }

            if let aiStatusMessage {
                Text(aiStatusMessage)
                    .font(.caption)
                    .foregroundColor(aiStatusIsError ? .error : .success)
            }
        }
    }

    private func aiCredentialStatus(_ source: AICredentialSource?) -> String {
        switch source {
        case .operatingSystemStore:
            return L("A credential is stored securely.")
        case let .environment(variable):
            return String(format: L("Using credential from environment variable %@."), variable)
        case nil:
            return L("No credential is available for this provider.")
        }
    }

    private var aiModelBinding: Binding<String> {
        Binding(get: { aiDraft.model }, set: { aiDraft.model = $0 })
    }

    private var aiKeyBinding: Binding<String> {
        Binding(get: { aiDraft.apiKey }, set: { aiDraft.apiKey = $0 })
    }

    private var aiAutoApproveBinding: Binding<Bool> {
        Binding(get: { aiDraft.autoApprove }, set: { aiDraft.autoApprove = $0 })
    }

    private func aiProviderButton(_ provider: EditorAIProvider) -> some View {
        SettingsChoiceButton(
            title: L(provider.displayName),
            isActive: aiDraft.provider == provider
        ) {
            aiDraft.select(provider)
            aiStatusMessage = nil
            aiStatusIsError = false
            isConfirmingAIKeyRemoval = false
        }
        .flex(1, shrink: 1)
    }

    private func applyAIProviderSettings() {
        let model = aiDraft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard aiDraft.provider == .none || !model.isEmpty else {
            aiStatusMessage = L("Enter a model name.")
            aiStatusIsError = true
            return
        }
        let settings = EditorAISettings(
            provider: aiDraft.provider,
            model: model.isEmpty ? aiDraft.provider.defaultModel : model,
            autoApprove: aiDraft.autoApprove
        )
        if app.applyAISettings(
            settings,
            apiKey: aiDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            aiDraft.clearCredential()
            aiStatusMessage = settings.provider == .none
                ? L("AI Assistant disabled.")
                : L("AI settings applied.")
            aiStatusIsError = false
            isConfirmingAIKeyRemoval = false
            persistShell()
            app.requestDisplayRefresh()
        } else {
            aiStatusMessage = L("AI settings could not be applied. See Console for details.")
            aiStatusIsError = true
        }
    }

    private func removeStoredAIKey() {
        if app.clearAIKey() {
            aiDraft = EditorAISettingsDraft(settings: .default)
            isConfirmingAIKeyRemoval = false
            aiStatusMessage = L("Stored credential removed and AI Assistant disabled.")
            aiStatusIsError = false
            persistShell()
            app.requestDisplayRefresh()
        } else {
            aiStatusMessage = L("Stored credential could not be removed. See Console for details.")
            aiStatusIsError = true
        }
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
        guard let display = AppDisplayHandleHolder.current else {
            app.logConsole("Plugin picker is unavailable",
                           severity: .error,
                           detail: "No active display is available to present the folder picker.")
            return
        }
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

struct EditorAISettingsDraft: Equatable {
    private(set) var provider: EditorAIProvider
    var model: String
    var apiKey: String
    var autoApprove: Bool

    init(settings: EditorAISettings) {
        provider = settings.provider
        // A model has no meaning while disabled; start blank so selecting a
        // provider reliably adopts that provider's default model.
        model = settings.provider == .none ? "" : settings.model
        apiKey = ""
        autoApprove = settings.autoApprove
    }

    mutating func select(_ nextProvider: EditorAIProvider) {
        guard provider != nextProvider else { return }
        let previousDefaultModel = provider.defaultModel
        if model.isEmpty || model == previousDefaultModel {
            model = nextProvider.defaultModel
        }
        // Never carry an uncommitted secret across providers: otherwise a key
        // typed for one service could silently be stored under another.
        apiKey = ""
        provider = nextProvider
    }

    mutating func clearCredential() {
        apiKey = ""
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
