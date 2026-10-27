internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// Workbench or whatever views the plugins declared, centered in the title bar.
///
/// The segments come from the catalog: the workbench is the editor's own, and
/// every other segment exists because an enabled package declared a panel for
/// that view. Nothing here asks whether a particular plugin is enabled, so a
/// package that stops contributing simply stops having a segment.
struct EditorViewSwitch: View {
    let host: AssistantHosting
    private var surface: Observed<EditorAssistantSurface, EditorAssistantSurface.State>

    init(host: AssistantHosting) {
        self.host = host
        surface = Observed(\.state, on: host.assistantSurface)
    }

    var body: some View {
        let _ = surface.wrappedValue
        let store = host.store
        let current = host.assistantSurface.view
        let working = store.agentTasks.contains { $0.phase == .planning }
            || store.chatMessages.contains { AssistantThread.isActive($0) }
        let reviews = store.pendingConfirmationRequest?.questions.count ?? 0
        return Row(alignment: .center, spacing: 2) {
            for segment in host.studioViewSegments {
                AnyView(button(segment, current: current, working: working, reviews: reviews))
            }
        }.padding(2).background(.surfaceSunken).cornerRadius(9).debugName("editor-view-switch")
    }

    private func button(_ segment: EditorStudioViewSegment, current: EditorStudioView,
                        working: Bool, reviews: Int) -> some View {
        let selected = segment.view == current
        // Only the agent view carries a run state; the editor owns that view's
        // decoration, while the catalog owns whether it exists at all.
        let isAgent = segment.view == .agent
        return Button(isSelected: selected) {
            host.assistantSurface.show(segment.view)
        } label: {
            Row(alignment: .center, spacing: 6) {
                if isAgent && working && reviews == 0 {
                    Spinner(size: 11)
                } else {
                    icon(segment, isAgent: isAgent)
                }
                Text(segment.title).font(.label)
                if isAgent && reviews > 0 {
                    Text("\(reviews)").font(.caption).foregroundColor(.onAccent)
                        .padding(horizontal: 5).frame(height: 16)
                        .background(EditorThemeTokens.assistantColor).cornerRadius(8)
                        .accessibility { $0.label = "\(reviews) \(L("Awaiting Review"))" }
                }
            }.padding(horizontal: 12)
        }.buttonStyle(EditorChromeButtonStyle(height: 26))
            .background(selected ? SemanticColorRef.surfaceRaised : .clear).cornerRadius(7)
            .accessibility { $0.state.isSelected = selected }
            .debugName("editor-view-" + segment.view.id)
    }

    @ViewBuilder private func icon(_ segment: EditorStudioViewSegment, isAgent: Bool) -> some View {
        if isAgent {
            Icon(UIIcons.Status.sparkles, size: 12,
                 color: host.isAIAvailable ? EditorThemeTokens.assistantColor : .onSurfaceMuted)
        } else if let name = segment.icon {
            Icon(.svg(named: name, in: EditorAppResourceBundle.bundle, subdirectory: "PanelIcons"), size: 12)
        } else {
            Icon(UIIcons.Editor.code, size: 12)
        }
    }
}
