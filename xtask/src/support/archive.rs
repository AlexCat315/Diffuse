//! Archive extraction delegates to the platform tar, which understands the
//! xz/gz formats the pinned toolchains ship in on every supported host.

use super::files;
use super::shell;
use super::terminal::ToolError;
use std::collections::BTreeMap;
use std::path::Path;

/// Extracts `archive` into `destination`, optionally stripping leading path
/// components.
pub fn extract(
    archive: &Path,
    destination: &Path,
    strip_components: usize,
    environment: &BTreeMap<String, String>,
) -> Result<(), ToolError> {
    if !archive.is_file() {
        return Err(ToolError::message(format!(
            "Archive not found: {}",
            archive.display()
        )));
    }
    files::directory(destination).map_err(io_error)?;
    let mut arguments: Vec<String> = if cfg!(windows) {
        // MSYS2's GNU tar treats a `-f` path of the form `C:/…` as a remote
        // host (`C:`) and dies with "Cannot connect to C: resolve failed".
        // `--force-local` tells it to read the archive as a local file.
        vec![
            "tar".into(),
            "--force-local".into(),
            "-xf".into(),
            archive.display().to_string(),
            "-C".into(),
            destination.display().to_string(),
        ]
    } else {
        vec![
            "tar".into(),
            "-xf".into(),
            archive.display().to_string(),
            "-C".into(),
            destination.display().to_string(),
        ]
    };
    if strip_components > 0 {
        arguments.push("--strip-components".into());
        arguments.push(strip_components.to_string());
    }
    shell::inherit(&arguments, None, environment, None)
}

fn io_error(error: std::io::Error) -> ToolError {
    ToolError::message(error.to_string())
}
