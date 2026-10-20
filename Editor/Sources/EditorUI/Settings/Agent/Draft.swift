internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct EditorAISettingsDraft: Equatable {
    private(set) var provider: EditorAIProvider
    var model: TextBuffer
    var apiKey: TextBuffer
    var autoApprove: Bool

    init(settings: EditorAISettings) {
        provider = settings.provider
        // A model has no meaning while disabled; start blank so selecting a
        // provider reliably adopts that provider's default model.
        model = TextBuffer(settings.provider == .none ? "" : settings.model)
        apiKey = ""
        autoApprove = settings.autoApprove
    }

    mutating func select(_ nextProvider: EditorAIProvider) {
        guard provider != nextProvider else { return }
        let previousDefaultModel = provider.defaultModel
        if model.isEmpty || model.stringValue == previousDefaultModel {
            model = TextBuffer(nextProvider.defaultModel)
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
