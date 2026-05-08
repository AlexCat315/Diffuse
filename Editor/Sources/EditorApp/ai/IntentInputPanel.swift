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

// MARK: - Setup

private struct AISetupView: View {
    let app: EditorApplication
    let store: EditorStore
    let apiKeyInput: Binding<String>
    let onConnect: () -> Void

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .column, alignItems: .stretch, spacing: 2) {
                Text(L("AI Assistant"))
                    .font(.bodyStrong)
                Text(L("Edit the scene with natural language."))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 14, vertical: 14)

            SetupDivider()

            Box(direction: .column, alignItems: .stretch, spacing: 10) {
                Text(L("Provider"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                Row(alignment: .center, spacing: 6) {
                    for provider in [EditorAIProvider.anthropic, .openai, .deepseek] {
                        SetupChoiceButton(
                            title: provider.displayName,
                            isActive: store.aiSettings.provider == provider
                        ) {
                            var s = store.aiSettings
                            s.provider = provider
                            s.model = provider.defaultModel
                            store.dispatch(.setAISettings(s))
                        }
                    }
                }
            }
            .padding(horizontal: 14, vertical: 14)

            if store.aiSettings.provider != .none {
                SetupDivider()

                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    Text(L("API Key"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                    TextField(L("Paste key and press Connect…"),
                              text: apiKeyInput,
                              clearable: true,
                              onSubmit: onConnect,
                              onClear: { apiKeyInput.wrappedValue = "" })
                    Row(alignment: .center, spacing: 8) {
                        Button(L("Connect"),
                               isEnabled: !apiKeyInput.wrappedValue
                                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            onConnect()
                        }
                        .flex()
                    }
                    Text(L("Stored in the system Keychain. Never leaves your device."))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
                .padding(horizontal: 14, vertical: 14)
            }
        }
    }
}

// MARK: - Chat

private struct AIChatView: View {
    let app: EditorApplication
    let store: EditorStore
    let inputText: Binding<String>
    let onDisconnect: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        Box(direction: .column, alignItems: .stretch) {
            // Header
            Row(alignment: .center, spacing: 6) {
                Text(store.aiSettings.model)
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
                Text("·")
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
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
            .background(.surfaceVariant)

            // Messages
            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    if store.chatMessages.isEmpty {
                        Box(direction: .column, alignItems: .stretch, spacing: 6) {
                            Text(L("Ask me to edit the scene"))
                                .font(.bodyStrong)
                                .foregroundColor(.onSurface)
                            Text(L("e.g. move Hero to X=5 · rename Ground to Floor · delete the camera"))
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                        .padding(horizontal: 12, vertical: 14)
                    } else {
                        for msg in store.chatMessages {
                            ChatBubble(msg: msg, app: app)
                        }
                    }
                }
                .padding(8)
            }
            .flex()

            // Input
            SetupDivider()
            Row(alignment: .center, spacing: 8) {
                let lastState = store.chatMessages.last?.assistantState
                let isWaiting = lastState == .thinking
                    || { if case .streaming = lastState { return true }; return false }()
                    || store.pendingConfirmationRequest != nil
                TextField(L("Message…"), text: inputText, onSubmit: onSubmit)
                    .flex()
                Button(L("Send"),
                       isEnabled: !inputText.wrappedValue
                           .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWaiting) {
                    onSubmit()
                }
            }
            .padding(horizontal: 8, vertical: 8)
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let msg: AIChatMessage
    let app: EditorApplication

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 5) {
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
                    Row(alignment: .center, spacing: 6) {
                        Text(L("Thinking…"))
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                } else if case .streaming(let partial) = state {
                    Text(partial + "…")
                        .font(.body)
                        .foregroundColor(.onSurfaceMuted)
                } else if case .replied(let text) = state {
                    Text(text)
                        .font(.body)
                        .foregroundColor(.onSurface)
                } else if case .pendingConfirmation(let summary) = state {
                    Box(direction: .column, alignItems: .stretch, spacing: 8) {
                        Text(summary)
                            .font(.body)
                            .foregroundColor(.onSurface)
                        Row(alignment: .center, spacing: 8) {
                            Button(L("Apply")) {
                                app.acceptPendingConfirmation()
                            }
                            .flex()
                            Button(L("Skip")) {
                                app.skipPendingConfirmation()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .flex()
                        }
                    }
                    .padding(horizontal: 10, vertical: 8)
                    .background(.surfaceSunken)
                    .cornerRadius(4)
                } else if case .applied(let summary) = state {
                    Row(alignment: .center, spacing: 6) {
                        Text(L("Applied"))
                            .font(.caption)
                            .foregroundColor(.success)
                        if !summary.isEmpty && summary != "Applied" {
                            Text("·")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                    }
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
        .padding(horizontal: 10, vertical: 8)
        .background(msg.role == .user ? .surfaceSunken : .surfaceVariant)
        .cornerRadius(6)
    }
}

// MARK: - Shared

private struct SetupDivider: View {
    var body: some View {
        Text("").font(.caption).frame(height: 1).background(.surfaceSunken)
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
            .frame(height: 28, minWidth: 80)
            .padding(horizontal: 8, vertical: 0)
            .background(isActive ? .accent : .surfaceSunken)
            .cornerRadius(4)
            .clipped()
        }
        .buttonStyle(.plain)
    }
}
