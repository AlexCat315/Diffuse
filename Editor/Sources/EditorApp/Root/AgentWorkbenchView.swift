import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace

/// Task-oriented shell over the same live scene and authoring operations.
struct AgentWorkbenchView: View {
    let app: EditorApplication
    let controller: WorkspaceController

    var body: some View {
        WorkspaceView(controller: controller) { panelID in
            switch panelID.rawValue {
            case "agent-tasks":
                AnyView(StoreScope(app.store) { store in AgentTaskList(tasks: store.agentTasks) })
            case "agent-preview": AnyView(AgentPreviewPanel(app: app))
            case "agent-conversation": AnyView(AgentConversationPanel(app: app))
            default: AnyView(EmptyView())
            }
        }
        .workspaceTheme(WorkspaceTheme(tabBarHeight: 30, splitDividerThickness: 5))
        .debugName("agent-workbench")
    }
}

private struct AgentPreviewPanel: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                EditorViewportWorkspacePanel(app: app).flex()
                    .frame(width: .percent(100), minWidth: 0, minHeight: 0)
                    .debugName("agent-scene-viewport")
                if store.pendingConfirmationRequest != nil {
                    Divider()
                    ConfirmationHostPanel(app: app).frame(height: 220, minWidth: 0, minHeight: 0)
                } else if let task = store.agentTasks.first {
                    Divider()
                    AgentTaskSummary(task: task)
                }
            }.flex().frame(minWidth: 0, minHeight: 0).debugName("agent-preview")
        }
    }
}

private struct AgentConversationPanel: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            Column(alignment: .leading, spacing: 0) {
                if store.agentTasks.first?.phase == .planning {
                    Button(L("Cancel")) { app.cancelAgentTask() }.buttonStyle(.ghost).padding(6)
                }
                IntentInputPanel(app: app).flex().frame(minWidth: 0, minHeight: 0)
            }.flex().frame(minWidth: 0, minHeight: 0).debugName("agent-conversation")
        }
    }
}

private struct AgentTaskList: View {
    let tasks: [EditorAgentTask]

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Column(alignment: .leading, spacing: 8) {
                    if tasks.isEmpty {
                        Text(L("Describe a task in the conversation to begin."))
                            .font(.caption).foregroundColor(.onSurfaceMuted).padding(10)
                    }
                    for task in tasks { AnyView(taskRow(task)) }

                }.padding(6)
            }.flex()
        }
        .flex().frame(minWidth: 0, minHeight: 0)
        .debugName("agent-task-list")
    }
    private func taskRow(_ task: EditorAgentTask) -> some View {
        Column(alignment: .leading, spacing: 5) {
            Text(task.prompt, lineLimit: 3).font(.body)
            Text(L(task.phase.title)).font(.caption)
                .foregroundColor(task.phase == .applied ? SemanticColorRef.success : .onSurfaceMuted)
            Text(L(task.target.workspace.title)).font(.caption).foregroundColor(.onSurfaceMuted)
        }.padding(10).background(.surfaceVariant).cornerRadius(5)
    }

}

private struct AgentTaskSummary: View {
    let task: EditorAgentTask

    var body: some View {
        Column(alignment: .leading, spacing: 5) {
            Row(alignment: .center, spacing: 8) {
                Text(L(task.phase.title)).font(.bodyStrong)
                Spacer(minLength: 0)
                Text("\(L("Base Version")): \(task.target.sceneRevision)")
                    .font(.caption).foregroundColor(.onSurfaceMuted)
            }
            Text(task.summary.isEmpty ? task.prompt : task.summary, lineLimit: 3).font(.caption)
            Text("\(L("Target")): \(L(task.target.workspace.title)) · \(task.target.selectedEntityIDs.sorted().map(String.init).joined(separator: ", "))")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }.padding(10).debugName("agent-task-summary")
    }
}
