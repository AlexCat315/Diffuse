internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct SettingsNavigation {
    var category: SettingsCategory = .general
    var query: TextBuffer = ""
}

enum SettingsFeedback {
    case success(String)
    case failure(String)

    var message: String { switch self { case .success(let text), .failure(let text): text } }
    var isError: Bool { if case .failure = self { true } else { false } }
}

struct AgentSettingsState {
    var draft: EditorAISettingsDraft
    var feedback: SettingsFeedback?
    var confirmsKeyRemoval = false

    init(settings: EditorAISettings) { draft = EditorAISettingsDraft(settings: settings) }
}

/// Window-owned, transient state survives presentation changes and page unmounts.
final class EditorSettingsSession {
    var navigation = SettingsNavigation()
    var agent: AgentSettingsState
    init(settings: EditorAISettings) { agent = AgentSettingsState(settings: settings) }
}

struct EditorSettingsPersistence {
    let app: EditorApplication

    func didChange() {
        let store = app.store
        EditorRootViewFactory.saveShellState(workspace: store.state.workspace,
            themeMode: store.themeMode, language: store.language, vsyncMode: store.vsyncMode,
            primarySelectBehavior: store.primarySelectBehavior, aiSettings: store.aiSettings,
            capabilitySettings: store.capabilitySettings)
        app.requestDisplayRefresh()
    }
}
