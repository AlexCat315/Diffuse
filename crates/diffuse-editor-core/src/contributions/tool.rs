//! `Editor/Sources/EditorCore/Contributions/Tool.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use cove_system::tool_locator::{ProcessEnvironment, ToolLocator};

/// A located command-line tool for a contribution and the environment it may run with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributionTool {
    pub executable: PathBuf,
    pub environment: BTreeMap<String, String>,
}

impl ContributionTool {
    /// GUI apps start with a minimal PATH, so the usual install locations are
    /// searched too: Homebrew, `~/.local/bin` and the system. `COVE_<COMMAND>_EXECUTABLE`
    /// names a specific build.
    pub fn locate(
        command: &str,
        environment: &BTreeMap<String, String>,
    ) -> Option<ContributionTool> {
        #[cfg(windows)]
        let (separator, common) = {
            let home = ProcessEnvironment::value("USERPROFILE", environment)
                .unwrap_or_else(|| std::env::var("USERPROFILE").unwrap_or_default());
            (
                ';',
                vec![format!("{home}/.cargo/bin"), format!("{home}/.local/bin")],
            )
        };
        #[cfg(not(windows))]
        let (separator, common) = {
            let home = ProcessEnvironment::value("HOME", environment)
                .unwrap_or_else(|| std::env::var("HOME").unwrap_or_default());
            (
                ':',
                vec![
                    "/opt/homebrew/bin".to_string(),
                    "/usr/local/bin".to_string(),
                    format!("{home}/.local/bin"),
                    format!("{home}/.cargo/bin"),
                    "/usr/bin".to_string(),
                    "/bin".to_string(),
                ],
            )
        };
        let path = ProcessEnvironment::value("PATH", environment)
            .unwrap_or_default()
            .split(separator)
            .map(str::to_string)
            .collect::<Vec<_>>();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let directories: Vec<String> = path
            .into_iter()
            .chain(common)
            .filter(|directory| seen.insert(directory.clone()))
            .collect();
        let inherited = ProcessEnvironment::setting(
            &directories.join(&separator.to_string()),
            "PATH",
            environment,
        );
        let override_executable = ProcessEnvironment::value(
            &format!("COVE_{}_EXECUTABLE", command.to_uppercase()),
            environment,
        );
        let executable = ToolLocator::executable(
            override_executable.as_deref().unwrap_or(command),
            &inherited,
        )?;
        Some(ContributionTool {
            executable,
            environment: inherited,
        })
    }

    /// Swift's default `environment: ProcessInfo.processInfo.environment`.
    pub fn locate_with_process_environment(command: &str) -> Option<ContributionTool> {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        Self::locate(command, &environment)
    }

    /// The editor's values for the variables a plugin's process permission
    /// allows; PATH is the search path the tool was found on.
    pub fn environment_for_keys(&self, keys: &[String]) -> BTreeMap<String, String> {
        keys.iter()
            .filter_map(|key| {
                ProcessEnvironment::value(key, &self.environment).map(|value| (key.clone(), value))
            })
            .collect()
    }
}
