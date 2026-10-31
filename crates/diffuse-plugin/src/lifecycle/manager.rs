//! The sole owner of package state, activation and contribution release.
//!
//! Ported from `Engine/Sources/PluginRuntime/Lifecycle/Manager.swift`.
//!
//! Swift serialised every operation on `@MainActor` with an awaited task tail, so
//! callers never had to arrange lifecycle ordering. Without an async runtime
//! (MIGRATION.md §5.5) the ordering lives in one `Mutex` over the entry table: an
//! operation takes the lock, mutates, and releases it, which gives the same
//! serialisation. Long-running driver work happens outside the lock, with the
//! generation check Swift used to detect a concurrent stop.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Mutex;

use diffuse_capability::capability_contract::CapabilityContract;
use diffuse_capability::support::disposal::DisposalScope;

use crate::PluginError;
use crate::contract::activation::PluginActivationEvent;
use crate::contract::plugin_manifest::CovePluginManifest;
use crate::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use crate::contract::requirements::{
    PluginRequirementResolver, RequiredPluginStillNeeded, UnmetPluginRequirements,
};
use crate::contribution::registrar::ContributionRegistrar;
use crate::lifecycle::status::{
    PluginManagerError, PluginPhase, PluginRuntimeActivation, PluginRuntimeDriver, PluginStatus,
};
use crate::plugin_authorization::{
    PluginAuthorizationError, PluginAuthorizationRecord, PluginContractDeriver,
    PluginExecutionBinding, PluginInspection,
};

pub struct Entry {
    pub package: ValidatedPluginPackage,
    pub inspection: PluginInspection,
    pub authorization: Option<PluginAuthorizationRecord>,
    pub scope: Option<DisposalScope>,
    pub binding: Option<PluginExecutionBinding>,
    pub failure: Option<String>,
}

impl Entry {
    pub fn new(package: ValidatedPluginPackage) -> Self {
        let inspection =
            PluginInspection::from_package(&package, PluginContractDeriver::contracts(&package));
        Entry {
            package,
            inspection,
            authorization: None,
            scope: None,
            binding: None,
            failure: None,
        }
    }
}

pub(crate) struct ManagerState {
    pub(crate) entries: BTreeMap<String, Entry>,
    pub(crate) epoch: u64,
    pub(crate) stopped: bool,
    pub(crate) pending_count: usize,
    pub(crate) events: BTreeSet<String>,
    driver: Option<std::sync::Arc<PluginRuntimeDriver>>,
}

pub struct PluginManager {
    state: Mutex<ManagerState>,
    registrar: ContributionRegistrar,
    loader: PluginPackageLoader,
    host_capabilities: BTreeMap<String, i64>,
}

impl PluginManager {
    pub fn new(
        registrar: ContributionRegistrar,
        loader: PluginPackageLoader,
        host_capabilities: BTreeMap<String, i64>,
    ) -> Self {
        PluginManager {
            state: Mutex::new(ManagerState {
                entries: BTreeMap::new(),
                epoch: 0,
                stopped: false,
                pending_count: 0,
                events: BTreeSet::new(),
                driver: None,
            }),
            registrar,
            loader,
            host_capabilities,
        }
    }

    pub fn new_with_loader(registrar: ContributionRegistrar, loader: PluginPackageLoader) -> Self {
        Self::new(registrar, loader, BTreeMap::new())
    }

    pub fn configure_runtime(&self, driver: PluginRuntimeDriver) {
        self.lock_state().driver = Some(std::sync::Arc::new(driver));
    }

    pub fn is_busy(&self) -> bool {
        self.lock_state().pending_count > 0
    }

    pub fn statuses(&self) -> Vec<PluginStatus> {
        let state = self.lock_state();
        state
            .entries
            .values()
            .map(|entry| {
                let phase = if entry.failure.is_some() {
                    PluginPhase::Failed
                } else if entry.binding.is_some() {
                    PluginPhase::Activated
                } else if entry.scope.is_some() {
                    PluginPhase::Enabled
                } else {
                    PluginPhase::Installed
                };
                PluginStatus {
                    inspection: entry.inspection.clone(),
                    phase,
                    is_enabled: entry.scope.is_some(),
                    failure: entry.failure.clone(),
                }
            })
            .collect()
    }

    pub fn enabled_inspections(&self) -> Vec<PluginInspection> {
        self.statuses()
            .into_iter()
            .filter(|status| status.is_enabled)
            .map(|status| status.inspection)
            .collect()
    }

    pub fn enabled_manifests(&self) -> BTreeMap<String, CovePluginManifest> {
        self.enabled_inspections()
            .into_iter()
            .map(|inspection| (inspection.manifest.id.clone(), inspection.manifest))
            .collect()
    }

    pub fn active_bindings(&self) -> BTreeMap<String, PluginExecutionBinding> {
        self.lock_state()
            .entries
            .iter()
            .filter_map(|(id, entry)| entry.binding.clone().map(|binding| (id.clone(), binding)))
            .collect()
    }

    pub fn package_urls(&self) -> BTreeMap<String, PathBuf> {
        self.lock_state()
            .entries
            .iter()
            .map(|(id, entry)| (id.clone(), entry.package.root_url.clone()))
            .collect()
    }

    pub fn install(&self, url: &std::path::Path) -> Result<PluginInspection, PluginError> {
        self.begin()?;
        let result = (|| {
            let package = self.loader.load(url)?;
            let id = package.manifest.id.clone();
            let mut state = self.lock_state();
            if state.stopped {
                return Err(PluginManagerError::Stopped.into());
            }
            if state
                .entries
                .get(&id)
                .is_some_and(|entry| entry.scope.is_some())
            {
                return Err(PluginManagerError::AlreadyEnabled(id).into());
            }
            let entry = Entry::new(package);
            let inspection = entry.inspection.clone();
            state.entries.insert(id, entry);
            Ok(inspection)
        })();
        self.finish();
        result
    }

    pub fn enable(
        &self,
        url: &std::path::Path,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<PluginInspection, PluginError> {
        self.begin()?;
        let result = self.enable_inner(url, authorization);
        self.finish();
        result
    }

    fn enable_inner(
        &self,
        url: &std::path::Path,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<PluginInspection, PluginError> {
        let package = self.loader.load(url)?;
        let id = package.manifest.id.clone();
        let entry = Entry::new(package);
        if !authorization.is_still_valid(&entry.inspection) {
            return Err(PluginAuthorizationError::NoLongerValid.into());
        }
        {
            let state = self.lock_state();
            if state
                .entries
                .get(&id)
                .is_some_and(|entry| entry.scope.is_some())
            {
                return Err(PluginManagerError::AlreadyEnabled(id).into());
            }
        }
        let unmet = PluginRequirementResolver::unmet(
            &entry.package.manifest.requires,
            &id,
            &self
                .enabled_manifests()
                .iter()
                .map(|(id, manifest)| (id.clone(), manifest.version))
                .collect(),
            &self.available_capabilities(),
        );
        if !unmet.is_empty() {
            return Err(UnmetPluginRequirements::new(id, unmet).into());
        }
        {
            let mut state = self.lock_state();
            let mut entry = entry;
            entry.authorization = Some(authorization.clone());
            state.entries.insert(id.clone(), entry);
        }
        // Read the package first: a temporary guard in the match scrutinee would
        // live until the end of the whole statement and deadlock in the `Err`
        // arm, which locks again.
        let package = {
            let state = self.lock_state();
            state
                .entries
                .get(&id)
                .map(|entry| entry.package.clone())
                .expect("entry inserted above")
        };
        let scope = match self.registrar.install(&package) {
            Ok(scope) => scope,
            Err(error) => {
                if let Some(entry) = self.lock_state().entries.get_mut(&id) {
                    entry.failure = Some(error.to_string());
                }
                return Err(error);
            }
        };
        let accepted = {
            let mut state = self.lock_state();
            if state.stopped {
                false
            } else {
                if let Some(entry) = state.entries.get_mut(&id) {
                    entry.scope = Some(scope);
                }
                true
            }
        };
        if !accepted {
            // The scope was moved into the entry; withdrawing releases it.
            let _ = self.withdraw(std::slice::from_ref(&id), None);
            return Err(PluginManagerError::Stopped.into());
        }
        let seen = self.lock_state().events.clone();
        let activation_events = self.activation_events(&id);
        if activation_events
            .iter()
            .any(|event| seen.iter().any(|seen| Self::matches(event, seen)))
            && let Err(error) = self.activate_entry(&id, &BTreeSet::new())
        {
            if let Some(entry) = self.lock_state().entries.get_mut(&id) {
                entry.failure = Some(error.to_string());
            }
            return Err(error);
        }
        Ok(self.inspection_of(&id).unwrap_or_else(|| {
            Entry::new(
                self.lock_state()
                    .entries
                    .get(&id)
                    .map(|entry| entry.package.clone())
                    .expect("entry present"),
            )
            .inspection
        }))
    }

    pub fn disable(&self, id: &str) -> Result<(), PluginError> {
        self.begin()?;
        let result = (|| {
            if !self.enabled_manifests().contains_key(id) {
                return Err(PluginManagerError::NotEnabled(id.to_string()).into());
            }
            self.withdraw(&self.dependent_closure(id), None)
        })();
        self.finish();
        result
    }

    pub fn uninstall(&self, id: &str) -> Result<(), PluginError> {
        self.begin()?;
        let result = (|| {
            if !self.lock_state().entries.contains_key(id) {
                return Err(PluginManagerError::NotInstalled(id.to_string()).into());
            }
            let dependents = self.dependents_of(id);
            if !dependents.is_empty() {
                return Err(RequiredPluginStillNeeded::new(id.to_string(), dependents).into());
            }
            self.withdraw(&[id.to_string()], None)?;
            self.lock_state().entries.remove(id);
            Ok(())
        })();
        self.finish();
        result
    }

    pub fn reload(&self, id: &str) -> Result<(), PluginError> {
        self.begin()?;
        let result = self.reload_inner(id);
        self.finish();
        result
    }

    fn reload_inner(&self, id: &str) -> Result<(), PluginError> {
        let (previous_root, authorization, was_active) = {
            let state = self.lock_state();
            let Some(previous) = state.entries.get(id) else {
                return Err(PluginManagerError::NotEnabled(id.to_string()).into());
            };
            let Some(authorization) = previous.authorization.clone() else {
                return Err(PluginManagerError::NotEnabled(id.to_string()).into());
            };
            if previous.scope.is_none() {
                return Err(PluginManagerError::NotEnabled(id.to_string()).into());
            }
            (
                previous.package.root_url.clone(),
                authorization,
                previous.binding.is_some(),
            )
        };
        let next = Entry::new(self.loader.load(&previous_root)?);
        if !authorization.is_still_valid(&next.inspection) {
            return Err(PluginAuthorizationError::NoLongerValid.into());
        }
        let outcome = (|| -> Result<(), PluginError> {
            self.withdraw(&[id.to_string()], None)?;
            let scope = self.registrar.install(&next.package)?;
            let accepted = {
                let mut state = self.lock_state();
                if state.stopped {
                    false
                } else {
                    let mut next = next;
                    next.authorization = Some(authorization);
                    next.scope = Some(scope);
                    let rebinding = next.binding.is_some();
                    let _ = rebinding;
                    state.entries.insert(id.to_string(), next);
                    true
                }
            };
            if !accepted {
                self.withdraw(&[id.to_string()], None)?;
                return Err(PluginManagerError::Stopped.into());
            }
            if was_active {
                self.activate_entry(id, &BTreeSet::new())?;
            }
            Ok(())
        })();
        if let Err(error) = &outcome {
            let affected = self.dependent_closure(id);
            let _ = self.withdraw(&affected, Some(error.to_string()));
        }
        outcome
    }

    pub fn activate_event(&self, event: &str) -> Result<(), PluginError> {
        if !PluginActivationEvent::is_valid(event) {
            return Err(crate::contract::plugin_manifest::PluginManifestValidationError::InvalidContribution(
                "activation".to_string(),
            )
            .into());
        }
        self.begin()?;
        let result = {
            self.lock_state().events.insert(event.to_string());
            let ids: Vec<String> = {
                let state = self.lock_state();
                state
                    .entries
                    .iter()
                    .filter(|(_, entry)| entry.scope.is_some() && entry.package.runtime.is_some())
                    .filter(|(id, _)| {
                        let _ = id;
                        true
                    })
                    .map(|(id, _)| id.clone())
                    .collect()
            };
            let ids: Vec<String> = ids
                .into_iter()
                .filter(|id| {
                    self.activation_events(id)
                        .iter()
                        .any(|declaration| Self::matches(declaration, event))
                })
                .collect();
            let mut first_error: Option<PluginError> = None;
            for id in ids {
                if let Err(error) = self.activate_entry(&id, &BTreeSet::new())
                    && first_error.is_none()
                {
                    first_error = Some(error);
                }
            }
            match first_error {
                Some(error) => Err(error),
                None => Ok(()),
            }
        };
        self.finish();
        result
    }

    pub fn activate(&self, id: &str) -> Result<PluginExecutionBinding, PluginError> {
        self.begin()?;
        let result = (|| {
            self.activate_entry(id, &BTreeSet::new())?;
            self.active_bindings().get(id).cloned().ok_or_else(|| {
                PluginError::from(
                    crate::contract::plugin_package::PluginPackageError::RuntimeRequired,
                )
            })
        })();
        self.finish();
        result
    }

    /// `invalidateRuntime(before:)`: releases every binding older than
    /// `generation`, plus its dependents.
    pub fn invalidate_runtime(&self, before: Option<u64>) -> Result<bool, PluginError> {
        let mut affected: BTreeSet<String> = BTreeSet::new();
        for (id, binding) in self.active_bindings() {
            if before.is_none_or(|generation| binding.host_generation < generation) {
                affected.extend(self.dependent_closure(&id));
            }
        }
        let mut affected: Vec<String> = affected.into_iter().collect();
        affected.sort();
        let _ = self.withdraw(&affected, Some("Plugin host invalidated".to_string()));
        Ok(!affected.is_empty())
    }

    pub fn stop(&self) {
        let (scopes, driver) = {
            let mut state = self.lock_state();
            if state.stopped {
                return;
            }
            state.stopped = true;
            state.epoch = state.epoch.wrapping_add(1);
            let manifests: BTreeMap<String, CovePluginManifest> = state
                .entries
                .iter()
                .map(|(id, entry)| (id.clone(), entry.package.manifest.clone()))
                .collect();
            let mut seen: BTreeSet<String> = BTreeSet::new();
            let mut ordered: Vec<String> = Vec::new();
            // Post-order: dependents before the plugin they require.
            for id in state.entries.keys().cloned().collect::<Vec<_>>() {
                Self::visit_for_stop(&id, &manifests, &mut seen, &mut ordered);
            }
            let scopes: Vec<DisposalScope> = ordered
                .iter()
                .filter_map(|id| {
                    state
                        .entries
                        .get_mut(id)
                        .and_then(|entry| entry.scope.take())
                })
                .collect();
            let driver = state.driver.take();
            state.entries.clear();
            (scopes, driver)
        };
        for scope in scopes {
            scope.dispose_all();
        }
        if let Some(driver) = driver {
            (driver.stop)();
        }
    }

    fn visit_for_stop(
        id: &str,
        manifests: &BTreeMap<String, CovePluginManifest>,
        seen: &mut BTreeSet<String>,
        ordered: &mut Vec<String>,
    ) {
        if !seen.insert(id.to_string()) {
            return;
        }
        let capabilities: BTreeSet<String> = BTreeSet::new();
        for dependent in PluginRequirementResolver::dependents(id, &capabilities, manifests) {
            Self::visit_for_stop(&dependent, manifests, seen, ordered);
        }
        ordered.push(id.to_string());
    }

    fn begin(&self) -> Result<(), PluginError> {
        self.lock_state().pending_count += 1;
        if self.lock_state().stopped {
            return Err(PluginManagerError::Stopped.into());
        }
        Ok(())
    }

    fn finish(&self) {
        let mut state = self.lock_state();
        if state.pending_count > 0 {
            state.pending_count -= 1;
        }
    }

    pub(crate) fn lock_state(&self) -> std::sync::MutexGuard<'_, ManagerState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    pub(crate) fn lock_entries(&self) -> std::sync::MutexGuard<'_, ManagerState> {
        self.lock_state()
    }

    pub(crate) fn driver(&self) -> Option<std::sync::Arc<PluginRuntimeDriver>> {
        self.lock_state().driver.clone()
    }

    pub(crate) fn current_epoch(&self) -> u64 {
        self.lock_state().epoch
    }

    pub(crate) fn inspection_of(&self, id: &str) -> Option<PluginInspection> {
        self.lock_state()
            .entries
            .get(id)
            .map(|entry| entry.inspection.clone())
    }

    pub(crate) fn entry_package(&self, id: &str) -> Option<ValidatedPluginPackage> {
        self.lock_state()
            .entries
            .get(id)
            .map(|entry| entry.package.clone())
    }

    pub(crate) fn contracts_of(&self, id: &str) -> Vec<CapabilityContract> {
        self.lock_state()
            .entries
            .get(id)
            .map(|entry| entry.inspection.contracts.clone())
            .unwrap_or_default()
    }
}

impl PluginManager {
    /// `activateEntry`: activates requirements first, then the plugin itself.
    pub(crate) fn activate_entry(
        &self,
        id: &str,
        visiting: &BTreeSet<String>,
    ) -> Result<(), PluginError> {
        let (enabled, has_runtime, has_binding, package, authorization) = {
            let state = self.lock_state();
            let Some(entry) = state.entries.get(id) else {
                return Err(PluginManagerError::NotEnabled(id.to_string()).into());
            };
            (
                entry.scope.is_some(),
                entry.package.runtime.is_some(),
                entry.binding.is_some(),
                entry.package.clone(),
                entry.authorization.clone(),
            )
        };
        if !enabled {
            return Err(PluginManagerError::NotEnabled(id.to_string()).into());
        }
        if has_binding || !has_runtime {
            return Ok(());
        }
        if visiting.contains(id) {
            return Err(PluginManagerError::ActivationCycle(id.to_string()).into());
        }
        let mut visited = visiting.clone();
        visited.insert(id.to_string());
        let outcome = (|| -> Result<(), PluginError> {
            let Some(authorization) = authorization else {
                return Err(PluginManagerError::RuntimeUnavailable.into());
            };
            let Some(driver) = self.driver_for_activation() else {
                return Err(PluginManagerError::RuntimeUnavailable.into());
            };
            for requirement in &package.manifest.requires {
                let provider: Option<String> = match requirement.kind {
                    crate::contract::requirements::PluginRequirementKind::Plugin => {
                        Some(requirement.id.clone())
                    }
                    crate::contract::requirements::PluginRequirementKind::Capability => self
                        .enabled_inspections()
                        .into_iter()
                        .find(|inspection| {
                            inspection
                                .contracts
                                .iter()
                                .any(|contract| contract.id == requirement.id)
                        })
                        .map(|inspection| inspection.manifest.id),
                };
                if let Some(provider) = provider {
                    self.activate_entry(&provider, &visited)?;
                }
            }
            let generation = self.current_epoch();
            let activated = (driver.activate)(package.root_url.clone(), authorization)?;
            let accepted = {
                let entry_inspection = self.inspection_of(id);
                let mut state = self.lock_state();
                let ok = entry_inspection.as_ref() == Some(&activated.binding.inspection)
                    && !state.stopped
                    && state.epoch == generation
                    && state.entries.contains_key(id);
                if ok && let Some(entry) = state.entries.get_mut(id) {
                    entry.binding = Some(activated.binding.clone());
                    entry.failure = None;
                }
                ok
            };
            if !accepted {
                if let Some(registration) = &activated.registration {
                    registration.dispose();
                }
                if let Some(driver) = self.driver_for_deactivation() {
                    let _ = (driver.deactivate)(&activated.binding);
                }
                return Err(PluginAuthorizationError::NoLongerValid.into());
            }
            if let Some(registration) = activated.registration {
                let mut state = self.lock_state();
                if let Some(scope) = state
                    .entries
                    .get_mut(id)
                    .and_then(|entry| entry.scope.as_ref())
                {
                    scope.track_registration(registration);
                }
            }
            Ok(())
        })();
        if let Err(error) = &outcome {
            // A failed activation must not leave its declarations usable while
            // dependent packages assume its runtime is available.
            let affected = self.dependent_closure(id);
            let _ = self.withdraw(&affected, Some(error.to_string()));
        }
        outcome
    }

    fn driver_for_activation(&self) -> Option<std::sync::Arc<PluginRuntimeDriver>> {
        self.driver()
    }

    fn driver_for_deactivation(&self) -> Option<std::sync::Arc<PluginRuntimeDriver>> {
        self.driver()
    }
}

impl PluginRuntimeActivation {
    pub fn binding(&self) -> &PluginExecutionBinding {
        &self.binding
    }
}

/// Swift's `activationEvents(for:)`.
impl PluginManager {
    pub(crate) fn activation_events(&self, id: &str) -> BTreeSet<String> {
        let Some(package) = self.entry_package(id) else {
            return BTreeSet::new();
        };
        let manifest = &package.manifest;
        let mut result: BTreeSet<String> = manifest.activation.iter().cloned().collect();
        for service in crate::contract::entry_points::decode_or_default::<
            crate::contribution::services::PluginServiceContributionPoint,
        >(manifest)
        {
            result.insert(format!("onService:{}", service.id));
        }
        for language in crate::contract::entry_points::decode_or_default::<
            crate::contribution::languages::language_point::LanguageContributionPoint,
        >(manifest)
        {
            if language.server.is_some() || language.format.is_some() {
                result.insert(format!("onLanguage:{}", language.id));
            }
        }
        for provider in crate::contract::entry_points::decode_or_default::<
            crate::contribution::ai::provider_point::AIProviderContributionPoint,
        >(manifest)
        {
            result.insert(format!("onAIProvider:{}", provider.id));
        }
        for task in crate::contract::entry_points::decode_or_default::<
            crate::contribution::processes::process_points::TaskContributionPoint,
        >(manifest)
        {
            result.insert(format!("onCommand:{}", task.id));
        }
        for vcs in crate::contract::entry_points::decode_or_default::<
            crate::contribution::processes::process_points::VersionControlContributionPoint,
        >(manifest)
        {
            result.insert(format!("onCommand:{}", vcs.id));
        }
        for command in crate::contract::entry_points::decode_or_default::<
            crate::contribution::workbench::command::CommandContributionPoint,
        >(manifest)
        {
            result.insert(format!("onCommand:{}", command.id));
        }
        for panel in crate::contract::entry_points::decode_or_default::<
            crate::contribution::workbench::panel::PanelContributionPoint,
        >(manifest)
        {
            if panel.entry_point.is_some() {
                result.insert(format!("onView:{}", panel.id));
            }
        }
        for view in crate::contract::entry_points::decode_or_default::<
            crate::contribution::workbench::document::DocumentViewContributionPoint,
        >(manifest)
        {
            result.insert(format!("onView:{}", view.id));
        }
        // Harnesses and context sources serve chat turns.
        let harnesses = crate::contract::entry_points::decode_or_default::<
            crate::contribution::ai::harness::AIHarnessContributionPoint,
        >(manifest);
        let contexts = crate::contract::entry_points::decode_or_default::<
            crate::contribution::ai::context::AIContextContributionPoint,
        >(manifest);
        if !harnesses.is_empty() || !contexts.is_empty() {
            result.insert("onAIChat".to_string());
        }
        for contract in self.contracts_of(id) {
            let name = contract
                .id
                .chars()
                .skip(manifest.id.chars().count() + 1)
                .collect::<String>();
            if name == "components" {
                result.insert("onStartup".to_string());
            }
            if manifest.exposes_to_ai(&name) {
                result.insert("onAIChat".to_string());
                result.insert(format!("onAITool:{}", contract.id));
            }
        }
        result
    }

    /// `matches(declaration:event:)`: exact equality, except `onWorkspaceContains:`
    /// which matches the event's path against the declaration's glob.
    pub(crate) fn matches(declaration: &str, event: &str) -> bool {
        let prefix = "onWorkspaceContains:";
        if !(declaration.starts_with(prefix) && event.starts_with(prefix)) {
            return declaration == event;
        }
        let pattern = &declaration[prefix.len()..];
        let path = &event[prefix.len()..];
        crate::pattern::glob_matches(pattern, path)
    }

    pub(crate) fn available_capabilities(&self) -> BTreeMap<String, i64> {
        let mut values = self.host_capabilities.clone();
        for inspection in self.enabled_inspections() {
            for contract in inspection.contracts {
                values.insert(contract.id, contract.version);
            }
        }
        values
    }
}
