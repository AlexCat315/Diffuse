import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Swift diagnostics for the selected script, rendered under the editor.
///
/// Severity colouring is deliberately duplicated from the build-output pane:
/// server diagnostics and compiler diagnostics are read side by side, and a
/// different palette would make them look like different problems.
struct ScriptEditorDiagnostics: View {
    let diagnostics: [ScriptLanguageDiagnostic]

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 8) {
                Text(L("Swift Diagnostics")).font(.caption)
                EditorPanelBadge("\(diagnostics.count)")
                Spacer(minLength: 0)
            }
            .padding(horizontal: 10, vertical: 5)
            ScrollView(.vertical, scrollbarGutter: .stable) {
                Column(alignment: .leading, spacing: 2) {
                    for diagnostic in diagnostics {
                        ScriptDiagnosticRow(diagnostic: diagnostic)
                    }
                }
                .padding(horizontal: 8, vertical: 5)
            }
            .frame(maxHeight: 144)
            .background(.surfaceSunken)
        }
    }
}

struct ScriptDiagnosticRow: View {
    let diagnostic: ScriptLanguageDiagnostic

    var body: some View {
        let color: SemanticColorRef = switch diagnostic.severity {
        case .error: .error
        case .warning: .warning
        case .information, .hint: .onSurfaceMuted
        }
        Row(alignment: .center, spacing: 8) {
            Text("\(diagnostic.startLine + 1):\(diagnostic.startCharacter + 1)")
                .font(.mono)
                .foregroundColor(color)
            Text(diagnostic.message, lineLimit: 2)
                .font(.caption)
                .foregroundColor(.onSurface)
            Spacer(minLength: 0)
        }
        .padding(horizontal: 5, vertical: 3)
    }
}
