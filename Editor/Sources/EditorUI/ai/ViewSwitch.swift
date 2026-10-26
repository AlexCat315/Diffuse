internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// Workbench or Agent, centered in the title bar. The Agent side carries the
/// agent's state, so it reads from the workbench without taking room there.
struct EditorViewSwitch: View {
    let app: EditorApplication
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(app: EditorApplication) {
        self.app = app
        surface = Observed(\.state, on: EditorAssistantSurface.of(app))
    }

    var body: some View {
        let store = app.store
        let view = surface.wrappedValue.view
        let working = store.agentTasks.contains { $0.phase == .planning }
            || store.chatMessages.contains { AssistantThread.isActive($0) }
        let reviews = store.pendingConfirmationRequest?.questions.count ?? 0
        return Row(alignment: .center, spacing: 2) {
            segment(.make, selected: view == .make) {
                Icon(UIIcons.Editor.code, size: 12)
                Text(L("Workbench")).font(.label)
            }
            segment(.agent, selected: view == .agent) {
                if working && reviews == 0 {
                    Spinner(size: 11)
                } else {
                    Icon(UIIcons.Status.sparkles, size: 12,
                         color: app.isAIAvailable ? EditorThemeTokens.assistantColor : .onSurfaceMuted)
                }
                Text(L("Agent")).font(.label)
                if reviews > 0 {
                    Text("\(reviews)").font(.caption).foregroundColor(.onAccent)
                        .padding(horizontal: 5).frame(height: 16).background(EditorThemeTokens.assistantColor).cornerRadius(8)
                        .accessibility { $0.label = "\(reviews) \(L("Awaiting Review"))" }
                }
            }
        }.padding(2).background(.surfaceSunken).cornerRadius(9).debugName("editor-view-switch")
    }

    private func segment<Label: View>(_ target: EditorStudioView, selected: Bool,
                                      @ViewBuilder label: () -> Label) -> some View {
        Button(isSelected: selected) {
            EditorAssistantSurface.of(app).show(target)
        } label: {
            Row(alignment: .center, spacing: 6) { label() }.padding(horizontal: 12)
        }.buttonStyle(EditorChromeButtonStyle(height: 26))
            .background(selected ? SemanticColorRef.surfaceRaised : .clear).cornerRadius(7)
            .accessibility { $0.state.isSelected = selected }
            .debugName("editor-view-" + (target == .make ? "make" : "agent"))
    }
}
