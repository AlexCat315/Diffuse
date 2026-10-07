import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Task-oriented shell over the same live scene and authoring operations.
struct AgentWorkbenchView: View {
    let app: EditorApplication
    let width: Float

    var body: some View {
        StoreScope(app.store) { store in
            Row(alignment: .top, spacing: 6) {
                if width >= 1100 {
                    AgentTaskList(tasks: store.agentTasks)
                        .frame(width: .points(210), height: .percent(100), minWidth: 0, minHeight: 0)
                }
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    Row(alignment: .center, spacing: 8) {
                        Text(L("Scene Preview")).font(.bodyStrong)
                        Spacer(minLength: 0)
                        Text(L(store.workspaceMode.title)).font(.caption).foregroundColor(.onSurfaceMuted)
                    }.padding(10)
                    Divider()
                    EditorViewportWorkspacePanel(app: app).flex()
                        .frame(width: .percent(100), minWidth: 0, minHeight: 0)
                        .debugName("agent-scene-viewport")
                    if store.pendingConfirmationRequest != nil {
                        Divider()
                        ConfirmationHostPanel(app: app)
                            .frame(height: 220, minWidth: 0, minHeight: 0)
                    } else if let task = store.agentTasks.first {
                        Divider()
                        AgentTaskSummary(task: task)
                    }
                }
                .flex().frame(height: .percent(100), minWidth: 0, minHeight: 0)
                .background(.surface).cornerRadius(7).border(.border, width: 1)
                .debugName("agent-preview")

                Column(alignment: .leading, spacing: 0) {
                    Row(alignment: .center, spacing: 6) {
                        Text(L("Task Conversation")).font(.bodyStrong)
                        Spacer(minLength: 0)
                        if store.agentTasks.first?.phase == .planning {
                            Button(L("Cancel")) { app.cancelAgentTask() }.buttonStyle(.ghost)
                        }
                    }.padding(10)
                    Divider()
                    IntentInputPanel(app: app).flex().frame(minWidth: 0, minHeight: 0)
                }
                .frame(width: .points(width < 900 ? 280 : 340), height: .percent(100), minWidth: 0, minHeight: 0)
                .background(.surface).cornerRadius(7).border(.border, width: 1)
                .debugName("agent-conversation")
            }
            .frame(width: .percent(100), height: .percent(100), minWidth: 0, minHeight: 0)
            .debugName("agent-workbench")
        }
    }
}

private struct AgentTaskList: View {
    let tasks: [EditorAgentTask]

    var body: some View {
        Column(alignment: .leading, spacing: 0) {
            Text(L("Tasks")).font(.bodyStrong).padding(10)
            Divider()
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
        .background(.surface).cornerRadius(7).border(.border, width: 1)
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
