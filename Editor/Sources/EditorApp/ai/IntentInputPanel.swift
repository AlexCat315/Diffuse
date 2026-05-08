import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct IntentInputPanel: View {
    let app: EditorApplication

    @State private var inputText: String = ""
    @State private var apiKeyInput: String = ""

    var body: some View {
        StoreScope(app.store) { store in
            Box(direction: .column, alignItems: .stretch) {
                if store.aiSettings.provider == .none || !app.hasStoredAIKey() {
                    AISetupView(app: app,
                                store: store,
                                apiKeyInput: $apiKeyInput,
                                onConnect: { saveKey(store) })
                        .flex()
                } else {
                    AIChatView(app: app,
                               store: store,
                               inputText: $inputText,
                               onDisconnect: { disconnect(store) },
                               onSubmit: { submitInput(store) })
                        .flex()
                }
            }
            .frame(minWidth: 280)
        }
    }

    private func saveKey(_ store: EditorStore) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.applyAISettings(store.aiSettings, apiKey: trimmed)
        apiKeyInput = ""
        persistShell(store)
    }

    private func disconnect(_ store: EditorStore) {
        app.clearAIKey()
        persistShell(store)
    }

    private func submitInput(_ store: EditorStore) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.submitNaturalLanguageIntent(trimmed)
        inputText = ""
    }

    private func persistShell(_ store: EditorStore) {
        EditorRootViewFactory.saveShellState(mode: store.workspaceMode,
                                             preset: store.activeLayoutPreset,
                                             themeMode: store.themeMode,
                                             language: store.language,
                                             vsyncMode: store.vsyncMode,
                                             primarySelectBehavior: store.primarySelectBehavior,
                                             aiSettings: store.aiSettings)
    }
}

private struct AISetupView: View {
    let app: EditorApplication
    let store: EditorStore
    let apiKeyInput: Binding<String>
    let onConnect: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            Box(direction: .column, alignItems: .stretch, spacing: 20) {
                Box(direction: .column, alignItems: .stretch, spacing: 4) {
                    Text(L("AI Assistant"))
                        .font(.bodyStrong)
                    Text(L("Describe scene changes in natural language."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }

                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    Text(L("Provider"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    Row(alignment: .center, spacing: 8) {
                        SetupChoiceButton(
                            title: EditorAIProvider.anthropic.displayName,
                            isActive: store.aiSettings.provider == .anthropic
                        ) {
                            var s = store.aiSettings
                            s.provider = .anthropic
                            store.dispatch(.setAISettings(s))
                        }
                    }
                }

                if store.aiSettings.provider != .none {
                    Box(direction: .column, alignItems: .stretch, spacing: 8) {
                        Text(L("API Key"))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                        TextField(L("Paste API key…"),
                                  text: apiKeyInput,
                                  clearable: true,
                                  onSubmit: onConnect,
                                  onClear: { apiKeyInput.wrappedValue = "" })
                        Button(L("Connect"), isEnabled: !apiKeyInput.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            onConnect()
                        }
                        Text(L("Your key is stored in the system Keychain and never leaves your device."))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct AIChatView: View {
    let app: EditorApplication
    let store: EditorStore
    let inputText: Binding<String>
    let onDisconnect: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        Box(direction: .column, alignItems: .stretch) {
            Row(alignment: .center, spacing: 8) {
                Text(store.aiSettings.provider.displayName)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Spacer(minLength: 0)
                Button(L("Disconnect")) {
                    onDisconnect()
                }
                .buttonStyle(.ghost)
                .frame(height: 24)
            }
            .padding(horizontal: 10, vertical: 6)

            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 6) {
                    if store.chatMessages.isEmpty {
                        Text(L("Describe what you'd like to do…"))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                            .padding(horizontal: 8, vertical: 12)
                    } else {
                        for msg in store.chatMessages {
                            ChatBubble(msg: msg, app: app)
                        }
                    }
                }
                .padding(8)
            }
            .flex()

            Box(direction: .column, alignItems: .stretch) {
                Row(alignment: .center, spacing: 8) {
                    let isWaiting = store.chatMessages.last?.assistantState == .thinking
                        || store.pendingConfirmationRequest != nil
                    TextField(L("Message…"), text: inputText, onSubmit: onSubmit)
                        .flex()
                    Button(L("Send"),
                           isEnabled: !inputText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWaiting) {
                        onSubmit()
                    }
                }
                .padding(horizontal: 8, vertical: 8)
            }
        }
    }
}

private struct ChatBubble: View {
    let msg: AIChatMessage
    let app: EditorApplication

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Text(msg.role == .user ? L("You") : L("AI"))
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            if !msg.text.isEmpty {
                Text(msg.text)
                    .font(.body)
                    .foregroundColor(.onSurface)
            }

            if let state = msg.assistantState {
                if case .thinking = state {
                    Text(L("Thinking…"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                } else if case .pendingConfirmation(let summary) = state {
                    Box(direction: .column, alignItems: .stretch, spacing: 6) {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.onSurface)
                        Row(alignment: .center, spacing: 8) {
                            Button(L("Apply")) {
                                app.acceptPendingConfirmation()
                            }
                            Button(L("Skip")) {
                                app.skipPendingConfirmation()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(horizontal: 8, vertical: 6)
                    .background(.surfaceSunken)
                    .cornerRadius(4)
                } else if case .applied(let summary) = state {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.success)
                } else if case .discarded = state {
                    Text(L("Discarded"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                } else if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.error)
                }
            }
        }
        .padding(horizontal: 8, vertical: 7)
        .background(msg.role == .user ? .surfaceSunken : .surfaceVariant)
        .cornerRadius(4)
    }
}

private struct SetupChoiceButton: View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(title, lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(isActive ? .onAccent : .onSurface)
            }
            .frame(height: 30, minWidth: 86)
            .padding(horizontal: 10, vertical: 0)
            .background(isActive ? .accent : .surfaceSunken)
            .cornerRadius(4)
            .clipped()
        }
        .buttonStyle(.plain)
    }
}
