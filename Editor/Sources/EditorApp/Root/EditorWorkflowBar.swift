import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct EditorWorkflowBar: View {
    let workspace: EditorWorkspaceState
    let playbackState: PlaybackState
    let width: Float
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 12) {
            Row(alignment: .center, spacing: 2) {
                domainButton(.game, mode: .level)
                domainButton(.creation, mode: .modeling)
            }
            .padding(2).background(.surfaceSunken).cornerRadius(6)
            Divider(axis: .vertical).frame(width: 1, height: 18)
            Row(alignment: .center, spacing: 2) {
                for task in tasks { AnyView(taskButton(task)) }
            }
            Spacer(minLength: 0)
            if width >= 1050 && workspace.interactionMode == .manual {
                LayoutPresetSelector(workspaceMode: workspace.mode, activePreset: workspace.layoutPreset,
                                     onSelectPreset: { onCommand(.setLayoutPreset($0)) })
            }
            if workspace.mode.isGameWorkspace {
                EditorPlaybackToolbar(state: playbackState, onCommand: onCommand)
            }
            Row(alignment: .center, spacing: 2) {
                for surface in EditorInteractionMode.allCases { AnyView(surfaceButton(surface)) }
            }
            .padding(2).background(.surfaceSunken).cornerRadius(6)
        }
        .padding(horizontal: 10, vertical: 4)
        .background(.surface)
        .debugName("editor-workflow-bar")
    }

    private func domainButton(_ domain: EditorAuthoringDomain, mode: EditorWorkspaceMode) -> some View {
        Button(L(domain.title), isSelected: workspace.mode.profile.domain == domain) {
            onCommand(.setWorkspaceMode(mode))
        }.buttonStyle(.toggle)
    }

    private func taskButton(_ task: EditorWorkspaceMode) -> some View {
        Button(L(task.title), isSelected: workspace.mode == task) { onCommand(.setWorkspaceMode(task)) }
            .buttonStyle(.tab)
    }

    private func surfaceButton(_ surface: EditorInteractionMode) -> some View {
        Button(L(surface.title), isSelected: surface == workspace.interactionMode) {
            onCommand(.setInteractionMode(surface))
        }.buttonStyle(.toggle)
    }

    private var tasks: [EditorWorkspaceMode] {
        workspace.mode.profile.domain == .game ? [.level, .scripting] : [.modeling, .animation]
    }
}
