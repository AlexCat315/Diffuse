//! `Editor/Sources/EditorCore/Application/Plugins/Processes.swift`.
//!
//! The process context one plugin may run commands in: its workspace, and the
//! executables its approved permission binds.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use cove_system::paths::PathIdentity;
use cove_system::tool_locator::{ProcessEnvironment, ToolLocator};
use diffuse_plugin::contribution::processes::systems::VersionControlContribution;
use diffuse_plugin::plugin_authorization::PluginAuthorizationRecord;
use diffuse_plugin::processes::contract::{PluginProcessContext, PluginProcessError};

use crate::application::editor_application::EditorApplication;
use crate::contributions::runtime_access::PluginRuntimeAccess;
use crate::scripting::dynamic::dynamic_script_manager::DynamicScriptManager;
use crate::scripting::toolchain::resolution::SwiftToolchainResolver;
use crate::version_control::providers::VersionControlProvider;

impl EditorApplication {
    /// The host resolves tools from its launch environment, never a package's
    /// environment or a project's bin directory. The approved permission still
    /// restricts command, arguments and environment on every invocation.
    pub fn plugin_process_context(
        &self,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<PluginProcessContext, PluginProcessError> {
        Self::build_plugin_process_context(
            &self.project_directory,
            self.workstation.scripts.manager(),
            &self.plugin_session.runtime,
            authorization,
        )
    }

    pub(super) fn build_plugin_process_context(
        project_directory: &str,
        scripts: &DynamicScriptManager,
        runtime: &PluginRuntimeAccess,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<PluginProcessContext, PluginProcessError> {
        let permissions = &authorization.host;
        let root = PathIdentity::canonical_url(Path::new(project_directory));
        let mut context = PluginProcessContext::new(root.clone());
        let providers: Vec<VersionControlProvider> = runtime
            .version_control_providers()
            .into_iter()
            .filter(|provider| provider.plugin_id() == authorization.plugin_id)
            .collect();
        if permissions
            .entry_points()
            .contains(VersionControlContribution::ENTRY_POINT)
        {
            if let Some(repository) = VersionControlProvider::repository_containing(
                &root,
                &BTreeSet::new(),
                Some(&providers),
            ) {
                context.workspace = repository.root;
            }
        }
        #[cfg(windows)]
        let separator = ';';
        #[cfg(not(windows))]
        let separator = ':';
        let environment: std::collections::BTreeMap<String, String> = std::env::vars().collect();
        // A package may not reach into the project's own directories: those
        // hold code the user did not approve for it.
        let directories: Vec<PathBuf> = ProcessEnvironment::value("PATH", &environment)
            .unwrap_or_default()
            .split(separator)
            .filter_map(|item| {
                let path = Path::new(item);
                if !path.is_absolute() {
                    return None;
                }
                let url = PathIdentity::canonical_url(path);
                if PathIdentity::contains(&url, &root, true) {
                    return None;
                }
                Some(url)
            })
            .collect();
        for rule in &permissions.processes {
            if rule.command == "sourcekit-lsp" {
                let configured = scripts
                    .swift_toolchain()
                    .map(|toolchain| toolchain.language_server_url);
                let executable = match configured {
                    Some(executable) => executable,
                    None => SwiftToolchainResolver::resolve_default()
                        .map(|toolchain| toolchain.language_server_url)
                        .map_err(|_| PluginProcessError::CommandNotBound(rule.command.clone()))?,
                };
                if PathIdentity::contains(&executable, &root, true) {
                    return Err(PluginProcessError::CommandNotBound(rule.command.clone()));
                }
                context.executables.insert(rule.command.clone(), executable);
                continue;
            }
            let joined = directories
                .iter()
                .map(|directory| directory.to_string_lossy().into_owned())
                .collect::<Vec<_>>()
                .join(&separator.to_string());
            let search = ProcessEnvironment::setting(&joined, "PATH", &environment);
            match ToolLocator::executable(&rule.command, &search) {
                Some(executable) if !PathIdentity::contains(&executable, &root, true) => {
                    context.executables.insert(rule.command.clone(), executable);
                }
                _ => return Err(PluginProcessError::CommandNotBound(rule.command.clone())),
            }
        }
        Ok(context)
    }
}
