internal import GuavaUI
internal import GuavaUIRuntime
internal import GuavaUITerminal
private import Foundation

/// One shell per project window, started in the project folder. The registry
/// owns it, so switching tabs or Spaces never restarts the program.
final class EditorTerminal {
    private let directory: URL
    private(set) var session: TerminalSession

    init(projectDirectory: String) {
        directory = URL(fileURLWithPath: projectDirectory)
        session = Self.makeSession(in: directory)
    }

    func restart() {
        session.terminate()
        session = Self.makeSession(in: directory)
    }

    private static func makeSession(in directory: URL) -> TerminalSession {
        var command = TerminalCommand.loginShell
        command.workingDirectory = directory
        return TerminalSession(command: command)
    }
}

/// The terminal fills its pane; when the shell exits, a quiet bar offers a
/// fresh one instead of leaving a dead screen.
struct EditorTerminalPanel: View {
    let terminal: EditorTerminal
    @State private var generation = 0
    @State private var hasExited = false

    var body: some View {
        let session = terminal.session
        session.onEvent = { event in
            if case .exited = event { hasExited = true }
        }
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            TerminalView(session: session, fontSize: 12.5)
                .id(generation)
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
                        generation += 1
                    }.buttonStyle(.ghost).controlSize(.small).debugName("editor-terminal-restart")
                }
                .padding(horizontal: 10)
                .frame(height: 32)
            }
        }
        // Text keeps off the pane's rounded edge.
        .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4))
        .frame(minWidth: 0, minHeight: 0)
    }
}
