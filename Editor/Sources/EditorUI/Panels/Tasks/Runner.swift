internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// The project's tasks, as the plugin that contributes them for this kind of
/// project describes them: build, test and run from the toolbar, then the
/// tests and the project's contents. Output runs in the Terminal panel and
/// problems join the editor's Problems list.
struct TasksPanel: View, @unchecked Sendable {
    let app: EditorApplication
    private let observed: Observed<EditorTasks, TaskSnapshot>
    @State private var isRunMenuPresented = false

    init(app: EditorApplication) {
        self.app = app
        observed = Observed(\.snapshot, on: app.workstation.tasks)
    }

    private var model: EditorTasks { app.workstation.tasks }

    var body: some View {
        let snapshot = observed.wrappedValue
        Column(alignment: .leading, spacing: 0) {
            if snapshot.isAvailable {
                toolbar(snapshot)
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Column(alignment: .leading, spacing: 0) {
                        TestExplorer(model: model, snapshot: snapshot)
                        TaskProjectContents(description: snapshot.description)
                    }.padding(vertical: 4).frame(width: .percent(100), minWidth: 0)
                }.flex().frame(minWidth: 0, minHeight: 0).debugName("tasks-content")
            } else {
                TaskEmptyState(L("No tasks for this project"))
            }
        }
        .frame(minWidth: 0, minHeight: 0)
        .debugName("tasks")
    }

    // MARK: Toolbar

    private func toolbar(_ snapshot: TaskSnapshot) -> some View {
        let busy = snapshot.run?.isRunning == true
        let runnables = snapshot.description?.runnables ?? []
        return EditorPanelToolbar(spacing: 4) {
            Text(snapshot.description?.name ?? snapshot.title ?? "", lineLimit: 1).font(.label).foregroundColor(.onSurface)
                .flex(1, shrink: 1).frame(minWidth: 0)
            EditorPanelIconButton(UIIcons.Editor.hammer, tooltip: L("Build"), isEnabled: !busy) { model.build() }
                .debugName("tasks-build")
            EditorPanelIconButton(UIIcons.Status.checkCircle, tooltip: L("Run Tests"), isEnabled: !busy) { model.test() }.debugName("tasks-test")
            runButton(runnables, isEnabled: !busy && !runnables.isEmpty)
            EditorPanelIconButton(UIIcons.Editor.stop, tooltip: L("Stop"), isEnabled: busy) { model.stop() }
                .debugName("tasks-stop")
            EditorPanelIconButton(UIIcons.Action.trash, tooltip: L("Clean"), isEnabled: !busy) { model.clean() }
        }
    }

    /// One target runs at once; several open a menu to pick from.
    private func runButton(_ targets: [String], isEnabled: Bool) -> some View {
        Popover(isPresented: $isRunMenuPresented, width: 220, placement: .bottomTrailing, surface: .content, overflow: .flip) {
            Button(icon: .resource(UIIcons.Editor.play), size: 11, isEnabled: isEnabled, tooltip: L("Run")) {
                if targets.count == 1 { run(targets[0]) } else { isRunMenuPresented = true }
            }.buttonStyle(ToggleButtonStyle(height: 22))
        } content: {
            Menu(targets.map { target in
                .item(MenuItem(id: target, title: target, action: {
                    isRunMenuPresented = false
                    run(target)
                }))
            }, width: 220, onDismiss: { isRunMenuPresented = false })
        }.debugName("tasks-run")
    }

    private func run(_ target: String) { model.run(target) }

    static func title(_ run: TaskRun) -> String {
        let name = switch run.kind {
        case .build: L("Build")
        case .test: L("Test")
        case .run: L("Run") + " " + (run.subject ?? "")
        case .resolve: L("Resolve Dependencies")
        case .clean: L("Clean")
        }
        if run.isRunning { return name + "…" }
        if run.failure == "Stopped" { return String(format: L("%@ stopped"), name) }
        return String(format: run.succeeded ? L("%@ succeeded") : L("%@ failed"), name)
    }

}

/// The running or last task, in the status bar; a click opens the panel.
struct TaskStatus: View {
    let app: EditorApplication
    let onOpen: () -> Void
    private let observed: Observed<EditorTasks, TaskSnapshot>

    init(app: EditorApplication, onOpen: @escaping () -> Void) {
        self.app = app
        self.onOpen = onOpen
        observed = Observed(\.snapshot, on: app.workstation.tasks)
    }

    var body: some View {
        if let run = observed.wrappedValue.run {
            Button(action: onOpen) {
                Row(alignment: .center, spacing: 4) {
                    if run.isRunning { Spinner(size: 9) } else {
                        Icon(run.succeeded ? UIIcons.Status.checkCircle : UIIcons.Status.xCircle, size: 10,
                             color: run.succeeded ? .success : .error)
                    }
                    Text(TasksPanel.title(run), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                }
            }.buttonStyle(.plain).debugName("editor-status-tasks")
        }
    }
}

/// An empty state centred in whatever space the panel gives it.
struct TaskEmptyState: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Box(direction: .column, alignItems: .center, justifyContent: .center) { EditorPanelEmptyState(title) }
            .flex().frame(width: .percent(100), minWidth: 0, minHeight: 0)
    }
}
