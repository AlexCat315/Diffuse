//! Locates Visual Studio's `vcvarsall.bat` — first through `vswhere.exe`, then
//! through the well-known edition paths — and imports the `x64` environment it
//! prints so cmake can link against the MSVC toolchain.
//!
//! The Swift source compiles this file only on Windows; the same conditional
//! compilation is preserved here so every other host links the call as a no-op.

#[cfg(windows)]
mod imp {
    use crate::support::shell;
    use crate::support::terminal::ToolError;
    use std::collections::BTreeMap;
    use std::path::{Path, PathBuf};

    /// Imports the x64 MSVC environment into `environment`.
    pub fn activate(environment: &mut BTreeMap<String, String>) -> Result<(), ToolError> {
        if environment.contains_key("VCToolsInstallDir") {
            return Ok(());
        }
        let programs_x86 = environment
            .get("ProgramFiles(x86)")
            .cloned()
            .unwrap_or_else(|| "C:\\Program Files (x86)".into());
        let programs = environment
            .get("ProgramFiles")
            .cloned()
            .unwrap_or_else(|| "C:\\Program Files".into());
        let mut vcvars: Option<PathBuf> = None;

        let vswhere =
            Path::new(&programs_x86).join("Microsoft Visual Studio/Installer/vswhere.exe");
        if vswhere.is_file() {
            // `vswhere` exits non-zero when no instance matches; that is not fatal.
            let output = shell::output(
                &[
                    vswhere.display().to_string(),
                    "-latest".into(),
                    "-products".into(),
                    "*".into(),
                    "-requires".into(),
                    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64".into(),
                    "-property".into(),
                    "installationPath".into(),
                ],
                None,
                environment,
                true,
            )
            .unwrap_or_default();
            if !output.is_empty() {
                let candidate = Path::new(output.trim()).join("VC/Auxiliary/Build/vcvarsall.bat");
                if candidate.is_file() {
                    vcvars = Some(candidate);
                }
            }
        }

        if vcvars.is_none() {
            'search: for edition in ["2026", "2022"] {
                for product in ["Community", "Professional", "Enterprise", "BuildTools"] {
                    let candidate = Path::new(&programs)
                        .join("Microsoft Visual Studio")
                        .join(edition)
                        .join(product)
                        .join("VC/Auxiliary/Build/vcvarsall.bat");
                    if candidate.is_file() {
                        vcvars = Some(candidate);
                        break 'search;
                    }
                }
            }
        }

        let vcvars = vcvars.ok_or_else(|| {
            ToolError::message("Install Visual Studio C++ Build Tools and a Windows SDK")
        })?;

        let comspec = environment
            .get("ComSpec")
            .cloned()
            .unwrap_or_else(|| "C:\\Windows\\System32\\cmd.exe".into());
        // `cmd /s /c '... && set'` dumps the environment the batch file configures.
        let dumped = shell::output(
            &[
                comspec,
                "/s".into(),
                "/c".into(),
                format!("\"{}\" x64 >nul 2>&1 && set", vcvars.display()),
            ],
            None,
            environment,
            true,
        )
        .unwrap_or_default();
        for line in dumped.lines() {
            let Some(equals) = line.find('=') else {
                continue;
            };
            environment.insert(line[..equals].to_string(), line[equals + 1..].to_string());
        }
        Ok(())
    }
}

#[cfg(windows)]
pub use imp::activate;

/// Other hosts have no MSVC environment to import; the call succeeds unchanged.
#[cfg(not(windows))]
pub fn activate(
    environment: &mut std::collections::BTreeMap<String, String>,
) -> Result<(), super::terminal::ToolError> {
    let _ = environment;
    Ok(())
}
