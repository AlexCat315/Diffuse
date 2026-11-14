//! Project export entry point used by Android packaging.

use std::collections::BTreeMap;
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use cove_logging::{Level, LogEvent, LogSystem, LoggingConfiguration};
use diffuse_editor_core::assets::asset_catalog::EditorAssetCatalog;
use diffuse_editor_core::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use diffuse_editor_core::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use diffuse_editor_core::scene::project_exporter::ProjectExporter;
use diffuse_editor_core::scripting::dynamic::project_compiled_scripts::{
    ProjectScriptBuildConfiguration, ProjectScriptDelivery,
};

fn argument<'a>(arguments: &'a [OsString], name: &str) -> Option<&'a OsStr> {
    let index = arguments.iter().position(|argument| argument == name)?;
    arguments.get(index + 1).map(OsString::as_os_str)
}

fn run(arguments: &[OsString]) -> Result<(), Box<dyn Error>> {
    let (Some(project), Some(output)) = (
        argument(arguments, "--project"),
        argument(arguments, "--output"),
    ) else {
        return Err(
            "Usage: CoveProjectExport --project PATH --output PATH --static-scripts".into(),
        );
    };
    let source = std::path::absolute(Path::new(project))?;
    let manifest: EditorSceneManifest = serde_json::from_slice(&std::fs::read(
        source.join(".cove").join("editor-scene-manifest.json"),
    )?)?;
    let scene = EditorSceneAdapter::with_defaults(false);
    if let Some(error) = scene.load(&manifest).error {
        return Err(error.into());
    }
    if !arguments
        .iter()
        .any(|argument| argument == "--static-scripts")
    {
        return Err("Select --static-scripts for an Android export".into());
    }
    let app_name = argument(arguments, "--name")
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| {
            source
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned()
        });
    let assets = EditorAssetCatalog::load_project_default(&source.to_string_lossy())?;
    let configuration = ProjectScriptBuildConfiguration::with_delivery(
        ProjectScriptDelivery::StaticLink,
        "cargo",
        BTreeMap::new(),
    );
    let descriptor = ProjectExporter::export(
        &manifest,
        &app_name,
        &assets,
        Some(&source),
        None,
        Some(&configuration),
        &PathBuf::from(output),
    )?;
    writeln!(
        std::io::stdout().lock(),
        "Exported {}: {} entities, {} assets",
        descriptor.app_name,
        descriptor.entity_count,
        descriptor.asset_count
    )?;
    Ok(())
}

fn main() -> ExitCode {
    let result = (|| -> Result<(), Box<dyn Error>> {
        let mut configuration = LoggingConfiguration::default();
        configuration.apply_process_environment()?;
        LogSystem::bootstrap(None, configuration, None)?;
        run(&std::env::args_os().collect::<Vec<_>>())
    })();
    let status = match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            LogSystem::logger("com.cove.tools").log(&LogEvent::new(
                Level::Error,
                format!("Project export failed: {error}"),
            ));
            ExitCode::FAILURE
        }
    };
    LogSystem::flush();
    status
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_paths_and_static_scripts_then_exports_the_manifest() {
        assert!(
            run(&[])
                .expect_err("missing paths")
                .to_string()
                .contains("--project")
        );
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("diffuse-export-{}-{nonce}", std::process::id()));
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let project = root.join("Project");
        let output = root.join("Output");
        std::fs::create_dir_all(project.join(".cove")).expect("create project");
        let manifest = EditorSceneManifest::new(0, 0, Vec::new());
        std::fs::write(
            project.join(".cove/editor-scene-manifest.json"),
            serde_json::to_vec(&manifest).expect("encode manifest"),
        )
        .expect("write manifest");
        let mut arguments = vec![
            "diffuse-export".into(),
            "--project".into(),
            project.into_os_string(),
            "--output".into(),
            output.clone().into_os_string(),
            "--name".into(),
            "Test Game".into(),
        ];
        assert!(
            run(&arguments)
                .expect_err("static mode required")
                .to_string()
                .contains("--static-scripts")
        );
        assert!(!output.exists());
        arguments.push("--static-scripts".into());
        run(&arguments).expect("export empty project");
        let descriptor = ProjectExporter::read_descriptor(&output).expect("read descriptor");
        assert_eq!(descriptor.app_name, "Test Game");
        assert_eq!(descriptor.entity_count, 0);
        assert_eq!(descriptor.asset_count, 0);
    }
}
