import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct EditorWorkflowBar: View {
    let workspace: EditorWorkspaceState
    let playbackState: PlaybackState
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 12) {
            EditorAuthoringSelector(mode: workspace.mode, onCommand: onCommand).flex(basis: 0)
            if workspace.mode.isGameWorkspace {
                EditorPlaybackToolbar(state: playbackState, onCommand: onCommand)
            }
            Row(alignment: .center, spacing: 3) {
                Spacer(minLength: 0)
                for mode in EditorInteractionMode.allCases {
                    AnyView(Button(L(mode.title), isSelected: workspace.interactionMode == mode) {
                        onCommand(.setInteractionMode(mode))
                    }.buttonStyle(.toolToggle))
                }
            }.flex(basis: 0).debugName("editor-interaction-selector")
        }
        .padding(horizontal: 10, vertical: 4)
        .background(.surface)
        .debugName("editor-workflow-bar")
    }
}

private struct EditorAuthoringSelector: View {
    let mode: EditorWorkspaceMode
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        let domain = mode.profile.domain
        Row(alignment: .center, spacing: 3) {
            Button(L("Game Development"), isSelected: domain == .game) {
                if domain != .game { onCommand(.setWorkspaceMode(.level)) }
            }.buttonStyle(.toolToggle)
            Button(L("3D Creation"), isSelected: domain == .creation) {
                if domain != .creation { onCommand(.setWorkspaceMode(.modeling)) }
            }.buttonStyle(.toolToggle)
            Box(direction: .row, alignItems: .center) {
                Box { EmptyView() }.frame(width: 1, height: 16).background(.divider)
            }.padding(horizontal: 8)
            for workflow in domain == .game ? [EditorWorkspaceMode.level, .scripting] : [.modeling, .animation] {
                AnyView(Button(L(workflow.title), isSelected: mode == workflow) {
                    onCommand(.setWorkspaceMode(workflow))
                }.buttonStyle(.tab))
            }
        }.debugName("editor-authoring-selector")
    }
}
