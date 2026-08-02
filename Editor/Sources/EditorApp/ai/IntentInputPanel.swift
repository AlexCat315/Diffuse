import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// AI intent / chat panel in the floating-island language. Chat history on a
/// sunken well, primary Send action, AI-setup placeholder when no provider.
struct IntentInputPanel: View {
    let app: EditorApplication
    let store: EditorStore
    @State private var inputText: String = ""

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        let aiIsBusy = store.pendingConfirmationRequest != nil
            || store.chatMessages.contains(where: isActiveAssistantMessage)
        Column(alignment: .leading, spacing: 0) {
            if store.aiSettings.provider == .none {
                Column(alignment: .leading, spacing: 8) {
                    Text(L("AI Assistant"))
                        .font(.bodyStrong)
                    Text(L("Edit the scene with natural language."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Text(L("Set an AI provider in Settings to enable."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Button(L("Open Settings")) {
                        app.openSettingsWindow()
                    }
                }
                .padding(horizontal: 12, vertical: 12)
                .flex(1, shrink: 1)
            } else {
                Column(alignment: .leading, spacing: 8) {
                    Row(alignment: .center, spacing: 8) {
                        Column(alignment: .leading, spacing: 2) {
                            Text(L("AI Assistant"))
                                .font(.bodyStrong)
                            Text(store.aiSettings.provider.displayName)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                        .flex(1, shrink: 1)

                        Button(L("Settings")) {
                            app.openSettingsWindow()
                        }
                        Button(L("Clear"),
                               isEnabled: !store.chatMessages.isEmpty && !aiIsBusy) {
                            store.dispatch(.clearChatHistory)
                        }
                    }
                    .padding(horizontal: 8, vertical: 6)

                    if !app.isAIAvailable {
                        Column(alignment: .leading, spacing: 6) {
                            Text(L("AI credential unavailable"))
                                .font(.bodyStrong)
                                .foregroundColor(.warning)
                            Text(L("The selected provider has no usable credential. Open Settings to add or replace its API key."))
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                            Button(L("Open Settings")) {
                                app.openSettingsWindow()
                            }
                        }
                        .padding(horizontal: 10, vertical: 8)
                        .background(.surfaceVariant)
                        .cornerRadius(7)
                        .border(.warning, width: 1)
                    }

                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        Column(alignment: .leading, spacing: 4) {
                            if store.chatMessages.isEmpty {
                                Text(L("Type a message to start."))
                                    .font(.caption)
                                    .foregroundColor(.onSurfaceMuted)
                                    .padding(horizontal: 12, vertical: 12)
                            } else {
                                for msg in store.chatMessages {
                                    ChatBubble(msg: msg)
                                }
                            }
                        }
                        .padding(horizontal: 8, vertical: 8)
                    }
                    .flex(1, shrink: 1)
                    .background(.surfaceSunken)
                    .cornerRadius(7)

                    if store.aiStatusMessage != nil || !store.aiWarnings.isEmpty {
                        AIStatusFeedback(status: store.aiStatusMessage,
                                         warnings: store.aiWarnings)
                    }

                    Row(alignment: .center, spacing: 8) {
                        TextField(L("Describe what you want to do…"),
                                  text: $inputText,
                                  onSubmit: { submitInput() })
                            .flex(1, shrink: 1)

                        Button(isEnabled: app.isAIAvailable
                                && app.isSceneAuthoringEnabled
                                && !aiIsBusy,
                               tooltip: app.isSceneAuthoringEnabled
                                   ? nil
                                   : L("Stop simulation to edit the scene"),
                               action: { submitInput() }) {
                            Text(L("Send"))
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
        if app.submitNaturalLanguageIntent(trimmed) {
            inputText = ""
        }
    }

    private func isActiveAssistantMessage(_ message: AIChatMessage) -> Bool {
        switch message.assistantState {
        case .thinking, .streaming, .pendingConfirmation:
            return true
        case .replied, .applied, .discarded, .failed, .none:
            return false
        }
    }
}

struct AIStatusFeedback: View {
    let status: String?
    let warnings: [String]

    var body: some View {
        Column(alignment: .leading, spacing: 4) {
            if let status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundColor(warnings.isEmpty ? .onSurfaceMuted : .warning)
            }
            if warnings.indices.contains(0) { warningRow(warnings[0]) }
            if warnings.indices.contains(1) { warningRow(warnings[1]) }
            if warnings.indices.contains(2) { warningRow(warnings[2]) }
            if warnings.indices.contains(3) { warningRow(warnings[3]) }
            if warnings.count > 4 {
                Text(String(format: L("+ %d more warnings"), warnings.count - 4))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
        }
        .padding(horizontal: 10, vertical: 7)
        .background(.surfaceVariant)
        .cornerRadius(7)
        .border(warnings.isEmpty ? SemanticColorRef.border : .warning, width: 1)
    }

    private func warningRow(_ warning: String) -> some View {
        Row(alignment: .top, spacing: 5) {
            Text("!")
                .font(.mono)
                .foregroundColor(.warning)
            Text(warning)
                .font(.caption)
                .foregroundColor(.warning)
                .flex(1, shrink: 1)
        }
    }
}

private struct ChatBubble: View {
    let msg: AIChatMessage

    var body: some View {
        Column(alignment: .leading, spacing: 4) {
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
                    Text(String(format: L("Waiting for confirmation: %@"), summary))
                        .font(.caption)
                        .foregroundColor(.warning)
                case .applied:
                    Row(alignment: .center, spacing: 4) {
                        Icon(UICommonIcons.checkmark, size: 10, color: .success)
                        Text(L("Applied"))
                            .font(.caption)
                            .foregroundColor(.success)
                    }
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
        .background(msg.role == .user ? SemanticColorRef.surfaceSunken : .surfaceVariant)
        .cornerRadius(7)
    }
}
