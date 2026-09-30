import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// One bottom workbench for runtime logs, project diagnostics, and compiler
/// output. The script editor keeps its full height for source editing.
struct EditorOutputPanel: View {
    let app: EditorApplication
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>
    @State private var selection = OutputTab.logs

    init(app: EditorApplication) {
        self.app = app
        workspace = Observed(\.snapshot, on: app.scriptWorkspace)
    }

    var body: some View {
        let snapshot = workspace.wrappedValue
        let count = snapshot.documents.reduce(0) { $0 + $1.diagnostics.count }
        TabView(selection: $selection, tabs: [
            TabItem(L("Logs"), id: OutputTab.logs) { ConsolePanel(store: app.store) },
            TabItem("\(L("Problems")) \(count)", id: OutputTab.problems) {
                problems(snapshot.documents)
            },
            TabItem(L("Build Output"), id: OutputTab.build) {
                buildOutput(snapshot.selectedDocument)
            },
        ])
        .frame(minWidth: 0, minHeight: 0)
    }

    private func problems(_ documents: [ScriptWorkspaceDocument]) -> some View {
        let withProblems = documents.filter { !$0.diagnostics.isEmpty }
        return ScrollView(.vertical, scrollbarGutter: .stable) {
            if withProblems.isEmpty {
                EditorPanelEmptyState(L("No problems detected"))
            } else {
                Box(direction: .column, alignItems: .stretch, spacing: 8) {
                    withProblems.map { documentProblems($0) }
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
                AnyView(Button(action: { _ = app.scriptWorkspace.select(scriptID: document.file.identifier) }) {
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
                TextField(text: Binding(get: { output }, set: { _ in }), axis: .vertical,
                          maxVisibleLines: 200, readOnly: true)
                    .font(.mono)
                    .textFieldStyle(OutputTextFieldStyle())
                    .flex(1, shrink: 1)
            }
        }
        .background(.surfaceSunken)
    }
}

private enum OutputTab: Hashable { case logs, problems, build }

private struct OutputTextFieldStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        configuration.content
    }
}
