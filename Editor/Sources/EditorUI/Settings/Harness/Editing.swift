internal import EditorCore
internal import GuavaUI
private import Foundation

/// Editing a provider is explicit; the active client only changes on Apply.
struct HarnessSettingsEditor {
    let app: EditorApplication
    let state: Binding<HarnessSettingsState>
    let onChange: () -> Void

    var draft: EditorAISettingsDraft { state.wrappedValue.draft }
    var isDirty: Bool { draft.differs(from: app.store.aiSettings) }

    func update(_ change: (inout HarnessSettingsState) -> Void) {
        var next = state.wrappedValue; change(&next); state.wrappedValue = next
    }

    func select(_ provider: AIProviderDescriptor?) {
        update { $0.draft.select(provider, in: app.aiProviderCatalog); $0.feedback = nil; $0.confirmsKeyRemoval = false }
    }

    func reset() { state.wrappedValue = HarnessSettingsState(settings: app.store.aiSettings) }

    func apply() {
        let model = draft.model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.providerID.isEmpty || !model.isEmpty else {
            update { $0.feedback = .failure(L("Enter a model name.")) }; return
        }
        let settings = EditorAISettings(providerID: draft.providerID,
                                        model: draft.providerID.isEmpty ? "" : model,
                                        autoApprove: draft.autoApprove)
        let key = draft.apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.isEnabled || !key.isEmpty || app.aiCredentialSource(for: settings.providerID) != nil else {
            update { $0.feedback = .failure(L("Enter an API key for the selected provider.")) }; return
        }
        guard app.applyAISettings(settings, apiKey: key) else {
            update { $0.feedback = .failure(L("AI settings could not be applied. See Console for details.")) }; return
        }
        update {
            $0.draft = EditorAISettingsDraft(settings: settings)
            $0.confirmsKeyRemoval = false
            $0.feedback = .success(settings.isEnabled ? L("AI settings applied.") : L("AI Assistant disabled."))
        }
        onChange()
    }

    func removeKey() {
        guard app.clearAIKey() else {
            update { $0.feedback = .failure(L("Stored credential could not be removed. See Console for details.")) }; return
        }
        state.wrappedValue = HarnessSettingsState(settings: app.store.aiSettings)
        update { $0.feedback = .success(L("Stored credential removed and AI Assistant disabled.")) }
        onChange()
    }

    func credentialStatus(_ source: AICredentialSource?) -> String {
        switch source {
        case .credentialFile: L("A credential is saved for this user.")
        case .environment(let variable): String(format: L("Using credential from environment variable %@."), variable)
        case nil: L("No credential is available for this provider.")
        }
    }
}

extension EditorAISettingsDraft {
    func differs(from settings: EditorAISettings) -> Bool {
        providerID != settings.providerID || autoApprove != settings.autoApprove || !apiKey.isEmpty
            || (!providerID.isEmpty && model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != settings.model)
    }
}
