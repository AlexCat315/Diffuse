//! Scene replacement and catalog reload from `Application/Scripting/Scripting.swift`.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::mpsc::channel;

use crate::application::editor_application::EditorApplication;
use crate::scripting::dynamic::dynamic_script_manager::{CompilationStatus, ScriptFile};
use crate::scripting::dynamic::project_script_catalog::{
    ProjectScriptCatalog, ProjectScriptCatalogDiagnosticSeverity,
};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::EditorIssueTarget;

pub(crate) enum SceneScriptReloadEvent {
    Compiled(Box<ScriptFile>, CompilationStatus),
    Finished,
}

impl EditorApplication {
    pub(crate) fn reload_scripts_after_scene_replacement(&self) {
        self.reload_project_scripts(true, false);
        self.reload_dynamic_scripts();
    }

    pub fn reload_project_scripts(&self, force: bool, report_unresolved: bool) {
        let catalog = match self.project_script_catalog_monitor.load_if_changed(force) {
            Ok(Some(catalog)) => catalog,
            Ok(None) => return,
            Err(error) => {
                if self.scene.script_catalog_entries.borrow().is_empty() {
                    self.scene
                        .apply_project_script_catalog(&ProjectScriptCatalog::built_in());
                    self.store.dispatch(EditorAction::ForceUIRefresh);
                }
                self.log_script_reload(
                    "Failed to reload script catalog",
                    EditorConsoleSeverity::Error,
                    error.to_string(),
                );
                return;
            }
        };
        let report = self.scene.apply_project_script_catalog(&catalog);
        self.store.dispatch(EditorAction::ForceUIRefresh);
        let source = catalog.source_url.as_ref().map_or_else(
            || "built-in catalog".into(),
            |path| path.display().to_string(),
        );
        self.log_script_reload(
            "Reloaded script catalog",
            EditorConsoleSeverity::Info,
            format!(
                "{} scripts ({} project) · {source}",
                report.registered_script_count, report.project_script_count,
            ),
        );
        for diagnostic in catalog.diagnostics {
            let severity = match diagnostic.severity {
                ProjectScriptCatalogDiagnosticSeverity::Warning => EditorConsoleSeverity::Warning,
                ProjectScriptCatalogDiagnosticSeverity::Error => EditorConsoleSeverity::Error,
            };
            self.store.dispatch(EditorAction::AppendConsoleMessage {
                message: format!("Script catalog: {}", diagnostic.message),
                severity,
                detail: None,
                target: None,
                next_step: None,
            });
        }
        if report_unresolved {
            for unresolved in report.unresolved_bindings {
                self.log_script_reload(
                    "Unresolved script binding",
                    EditorConsoleSeverity::Error,
                    unresolved,
                );
            }
        }
    }

    pub fn reload_dynamic_scripts(&self) {
        let scripts = &self.workstation.scripts;
        let manager = scripts.manager();
        let files = match manager.scan_script_files() {
            Ok(files) => files,
            Err(error) => {
                self.log_script_reload(
                    "Failed to scan dynamic scripts",
                    EditorConsoleSeverity::Error,
                    error.to_string(),
                );
                return;
            }
        };
        let mut options = BTreeMap::new();
        let mut aliases = BTreeMap::new();
        for file in files {
            for alias in file.legacy_identifiers {
                aliases.insert(alias, file.identifier.clone());
            }
            options.insert(file.identifier, file.display_name);
        }
        self.scene.set_dynamic_script_options(options, aliases);
        self.store.dispatch(EditorAction::ForceUIRefresh);
        scripts.mark_all_builds_started();
        if !manager.project_trust_state().allows_execution() {
            return;
        }
        let (send, receive) = channel();
        let completed = send.clone();
        let started = manager.compile_all_scripts(
            Arc::new(move |file, status| {
                let _ = send.send(SceneScriptReloadEvent::Compiled(
                    Box::new(file.clone()),
                    status,
                ));
            }),
            Arc::new(move || {
                let _ = completed.send(SceneScriptReloadEvent::Finished);
            }),
        );
        match started {
            Ok(()) => self.script_reload_events.borrow_mut().push(receive),
            Err(error) => self.log_script_reload(
                "Failed to scan dynamic scripts",
                EditorConsoleSeverity::Error,
                error.to_string(),
            ),
        }
        self.poll_script_reload();
    }

    /// Keeps build notifications and scene queries on the editor thread.
    pub fn poll_script_reload(&self) {
        let mut events = Vec::new();
        self.script_reload_events.borrow_mut().retain(|receiver| {
            loop {
                match receiver.try_recv() {
                    Ok(event) => {
                        let finished = matches!(event, SceneScriptReloadEvent::Finished);
                        events.push(event);
                        if finished {
                            return false;
                        }
                    }
                    Err(std::sync::mpsc::TryRecvError::Empty) => return true,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => return false,
                }
            }
        });
        for event in events {
            match event {
                SceneScriptReloadEvent::Compiled(file, status) => {
                    if let CompilationStatus::Failed { message } = &status {
                        self.store.dispatch(EditorAction::AppendConsoleMessage {
                            message: "Failed to compile dynamic script".into(),
                            severity: EditorConsoleSeverity::Error,
                            detail: Some(format!("{}: {message}", file.display_name)),
                            target: Some(EditorIssueTarget::compiler_diagnostic(
                                &file.identifier,
                                &file.url,
                                message,
                            )),
                            next_step: Some(
                                "Open the script, fix the reported errors, then Save and Compile."
                                    .into(),
                            ),
                        });
                    }
                    self.workstation
                        .scripts
                        .record_build_result(&file.identifier, status);
                }
                SceneScriptReloadEvent::Finished => {
                    self.store.dispatch(EditorAction::ForceUIRefresh);
                    for unresolved in self.scene.unresolved_script_binding_descriptions(false) {
                        self.log_script_reload(
                            "Unresolved script binding",
                            EditorConsoleSeverity::Error,
                            unresolved,
                        );
                    }
                }
            }
        }
    }

    fn log_script_reload(&self, message: &str, severity: EditorConsoleSeverity, detail: String) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity,
            detail: Some(detail),
            target: None,
            next_step: None,
        });
    }
}
