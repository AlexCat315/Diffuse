// TODO: Full migration blocked by TextField widget (batch 4).
// IntentInputPanel uses TextField extensively for AI chat input and API key setup.
// See original in git history for the GuavaUICompose version.

import EditorCore
import GuavaKit

struct IntentInputPanel: GuavaKit.View {
    let app: EditorApplication
    @Observed var store: EditorStore

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 0) {
            if store.aiSettings.provider == .none /* || !app.hasStoredAIKey() */ {
                // AI Setup placeholder
                Column(alignment: .stretch, spacing: 8) {
                    Text(L("AI Assistant"))
                        .font(.bodyStrong)
                    Text(L("Edit the scene with natural language."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    // TODO: TextField for API key — batch 4
                    Text(L("Configure API key in Settings"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(12)
                .flex(1, shrink: 1)
            } else {
                // Chat placeholder
                Column(alignment: .stretch, spacing: 8) {
                    Text(L("AI Chat"))
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                    Text(L("Chat interface will be available after TextField migration (batch 4)."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(12)
                .flex(1, shrink: 1)
            }
        }
        .frame(minWidth: 280)
    }
}
