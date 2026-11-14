//! Operation status from `Editor/Sources/EditorCore/Application/Workbench.swift`.

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::{
    EditorIssueTarget, EditorOperation, EditorOperationKind, EditorOperationStatus,
};

impl EditorApplication {
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
