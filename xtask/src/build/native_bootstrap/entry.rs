//! Translation of
//! Tools/Developer/Sources/Build/NativeBootstrap/Entry.swift (MIGRATION.md §4:
//! the CLI surface stays the same; the media staging step was dropped when
//! `MediaStaging` was marked `removed` in favour of Cove's staged FFmpeg).

use crate::support::terminal::{Terminal, ToolError};

/// Builds the native libraries used by Diffuse.
pub enum NativeBootstrap {}

impl NativeBootstrap {
    pub const USAGE: &'static str = "cargo xtask native-bootstrap [--force]\n\n  --force  Rebuild OpenEXR and Imath from the pinned sources.\n";

    pub fn run(arguments: &[String]) -> Result<(), ToolError> {
        if arguments.iter().any(|arg| arg == "--help" || arg == "-h") {
            Terminal::info(Self::USAGE);
            return Ok(());
        }
        if let Some(unknown) = arguments.iter().find(|arg| *arg != "--force") {
            return Err(ToolError::message(format!(
                "Unknown native-bootstrap argument: {unknown}"
            )));
        }
        crate::build::native_bootstrap::bootstrap::Bootstrap::run(arguments)
    }
}
