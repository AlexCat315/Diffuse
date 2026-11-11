//! Translation of
//! Tools/Developer/Sources/Build/NativeBootstrap/Entry.swift (MIGRATION.md §4:
//! the CLI surface stays the same; the media staging step was dropped when
//! `MediaStaging` was marked `removed` in favour of Cove's staged FFmpeg).

use crate::support::terminal::{Terminal, ToolError};

/// Builds the Engine and CoveUI native C/C++ dependencies.
pub enum NativeBootstrap {}

impl NativeBootstrap {
    pub const USAGE: &'static str = "cove-dev native-bootstrap [--force]\n\n  --force  Discard Engine/build/native and restage Bun\n           even when it already verifies.\n";

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
