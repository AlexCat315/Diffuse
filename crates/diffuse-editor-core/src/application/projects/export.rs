//! `Editor/Sources/EditorCore/Application/Projects/Export.swift`.

use std::env;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread;

use cove_system::files::FileLock;
use cove_system::paths::PathIdentity;
use diffuse_assets::asset_registry::AssetRegistryError;

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::{EditorAsset, EditorAssetCatalog};
use crate::localization::localized;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::project_exporter::{
    ProjectExportDescriptor, ProjectExportError, ProjectExporter, ProjectExporterError,
    is_executable_file, player_executable_name,
};
use crate::scripting::dynamic::project_compiled_scripts::{
    ProjectCompiledScripts, ProjectCompiledScriptsError, ProjectScriptBuildConfiguration,
};
use crate::scripting::dynamic::script_project_trust::ScriptProjectTrustError;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::{
    EditorIssueTarget, EditorOperationKind, EditorOperationStatus,
};

pub(crate) struct ProjectExportJob {
    operation_id: String,
    run_after_export: bool,
    result: Receiver<Result<CompletedExport, EditorProjectExportError>>,
}

struct ProjectExportRequest {
    source: PathBuf,
    app_name: String,
    assets: Vec<EditorAsset>,
    manifest: EditorSceneManifest,
    used_play_snapshot: bool,
    player: Option<PathBuf>,
    allow_script_build: bool,
}

struct CompletedExport {
    output: PathBuf,
    descriptor: ProjectExportDescriptor,
    includes_player: bool,
    used_play_snapshot: bool,
    signing_message: Option<(EditorConsoleSeverity, &'static str, String)>,
}

#[derive(Debug, thiserror::Error)]
enum EditorProjectExportError {
    #[error(transparent)]
    Assets(#[from] AssetRegistryError),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Export(#[from] ProjectExportError),
    #[error(transparent)]
    ScriptScan(#[from] ProjectCompiledScriptsError),
    #[error("{error}")]
    UnresolvedBinding {
        #[source]
        error: ProjectExportError,
        target: Option<EditorIssueTarget>,
    },
    #[error("the project export worker stopped")]
    WorkerStopped,
}

impl ProjectExportRequest {
    fn export(self) -> Result<CompletedExport, EditorProjectExportError> {
        let output = self.source.join("export");
        let lock_dir = self.source.join(".cove");
        std::fs::create_dir_all(&lock_dir)?;
        // Separate application sessions may target the same output directory.
        let _lock = FileLock::acquire(&lock_dir.join("project-export.lock"))?;
        let configuration = ProjectScriptBuildConfiguration::discover_default(
            &env::current_exe().unwrap_or_default(),
        );
        let descriptor = ProjectExporter::export_with_script_trust(
            &self.manifest,
            &self.app_name,
            &self.assets,
            Some(&self.source),
            self.player.as_deref(),
            Some(&configuration),
            &output,
            self.allow_script_build,
        )
        .map_err(|error| match &error {
            ProjectExportError::Exporter(ProjectExporterError::UnresolvedScriptBindings(ids)) => {
                let target = EditorIssueTarget::unresolved_binding_target(ids, &self.manifest);
                EditorProjectExportError::UnresolvedBinding { error, target }
            }
            _ => error.into(),
        })?;
        let includes_player = self.player.is_some();
        let signing_message = includes_player
            .then(|| sign_export(&descriptor.app_name, &output))
            .flatten();
        Ok(CompletedExport {
            output,
            descriptor,
            includes_player,
            used_play_snapshot: self.used_play_snapshot,
            signing_message,
        })
    }
}

impl EditorApplication {
    pub fn request_project_export(&self, run_after_export: bool) {
        if !self.can_begin_project_export() {
            return;
        }
        let operation_id = self.begin_operation(
            EditorOperationKind::Exporting,
            localized("Exporting project…"),
            0,
        );
        let request = match self.capture_project_export() {
            Ok(request) => request,
            Err(error) => {
                self.complete_project_export(&operation_id, Err(error));
                return;
            }
        };
        let (send, result) = mpsc::channel();
        match thread::Builder::new()
            .name("diffuse.project-export".into())
            .spawn(move || {
                let _ = send.send(request.export());
                cove_runtime::scene::wake_scene_thread();
            }) {
            Ok(_) => {
                self.project_export.replace(Some(ProjectExportJob {
                    operation_id,
                    run_after_export,
                    result,
                }));
            }
            Err(error) => {
                self.complete_project_export(&operation_id, Err(error.into()));
            }
        }
    }

    /// Applies worker results to the editor store on the owner thread.
    pub fn poll_project_export(&self) {
        let completed = {
            let mut pending = self.project_export.borrow_mut();
            let Some(job) = pending.as_ref() else {
                return;
            };
            let result = match job.result.try_recv() {
                Ok(result) => result,
                Err(TryRecvError::Empty) => return,
                Err(TryRecvError::Disconnected) => Err(EditorProjectExportError::WorkerStopped),
            };
            pending.take().map(|job| (job, result))
        };
        if let Some((job, result)) = completed
            && self.is_active()
            && let Some(path) = self.complete_project_export(&job.operation_id, result)
            && job.run_after_export
        {
            self.run_exported_project(&path);
        }
    }

    pub fn export_project(&self) -> Option<PathBuf> {
        if !self.can_begin_project_export() {
            return None;
        }
        let id = self.begin_operation(
            EditorOperationKind::Exporting,
            localized("Exporting project…"),
            0,
        );
        let result = self
            .capture_project_export()
            .and_then(ProjectExportRequest::export);
        self.complete_project_export(&id, result)
    }

    fn can_begin_project_export(&self) -> bool {
        self.is_active()
            && !self.store.operations().iter().any(|operation| {
                operation.kind == EditorOperationKind::Exporting
                    && operation.status == EditorOperationStatus::Running
            })
    }

    fn capture_project_export(&self) -> Result<ProjectExportRequest, EditorProjectExportError> {
        let (manifest, used_play_snapshot) = self.authored_scene_manifest();
        let source = PathIdentity::canonical_url(Path::new(&self.project_directory));
        let name = source.file_name().unwrap_or_default().to_string_lossy();
        let app_name = if name.trim().is_empty() {
            "Cove Game"
        } else {
            name.trim()
        }
        .to_owned();
        let assets = EditorAssetCatalog::load_project_default(&self.project_directory)?;
        let allow_script_build = self
            .workstation
            .scripts
            .manager()
            .project_trust_state()
            .allows_execution();
        if !allow_script_build && ProjectCompiledScripts::has_sources(&source)? {
            return Err(ProjectCompiledScriptsError::from(
                ScriptProjectTrustError::ExecutionBlocked,
            )
            .into());
        }
        Ok(ProjectExportRequest {
            source,
            app_name,
            assets,
            manifest,
            used_play_snapshot,
            player: resolve_player_executable(),
            allow_script_build,
        })
    }

    fn complete_project_export(
        &self,
        id: &str,
        result: Result<CompletedExport, EditorProjectExportError>,
    ) -> Option<PathBuf> {
        match result {
            Ok(export) => {
                if let Some((severity, message, detail)) = export.signing_message {
                    self.log_export_message(message, severity, Some(detail), None);
                }
                if !export.includes_player {
                    self.log_export_message(
                        "Exported portable project data without an application",
                        EditorConsoleSeverity::Warning,
                        None,
                        Some("Build CovePlayer or set COVE_PLAYER_EXECUTABLE, then export again."),
                    );
                }
                let snapshot = if export.used_play_snapshot {
                    ", authored pre-play state"
                } else {
                    ""
                };
                self.log_export_message(
                    "Exported project bundle",
                    EditorConsoleSeverity::Info,
                    Some(format!(
                        "{} entities, {} assets{snapshot} → {}",
                        export.descriptor.entity_count,
                        export.descriptor.asset_count,
                        export.output.display()
                    )),
                    None,
                );
                self.finish_operation(id, true, localized("Project exported"), None, None, None);
                Some(export.output)
            }
            Err(error) => {
                let next_step = if matches!(
                    error,
                    EditorProjectExportError::Assets(_)
                        | EditorProjectExportError::ScriptScan(_)
                        | EditorProjectExportError::Export(ProjectExportError::Scripts(
                            ProjectCompiledScriptsError::Trust(_)
                        ))
                ) {
                    "Check project assets and script trust in Settings, then export again."
                } else {
                    "Check Build Output and project assets, fix the errors, then export again."
                };
                self.finish_operation(
                    id,
                    false,
                    localized("Project export failed"),
                    Some(next_step.into()),
                    Some(self.export_failure_target(&error)),
                    Some(error.to_string()),
                );
                None
            }
        }
    }

    fn export_failure_target(&self, error: &EditorProjectExportError) -> EditorIssueTarget {
        match error {
            EditorProjectExportError::Export(ProjectExportError::Exporter(error)) => match error {
                ProjectExporterError::MissingAsset(path)
                | ProjectExporterError::UnsafeRelativePath(path)
                | ProjectExporterError::ConflictingAssetDestination(path) => {
                    return EditorIssueTarget::File { path: path.clone() };
                }
                ProjectExporterError::ConflictingScriptIdentifier(id) => {
                    return EditorIssueTarget::Script {
                        id: id.clone(),
                        line: 0,
                        column: 0,
                    };
                }
                _ => {}
            },
            EditorProjectExportError::UnresolvedBinding {
                target: Some(target),
                ..
            } => return target.clone(),
            _ => {}
        }
        EditorIssueTarget::File {
            path: self.project_directory.clone(),
        }
    }

    pub fn run_exported_project(&self, project: &Path) -> bool {
        let project = PathIdentity::canonical_url(project);
        match launch_exported_player(&project) {
            Ok(()) => {
                self.log_export_message(
                    "Started exported build",
                    EditorConsoleSeverity::Info,
                    Some(project.display().to_string()),
                    None,
                );
                true
            }
            Err(error) => {
                self.log_export_message(
                    "Unable to run exported build",
                    EditorConsoleSeverity::Error,
                    Some(error.to_string()),
                    None,
                );
                false
            }
        }
    }

    fn log_export_message(
        &self,
        message: &str,
        severity: EditorConsoleSeverity,
        detail: Option<String>,
        next_step: Option<&str>,
    ) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity,
            detail,
            target: None,
            next_step: next_step.map(str::to_owned),
        });
    }
}

fn resolve_player_executable() -> Option<PathBuf> {
    let executable = env::current_exe().ok();
    let directory = executable.as_deref().and_then(Path::parent);
    [
        env::var_os("COVE_PLAYER_EXECUTABLE").map(PathBuf::from),
        directory.map(|dir| dir.join(player_executable_name())),
    ]
    .into_iter()
    .flatten()
    .filter(|path| is_executable_file(path))
    .find_map(|path| std::fs::canonicalize(path).ok())
}

fn launch_exported_player(project: &Path) -> io::Result<()> {
    let descriptor = ProjectExporter::read_descriptor(project).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("Invalid build descriptor: {error}"),
        )
    })?;
    if descriptor.schema_version != ProjectExporter::SCHEMA_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "Unsupported build descriptor version {}",
                descriptor.schema_version
            ),
        ));
    }
    if !cove_system::command::process_execution_available() {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            cove_system::command::ProcessError::Unavailable,
        ));
    }

    let packaged = ProjectExporter::runnable_executable_url(&descriptor.app_name, project);
    let (executable, embedded) = if is_executable_file(&packaged) {
        (packaged, cfg!(target_os = "macos"))
    } else {
        let executable = resolve_player_executable().ok_or_else(|| io::Error::new(io::ErrorKind::NotFound,
            "CovePlayer is not installed next to the Editor. Set COVE_PLAYER_EXECUTABLE to its path."))?;
        (executable, false)
    };
    // Cove's Windows process jobs kill children when the editor exits. The
    // standalone player must outlive the editor, so hand the child to a reaper.
    let mut command = std::process::Command::new(executable);
    if !embedded {
        command.arg("--project").arg(project);
    }
    command.current_dir(project);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let (send, receive) = mpsc::sync_channel::<std::process::Child>(1);
    thread::Builder::new()
        .name("diffuse.player-reaper".into())
        .spawn(move || {
            if let Ok(mut child) = receive.recv() {
                let _ = child.wait();
            }
        })?;
    if let Err(error) = send.send(command.spawn()?) {
        let mut child = error.0;
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::other("the player reaper stopped"));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn sign_export(
    app_name: &str,
    output: &Path,
) -> Option<(EditorConsoleSeverity, &'static str, String)> {
    use cove_system::process::{ProcessCommand, ProcessLimits, ProcessSession};
    use std::time::Duration;

    let bundle = ProjectExporter::application_bundle_url(app_name, output);
    let result = (|| -> io::Result<_> {
        let command = ProcessCommand::new("/usr/bin/codesign")?
            .arg("--force")
            .arg("--deep")
            .arg("--sign")
            .arg("-")
            .arg("--timestamp=none")
            .arg(bundle.as_os_str());
        ProcessSession::spawn(
            &command,
            ProcessLimits {
                timeout: Duration::from_secs(600),
                ..Default::default()
            },
        )?
        .collect()
    })();
    let detail = match result {
        Ok(status) if status.code == 0 => {
            return Some((
                EditorConsoleSeverity::Info,
                "Ad-hoc signed exported application",
                bundle
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .into_owned(),
            ));
        }
        Ok(status) => format!("codesign exited with status {}", status.code),
        Err(error) => error.to_string(),
    };
    Some((
        EditorConsoleSeverity::Warning,
        "Exported application could not be ad-hoc signed",
        detail,
    ))
}

#[cfg(not(target_os = "macos"))]
fn sign_export(
    _app_name: &str,
    _output: &Path,
) -> Option<(EditorConsoleSeverity, &'static str, String)> {
    None // These platforms export a portable Player directory without app signing.
}
