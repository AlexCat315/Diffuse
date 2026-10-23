internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// The live session's task results and operations, backed by the same store as
/// the Agent and console. Session data never becomes authored project content.
struct SessionJournal: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            Column(alignment: .leading, spacing: 0) {
                EditorPanelToolbar {
                    Icon(UIIcons.Editor.gitCommit, size: 12, color: .onSurfaceMuted)
                    Text(L("This Session")).font(.caption).foregroundColor(.onSurfaceVariant)
                    Spacer(minLength: 0)
                    EditorPanelBadge("r\(store.sceneRevision)")
                }
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    // Every journal entry is a card; spacing, not rules, separates them.
                    Column(alignment: .leading, spacing: 6) {
                        if store.agentTasks.isEmpty && store.operations.isEmpty && store.consoleEntries.isEmpty {
                            EditorPanelEmptyState(L("A fresh start"), detail: L("Tasks and activity appear here as you work."))
                        }
                        for task in store.agentTasks {
                            AnyView(taskRow(task))
                        }
                        for operation in store.operations.reversed() {
                            AnyView(entry(icon: UIIcons.Editor.hammer, title: L(operation.message),
                                          detail: "\(operation.completed) / \(operation.total)",
                                          color: operation.status == .failed ? .error : .accent))
                        }
                        for item in store.consoleEntries.suffix(60).reversed() {
                            AnyView(Button {
                                if let target = item.target { app.navigateToIssue(target) }
                            } label: {
                                entry(icon: item.severity == .info ? UIIcons.Status.info : UIIcons.Status.alertTriangle,
                                      title: L(item.message), detail: item.detail ?? "",
                                      color: item.severity == .error ? .error : item.severity == .warning ? .warning : .onSurfaceMuted)
                            }.buttonStyle(.plain).frame(width: .percent(100)))
                        }
                    }.padding(8).frame(width: .percent(100), minWidth: 0)
                }.flex().frame(minWidth: 0, minHeight: 0)
            }.flex().frame(minWidth: 0, minHeight: 0).debugName("editor-session-journal")
        }
    }

    private func taskRow(_ task: EditorAgentTask) -> some View {
        Column(alignment: .leading, spacing: 4) {
            Row(alignment: .center, spacing: 6) {
                Icon(UIIcons.Status.sparkles, size: 12, color: EditorThemeTokens.harnessColor)
                Text(L(task.phase.title)).font(.caption).foregroundColor(EditorThemeTokens.harnessColor)
                Spacer(minLength: 0)
                Text("r\(task.target.sceneRevision)").font(.mono).foregroundColor(.onSurfaceMuted)
            }
            Text(task.prompt, lineLimit: 3).font(.body)
            if !task.summary.isEmpty {
                Text(task.summary, lineLimit: 4).font(.caption).foregroundColor(.onSurfaceVariant)
            }
        }.padding(horizontal: 12, vertical: 10).frame(width: .percent(100), minWidth: 0)
            .background(.surfaceRaised).cornerRadius(10)
    }

    private func entry(icon: BundleImageResource, title: String, detail: String,
                       color: SemanticColorRef) -> some View {
        Column(alignment: .leading, spacing: 0) {
            Row(alignment: .top, spacing: 8) {
                Icon(icon, size: 13, color: color).padding(EdgeInsets(top: 2))
                Column(alignment: .leading, spacing: 3) {
                    Text(title, lineLimit: 3).font(.body).foregroundColor(.onSurfaceVariant)
                    if !detail.isEmpty { Text(detail, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceMuted) }
                }.flex().frame(minWidth: 0)
            }.padding(horizontal: 12, vertical: 9)
        }.frame(width: .percent(100), minWidth: 0)
            .background(.surfaceRaised).cornerRadius(10)
    }
}
