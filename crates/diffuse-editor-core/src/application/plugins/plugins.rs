//! `Editor/Sources/EditorCore/Application/Plugins/Plugins.swift` — the plugin
//! query-snapshot seam the assistant session consumes.
//!
//! The remaining Plugins.swift sections (enable/disable, contribution reload,
//! entry-point reads, harness activation) are ported with the plugin management
//! batches; this file currently carries the revision-bound snapshot provider.

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::path::Path;
use std::rc::Rc;

use diffuse_ai::planning::capability_draft_pipeline::CapabilityInvocationDraft;
use diffuse_ai::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use diffuse_ai::tools::plugin_capability_executor::PluginQuerySnapshotProvider;
use diffuse_assets::swift_json;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_manifest::PluginImportPermission;
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::host::plugin_host_process_client::PluginHostProcessClient;
use diffuse_plugin::host::plugin_host_rpc::PluginQuerySnapshot;
use diffuse_plugin::plugin_authorization::PluginAuthorizationRecord;
use diffuse_plugin::plugin_authorization::PluginInspection;
use diffuse_plugin::PluginError;

use crate::application::editor_application::{EditorApplication, SendableAppHandle};
use crate::application::plugins::editor_plugin_capability_error::EditorPluginCapabilityError;
use crate::assets::asset_catalog::EditorAssetCatalog;
use crate::contributions::themes::theme_catalog::EditorThemeCatalog;

/// Any error a snapshot build can raise, matching Swift's untyped `throws`.
pub(crate) type PluginSnapshotError = Box<dyn Error + Send + Sync>;

impl EditorApplication {
    /// `makePluginQuerySnapshotProvider()` — answers one plugin's revision-bound
    /// snapshot for the session; `None` without a plugin executor.
    pub fn make_plugin_query_snapshot_provider(
        self: &Rc<Self>,
    ) -> Option<PluginQuerySnapshotProvider> {
        if self.plugin_capability_executor.borrow().is_none() {
            return None;
        }
        let app = SendableAppHandle(Rc::downgrade(self));
        Some(std::sync::Arc::new(move |plugin_id: &str, revision: u64| {
            let app = app.upgrade().ok_or_else(|| {
                Box::new(EditorPluginCapabilityError::PluginNotEnabled(plugin_id.to_string()))
                    as PluginSnapshotError
            })?;
            app.make_plugin_query_snapshot(plugin_id, revision)
                .map_err(|error| error as PluginSnapshotError)
        }))
    }

    /// `makePluginQuerySnapshot(pluginID:sceneRevision:)` — the bounded payloads
    /// the plugin's granted snapshot imports require.
    pub(crate) fn make_plugin_query_snapshot(
        &self,
        plugin_id: &str,
        scene_revision: u64,
    ) -> Result<Option<PluginQuerySnapshot>, PluginSnapshotError> {
        let executor = {
            let borrowed = self.plugin_capability_executor.borrow();
            borrowed.clone()
        };
        let executor = executor.ok_or_else(|| {
            Box::new(EditorPluginCapabilityError::PluginNotEnabled(plugin_id.to_string()))
                as PluginSnapshotError
        })?;
        let imports: BTreeSet<PluginImportPermission> = executor
            .required_imports(plugin_id)
            .map_err(|error| Box::new(error) as PluginSnapshotError)?
            .into_iter()
            .filter(|permission| permission.is_snapshot())
            .collect();
        if imports.is_empty() {
            return Ok(None);
        }
        let actual = self.scene.revision();
        if actual != scene_revision {
            return Err(Box::new(EditorPluginCapabilityError::SceneRevisionChanged {
                expected: scene_revision,
                actual,
            }));
        }

        let mut snapshot = PluginQuerySnapshot::new(scene_revision);
        if imports.contains(&PluginImportPermission::SceneQuery) {
            let scene = self.scene.scene();
            let encoded = SceneSemanticEncoder::new().encode(
                &scene,
                self.store.selected_entity_id(),
                Some(self.store.content().raw_value().to_string()),
                None,
            );
            let json = swift_json::to_compact(&encoded)?;
            snapshot.scene = Some(Data::from_bytes(json.into_bytes()));
        }
        if imports.contains(&PluginImportPermission::SelectionQuery) {
            let selected: Vec<String> = self
                .store
                .selected_entity_id()
                .map(|id| vec![format!("scene:{id}")])
                .unwrap_or_default();
            let value = serde_json::json!({ "selected": selected });
            snapshot.selection = Some(Data::from_bytes(value.to_string().into_bytes()));
        }
        if imports.contains(&PluginImportPermission::AssetMetadataQuery) {
            let assets: Vec<serde_json::Value> = EditorAssetCatalog::entries()
                .into_iter()
                .map(|asset| {
                    serde_json::json!({
                        "id": asset.id,
                        "name": asset.name,
                        "relative_path": asset.relative_path,
                        "kind": format!("{:?}", asset.kind),
                        "mesh_index": asset.mesh_index,
                    })
                })
                .collect();
            let value = serde_json::json!({ "assets": assets });
            snapshot.asset_metadata = Some(Data::from_bytes(value.to_string().into_bytes()));
        }
        snapshot.validate(&imports)?;
        Ok(Some(snapshot))
    }

    /// `makePluginQuerySnapshots(for:sceneRevision:)` — one snapshot per plugin
    /// that the draft set references.
    pub(crate) fn make_plugin_query_snapshots(
        &self,
        drafts: &[CapabilityInvocationDraft],
        scene_revision: u64,
    ) -> Result<BTreeMap<String, PluginQuerySnapshot>, PluginSnapshotError> {
        let plugin_ids: BTreeSet<String> = drafts
            .iter()
            .filter_map(|draft| draft.source_plugin_id.clone())
            .collect();
        let mut result = BTreeMap::new();
        for plugin_id in plugin_ids {
            if let Some(snapshot) = self.make_plugin_query_snapshot(&plugin_id, scene_revision)? {
                result.insert(plugin_id, snapshot);
            }
        }
        Ok(result)
    }
}

/// Everything plugin inspection can fail with.
#[derive(Debug, thiserror::Error)]
pub enum PluginInspectionError {
    #[error("{0}")]
    Package(#[from] PluginError),
    #[error("{0}")]
    Theme(#[from] crate::contributions::themes::theme_catalog::ThemeCatalogError),
    #[error(
        "The trusted DiffusePluginHost executable is unavailable. Rebuild or reinstall the Editor."
    )]
    HostUnavailable,
}

impl EditorApplication {
    /// Inspects static contracts, manifest metadata and code without enabling
    /// or exposing the plugin: what the UI must show before the user creates an
    /// explicit authorization record.
    pub fn inspect_plugin(
        &self,
        plugin_url: &Path,
    ) -> Result<PluginInspection, PluginInspectionError> {
        let loader = PluginPackageLoader::new(
            diffuse_capability::capability_registry::CapabilityRegistry::default_registry(),
            None,
            ContributionPointRegistry::standard(),
        );
        let package = loader.load(plugin_url)?;
        if package.runtime.is_none() {
            EditorThemeCatalog::validate(&package)?;
            return Ok(PluginInspection::from_package(&package, Vec::new()));
        }
        // Inspection is a one-shot read of an uninstalled package: give it a
        // throwaway process so it never joins the pool serving enabled plugins.
        let Some(executable) = self.trusted_plugin_host_executable_url.clone() else {
            return Err(PluginInspectionError::HostUnavailable);
        };
        let client = PluginHostProcessClient::new(executable, Vec::new(), None);
        let result = client.inspect_plugin(plugin_url).map_err(Into::into);
        client.stop();
        result
    }

    /// Only after the user approved the inspection shown by the UI: any code,
    /// contract, permission or schema change invalidates the record.
    pub fn make_plugin_authorization(
        &self,
        inspection: &PluginInspection,
        authorised_at: &diffuse_capability::support::swift_date::SwiftDate,
    ) -> Result<PluginAuthorizationRecord, PluginError> {
        PluginAuthorizationRecord::from_inspection(inspection, authorised_at.clone())
    }

    /// A stored record is reusable only when every current inspection field is
    /// identical; finding a record never loads or exposes the plugin.
    pub fn stored_plugin_authorization(
        &self,
        inspection: &PluginInspection,
    ) -> Option<PluginAuthorizationRecord> {
        self.plugin_session
            .authorization_store
            .authorization(inspection)
    }

    pub fn enabled_plugin_inspections(&self) -> Vec<PluginInspection> {
        self.plugin_session.manager.enabled_inspections()
    }

    /// `isPluginHostAvailable` — no host means the management UI stays read-only.
    pub fn is_plugin_host_available(&self) -> bool {
        self.trusted_plugin_host_executable_url.is_some()
    }
}
