//! Operation status from `Editor/Sources/EditorCore/Application/Workbench.swift`.

use crate::application::editor_application::EditorApplication;
use crate::scripting::rust_analyzer::language::script_language_models::ScriptDefinitionLocation;
use crate::scripting::toolchain::editing_preferences::SwiftEditingPreferences;
use crate::state::workspace::editor_workbench_state::EditorScriptNavigationRequest;
use crate::version_control::model::VersionControlChange;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::{
    EditorIssueTarget, EditorOperation, EditorOperationKind, EditorOperationStatus,
};

impl EditorApplication {
    /// `openDocument(_:)` — opens a project-relative file and brings the editor
    /// forward.
    pub fn open_document(&self, path: &str) {
        self.workstation.documents.open(path);
        self.show_panel("documents");
    }

    /// `compareChange(_:)` — shows a change's diff in the editor's diff tab.
    pub fn compare_change(&self, change: &VersionControlChange) {
        self.workstation.documents.show_comparison();
        self.show_panel("documents");
        self.workstation.version_control.compare(change);
    }

    /// `saveDocumentFormatting(_:)` — formats a Swift-family script first when
    /// the editing preferences ask for it; a formatting failure still saves the
    /// text as typed.
    pub fn save_document_formatting(&self, path: &str) -> bool {
        if SwiftEditingPreferences::load().formats_on_save
            && let Some(id) = self.workstation.script_id_for_document(path)
            && self.workstation.scripts.snapshot().language_service_state
                == crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageServiceState::Ready
            && let Ok(edit) = self.workstation.scripts.manager().formatting_with_defaults(&id)
            && !edit.documents.is_empty()
            && let Err(error) = self.workstation.scripts.apply_language_edit(&edit)
        {
            self.log_console(
                "Failed to format script on save",
                EditorConsoleSeverity::Warning,
                Some(error.to_string()),
                Option::<EditorIssueTarget>::None,
                None,
            );
        }
        self.workstation.save_document(path)
    }

    /// `openSwiftLocation(_:)` — opens a language-service location: a script, or
    /// any script source file in the project.
    pub fn open_swift_location(&self, location: &ScriptDefinitionLocation) -> bool {
        let mut id = location.script_id.clone();
        if id.is_none() {
            if let Some(path) = location.document_uri.strip_prefix("file://")
                && let Some(document_path) = self.workstation.document_path_for(std::path::Path::new(path))
            {
                self.workstation.documents.open(&document_path);
                id = self.workstation.script_id_for_document(&document_path);
            }
        }
        let Some(id) = id else {
            return false;
        };
        self.navigate_to_issue(&EditorIssueTarget::Script {
            id,
            line: location.span.start.line as i64,
            column: location.span.start.character as i64,
        });
        true
    }

    /// `closeComparison()` — closes the diff tab and ends the comparison.
    pub fn close_comparison(&self) {
        self.workstation.documents.close_comparison();
        self.workstation.version_control.end_comparison();
    }

    /// `navigateToIssue(_:)` — brings the target of an issue forward.
    pub fn navigate_to_issue(&self, target: &EditorIssueTarget) {
        match target {
            EditorIssueTarget::Script { id, line, column } => {
                if !self.workstation.scripts.select(id) {
                    self.log_console(
                        "Script is missing",
                        EditorConsoleSeverity::Warning,
                        Some(id.clone()),
                        Option::<EditorIssueTarget>::None,
                        Some("Restore the script file, then refresh the script catalog.".into()),
                    );
                    return;
                }
                self.store
                    .dispatch(EditorAction::NavigateToScript(
                        EditorScriptNavigationRequest::with_position(id.clone(), *line, *column),
                    ));
                if let Some(path) = self.workstation.document_path_for_script(id) {
                    self.workstation.documents.open(&path);
                }
                self.show_panel("documents");
            }
            EditorIssueTarget::Entity { id } => {
                if self.scene.entity_summary(Some(*id)).is_none() {
                    return;
                }
                self.store
                    .dispatch(EditorAction::SetSelectedEntity(Some(*id)));
                self.store
                    .dispatch(EditorAction::SetInspectorSceneSettingsVisible(false));
                self.show_panel("inspector");
            }
            EditorIssueTarget::Asset { id } => {
                self.store
                    .dispatch(EditorAction::NavigateToAsset(Some(id.clone())));
                self.show_panel("assets");
            }
            EditorIssueTarget::File { path } => {
                let matching = self
                    .workstation
                    .scripts
                    .snapshot()
                    .documents
                    .iter()
                    .find(|document| {
                        document.file.url.to_string_lossy() == *path
                            || document
                                .file
                                .url
                                .file_name()
                                .is_some_and(|name| name == std::ffi::OsStr::new(path))
                    })
                    .map(|document| document.file.identifier.clone());
                match matching {
                    Some(id) => self.navigate_to_issue(&EditorIssueTarget::Script {
                        id,
                        line: 0,
                        column: 0,
                    }),
                    None => {
                        self.store
                            .dispatch(EditorAction::NavigateToAsset(Some(path.clone())));
                        self.show_panel("assets");
                    }
                }
            }
        }
    }

    pub fn begin_operation(
        &self,
        kind: EditorOperationKind,
        message: String,
        total: i64,
    ) -> String {
        let mut operation = EditorOperation::with_defaults(kind, message);
        operation.total = total;
        let id = operation.id.clone();
        self.store.dispatch(EditorAction::SetOperation(operation));
        self.request_display_refresh();
        id
    }

    pub fn finish_operation(
        &self,
        id: &str,
        succeeded: bool,
        message: String,
        next_step: Option<String>,
        target: Option<EditorIssueTarget>,
        detail: Option<String>,
    ) {
        let Some(mut operation) = self
            .store
            .operations()
            .into_iter()
            .find(|operation| operation.id == id)
        else {
            return;
        };
        operation.status = if succeeded {
            operation.completed = operation.total;
            EditorOperationStatus::Succeeded
        } else {
            EditorOperationStatus::Failed
        };
        operation.message = message.clone();
        operation.next_step = next_step.clone();
        operation.target = target.clone();
        self.store.dispatch(EditorAction::SetOperation(operation));
        if !succeeded {
            self.store.dispatch(EditorAction::AppendConsoleMessage {
                message,
                severity: EditorConsoleSeverity::Error,
                detail,
                target,
                next_step,
            });
        }
        self.request_display_refresh();
    }
}
