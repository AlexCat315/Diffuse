internal import EditorCore
internal import GuavaUI
private import Foundation

/// Editing a provider is explicit; the active client only changes on Apply.
struct AgentSettingsEditor {
    let app: EditorApplication
    let state: Binding<AgentSettingsState>
    let onChange: () -> Void

    var draft: EditorAISettingsDraft { state.wrappedValue.draft }
    var isDirty: Bool { draft.differs(from: app.store.aiSettings) }

    func update(_ change: (inout AgentSettingsState) -> Void) {
        var next = state.wrappedValue; change(&next); state.wrappedValue = next
    }

    func select(_ provider: EditorAIProvider) {
        update { $0.draft.select(provider); $0.feedback = nil; $0.confirmsKeyRemoval = false }
    }

    func reset() { state.wrappedValue = AgentSettingsState(settings: app.store.aiSettings) }

    func apply() {
        let model = draft.model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft.provider == .none || !model.isEmpty else {
            update { $0.feedback = .failure(L("Enter a model name.")) }; return
        }
        let settings = EditorAISettings(provider: draft.provider, model: model, autoApprove: draft.autoApprove)
        let key = draft.apiKey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.provider == .none || !key.isEmpty || app.aiCredentialSource(for: settings.provider) != nil else {
            update { $0.feedback = .failure(L("Enter an API key for the selected provider.")) }; return
        }
        guard app.applyAISettings(settings, apiKey: key) else {
            update { $0.feedback = .failure(L("AI settings could not be applied. See Console for details.")) }; return
        }
        update {
            $0.draft = EditorAISettingsDraft(settings: settings)
            $0.confirmsKeyRemoval = false
            $0.feedback = .success(settings.provider == .none ? L("AI Assistant disabled.") : L("AI settings applied."))
        }
        onChange()
    }

    func removeKey() {
        guard app.clearAIKey() else {
            update { $0.feedback = .failure(L("Stored credential could not be removed. See Console for details.")) }; return
        }
        state.wrappedValue = AgentSettingsState(settings: app.store.aiSettings)
        update { $0.feedback = .success(L("Stored credential removed and AI Assistant disabled.")) }
        onChange()
    }

    var credentialStatus: String {
        switch app.aiCredentialSource(for: draft.provider) {
        case .operatingSystemStore: L("A credential is stored securely.")
        case .environment(let variable): String(format: L("Using credential from environment variable %@."), variable)
        case nil: L("No credential is available for this provider.")
        }
    }
}

extension EditorAISettingsDraft {
    func differs(from settings: EditorAISettings) -> Bool {
        provider != settings.provider || autoApprove != settings.autoApprove || !apiKey.isEmpty
            || (provider != .none && model.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != settings.model)
    }
}
