import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// One bottom workbench for runtime logs, project diagnostics, and compiler
/// output. The script editor keeps its full height for source editing.
struct EditorOutputPanel: View {
    let app: EditorApplication
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>

    init(app: EditorApplication) {
        self.app = app
        workspace = Observed(\.snapshot, on: app.scriptWorkspace)
    }

    var body: some View {
        let snapshot = workspace.wrappedValue
        let failures = app.store.consoleEntries.filter { $0.severity == .error || $0.severity == .warning }
        let count = snapshot.documents.reduce(0) { $0 + $1.diagnostics.count } + failures.count
        TabView(selection: Binding(get: { app.store.outputTab }, set: { app.store.dispatch(.setOutputTab($0)) }), tabs: [
            TabItem(L("Logs"), id: EditorOutputTab.logs) {
                ConsolePanel(store: app.store, onNavigate: app.navigateToIssue)
            },
            TabItem("\(L("Problems")) \(count)", id: EditorOutputTab.problems) {
                problems(snapshot.documents, failures: failures)
            },
            TabItem(L("Build Output"), id: EditorOutputTab.build) {
                buildOutput(snapshot.selectedDocument)
            },
        ])
        .frame(minWidth: 0, minHeight: 0)
    }

    private func problems(_ documents: [ScriptWorkspaceDocument], failures: [EditorConsoleEntry]) -> some View {
        let withProblems = documents.filter { !$0.diagnostics.isEmpty }
        return ScrollView(.vertical, scrollbarGutter: .stable) {
            if withProblems.isEmpty && failures.isEmpty {
                EditorPanelEmptyState(L("No problems detected"))
            } else {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    withProblems.map { documentProblems($0) }
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
        .background(.surfaceSunken)
    }

    private func documentProblems(_ document: ScriptWorkspaceDocument) -> AnyView {
        AnyView(Box(direction: .column, alignItems: .stretch, spacing: 2) {
            Text("\(document.file.displayName).swift")
                .font(.label).foregroundColor(.onSurfaceVariant)
                .padding(horizontal: 8, vertical: 4)
            document.diagnostics.map { diagnostic in
                AnyView(Button(action: {
                    app.navigateToIssue(.script(id: document.file.identifier,
                        line: diagnostic.startLine, column: diagnostic.startCharacter))
                }) {
                    ScriptDiagnosticRow(diagnostic: diagnostic)
                }.buttonStyle(.plain))
            }
        })
    }

    private func buildOutput(_ document: ScriptWorkspaceDocument?) -> some View {
        let output = document?.output ?? ""
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            EditorPanelToolbar {
                Text(document.map { "\($0.file.displayName).swift" } ?? L("Select a script"))
                    .font(.caption).foregroundColor(.onSurfaceVariant)
                Spacer(minLength: 0)
                Button(L("Copy"), isEnabled: !output.isEmpty) { ClipboardHolder.write?(output) }
                    .buttonStyle(.ghost).controlSize(.small)
                Button(L("Clear"), isEnabled: !output.isEmpty, action: app.scriptWorkspace.clearSelectedOutput)
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
        .background(.surfaceSunken)
    }
}

private struct OutputTextFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content
    }
}
