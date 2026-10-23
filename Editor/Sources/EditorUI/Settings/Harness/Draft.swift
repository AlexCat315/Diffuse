internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct EditorAISettingsDraft: Equatable {
    private(set) var providerID: String
    var model: TextBuffer
    var apiKey: TextBuffer
    var autoApprove: Bool

    init(settings: EditorAISettings) {
        providerID = settings.providerID
        // A model has no meaning while disabled; start blank so selecting a
        // provider reliably adopts that provider's default model.
        model = TextBuffer(settings.isEnabled ? settings.model : "")
        apiKey = ""
        autoApprove = settings.autoApprove
    }

    mutating func select(_ nextProvider: AIProviderDescriptor?, in catalog: AIProviderCatalog) {
        let nextID = nextProvider?.id ?? ""
        guard providerID != nextID else { return }
        let previousDefaultModel = catalog.provider(id: providerID)?.defaultModel ?? ""
        if model.isEmpty || model.stringValue == previousDefaultModel {
            model = TextBuffer(nextProvider?.defaultModel ?? "")
        }
        // Never carry an uncommitted secret across providers: otherwise a key
        // typed for one service could silently be stored under another.
        apiKey = ""
        providerID = nextID
    }

    mutating func clearCredential() {
        apiKey = ""
    }
}
