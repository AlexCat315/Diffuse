//! `Editor/Sources/EditorCore/AI/Plugins/EditorPluginManagementState.swift`.
//!
//! Plain-text, bounded data safe for presentation in the Settings panel. The
//! package URL and executable binding stay private to `EditorApplication`, so
//! mutating observable state cannot enable a plugin.

use std::collections::BTreeMap;

use diffuse_plugin::lifecycle::status::PluginPhase;
use diffuse_plugin::plugin_authorization::PluginInspection;
use serde::{Deserialize, Serialize};

use crate::contributions::categories::PluginCategory;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorPluginManagementPhase {
    Idle,
    Inspecting,
    AwaitingAuthorization,
    Enabling,
    Failed,
}

impl EditorPluginManagementPhase {
    pub fn raw_value(self) -> &'static str {
        match self {
            EditorPluginManagementPhase::Idle => "idle",
            EditorPluginManagementPhase::Inspecting => "inspecting",
            EditorPluginManagementPhase::AwaitingAuthorization => "awaitingAuthorization",
            EditorPluginManagementPhase::Enabling => "enabling",
            EditorPluginManagementPhase::Failed => "failed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorPluginCapabilitySummary {
    pub id: String,
    pub title: String,
    pub description: String,
    pub access: String,
    pub schema_hash: String,
}

impl EditorPluginCapabilitySummary {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        description: impl Into<String>,
        access: impl Into<String>,
        schema_hash: impl Into<String>,
    ) -> Self {
        EditorPluginCapabilitySummary {
            id: id.into(),
            title: title.into(),
            description: description.into(),
            access: access.into(),
            schema_hash: schema_hash.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorPluginInspectionSummary {
    pub id: String,
    pub version: i64,
    pub name: String,
    pub description: String,
    pub access: String,
    pub imports: Vec<String>,
    pub process_permissions: Vec<String>,
    pub composable_host_capabilities: Vec<String>,
    pub capabilities: Vec<EditorPluginCapabilitySummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contract_hash: Option<String>,
    pub resource_hashes: BTreeMap<String, String>,
    pub contribution_points: Vec<String>,
    pub has_reusable_authorization: bool,
    pub lifecycle: EditorPluginLifecycle,
}

impl EditorPluginInspectionSummary {
    pub fn new(
        inspection: &PluginInspection,
        has_reusable_authorization: bool,
        lifecycle: EditorPluginLifecycle,
    ) -> Self {
        let manifest = &inspection.manifest;
        let mut imports: Vec<String> = manifest
            .imports
            .iter()
            .map(|permission| permission.raw_value().to_string())
            .collect();
        imports.sort();
        let process_permissions = manifest
            .host
            .processes
            .iter()
            .map(|rule| {
                let mut parts: Vec<String> = Vec::with_capacity(1 + rule.argument_prefix.len());
                parts.push(rule.command.clone());
                parts.extend(rule.argument_prefix.iter().cloned());
                let suffix = if rule.allows_additional_arguments {
                    " …"
                } else {
                    ""
                };
                format!("{}{suffix}", parts.join(" "))
            })
            .collect();
        let mut composable_host_capabilities = manifest.composable_host_capabilities.clone();
        composable_host_capabilities.sort();
        let mut capabilities: Vec<EditorPluginCapabilitySummary> = inspection
            .contracts
            .iter()
            .map(|contract| {
                EditorPluginCapabilitySummary::new(
                    contract.id.clone(),
                    contract.title.clone(),
                    contract.description.clone(),
                    contract.access.raw_value(),
                    contract.schema_hash.clone(),
                )
            })
            .collect();
        capabilities.sort_by(|left, right| left.id.cmp(&right.id));
        EditorPluginInspectionSummary {
            id: manifest.id.clone(),
            version: manifest.version,
            name: manifest.name.clone(),
            description: manifest.description.clone(),
            access: manifest.access.raw_value().to_string(),
            imports,
            process_permissions,
            composable_host_capabilities,
            capabilities,
            code_hash: inspection.code_hash.clone(),
            contract_hash: inspection.contract_hash.clone(),
            resource_hashes: inspection.resource_hashes.clone(),
            contribution_points: manifest.contributes.point_ids(),
            has_reusable_authorization,
            lifecycle,
        }
    }

    /// Swift's `lifecycle: EditorPluginLifecycle = .init()` default.
    pub fn with_default_lifecycle(
        inspection: &PluginInspection,
        has_reusable_authorization: bool,
    ) -> Self {
        Self::new(
            inspection,
            has_reusable_authorization,
            EditorPluginLifecycle::default(),
        )
    }

    pub fn categories(&self) -> Vec<PluginCategory> {
        PluginCategory::categories(&self.contribution_points, !self.capabilities.is_empty())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorPluginManagementState {
    pub phase: EditorPluginManagementPhase,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidate: Option<EditorPluginInspectionSummary>,
    pub installed: Vec<EditorPluginInspectionSummary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl EditorPluginManagementState {
    pub fn new(
        phase: EditorPluginManagementPhase,
        candidate: Option<EditorPluginInspectionSummary>,
        installed: Vec<EditorPluginInspectionSummary>,
        message: Option<String>,
    ) -> Self {
        let mut installed = installed;
        installed.sort_by(|left, right| left.id.cmp(&right.id));
        EditorPluginManagementState {
            phase,
            candidate,
            installed,
            message,
        }
    }

    /// Swift's `static let idle`.
    pub fn idle() -> Self {
        Self::default()
    }
}

impl Default for EditorPluginManagementState {
    fn default() -> Self {
        Self::new(EditorPluginManagementPhase::Idle, None, Vec::new(), None)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorPluginLifecycle {
    pub phase: PluginPhase,
    pub is_enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

impl EditorPluginLifecycle {
    pub fn new(phase: PluginPhase, is_enabled: bool, failure: Option<String>) -> Self {
        EditorPluginLifecycle {
            phase,
            is_enabled,
            failure,
        }
    }
}

impl Default for EditorPluginLifecycle {
    fn default() -> Self {
        Self::new(PluginPhase::Installed, false, None)
    }
}
