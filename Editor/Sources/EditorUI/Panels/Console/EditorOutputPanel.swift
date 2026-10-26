import EditorCore
import CoveUI
import CoveUIRuntime

/// One bottom workbench for runtime logs, project diagnostics, and compiler
/// output. The script editor keeps its full height for source editing.
struct EditorOutputPanel: View {
    let app: EditorApplication
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    private var tasks: Observed<EditorTasks, TaskSnapshot>

    init(app: EditorApplication) {
        self.app = app
        workspace = Observed(\.snapshot, on: app.workstation.scripts)
        tasks = Observed(\.snapshot, on: app.workstation.tasks)
    }

    var body: some View {
        let snapshot = workspace.wrappedValue
        let failures = app.store.consoleEntries.filter { $0.severity == .error || $0.severity == .warning }
        let taskProblems = tasks.wrappedValue.problems
        let count = EditorProblemSummary(documents: snapshot.documents, consoleEntries: failures, taskProblems: taskProblems).total
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            switch app.store.outputTab {
            case .logs:
                ConsolePanel(store: app.store, onNavigate: app.navigateToIssue,
                             outputSelector: AnyView(OutputModeSelector(store: app.store, problemCount: count)),
                             notify: { [app] title, tone in EditorNotifications.of(app).post(title, id: "console-copy", tone: tone) })
                    .flex()
            case .problems:
                EditorPanelToolbar {
                    OutputModeSelector(store: app.store, problemCount: count)
                    Spacer(minLength: 0)
                }
                problems(snapshot.documents, failures: failures, taskProblems: taskProblems).flex()
            case .build:
                buildOutput(snapshot.selectedDocument, problemCount: count).flex()
            }
        }
        .frame(minWidth: 0, minHeight: 0)
    }

    private func problems(_ documents: [ScriptWorkspaceDocument], failures: [EditorConsoleEntry],
                          taskProblems: [TaskProblem]) -> some View {
        let withProblems = documents.filter { !$0.diagnostics.isEmpty }
        return ScrollView(.vertical, scrollbarGutter: .stable) {
            if withProblems.isEmpty && failures.isEmpty && taskProblems.isEmpty {
                EditorPanelEmptyState(L("No problems detected"))
            } else {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    withProblems.map { documentProblems($0) }
                    if !taskProblems.isEmpty { buildProblems(taskProblems) }
                    failures.map { entry in
                        AnyView(Column(alignment: .leading, spacing: 4) {
                            Text(L(entry.message)).font(.label).foregroundColor(entry.severity == .error ? .error : .warning)
                            if let detail = entry.detail { Text(detail).font(.caption).foregroundColor(.onSurfaceVariant) }
                            if let nextStep = entry.nextStep { Text(L(nextStep)).font(.caption).foregroundColor(.warning) }
                            if let target = entry.target {
                                Button(L("Go to source")) { app.navigateToIssue(target) }.buttonStyle(.ghost)
                            }
                        }.padding(8))
                    }
                }
                .padding(8)
            }
        }
    }

    /// Compiler messages from the latest project task, by file.
    private func buildProblems(_ problems: [TaskProblem]) -> AnyView {
        var files: [String] = []
        for problem in problems where !files.contains(problem.file) { files.append(problem.file) }
        return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
            files.map { file in
                AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    Text((file as NSString).lastPathComponent)
                        .font(.label).foregroundColor(.onSurfaceVariant)
                        .padding(horizontal: 8, vertical: 4)
                    problems.filter { $0.file == file }.map { problem in
                        AnyView(Button(action: { open(problem) }) {
                            Row(alignment: .center, spacing: 8) {
                                Text("\(problem.line):\(problem.column)").font(.mono)
                                    .foregroundColor(problem.severity == .error ? .error : problem.severity == .warning ? .warning : .onSurfaceMuted)
                                Text(problem.message, lineLimit: 2).font(.caption).foregroundColor(.onSurface)
                                Spacer(minLength: 0)
                            }.padding(horizontal: 5, vertical: 3)
                        }.buttonStyle(.plain))
                    }
                })
            }
        })
    }

    private func open(_ problem: TaskProblem) {
        let position = ScriptLanguagePosition(line: max(0, problem.line - 1), character: max(0, problem.column - 1))
        app.openSwiftLocation(ScriptDefinitionLocation(documentURI: app.workstation.tasks.url(of: problem).absoluteString,
                                                       scriptID: nil, span: ScriptLanguageSpan(start: position, end: position)))
    }

    private func documentProblems(_ document: ScriptWorkspaceDocument) -> AnyView {
        AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
            Text("\(document.file.displayName).swift")
                .font(.label).foregroundColor(.onSurfaceVariant)
                .padding(horizontal: 8, vertical: 4)
            document.diagnostics.map { diagnostic in
                AnyView(Column(alignment: .leading, spacing: 0) {
                    Button(action: {
                        app.navigateToIssue(.script(id: document.file.identifier,
                            line: diagnostic.startLine, column: diagnostic.startCharacter))
                    }) {
                        ScriptDiagnosticRow(diagnostic: diagnostic)
                    }.buttonStyle(.plain)
                    diagnostic.related.map { relation in
                        AnyView(Button(action: { app.openSwiftLocation(relation.location) }) {
                            ScriptDiagnosticRelationRow(relation: relation)
                        }.buttonStyle(.plain).padding(EdgeInsets(leading: 24)))
                    }
                })
            }
        })
    }

    private func buildOutput(_ document: ScriptWorkspaceDocument?, problemCount: Int) -> some View {
        let output = document?.output ?? ""
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelToolbar {
                OutputModeSelector(store: app.store, problemCount: problemCount)
                Text(document.map { "\($0.file.displayName).swift" } ?? L("Select a script"))
                    .font(.caption).foregroundColor(.onSurfaceVariant)
                Spacer(minLength: 0)
                Button(L("Copy"), isEnabled: !output.isEmpty) { ClipboardHolder.write?(output) }
                    .buttonStyle(.ghost).controlSize(.small)
                Button(L("Clear"), isEnabled: !output.isEmpty, action: app.workstation.scripts.clearSelectedOutput)
                    .buttonStyle(.ghost).controlSize(.small)
            }
            if output.isEmpty {
                EditorPanelEmptyState(L("Build output will appear here.")).flex()
            } else {
                TextField(text: .constant(TextBuffer(output))) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 200
                    input.behavior.readOnly = true
                }
                    .font(.mono)
                    .textFieldStyle(OutputTextFieldStyle())
                    .flex(1, shrink: 1)
            }
        }
    }
}

private struct OutputModeSelector: View {
    let store: EditorStore
    let problemCount: Int
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 190, placement: .bottomLeading, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 6) {
                Text(title(store.outputTab), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                Icon(UIIcons.Navigation.chevronDown, size: 10, color: .onSurfaceMuted)
            }.padding(horizontal: 7).frame(height: 22).background(.surfaceVariant).cornerRadius(5)
                .accessibility { $0.label = L("Console"); $0.value = title(store.outputTab) }
        } content: {
            Menu([EditorOutputTab.logs, .problems, .build].map { tab in
                .item(MenuItem(id: String(describing: tab), title: title(tab), isSelected: store.outputTab == tab, action: {
                    store.dispatch(.setOutputTab(tab))
                    isPresented = false
                }))
            }, width: 190, onDismiss: { isPresented = false })
        }.debugName("editor-output-mode")
    }

    private func title(_ tab: EditorOutputTab) -> String {
        switch tab {
        case .logs: L("Logs")
        case .problems: "\(L("Problems")) \(problemCount)"
        case .build: L("Build Output")
        }
    }
}

private struct OutputTextFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content
    }
}
