import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct EditorWorkflowBar: View {
    let mode: EditorWorkspaceMode
    let interaction: EditorInteractionMode
    let onCommand: (EditorMenuCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            Button(L("Game Development"), isSelected: mode.profile.domain == .game) {
                onCommand(.setWorkspaceMode(.level))
            }.buttonStyle(.tab)
            Button(L("3D Creation"), isSelected: mode.profile.domain == .creation) {
                onCommand(.setWorkspaceMode(.modeling))
            }.buttonStyle(.tab)
            Text("/").foregroundColor(.onSurfaceMuted)
            for task in tasks { AnyView(taskButton(task)) }
            Spacer(minLength: 0)
            for surface in EditorInteractionMode.allCases { AnyView(surfaceButton(surface)) }

        }
        .padding(horizontal: 10, vertical: 4)
        .background(.surface)
        .debugName("editor-workflow-bar")
    }

    private func taskButton(_ task: EditorWorkspaceMode) -> some View {
        Button(L(task.title), isSelected: mode == task) { onCommand(.setWorkspaceMode(task)) }
            .buttonStyle(.ghost)
    }

    private func surfaceButton(_ surface: EditorInteractionMode) -> some View {
        Button(L(surface.title), isSelected: surface == interaction) {
            onCommand(.setInteractionMode(surface))
        }.buttonStyle(.tab)
    }

    private var tasks: [EditorWorkspaceMode] {
        mode.profile.domain == .game ? [.level, .scripting] : [.modeling, .animation]
    }
}
