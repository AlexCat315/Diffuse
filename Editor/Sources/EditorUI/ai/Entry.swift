internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// The assistant's one entry, centered in the title bar. It shows whether
/// Guava is working or waiting for a review; clicking it opens the thread.
struct AssistantTitleField: View {
    let app: EditorApplication
    let compact: Bool
    let shortcut: String

    var body: some View {
        let store = app.store
        let working = store.agentTasks.contains { $0.phase == .planning }
            || store.chatMessages.contains { AssistantThread.isActive($0) }
        let reviews = store.pendingConfirmationRequest?.questions.count ?? 0
        let label = reviews > 0 ? "\(reviews) \(L("item(s) require confirmation"))"
            : working ? L("Guava is working") : L("Ask Guava")
        return Button(tooltip: L("Ask Guava")) {
            EditorAssistantSurface.of(app).open()
            EditorAssistantSurface.of(app).focus()
        } label: {
            Row(alignment: .center, spacing: 7) {
                if working && reviews == 0 {
                    Spinner(size: 11)
                } else {
                    Icon(UIIcons.Status.sparkles, size: 13,
                         color: app.isAIAvailable ? EditorThemeTokens.assistantColor : .onSurfaceMuted)
                }
                if !compact {
                    Text(label, lineLimit: 1).font(.caption)
                        .foregroundColor(reviews > 0 ? EditorThemeTokens.assistantColor : .onSurfaceMuted)
                        .flex(1, shrink: 1).frame(minWidth: 0)
                    Text(shortcut).font(.caption).foregroundColor(.onSurfaceMuted).padding(horizontal: 4)
                        .border(.borderStrong, width: 1).cornerRadius(3)
                }
            }.padding(EdgeInsets(leading: 9, trailing: 6)).frame(width: .percent(100), height: .points(28), minWidth: 0)
                .background(.surfaceSunken).cornerRadius(8).border(.borderStrong, width: 1)
        }.buttonStyle(.plain).frame(width: .percent(100)).debugName("editor-assistant-field")
    }
}

/// The open thread floats under the title bar, over the work. Clicking
/// outside or Escape folds it; pinning moves it to the right column.
struct AssistantLayer: View {
    let app: EditorApplication
    let availableHeight: Float
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication, availableHeight: Float) {
        self.app = app
        self.availableHeight = availableHeight
        surface = Observed(\.state, on: EditorAssistantSurface.of(app))
    }

    var body: some View {
        let state = surface.wrappedValue
        let visible = state.isOpen && !state.isPinned && app.isAgentEnabled
        AnimatedVisibility(isVisible: visible, transition: .opacity.combined(with: .move(edge: .top, distance: 8))) {
            if visible {
                ModalBarrier(onBackgroundTap: { EditorAssistantSurface.of(app).close() }) {
                    Box(direction: .column, alignItems: .center, justifyContent: .flexStart, spacing: 0) {
                        AssistantThread(app: app, placement: .sheet)
                            .frame(width: .percent(92), height: .points(max(240, min(560, availableHeight - 140))),
                                   maxWidth: 720)
                            .cornerRadius(12).border(.borderStrong, width: 1)
                            .shadow(color: Color.black.multipliedAlpha(0.45), offsetY: 20, blur: 50).clipped()
                            .debugName("editor-assistant-sheet")
                    }.padding(EdgeInsets(top: 46)).frame(width: .percent(100), height: .percent(100))
                }
            }
        }.frame(width: .percent(100), height: .percent(100))
    }
}
