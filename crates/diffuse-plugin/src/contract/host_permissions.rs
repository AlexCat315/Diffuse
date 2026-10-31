//! Process and network authority a package declares in `plugin.json`.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contract/HostPermissions.swift`.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::contract::plugin_manifest::{PluginImportPermission, PluginManifestValidationError};
use crate::network::http::PluginHTTPPermission;
use crate::pattern::{environment_key, host_pattern, lower_dash, process_token};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginHostPermissions {
    /// Either key may be absent: a package that only reaches the network does
    /// not declare processes, and the reverse. An absent list means none.
    #[serde(default)]
    pub processes: Vec<PluginProcessPermission>,
    #[serde(default)]
    pub http: Vec<PluginHTTPPermission>,
}

impl PluginHostPermissions {
    pub fn new() -> Self {
        PluginHostPermissions::default()
    }

    pub fn entry_points(&self) -> BTreeSet<String> {
        self.processes
            .iter()
            .flat_map(|permission| permission.entry_points.iter().cloned())
            .collect()
    }
}

/// A command name is bound to a trusted absolute executable by the host. A
/// package cannot inject a search path, executable path or working directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginProcessPermission {
    pub id: String,
    pub command: String,
    #[serde(default)]
    pub argument_prefix: Vec<String>,
    #[serde(default)]
    pub allows_additional_arguments: bool,
    #[serde(default)]
    pub environment_keys: Vec<String>,
    #[serde(default)]
    pub entry_points: Vec<String>,
    #[serde(default = "default_lifetime_milliseconds")]
    pub lifetime_milliseconds: Option<i64>,
}

fn default_lifetime_milliseconds() -> Option<i64> {
    Some(30_000)
}

impl PluginProcessPermission {
    pub fn new(id: impl Into<String>, command: impl Into<String>) -> Self {
        PluginProcessPermission {
            id: id.into(),
            command: command.into(),
            argument_prefix: Vec::new(),
            allows_additional_arguments: false,
            environment_keys: Vec::new(),
            entry_points: Vec::new(),
            lifetime_milliseconds: Some(30_000),
        }
    }
}

impl PluginHostPermissions {
    pub fn validate(
        &self,
        imports: &[PluginImportPermission],
    ) -> Result<(), PluginManifestValidationError> {
        let has_import = |permission: PluginImportPermission| imports.contains(&permission);
        let ids: BTreeSet<&String> = self.processes.iter().map(|rule| &rule.id).collect();
        if !(self.processes.len() <= 16
            && ids.len() == self.processes.len()
            && (self.processes.is_empty() || has_import(PluginImportPermission::Process))
            && (!has_import(PluginImportPermission::Process) || !self.processes.is_empty()))
        {
            return Err(PluginManifestValidationError::InvalidHostPermissions);
        }
        for rule in &self.processes {
            let entry_points_ok = !rule.entry_points.is_empty()
                && rule.entry_points.len() <= 32
                && rule
                    .entry_points
                    .iter()
                    .all(|entry_point| lower_dash(entry_point, 1, 80));
            let environment_ok = rule.environment_keys.len() <= 32
                && rule.environment_keys.iter().all(|key| environment_key(key));
            let lifetime_ok = rule
                .lifetime_milliseconds
                .is_none_or(|milliseconds| milliseconds > 0 && milliseconds <= 86_400_000);
            if !(process_token(&rule.id)
                && process_token(&rule.command)
                && rule.argument_prefix.len() <= 32
                && rule
                    .argument_prefix
                    .iter()
                    .all(|argument| argument.len() <= 4096 && !argument.contains('\0'))
                && environment_ok
                && entry_points_ok
                && lifetime_ok)
            {
                return Err(PluginManifestValidationError::InvalidHostPermissions);
            }
        }
        let http_ids: BTreeSet<&String> = self.http.iter().map(|rule| &rule.id).collect();
        if !(self.http.len() <= 16
            && http_ids.len() == self.http.len()
            && (self.http.is_empty() || has_import(PluginImportPermission::Http))
            && (!has_import(PluginImportPermission::Http) || !self.http.is_empty()))
        {
            return Err(PluginManifestValidationError::InvalidHostPermissions);
        }
        for rule in &self.http {
            if !(lower_dash(&rule.id, 1, 80)
                && !rule.hosts.is_empty()
                && rule.hosts.len() <= 64
                && rule.hosts.iter().all(|host| Self::valid_host_pattern(host))
                && rule.maximum_response_bytes > 0
                && rule.maximum_response_bytes <= 64 * 1_024 * 1_024
                && rule.timeout_milliseconds > 0
                && rule.timeout_milliseconds <= 300_000)
            {
                return Err(PluginManifestValidationError::InvalidHostPermissions);
            }
        }
        Ok(())
    }

    /// A host pattern is a bare DNS name or `*.` followed by one, with an
    /// optional port. Rules are matched against the request's parsed host, so a
    /// rule can never smuggle a path or credentials.
    fn valid_host_pattern(value: &str) -> bool {
        // The pattern language, the case-insensitivity and the 253-character
        // bound are all in `pattern::host_pattern`.
        host_pattern(value) && value.split(':').next().unwrap_or(value).chars().count() <= 253
    }
}
