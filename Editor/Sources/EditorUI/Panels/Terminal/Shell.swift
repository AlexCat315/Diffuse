internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime
internal import CoveUITerminal
private import Foundation

/// One shell per project window, started in the project folder, and a tab
/// for the latest project task, whose output the task's plugin process
/// produces. The registry owns it, so switching tabs or Spaces never
/// restarts the shell.
final class EditorTerminal: _ObservableObject {
    enum Tab: Equatable { case shell, task }

    private let publisher = _ObservablePublisher<EditorTerminal>()
    private let directory: URL
    private(set) var session: TerminalSession
    private(set) var task: (session: TerminalSession, run: TaskRun)?
    private(set) var selected = Tab.shell
    private(set) var revision: UInt64 = 0

    init(projectDirectory: String) {
        directory = URL(fileURLWithPath: projectDirectory)
        session = Self.makeSession(in: directory)
    }

    /// Shows each task the project runs in the task tab, which comes forward
    /// with `reveal` when a task starts.
    func follow(_ tasks: EditorTasks, reveal: @escaping () -> Void) {
        tasks.onOutput = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .started(run):
                self.task?.session.terminate()
                self.task = (TerminalSession.display(), run)
                self.selected = .task
                self.publish()
                reveal()
            case let .output(bytes):
                self.task?.session.show(bytes)
            case let .finished(run):
                guard let task = self.task else { return }
                task.session.showExit(code: Int32(clamping: run.status ?? 1))
                self.task = (task.session, run)
                self.publish()
            }
        }
    }

    func select(_ tab: Tab) {
        guard selected != tab else { return }
        selected = tab
        publish()
    }

    func restart() {
        session.terminate()
        session = Self.makeSession(in: directory)
        publish()
    }

    private static func makeSession(in directory: URL) -> TerminalSession {
        var command = TerminalCommand.loginShell
        command.workingDirectory = directory
        return TerminalSession(command: command)
    }

    private func publish() { revision &+= 1; publisher.send() }
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

/// The terminal fills its pane; when the shell exits, a quiet bar offers a
/// fresh one instead of leaving a dead screen. Once a task has run, a tab row
/// switches between the shell and the task's output.
struct EditorTerminalPanel: View {
    let terminal: EditorTerminal
    private let observed: Observed<EditorTerminal, UInt64>
    @State private var hasExited = false

    init(terminal: EditorTerminal) {
        self.terminal = terminal
        observed = Observed(\.revision, on: terminal)
    }

    var body: some View {
        let _ = observed.wrappedValue
        let session = terminal.session
        session.onEvent = { event in
            if case .exited = event { hasExited = true }
        }
        let task = terminal.selected == .task ? terminal.task : nil
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if let run = terminal.task?.run {
                Row(alignment: .center, spacing: 2) {
                    Button(isSelected: terminal.selected == .shell, action: { terminal.select(.shell) }) {
                        Text(L("Shell"), lineLimit: 1).font(.caption)
                    }.buttonStyle(ToggleButtonStyle(height: 22))
                    Button(isSelected: terminal.selected == .task, action: { terminal.select(.task) }) {
                        Row(alignment: .center, spacing: 4) {
                            if run.isRunning { Spinner(size: 9) }
                            Text(TasksPanel.title(run), lineLimit: 1).font(.caption)
                        }
                    }.buttonStyle(ToggleButtonStyle(height: 22)).debugName("editor-terminal-task-tab")
                    Spacer(minLength: 0)
                }.padding(EdgeInsets(bottom: 4))
            }
            if let task {
                TerminalView(session: task.session, fontSize: 12.5)
                    .id(ObjectIdentifier(task.session))
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
                    .debugName("editor-terminal-task")
            } else {
                TerminalView(session: session, fontSize: 12.5)
                    .id(ObjectIdentifier(session))
                    .flex()
                    .frame(minWidth: 0, minHeight: 0)
                    .debugName("editor-terminal")
                if hasExited {
                    Row(alignment: .center, spacing: 8) {
                        Text(L("The shell has exited.")).font(.caption).foregroundColor(.onSurfaceMuted)
                        Spacer(minLength: 0)
                        Button(L("Restart")) {
                            terminal.restart()
                            hasExited = false
                        }.buttonStyle(.ghost).controlSize(.small).debugName("editor-terminal-restart")
                    }
                    .padding(horizontal: 10)
                    .frame(height: 32)
                }
            }
        }
        // Text keeps off the pane's rounded edge.
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4))
        .frame(minWidth: 0, minHeight: 0)
    }
}
