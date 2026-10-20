import EditorCore
import GuavaUI
import GuavaUIRuntime

/// One bottom workbench for runtime logs, project diagnostics, and compiler
/// output. The script editor keeps its full height for source editing.
struct EditorOutputPanel: View {
    let app: EditorApplication
    private var workspace: Observed<ScriptWorkspaceModel, ScriptWorkspaceSnapshot>

    init(app: EditorApplication) {
        self.app = app
        workspace = Observed(\.snapshot, on: app.workstation.scripts)
    }

    var body: some View {
        let snapshot = workspace.wrappedValue
        let failures = app.store.consoleEntries.filter { $0.severity == .error || $0.severity == .warning }
        let count = snapshot.documents.reduce(0) { $0 + $1.diagnostics.count } + failures.count
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            switch app.store.outputTab {
            case .logs:
                ConsolePanel(store: app.store, onNavigate: app.navigateToIssue,
                             outputSelector: AnyView(OutputModeSelector(store: app.store, problemCount: count)))
            case .problems:
                EditorPanelToolbar {
                    OutputModeSelector(store: app.store, problemCount: count)
                    Spacer(minLength: 0)
                }
                Divider()
                problems(snapshot.documents, failures: failures).flex()
            case .build:
                buildOutput(snapshot.selectedDocument, problemCount: count)
            }
        }
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
        .background(.surfaceSunken)
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
