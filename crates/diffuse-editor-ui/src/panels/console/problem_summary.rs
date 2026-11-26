//! `Editor/Sources/EditorUI/Panels/Console/ProblemSummary.swift`.
//!
//! The problems the console's Problems tab lists, counted once so the tab and
//! the status bar always agree.

use diffuse_editor_core::scripting::rust_analyzer::language::script_language_models::ScriptDiagnosticSeverity;
use diffuse_editor_core::scripting::assets::script_workspace_model::ScriptWorkspaceDocument;
use diffuse_editor_core::state::editor_state::{EditorConsoleEntry, EditorConsoleSeverity};
use diffuse_editor_core::tasks::results::{TaskProblem, TaskProblemSeverity};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct EditorProblemSummary {
    pub errors: i64,
    pub warnings: i64,
    /// Information and hint diagnostics from the language server.
    pub notes: i64,
}

impl EditorProblemSummary {
    pub fn total(&self) -> i64 {
        self.errors + self.warnings + self.notes
    }

    pub fn new(
        documents: &[ScriptWorkspaceDocument],
        console_entries: &[EditorConsoleEntry],
        task_problems: &[TaskProblem],
    ) -> Self {
        let mut summary = EditorProblemSummary::default();
        for problem in task_problems {
            match problem.severity {
                TaskProblemSeverity::Error => summary.errors += 1,
                TaskProblemSeverity::Warning => summary.warnings += 1,
                TaskProblemSeverity::Note => summary.notes += 1,
            }
        }
        for diagnostic in documents.iter().flat_map(|document| &document.diagnostics) {
            match diagnostic.severity {
                ScriptDiagnosticSeverity::Error => summary.errors += 1,
                ScriptDiagnosticSeverity::Warning => summary.warnings += 1,
                ScriptDiagnosticSeverity::Information | ScriptDiagnosticSeverity::Hint => {
                    summary.notes += 1;
                }
            }
        }
        for entry in console_entries {
            match entry.severity {
                EditorConsoleSeverity::Error => summary.errors += 1,
                EditorConsoleSeverity::Warning => summary.warnings += 1,
                EditorConsoleSeverity::Info => {}
            }
        }
        summary
    }
}
