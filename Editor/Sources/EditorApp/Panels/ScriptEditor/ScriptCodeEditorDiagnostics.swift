import EditorCore
import GuavaUICompose

/// Only rebuild the interval index when its source revision or reply changes.
final class ScriptCodeEditorDiagnostics {
    private var buffer: TextBuffer?
    private var source: [ScriptLanguageDiagnostic] = []
    private(set) var mapped = TextDiagnostics.empty
    func synchronize(buffer: TextBuffer, diagnostics: [ScriptLanguageDiagnostic]) -> TextDiagnostics {
        guard self.buffer != buffer || source != diagnostics else { return mapped }
        self.buffer = buffer; source = diagnostics
        mapped = diagnostics.isEmpty ? .empty : TextDiagnostics(diagnostics.map { diagnostic in
            let start = ScriptSourceCoordinates.utf8Offset(in: buffer,
                at: .init(line: diagnostic.startLine, character: diagnostic.startCharacter))
            let end = ScriptSourceCoordinates.utf8Offset(in: buffer,
                at: .init(line: diagnostic.endLine, character: diagnostic.endCharacter))
            let severity: TextDiagnostic.Severity = switch diagnostic.severity {
            case .error: .error
            case .warning: .warning
            case .information: .information
            case .hint: .hint
            }
            return TextDiagnostic(utf8Range: start..<max(start, end), severity: severity, message: diagnostic.message)
        })
        return mapped
    }
}
struct ScriptDiagnosticHover {
    let buffer: TextBuffer
    let anchor: TooltipAnchor
    let message: String
}
