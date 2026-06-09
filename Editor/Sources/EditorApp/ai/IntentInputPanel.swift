import EditorCore
import GuavaKit

struct IntentInputPanel: GuavaKit.View {
    let app: EditorApplication
    @Observed var store: EditorStore
    @State var inputText: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 0) {
            if store.aiSettings.provider == .none {
                // AI Setup placeholder
                Column(alignment: .stretch, spacing: 8) {
                    Text(L("AI Assistant"))
                        .font(.bodyStrong)
                    Text(L("Edit the scene with natural language."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text(L("Set an AI provider in Settings to enable."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(12)
                .flex(1, shrink: 1)
            } else {
                // Active AI mode
                Column(alignment: .stretch, spacing: 8) {
                    // Chat messages area
                    ScrollView(.column) {
                        Column(alignment: .stretch, spacing: 4) {
                            if store.chatMessages.isEmpty {
                                Text(L("Type a message to start."))
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceMuted)
                                    .padding(12)
                            } else {
                                for msg in store.chatMessages {
                                    ChatBubble(msg: msg)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .flex(1, shrink: 1)
                    .background(.surfaceSunken)
                    .cornerRadius(4)

                    // Input row
                    Row(alignment: .center, spacing: 8) {
                        TextField(
                            text: inputText,
                            placeholder: L("Describe what you want to do…"),
                            onChange: { inputText = $0 },
                            onSubmit: { submitInput() }
                        )
                        .flex(1, shrink: 1)

                        Button(action: { submitInput() }) {
                            Text(L("Send"))
                                .font(.caption)
                                .foregroundColor(.onAccent)
                                .padding(horizontal: 12, vertical: 6)
                                .background(.accent)
                                .cornerRadius(4)
                        }
                    }
                    .padding(horizontal: 8, vertical: 6)
                }
                .flex(1, shrink: 1)
            }
        }
        .frame(minWidth: 280)
    }

    private func submitInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.submitNaturalLanguageIntent(trimmed)
        inputText = ""
    }
}

private struct ChatBubble: GuavaKit.View {
    let msg: AIChatMessage

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 4) {
            Text(msg.role == .user ? L("You") : L("AI"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            if !msg.text.isEmpty {
                Text(msg.text)
                    .font(.body)
                    .foregroundColor(.onSurface)
            }

            if let state = msg.assistantState {
                switch state {
                case .thinking:
                    Text(L("Thinking…"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                case .streaming(let partial):
                    Text(partial + "…")
                        .font(.body)
                        .foregroundColor(.onSurfaceMuted)
                case .replied(let text):
                    Text(text)
                        .font(.body)
                        .foregroundColor(.onSurface)
                case .pendingConfirmation(let summary):
                    Text(L("Waiting for confirmation: \(summary)"))
                        .font(.caption)
                        .foregroundColor(.warning)
                case .applied:
                    Text(L("✓ Applied"))
                        .font(.caption)
                        .foregroundColor(.success)
                case .discarded:
                    Text(L("Discarded"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.error)
                }
            }
        }
        .padding(horizontal: 10, vertical: 6)
        .background(msg.role == .user ? .surfaceSunken : .surfaceVariant)
        .cornerRadius(6)
    }
}
