import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Swift diagnostics for the selected script.
///
/// Collapsed by default: a handful of warnings should never push the editor
/// out of the way. The header summarises severity counts, the first entry is
/// shown inline as a preview, and the list only expands on request.
///
/// Severity colouring is deliberately duplicated from the build-output pane:
/// server diagnostics and compiler diagnostics are read side by side, and a
/// different palette would make them look like different problems.
struct ScriptEditorDiagnostics: View {
    let diagnostics: [ScriptLanguageDiagnostic]

    @State private var isExpanded = false

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            header
            if isExpanded { list }
        }
    }

    private var header: some View {
        Row(alignment: .center, spacing: 8) {
            Text(L("Swift Diagnostics")).font(.caption)
            EditorPanelBadge("\(diagnostics.count)")
            Text(summary, lineLimit: 1)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
            Spacer(minLength: 0)
            if diagnostics.count > 1 {
                Button(action: { isExpanded.toggle() }) {
                    Text(isExpanded ? L("Collapse") : L("Expand"))
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(horizontal: 10, vertical: 5)
    }

    private var list: some View {
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

    /// Severity counts plus the first message, so the collapsed row still tells
    /// the user *what* is wrong without opening the list.
    private var summary: String {
        guard let first = diagnostics.first else { return "" }
        let errors = diagnostics.reduce(0) { $0 + ($1.severity == .error ? 1 : 0) }
        let warnings = diagnostics.reduce(0) { $0 + ($1.severity == .warning ? 1 : 0) }
        let counts: [String] = [
            errors > 0 ? L("\(errors) errors") : nil,
            warnings > 0 ? L("\(warnings) warnings") : nil,
        ].compactMap { $0 }
        let prefix = counts.isEmpty ? "" : counts.joined(separator: " · ") + " — "
        return "\(prefix)\(first.startLine + 1):\(first.startCharacter + 1) \(first.message)"
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
