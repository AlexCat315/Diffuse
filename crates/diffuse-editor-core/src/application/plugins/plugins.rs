//! `Editor/Sources/EditorCore/Application/Plugins/Plugins.swift` — the plugin
//! query-snapshot seam the assistant session consumes.
//!
//! Runtime binding, capability projection, and package authorization.

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;

use diffuse_ai::planning::capability_draft_pipeline::CapabilityInvocationDraft;
use diffuse_ai::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use diffuse_ai::tools::plugin_capability_executor::{PluginCapabilityExecutor, PluginQuerySnapshotProvider};
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

pub type PluginLifecycleError = Box<dyn Error + Send + Sync>;

impl EditorApplication {
    pub(crate) fn configure_plugin_runtime(&self) {
        use diffuse_plugin::contract::plugin_component_capability::PluginComponentCapability;
        use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;
        use diffuse_plugin::lifecycle::disposal::Registration;
        use diffuse_plugin::lifecycle::status::{PluginRuntimeActivation, PluginRuntimeDriver};

        let project_directory = self.project_directory.clone();
        let scripts = self.workstation.scripts.manager().clone();
        let runtime = self.plugin_session.runtime.clone();
        let components = self.plugin_session.components.clone();
        let hosts = self.plugin_session.hosts.clone();
        let unload_hosts = hosts.clone();
        let stop_hosts = hosts.clone();
        let jobs = self.plugin_session.editor.jobs.clone();
        self.plugin_session
            .manager
            .configure_runtime(PluginRuntimeDriver::new(
                move |package, authorization| {
                    let context = Self::build_plugin_process_context(
                        &project_directory,
                        &scripts,
                        &runtime,
                        &authorization,
                    )?;
                    let id = &authorization.plugin_id;
                    let client = hosts.client(id)?;
                    let binding = match client.load_plugin(&package, &authorization, Some(context))
                    {
                        Ok(binding) => binding,
                        Err(error) => {
                            hosts.discard(id);
                            return Err(error);
                        }
                    };
                    if PluginComponentCapability::declares_components(
                        &binding.inspection.contracts,
                        id,
                    ) {
                        let capability = PluginComponentCapability::capability_id(id);
                        match client.prepare_capability(
                            &binding,
                            &capability,
                            PluginComponentCapability::input(),
                            None,
                        ) {
                            Ok(PluginPreparedCapabilityResult::Read(payload)) => {
                                if let Ok(declarations) =
                                    super::plugin_components::PluginComponentDeclaration::decode(
                                        &payload,
                                    )
                                {
                                    components.set(declarations, id);
                                }
                            }
                            Ok(_) | Err(_) => {}
                        }
                    }
                    let components = Arc::downgrade(&components);
                    let id = id.clone();
                    let registration = Registration::new(move || {
                        if let Some(components) = components.upgrade() {
                            components.remove(&id);
                        }
                    });
                    Ok(PluginRuntimeActivation::new(
                        binding,
                        Some(Arc::new(registration)),
                    ))
                },
                move |binding| {
                    let id = binding.plugin_id();
                    jobs.cancel_owner(id);
                    let result = unload_hosts
                        .existing(id)
                        .map(|client| client.unload_plugin(Path::new(&binding.plugin_path)))
                        .transpose();
                    unload_hosts.discard(id);
                    result.map(|_| ())
                },
                move || stop_hosts.stop_all(),
            ));
    }

    pub fn activate_plugins(self: &Rc<Self>, event: &str) -> Result<(), PluginLifecycleError> {
        let operation = self.plugin_session.manager.activate_event(event);
        let projection = self.synchronize_plugins();
        operation?;
        projection
    }

    pub(super) fn synchronize_plugins(self: &Rc<Self>) -> Result<(), PluginLifecycleError> {
        use diffuse_capability::capability_contract::CapabilityExposurePolicy;
        use diffuse_intent::BuiltInTypedCapabilityCatalog;

        let manager = &self.plugin_session.manager;
        self.refresh_contribution_snapshots();
        let bindings = manager.active_bindings();
        let host_registry = BuiltInTypedCapabilityCatalog::registry();
        let executor = if bindings.is_empty() {
            Ok(None)
        } else {
            PluginCapabilityExecutor::new(
                &host_registry,
                bindings.values().cloned().collect(),
                &manager.enabled_inspections(),
                Arc::new(super::host_pool::PluginHostRouter::new(
                    self.plugin_session.hosts.clone(),
                )),
            )
            .map(Some)
        };
        if executor.is_err() {
            let _ = manager.invalidate_runtime(None);
            self.plugin_session.components.remove_all();
            self.refresh_contribution_snapshots();
        }
        self.scene
            .with_scene_mut(|scene| self.plugin_session.components.apply(scene));

        let language_service = &self.workstation.scripts.manager().language_plugin;
        let language_binding = self
            .language_catalog()
            .languages
            .iter()
            .find(|language| language.server.is_some())
            .and_then(|language| manager.active_bindings().remove(&language.plugin_id));
        let was_bound = language_service.is_bound();
        let client = language_binding
            .as_ref()
            .and_then(|binding| self.plugin_session.hosts.existing(binding.plugin_id()));
        let now_bound = language_binding.is_some();
        if language_service.bind(language_binding, client) {
            if was_bound {
                self.workstation
                    .scripts
                    .stop_language_service_for_plugin_change();
            }
            if now_bound {
                self.workstation
                    .scripts
                    .start_language_service_for_plugin_change();
            }
        }

        let next = executor.as_ref().ok().and_then(Option::as_ref);
        let mut state = self.plugin_session.state();
        let provider = state
            .providers
            .provider(&self.store.ai_settings().provider_id)
            .cloned();
        let provider_changed = provider != state.ai_provider;
        state.ai_provider = provider;
        let authorities = next
            .map(|executor| executor.plugin_authorities.clone())
            .unwrap_or_default();
        let changed = authorities != state.ai_authorities;
        state.ai_authorities = authorities.clone();
        if let Some(monitor) = &state.package_monitor {
            monitor.set_packages(self.plugin_package_urls());
        }
        drop(state);

        self.plugin_capability_executor.replace(next.cloned());
        if changed || provider_changed || executor.is_err() {
            let settings = self.store.capability_settings();
            self.intent_coordinator.configure_capability_planner(
                Self::make_capability_invocation_planner(&settings, next),
            );
            let policy = next
                .map(PluginCapabilityExecutor::exposure_policy)
                .unwrap_or_else(|| CapabilityExposurePolicy {
                    allowed_domains: Some(BTreeSet::from(["scene".to_string()])),
                    ..CapabilityExposurePolicy::default()
                });
            self.tool_access.capability_sessions.replace_registry(
                next.map(|executor| executor.registry.clone())
                    .unwrap_or(host_registry),
                policy,
                authorities,
            );
            if provider_changed {
                self.rebuild_session_after_plugin_projection();
            } else if let Some(session) = self.session.borrow().as_ref() {
                session.replace_plugin_capabilities(
                    next.cloned(),
                    self.make_plugin_query_snapshot_provider(),
                );
                self.agent_execution.borrow_mut().proposal = None;
            }
        }
        self.publish_plugin_management(
            crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementPhase::Idle,
            self.store.plugin_management().candidate,
            None,
        );
        executor.map(|_| ()).map_err(Into::into)
    }
}

impl EditorApplication {
    /// Enables the exact package covered by the supplied authorization.
    pub fn enable_plugin(
        self: &Rc<Self>,
        package: &Path,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<PluginInspection, PluginLifecycleError> {
        let manager = &self.plugin_session.manager;
        let inspection = match manager.enable(package, authorization) {
            Ok(inspection) => inspection,
            Err(error) => {
                let _ = self.synchronize_plugins();
                return Err(error.into());
            }
        };
        let persist = || -> Result<(), PluginLifecycleError> {
            self.plugin_session
                .authorization_store
                .record(authorization)?;
            if super::bundled::BundledPlugins::plugin(&inspection.manifest.id).is_some() {
                super::bundled::BundledPlugins::set_enabled(
                    true,
                    &inspection.manifest.id,
                    Path::new(&self.project_directory),
                    self.plugin_session.editor.peers.borrow().is_some(),
                )?;
            }
            Ok(())
        };
        if let Err(error) = persist() {
            let _ = manager.disable(&inspection.manifest.id);
            let _ = self.synchronize_plugins();
            return Err(error);
        }
        self.synchronize_plugins()?;
        Ok(inspection)
    }

    pub fn inspect_plugin_for_management(self: &Rc<Self>, package: &Path) {
        use crate::ai::plugins::editor_plugin_management_state::{
            EditorPluginInspectionSummary, EditorPluginManagementPhase,
        };

        self.plugin_session.state().pending_approval = None;
        self.publish_plugin_management(EditorPluginManagementPhase::Inspecting, None, None);
        let inspect = || -> Result<PluginInspection, PluginLifecycleError> {
            let inspection = self.inspect_plugin(package)?;
            let manager = &self.plugin_session.manager;
            if !manager
                .enabled_manifests()
                .contains_key(&inspection.manifest.id)
                && manager.install(package)? != inspection
            {
                return Err(
                    diffuse_plugin::plugin_authorization::PluginAuthorizationError::NoLongerValid
                        .into(),
                );
            }
            Ok(inspection)
        };
        match inspect() {
            Ok(inspection) => {
                let reusable = self.stored_plugin_authorization(&inspection).is_some();
                let candidate =
                    EditorPluginInspectionSummary::with_default_lifecycle(&inspection, reusable);
                self.plugin_session.state().pending_approval =
                    Some(super::plugin_session::PendingPluginApproval {
                        package_url: cove_system::paths::PathIdentity::canonical_url(package),
                        inspection,
                    });
                self.publish_plugin_management(
                    EditorPluginManagementPhase::AwaitingAuthorization,
                    Some(candidate),
                    None,
                );
            }
            Err(error) => self.publish_plugin_management(
                EditorPluginManagementPhase::Failed,
                None,
                Some(error.to_string()),
            ),
        }
    }

    pub(super) fn publish_plugin_management(
        &self,
        phase: crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementPhase,
        candidate: Option<
            crate::ai::plugins::editor_plugin_management_state::EditorPluginInspectionSummary,
        >,
        message: Option<String>,
    ) {
        use crate::ai::plugins::editor_plugin_management_state::{
            EditorPluginInspectionSummary, EditorPluginLifecycle, EditorPluginManagementState,
        };
        use crate::state::editor_reducer::EditorAction;

        let installed = self
            .plugin_session
            .manager
            .statuses()
            .into_iter()
            .map(|status| {
                let reusable = self
                    .stored_plugin_authorization(&status.inspection)
                    .is_some();
                EditorPluginInspectionSummary::new(
                    &status.inspection,
                    reusable,
                    EditorPluginLifecycle::new(status.phase, status.is_enabled, status.failure),
                )
            })
            .collect();
        let next = EditorPluginManagementState::new(phase, candidate, installed, message);
        if self.store.plugin_management() != next {
            self.store
                .dispatch(EditorAction::SetPluginManagementState(next));
            self.request_display_refresh();
        }
    }
}
