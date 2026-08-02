import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// ⌘K-style AI command palette: a floating card on the modal scrim.
struct CommandPaletteOverlay: View {
    let app: EditorApplication
    let store: EditorStore
    @State private var inputText: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        ModalBarrier(onBackgroundTap: { dismiss() }) {
            Column(alignment: .leading, spacing: 0) {
                Row(alignment: .center, spacing: 8) {
                    Text(L("AI Command"))
                        .font(.bodyStrong)
                        .foregroundColor(.onSurface)
                        .flex(1, shrink: 1)

                    Button(icon: .resource(UICommonIcons.close),
                           size: 12,
                           action: { dismiss() })
                    .buttonStyle(GhostButtonStyle())
                }
                .padding(horizontal: 14, vertical: 10)

                Divider()

                TextField(L("Describe what you want to do…"),
                          text: $inputText,
                          onSubmit: { submitAndClose() })
                    .padding(horizontal: 14, vertical: 10)

                if store.aiStatusMessage != nil || !store.aiWarnings.isEmpty {
                    AIStatusFeedback(status: store.aiStatusMessage,
                                     warnings: store.aiWarnings)
                        .padding(horizontal: 14, vertical: 8)
                }

                if !app.isAIAvailable {
                    Row(alignment: .center, spacing: 8) {
                        Text(store.aiSettings.provider == .none
                             ? L("Set an AI provider in Settings to enable.")
                             : L("AI credential unavailable"))
                            .font(.caption)
                            .foregroundColor(.warning)
                            .flex(1, shrink: 1)
                        Button(L("Open Settings")) {
                            app.openSettingsWindow()
                        }
                    }
                    .padding(horizontal: 14, vertical: 8)
                }

                Divider()

                Row(alignment: .center, spacing: 6) {
                    Text(L("Enter to submit · Escape to close"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                        .flex(1, shrink: 1)
                }
                .padding(horizontal: 14, vertical: 8)
            }
            .frame(width: 480)
            .background(.surfaceFloating)
            .cornerRadius(12)
            .border(.border, width: 1)
        }
    }

    private func submitAndClose() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if app.submitNaturalLanguageIntent(trimmed) {
            dismiss()
        }
    }

    private func dismiss() {
        app.store.dispatch(.setCommandPaletteVisible(false))
        inputText = ""
    }
}
