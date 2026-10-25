internal import EditorCore
private import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// The conversation at the center of the agent view, kept to a reading width.
struct AssistantThread: View {
    let app: EditorApplication
    /// Side margin that keeps lines to a reading width in a wide column.
    var inset: Float = 12
    @State private var inputText: TextBuffer
    private var documents: Observed<EditorDocumentWorkspace, EditorDocumentSnapshot>
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, inset: Float = 12) {
        self.app = app
        self.inset = inset
        documents = Observed(\.snapshot, on: app.workstation.documents)
        surface = Observed(\.state, on: EditorAssistantSurface.of(app))
        _inputText = State(wrappedValue: EditorAssistantSurface.of(app).draft)
    }

    static func isActive(_ message: AIChatMessage) -> Bool {
        switch message.assistantState {
        case .thinking, .streaming, .pendingConfirmation: true
        case .replied, .applied, .discarded, .failed, .none: false
        }
    }

    var body: some View {
        StoreScope(app.store) { store in
            let busy = store.pendingConfirmationRequest != nil
                || store.chatMessages.contains(where: Self.isActive)
            Column(alignment: .leading, spacing: 0) {
                EditorPanelToolbar {
                    Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.assistantColor)
                    Text(store.agentTasks.first.map { L($0.phase.title) } ?? L("New Task"))
                        .font(.label)
                    Spacer(minLength: 0)
                    if store.agentTasks.first?.phase == .planning {
                        Button(L("Cancel")) { app.cancelAgentTask() }
                            .buttonStyle(EditorChromeButtonStyle(height: 22))
                    }
                    Button(icon: .resource(UIIcons.Action.trash), size: 12,
                           isEnabled: !busy && !store.chatMessages.isEmpty,
                           tooltip: L("Clear conversation"),
                           action: { store.dispatch(.clearChatHistory) })
                        .buttonStyle(EditorChromeButtonStyle(height: 22))
                    if store.pendingConfirmationRequest != nil {
                        Button(L("Open in Workbench")) {
                            // Reviews are scene edit plans, so the workbench opens on the scene.
                            EditorWorkbenchLink.of(app).show(EditorContentFollower.panel(for: .scene))
                            EditorAssistantSurface.of(app).show(.make)
                        }
                            .buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("editor-agent-open-make")
                    }
                }
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 14) {
                        if let request = store.pendingConfirmationRequest {
                            AgentReview(app: app, request: request).id(request.batchID)
                        }
                        if store.chatMessages.isEmpty && store.pendingConfirmationRequest == nil { introduction }
                        for task in store.agentTasks where !task.summary.isEmpty { AnyView(taskRow(task)) }
                        for message in store.chatMessages { ChatBubble(msg: message) }
                        if store.aiStatusMessage != nil || !store.aiWarnings.isEmpty {
                            AIStatusFeedback(status: store.aiStatusMessage, warnings: store.aiWarnings)
                        }
                    }.padding(horizontal: inset, vertical: 16).frame(width: .percent(100), minWidth: 0)
                }.flex().frame(minWidth: 0, minHeight: 0)
                // The composer keeps the thread's reading width; padding needs its own box here.
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    composer(busy: busy)
                }.padding(horizontal: max(0, inset - 8)).frame(width: .percent(100), minWidth: 0)
            }.flex().frame(minWidth: 0, minHeight: 0).background(.surface)
                .debugName("editor-agent-thread")
        }
    }

    /// What each task of this session settled on; the session never becomes project content.
    private func taskRow(_ task: EditorAgentTask) -> some View {
        Column(alignment: .leading, spacing: 4) {
            Row(alignment: .center, spacing: 6) {
                Text(L(task.phase.title)).font(.caption).foregroundColor(EditorThemeTokens.assistantColor)
                Spacer(minLength: 0)
                Text("r\(task.target.sceneRevision)").font(.mono).foregroundColor(.onSurfaceMuted)
            }
            Text(task.summary, lineLimit: 4).font(.caption).foregroundColor(.onSurfaceVariant)
        }.padding(horizontal: 12, vertical: 10).frame(width: .percent(100), minWidth: 0)
            .background(.surfaceRaised).cornerRadius(10)
    }

    private var introduction: some View {
        Column(alignment: .leading, spacing: 12) {
            Icon(UIIcons.Status.sparkles, size: 22, color: EditorThemeTokens.assistantColor)
                .frame(width: 42, height: 42)
                .background(EditorThemeTokens.assistantColor.opacity(0.10)).cornerRadius(12)
            Text(L("What shall we make?")).font(.title).foregroundColor(.onSurface)
            if !app.isAIAvailable {
                Column(alignment: .leading, spacing: 8) {
                    Text(L("Connect an AI provider to start working together."))
                        .font(.caption).foregroundColor(.onSurfaceMuted)
                    Button(L("Set up Assistant")) { app.openSettingsWindow() }
                        .buttonStyle(EditorChromeButtonStyle(agent: true))
                        .background(EditorThemeTokens.assistantColor.opacity(0.10)).cornerRadius(6)
                }.padding(vertical: 4)
            }
            Box {}.frame(height: 8)
            if app.store.content == .scene {
                suggestion(L("Explain the current selection"))
                suggestion(L("Help me plan the next step"))
            } else {
                suggestion(L("Summarize this file"))
                suggestion(L("Polish this document"))
                suggestion(L("Find problems in this file"))
            }
            suggestion(L("Find issues in this project"))
            if app.workstation.versionControl.snapshot.repository != nil {
                suggestion(L("Review my uncommitted changes"))
            }
        }.padding(vertical: 16).frame(width: .percent(100), minWidth: 0)
    }

    private func suggestion(_ text: String) -> some View {
        Button { updateDraft(TextBuffer(text)) } label: {
            Row(alignment: .center, spacing: 8) {
                Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.assistantColor)
                Text(text, lineLimit: 2).font(.body).foregroundColor(.onSurfaceVariant).flex()
                Icon(UIIcons.Navigation.arrowUpRight, size: 12, color: .onSurfaceMuted)
            }.padding(horizontal: 10, vertical: 10).frame(width: .percent(100), minWidth: 0)
                .background(.surfaceRaised).cornerRadius(10)
        }.buttonStyle(.plain).frame(width: .percent(100))
    }

    /// Padding and background share a node, so the inset around the bordered
    /// field needs its own wrapper; a second `.padding` would replace the first.
    private func composer(busy: Bool) -> some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Column(alignment: .leading, spacing: 8) {
                let focus = EditorWorkFocus(app: app, documents: documents.wrappedValue)
                if focus.leaf != nil { EditorFocusChip(focus: focus) }
                TextField(L("Describe what you want to do…"), text: Binding(get: { inputText }, set: updateDraft)) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 5
                    input.events.onSubmit = submitInput
                    let focus = surface.wrappedValue.focusRequest
                    if focus > 0 { input.navigation.focusRequestID = "assistant-thread-\(focus)" }
                }.font(.body).textFieldStyle(AgentComposerFieldStyle())
                    .frame(width: .percent(100), minHeight: 48).debugName("editor-agent-composer")
                Row(alignment: .center, spacing: 5) {
                    Icon(UIIcons.Status.shieldCheck, size: 11, color: .onSurfaceMuted)
                    Text(sendHint(busy: busy), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                        .flex(0, shrink: 1).frame(minWidth: 0).debugName("editor-agent-hint")
                    Spacer(minLength: 0)
                    Button(icon: .resource(UIIcons.Navigation.arrowUp), size: 13,
                           isEnabled: app.isAIAvailable && app.isSceneAuthoringEnabled && !busy
                               && !inputText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           tooltip: L("Send"), action: submitInput)
                        .buttonStyle(EditorChromeButtonStyle(height: 26, agent: true))
                        .background(EditorThemeTokens.assistantColor.opacity(0.14)).cornerRadius(6)
                        .debugName("editor-agent-send")
                }.frame(width: .percent(100), minWidth: 0)
            }.padding(10).background(.surfaceSunken).cornerRadius(10).border(.borderStrong, width: 1)
        }.padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8)).frame(width: .percent(100), minWidth: 0)
    }

    /// Why Send is unavailable, or the review promise when it is.
    private func sendHint(busy: Bool) -> String {
        if !app.isAIAvailable { return L("Assistant offline") }
        if !app.isSceneAuthoringEnabled { return L("Stop the game to send a request") }
        if app.store.pendingConfirmationRequest != nil { return L("Review the pending changes first") }
        if busy { return L("Guava is working") }
        return L("Review before applying")
    }

    private func updateDraft(_ text: TextBuffer) { EditorAssistantSurface.of(app).draft = text; inputText = text }

    private func submitInput() {
        let trimmed = inputText.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if app.submitNaturalLanguageIntent(trimmed) { updateDraft("") }
    }
}

private struct AgentComposerFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View { configuration.content }
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
                    // Replies are Markdown: lists, code and emphasis read as written.
                    MarkdownView(text).frame(width: .percent(100), minWidth: 0)
                    Row(alignment: .center, spacing: 0) {
                        Spacer(minLength: 0)
                        Button(icon: .resource(UIIcons.Action.copy), size: 11, isEnabled: ClipboardHolder.write != nil,
                               tooltip: L("Copy")) { ClipboardHolder.write?(text) }
                            .buttonStyle(EditorChromeButtonStyle(height: 20))
                    }
                case .pendingConfirmation(let summary):
                    Text(String(format: L("Waiting for confirmation: %@"), summary))
                        .font(.caption)
                        .foregroundColor(.warning)
                case .applied:
                    Row(alignment: .center, spacing: 4) {
                        Icon(UIIcons.Action.check, size: 10, color: .success)
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
