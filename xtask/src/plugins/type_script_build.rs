//! Studio plugin build: drive the vendored Bun runtime over the Plugin SDK's
//! own `cli.ts`, exactly as `plugin-build` did.

use crate::support::shell;
use crate::support::terminal::ToolError;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub struct PluginBuild {
    pub directory: PathBuf,
    pub root: PathBuf,
    pub output: Option<PathBuf>,
}

impl PluginBuild {
    pub fn run(&self) -> Result<(), ToolError> {
        let name = if cfg!(windows) { "bun.exe" } else { "bun" };
        let bun = self
            .root
            .join("Engine/Sources/PluginRuntime/Resources/bun")
            .join(name);
        if !is_executable(&bun) {
            return Err(ToolError::message(
                "Bun runtime is missing from Engine/Sources/PluginRuntime/Resources/bun",
            ));
        }
        let destination = self.output.clone().unwrap_or_else(|| {
            let parent = self
                .directory
                .parent()
                .map(Path::to_path_buf)
                .unwrap_or_else(|| PathBuf::from("."));
            let last = self
                .directory
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            parent.join(format!("{last}.coveplugin"))
        });
        shell::inherit(
            &[
                bun.display().to_string(),
                self.root.join("PluginSDK/src/cli.ts").display().to_string(),
                "build".into(),
                self.directory.display().to_string(),
                destination.display().to_string(),
            ],
            None,
            &std::env::vars().collect::<BTreeMap<_, _>>(),
            None,
        )
    }
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_bun_runtime_reports_its_location() {
        let build = PluginBuild {
            directory: PathBuf::from("/tmp/plugin"),
            root: PathBuf::from("/nonexistent/cove"),
            output: None,
        };
        let error = build.run().unwrap_err();
        assert_eq!(
            error.to_string(),
            "Bun runtime is missing from Engine/Sources/PluginRuntime/Resources/bun"
        );
    }

    #[test]
    fn the_default_output_is_a_coveplugin_beside_the_source() {
        let build = PluginBuild {
            directory: PathBuf::from("/tmp/plugins/studio"),
            root: PathBuf::from("/nonexistent/cove"),
            output: None,
        };
        let destination = build.output.clone().unwrap_or_else(|| {
            build.directory.parent().unwrap().join(format!(
                "{}.coveplugin",
                build.directory.file_name().unwrap().to_string_lossy()
            ))
        });
        assert_eq!(destination, PathBuf::from("/tmp/plugins/studio.coveplugin"));
    }
}
