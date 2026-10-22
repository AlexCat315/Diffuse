internal import EditorCore

/// The problems the console's Problems tab lists, counted once so the tab and
/// the status bar always agree.
struct EditorProblemSummary: Equatable {
    var errors = 0
    var warnings = 0
    /// Information and hint diagnostics from the language server.
    var notes = 0

    var total: Int { errors + warnings + notes }

    init(documents: [ScriptWorkspaceDocument], consoleEntries: [EditorConsoleEntry], taskProblems: [TaskProblem] = []) {
        for problem in taskProblems {
            switch problem.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .note: notes += 1
            }
        }
        for diagnostic in documents.lazy.flatMap(\.diagnostics) {
            switch diagnostic.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .information, .hint: notes += 1
            }
        }
        for entry in consoleEntries {
            switch entry.severity {
            case .error: errors += 1
            case .warning: warnings += 1
            case .info: break
            }
        }
    }
}
