internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct HarnessProviderSettings: View {
    let editor: HarnessSettingsEditor

    var body: some View {
        // One credential lookup per render; each reads the credential file.
        let providers = editor.app.aiProviderCatalog.providers
        let draftSource = editor.app.aiCredentialSource(for: editor.draft.providerID)
        let active = editor.app.store.aiSettings.providerID
        let activeSource = editor.draft.providerID == active ? draftSource : editor.app.aiCredentialSource(for: active)
        SettingsCard(L("Provider & Credentials"), subtitle: L("Bring your provider. Keep control of your credentials.")) {
            TextScalerReader { scaler in
                ContainerSizeReader { size in
                    GridLayout(columns: Array(repeating: .flexible(), count: Float(size.width) < scaler.scale(440) ? 2 : 4), columnSpacing: 8, rowSpacing: 8) {
                        AnyView(providerChoice(nil))
                        for provider in providers { AnyView(providerChoice(provider)) }
                    }
                }
            }
            if !editor.draft.providerID.isEmpty {
                Column(alignment: .leading, spacing: 7) {
                    Text(L("Model")).font(.label).foregroundColor(.onSurface)
                    TextField(L("Model"), text: Binding(get: { editor.draft.model }, set: { value in
                        editor.update { $0.draft.model = value; $0.feedback = nil }
                    })) { input in input.behavior.clearable = true; input.events.onSubmit = editor.apply }
                        .frame(width: .percent(100), minWidth: 0).debugName("settings-harness-model")
                    Text(L("Use a model supported by the selected provider.")).font(.caption).foregroundColor(.onSurfaceMuted)
                }.frame(width: .percent(100))
                Column(alignment: .leading, spacing: 7) {
                    Text(L("API key")).font(.label).foregroundColor(.onSurface)
                    TextField(draftSource == nil ? L("API key")
                        : L("API key (leave blank to use the available credential)"), text: Binding(get: { editor.draft.apiKey }, set: { value in
                        editor.update { $0.draft.apiKey = value; $0.feedback = nil }
                    })) { input in
                        input.behavior.secure = true; input.behavior.clearable = true; input.events.onSubmit = editor.apply
                    }.frame(width: .percent(100), minWidth: 0).debugName("settings-harness-key")
                    Row(alignment: .center, spacing: 6) {
                        Icon(UIIcons.Status.shieldCheck, size: 12, color: .onSurfaceMuted)
                        Text(editor.credentialStatus(draftSource)).font(.caption).foregroundColor(.onSurfaceMuted).flex().frame(minWidth: 0)
                    }
                }.frame(width: .percent(100))
            } else {
                Text(L("Harness is disabled. Choose a provider to configure it."))
                    .font(.body).foregroundColor(.onSurfaceMuted)
            }
            if editor.draft.providerID == active, !active.isEmpty, activeSource == .credentialFile {
                if editor.state.wrappedValue.confirmsKeyRemoval {
                    Alert(L("Remove Stored Key"), message: L("Removing the stored key disables this provider until you add a credential again."), tone: .warning) { _ in } actions: {
                        Button(L("Confirm Remove Key"), role: .destructive, action: editor.removeKey).buttonStyle(.destructive)
                        Button(L("Keep Key")) { editor.update { $0.confirmsKeyRemoval = false } }.buttonStyle(.secondary)
                    }
                } else {
                    Button(L("Remove Stored Key")) { editor.update { $0.confirmsKeyRemoval = true } }
                        .buttonStyle(.ghost).debugName("settings-harness-remove-key")
                }
            }
        }
    }

    private func providerChoice(_ provider: AIProviderDescriptor?) -> some View {
        let selected = editor.draft.providerID == (provider?.id ?? "")
        let title = provider?.title ?? "None"
        return Button(isSelected: selected, action: { editor.select(provider) }) {
            Column(alignment: .leading, spacing: 10) {
                Row(alignment: .center, spacing: 4) {
                    Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        Text(provider == nil ? "—" : String(title.prefix(1)))
                            .font(.bodyStrong).foregroundColor(.onSurface)
                    }.frame(width: 24, height: 24).background(.surfaceVariant).cornerRadius(6)
                    Spacer(minLength: 0)
                    if selected { Icon(UIIcons.Action.check, size: 12, color: .accent) }
                }
                Text(L(title), lineLimit: 1).font(.label).foregroundColor(.onSurface)
            }.padding(12).frame(width: .percent(100), minWidth: 0)
                .background(selected ? .accentMuted : .surfaceSunken)
                .cornerRadius(7).border(selected ? .accent : .divider, width: 1)
        }.buttonStyle(.plain).frame(width: .percent(100), minWidth: 0)
            .accessibility { $0.label = L(title); $0.state.isSelected = selected }
            .debugName("settings-provider-" + (provider?.id ?? "none"))
    }
}

struct HarnessExecutionSettings: View {
    let editor: HarnessSettingsEditor

    var body: some View {
        SettingsCard(L("Execution & Review")) {
            SettingsField(L("Automatically apply safe AI changes"), help: L("Operations that require confirmation will still wait for approval.")) {
                Toggle(isOn: Binding(get: { editor.draft.autoApprove }, set: { value in
                    editor.update { $0.draft.autoApprove = value; $0.feedback = nil }
                })).accessibility { $0.label = L("Automatically apply safe AI changes") }.debugName("settings-harness-auto-approve")
            }
        }
    }
}

struct CapabilitySettings: View {
    let app: EditorApplication
    let onChange: () -> Void

    var body: some View {
        SettingsCard(L("Capability Gate")) {
            SettingsField(L("Available capabilities"), help: L("Stable keeps the default capability set. Beta and Experimental expose earlier-stage tools.")) {
                Select(selection: Binding(get: { app.store.capabilitySettings.releasePhase }, set: { phase in
                    guard app.store.capabilitySettings.releasePhase != phase else { return }
                    app.applyCapabilitySettings(EditorCapabilitySettings(releasePhase: phase)); onChange()
                }), options: EditorCapabilityReleasePhase.allCases.map { .init(value: $0, label: L($0.displayName)) }, width: 200).frame(width: 200)
                    .debugName("settings-capabilities")
            }
        }
    }
}
