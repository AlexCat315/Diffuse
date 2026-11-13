//! Translation of
//! Editor/Sources/EditorCore/Scripting/SourceKitLSP/SourceKit/SourceKitLSPCapabilities.swift
//! (MIGRATION.md §4 D1: the script language server is `rust-analyzer`, so the
//! optional flags probed from `--help` are rust-analyzer's workspace-loading
//! switches instead of `sourcekit-lsp`'s workspace type and trust flags).
//!
//! Flags come and go between rust-analyzer releases. Passing an unknown flag
//! aborts the process before a single message is exchanged, so the client probes
//! support instead of hard-coding a list. `--no-deps` keeps analysis on the
//! generated workspace's own targets, and `--no-build-scripts` matches the
//! trust boundary that stops project build scripts from running.

use std::path::Path;

use cove_system::command::{ProcessBudget, ProcessCommand};
use cove_system::run::ProcessRunner;

use crate::scripting::rust_analyzer::server::executable_locator::RustAnalyzerExecutableLocator;

/// Optional command-line flags supported by a particular `rust-analyzer` build.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RustAnalyzerCapabilities {
    pub supports_no_deps: bool,
    pub supports_no_build_scripts: bool,
}

impl RustAnalyzerCapabilities {
    pub fn new(supports_no_deps: bool, supports_no_build_scripts: bool) -> Self {
        Self {
            supports_no_deps,
            supports_no_build_scripts,
        }
    }

    /// Everything we currently know how to ask for, gated only by actual
    /// support — the probe could not run, so assume the modern set is present.
    pub fn optimistic() -> Self {
        Self::new(true, true)
    }
}

/// Turns capabilities into the argument list the client launches with.
pub struct RustAnalyzerCommandLine;

impl RustAnalyzerCommandLine {
    pub fn arguments(
        _workspace_url: &Path,
        capabilities: &RustAnalyzerCapabilities,
    ) -> Vec<String> {
        let mut arguments: Vec<String> = Vec::new();
        if capabilities.supports_no_deps {
            arguments.push("--no-deps".to_string());
        }
        if capabilities.supports_no_build_scripts {
            arguments.push("--no-build-scripts".to_string());
        }
        arguments
    }
}

impl RustAnalyzerExecutableLocator {
    /// Runs `<executable> --help` and parses which of our flags appear.
    ///
    /// `--help` exits immediately and costs a few milliseconds; doing it once
    /// per client lifetime is far cheaper than recovering from a dead process.
    /// Falling back to [`RustAnalyzerCapabilities::optimistic`] keeps behaviour
    /// unchanged when the probe itself cannot run (sandboxed launch, sandboxed
    /// output, etc.), which is the safer failure mode.
    pub fn probe_capabilities(executable_url: &Path) -> RustAnalyzerCapabilities {
        let mut command = ProcessCommand::new(executable_url.to_path_buf(), std::env::temp_dir());
        command.arguments = vec!["--help".to_string()];
        let mut budget = ProcessBudget::new();
        budget.lifetime_milliseconds = Some(5000);
        budget.output_bytes = 262_144;
        let Ok(result) = ProcessRunner::run_synchronously(&command, budget) else {
            return RustAnalyzerCapabilities::optimistic();
        };
        if result.status != 0 {
            return RustAnalyzerCapabilities::optimistic();
        }
        let mut bytes = result.stdout;
        bytes.extend(result.stderr);
        Self::capabilities_from_help_output(&String::from_utf8_lossy(&bytes))
    }

    pub fn capabilities_from_help_output(help: &str) -> RustAnalyzerCapabilities {
        if help.is_empty() {
            return RustAnalyzerCapabilities::optimistic();
        }
        RustAnalyzerCapabilities::new(
            help.contains("--no-deps"),
            help.contains("--no-build-scripts"),
        )
    }
}
