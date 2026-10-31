//! Locates the debug products the editor validations drive, preferring the
//! Xcode `Products` directory and falling back to SwiftPM's `.build/debug`
//! layout exactly as the Python and JavaScript originals did.

use crate::support::repository;
use crate::support::terminal::ToolError;
use std::path::{Path, PathBuf};

pub struct BuildProducts;

impl BuildProducts {
    pub fn is_file(url: &Path) -> bool {
        std::fs::metadata(url)
            .map(|metadata| metadata.is_file())
            .unwrap_or(false)
    }

    pub fn executable(package: &str, name: &str, configuration: &str) -> Result<PathBuf, ToolError> {
        let product = capitalize(configuration);
        let root = repository::root();
        let candidates = [
            root.join(format!(
                "{package}/.build/out/Products/{product}/{name}"
            )),
            root.join(format!("{package}/.build/{configuration}/{name}")),
        ];
        let found = candidates
            .iter()
            .find(|candidate| Self::is_file(candidate))
            .ok_or_else(|| {
                ToolError::message(format!(
                    "Build {package}'s {name} before running this validation"
                ))
            })?;
        Ok(std::fs::canonicalize(found).unwrap_or_else(|_| found.clone()))
    }

    /// The stdio MCP server exercised by the protocol and Crystal Rush checks.
    /// `DIFFUSE_MCP_EXECUTABLE` replaces the built candidates when set.
    pub fn mcp_server() -> Result<PathBuf, ToolError> {
        let root = repository::root();
        let override_path = std::env::var("DIFFUSE_MCP_EXECUTABLE").ok().filter(|v| !v.is_empty());
        let candidates: Vec<PathBuf> = match override_path {
            Some(path) => vec![PathBuf::from(path)],
            None => vec![
                root.join("DiffuseMCP/.build/out/Products/Debug/DiffuseMCP"),
                root.join("DiffuseMCP/.build/debug/DiffuseMCP"),
            ],
        };
        candidates
            .iter()
            .find(|candidate| Self::is_file(candidate))
            .cloned()
            .ok_or_else(|| {
                ToolError::message(
                    "Build DiffuseMCP's DiffuseMCP first, or set DIFFUSE_MCP_EXECUTABLE",
                )
            })
    }
}

/// `configuration.prefix(1).uppercased() + configuration.dropFirst()`.
fn capitalize(configuration: &str) -> String {
    let mut characters = configuration.chars();
    match characters.next() {
        Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn configuration_prefix_is_upper_cased() {
        assert_eq!(capitalize("debug"), "Debug");
        assert_eq!(capitalize("Release"), "Release");
        assert_eq!(capitalize(""), "");
    }

    #[test]
    fn missing_products_report_an_actionable_error() {
        let error = BuildProducts::executable("NoSuchPackage", "Nothing", "debug").unwrap_err();
        assert!(error.to_string().contains("Build NoSuchPackage's Nothing"));
    }
}
