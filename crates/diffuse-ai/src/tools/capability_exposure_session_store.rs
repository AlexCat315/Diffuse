//! Ported from `Engine/Sources/AIRuntime/Tools/CapabilityExposureSessionStore.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};

use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot,
    PluginCapabilityAuthority, ReleasePhase,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::support::swift_date::SwiftDate;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::uuid::Uuid;

use crate::planning::capability_draft_pipeline::{
    CapabilityDraftError, CapabilityDraftStore, CapabilityInvocationDraft,
};
use crate::tools::tool_policy::{ToolCall, ToolCallOrigin, ToolPolicy, ToolPolicyError};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CapabilityExposureSessionError {
    InvalidSessionID,
    SessionNotFound,
    ReadCapabilityRequiresHostAdapter(String),
}

impl std::fmt::Display for CapabilityExposureSessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CapabilityExposureSessionError::InvalidSessionID => {
                formatter.write_str("capability session id must be a UUID")
            }
            CapabilityExposureSessionError::SessionNotFound => {
                formatter.write_str("capability exposure session was not found or expired")
            }
            CapabilityExposureSessionError::ReadCapabilityRequiresHostAdapter(id) => {
                write!(
                    formatter,
                    "read capability '{id}' must be executed by a host adapter"
                )
            }
        }
    }
}

impl std::error::Error for CapabilityExposureSessionError {}

/// Swift's methods threw either their own error or `CapabilityDraftError`;
/// Rust callers need one type for `?`.
#[derive(Clone, Debug, PartialEq)]
pub enum CapabilityExposureSessionStoreError {
    Session(CapabilityExposureSessionError),
    Draft(CapabilityDraftError),
    ToolPolicy(ToolPolicyError),
}

impl std::fmt::Display for CapabilityExposureSessionStoreError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CapabilityExposureSessionStoreError::Session(error) => error.fmt(formatter),
            CapabilityExposureSessionStoreError::Draft(error) => error.fmt(formatter),
            CapabilityExposureSessionStoreError::ToolPolicy(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for CapabilityExposureSessionStoreError {}

impl From<CapabilityExposureSessionError> for CapabilityExposureSessionStoreError {
    fn from(error: CapabilityExposureSessionError) -> Self {
        CapabilityExposureSessionStoreError::Session(error)
    }
}

impl From<CapabilityDraftError> for CapabilityExposureSessionStoreError {
    fn from(error: CapabilityDraftError) -> Self {
        CapabilityExposureSessionStoreError::Draft(error)
    }
}

impl From<ToolPolicyError> for CapabilityExposureSessionStoreError {
    fn from(error: ToolPolicyError) -> Self {
        CapabilityExposureSessionStoreError::ToolPolicy(error)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilitySearchActivation {
    pub snapshot_id: String,
    /// Contracts matching the current search (or core reads at bootstrap).
    pub contracts: Vec<CapabilityContract>,
    /// Complete current allow-list, used by transports to refresh tools after
    /// a scene-revision reset without retaining stale tool definitions.
    pub active_contracts: Vec<CapabilityContract>,
    pub active_tool_count: usize,
}

impl CapabilitySearchActivation {
    pub fn new(
        snapshot_id: String,
        contracts: Vec<CapabilityContract>,
        active_contracts: Option<Vec<CapabilityContract>>,
        active_tool_count: usize,
    ) -> Self {
        Self {
            snapshot_id,
            active_contracts: active_contracts.unwrap_or_else(|| contracts.clone()),
            contracts,
            active_tool_count,
        }
    }
}

struct Entry {
    snapshot: CapabilityExposureSnapshot,
    drafts: Arc<CapabilityDraftStore>,
    last_accessed_at: SwiftDate,
}

impl Drop for Entry {
    fn drop(&mut self) {
        self.drafts.remove_all();
    }
}

struct StoreState {
    registry: CapabilityRegistry,
    exposure_policy: CapabilityExposurePolicy,
    plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
    workflow_document_id: Option<Uuid>,
    generation: u64,
    sessions: BTreeMap<String, Entry>,
}

/// Transport-neutral session state used by MCP and other local model clients.
/// It owns the host-side tool-name allow-list and Draft store; clients receive
/// generated tool definitions but never authority-bearing registry objects.
pub struct CapabilityExposureSessionStore {
    ttl: f64,
    /// Host tool policy evaluated before a draft is created; `None` is a
    /// pass-through.
    tool_policy: Option<ToolPolicy>,
    state: Mutex<StoreState>,
}

impl CapabilityExposureSessionStore {
    pub const MAXIMUM_SESSIONS: usize = 8;
    pub const MAXIMUM_ACTIVE_CAPABILITIES: usize = 16;

    /// Swift default: `CapabilityRegistry.aiDefault`, the default Draft TTL,
    /// `allowedDomains: ["scene"]`, no plugin authorities, no tool policy.
    pub fn new() -> Self {
        Self::with_configuration(
            BuiltInTypedCapabilityCatalog::registry(),
            CapabilityDraftStore::DEFAULT_TTL,
            default_exposure_policy(),
            BTreeMap::new(),
            None,
        )
    }

    pub fn with_configuration(
        registry: CapabilityRegistry,
        ttl: f64,
        exposure_policy: CapabilityExposurePolicy,
        plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
        tool_policy: Option<ToolPolicy>,
    ) -> Self {
        Self {
            ttl: ttl.max(1.0),
            tool_policy,
            state: Mutex::new(StoreState {
                registry,
                exposure_policy,
                plugin_authorities,
                workflow_document_id: None,
                generation: 0,
                sessions: BTreeMap::new(),
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, StoreState> {
        match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Atomically replaces the Registry and its matching exposure authority.
    /// Invalidation is scoped: sessions whose snapshots reference only
    /// unchanged, still-enabled plugins survive; a policy change outside
    /// plugin scoping, or a changed/removed plugin authority, drops the
    /// affected sessions and their Drafts first, so tools from a disabled or
    /// upgraded plugin cannot survive a dynamic catalog change.
    pub fn replace_registry(
        &self,
        registry: CapabilityRegistry,
        exposure_policy: CapabilityExposurePolicy,
        plugin_authorities: BTreeMap<String, PluginCapabilityAuthority>,
    ) {
        let mut state = self.lock();
        let previous_authorities = std::mem::take(&mut state.plugin_authorities);
        let previous_policy = state.exposure_policy.clone();
        state.registry = registry;
        state.exposure_policy = exposure_policy;
        state.plugin_authorities = plugin_authorities;
        state.generation = state.generation.wrapping_add(1);
        discard_invalidated_sessions(&mut state, &previous_authorities, &previous_policy);
    }

    /// A workflow or document change invalidates tools and drafts minted under
    /// the previous authoring context, including equal-revision scene swaps.
    pub fn set_workflow_scope(&self, policy: &CapabilityExposurePolicy, document_id: &Uuid) {
        let mut state = self.lock();
        if state.exposure_policy == *policy
            && state.workflow_document_id.as_ref() == Some(document_id)
        {
            return;
        }
        state.sessions.clear();
        state.exposure_policy = policy.clone();
        state.workflow_document_id = Some(document_id.clone());
        state.generation = state.generation.wrapping_add(1);
    }

    /// Plugin enablement, authorisation, upgrades, and PluginHost restarts all
    /// replace the authority set. Sessions that reference a changed, newly
    /// disabled, or removed plugin are discarded because their tool names and
    /// Drafts were minted under a different executable boundary; sessions that
    /// reference only unchanged plugins survive.
    pub fn replace_plugin_authorities(
        &self,
        authorities: BTreeMap<String, PluginCapabilityAuthority>,
        enabled_plugin_ids: &BTreeSet<String>,
    ) {
        let mut state = self.lock();
        let previous_authorities = std::mem::take(&mut state.plugin_authorities);
        let previous_policy = state.exposure_policy.clone();
        state.plugin_authorities = authorities;
        state.exposure_policy.enabled_plugin_ids = enabled_plugin_ids.clone();
        state.generation = state.generation.wrapping_add(1);
        discard_invalidated_sessions(&mut state, &previous_authorities, &previous_policy);
    }

    /// Swift's `now: Date = Date()` default.
    pub fn bootstrap_with_defaults(
        &self,
        session_id: &str,
        scene_revision: u64,
    ) -> Result<CapabilitySearchActivation, CapabilityExposureSessionStoreError> {
        self.bootstrap(session_id, scene_revision, SwiftDate::now())
    }

    /// Opens (or resumes) a session with only the small host-approved read set.
    /// This is used before a model has searched for any write capability.
    pub fn bootstrap(
        &self,
        session_id: &str,
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilitySearchActivation, CapabilityExposureSessionStoreError> {
        let id = validated_session_id(session_id)?;
        let mut state = self.lock();
        purge_expired(&mut state, self.ttl, now);
        let snapshot = session_entry(&mut state, &id, scene_revision, now, self.ttl);
        if let Some(entry) = state.sessions.get_mut(id.as_str()) {
            entry.last_accessed_at = now;
        }
        let active_tool_count = snapshot.contracts.len();
        Ok(CapabilitySearchActivation::new(
            snapshot.id.clone(),
            snapshot.contracts.clone(),
            Some(snapshot.contracts),
            active_tool_count,
        ))
    }

    pub fn search_with_defaults(
        &self,
        session_id: &str,
        query: &str,
        scene_revision: u64,
    ) -> Result<CapabilitySearchActivation, CapabilityExposureSessionStoreError> {
        self.search(
            session_id,
            query,
            None,
            None,
            scene_revision,
            SwiftDate::now(),
        )
    }

    pub fn search(
        &self,
        session_id: &str,
        query: &str,
        domain: Option<&str>,
        access: Option<CapabilityAccess>,
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilitySearchActivation, CapabilityExposureSessionStoreError> {
        let id = validated_session_id(session_id)?;
        let mut state = self.lock();
        purge_expired(&mut state, self.ttl, now);
        session_entry(&mut state, &id, scene_revision, now, self.ttl);

        let mut search_policy = state.exposure_policy.clone();
        search_policy.active_release_phase = ReleasePhase::Stable;
        search_policy.allowed_domains = match domain {
            Some(requested) => {
                let requested_set: BTreeSet<String> =
                    std::iter::once(requested.to_string()).collect();
                Some(match &state.exposure_policy.allowed_domains {
                    Some(existing) => existing.intersection(&requested_set).cloned().collect(),
                    None => requested_set,
                })
            }
            None => state.exposure_policy.allowed_domains.clone(),
        };
        let verb_count = state.registry.all_verbs().len();
        search_policy.maximum_capabilities = Self::MAXIMUM_ACTIVE_CAPABILITIES.max(verb_count);

        let candidates: Vec<CapabilityContract> = state
            .registry
            .search_contracts(query, &search_policy, &state.plugin_authorities, verb_count)
            .into_iter()
            .filter(|contract| !contract.id.starts_with("system."))
            .filter(|contract| access.is_none_or(|wanted| contract.access == wanted))
            .collect();

        let existing_ids: Vec<String> = state
            .sessions
            .get(id.as_str())
            .map(|entry| {
                entry
                    .snapshot
                    .contracts
                    .iter()
                    .map(|contract| contract.id.clone())
                    .collect()
            })
            .unwrap_or_default();
        let existing_set: BTreeSet<String> = existing_ids.iter().cloned().collect();
        let available = Self::MAXIMUM_ACTIVE_CAPABILITIES.saturating_sub(existing_ids.len());
        let additions: Vec<&CapabilityContract> = candidates
            .iter()
            .filter(|contract| !existing_set.contains(&contract.id))
            .take(available)
            .collect();
        let mut preferred_ids = existing_ids;
        preferred_ids.extend(additions.iter().map(|contract| contract.id.clone()));
        let included_ids: BTreeSet<String> = preferred_ids.iter().cloned().collect();

        state.generation = state.generation.wrapping_add(1);
        let generation = state.generation;
        let mut active_policy = state.exposure_policy.clone();
        active_policy.active_release_phase = ReleasePhase::Stable;
        active_policy.maximum_capabilities = Self::MAXIMUM_ACTIVE_CAPABILITIES;
        let mut expanded = state.registry.exposure_snapshot(
            &active_policy,
            Some(scene_revision),
            generation,
            &preferred_ids,
            Some(&included_ids),
            &state.plugin_authorities,
        );
        // Expanding an allow-list must not invalidate Drafts already created in
        // the same session. Revision changes create a fresh Entry above.
        let snapshot = match state.sessions.get_mut(id.as_str()) {
            Some(entry) => {
                expanded.id = entry.snapshot.id.clone();
                expanded.created_at = entry.snapshot.created_at;
                entry.snapshot = expanded;
                entry.last_accessed_at = now;
                entry.snapshot.clone()
            }
            None => return Err(CapabilityExposureSessionError::SessionNotFound.into()),
        };

        let activated: Vec<CapabilityContract> = candidates
            .into_iter()
            .filter(|contract| snapshot.contract(&contract.id).is_some())
            .collect();
        Ok(CapabilitySearchActivation::new(
            snapshot.id.clone(),
            activated,
            Some(snapshot.contracts.clone()),
            snapshot.contracts.len(),
        ))
    }

    pub fn contract_with_defaults(
        &self,
        session_id: &str,
        tool_name: &str,
        scene_revision: u64,
    ) -> Result<CapabilityContract, CapabilityExposureSessionStoreError> {
        self.contract(session_id, tool_name, scene_revision, SwiftDate::now())
    }

    pub fn contract(
        &self,
        session_id: &str,
        tool_name: &str,
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilityContract, CapabilityExposureSessionStoreError> {
        let mut state = self.lock();
        let entry = active_entry(&mut state, session_id, scene_revision, now, self.ttl)?;
        entry
            .snapshot
            .contract_for_tool_name(tool_name)
            .cloned()
            .ok_or_else(|| CapabilityDraftError::UnknownTool(tool_name.to_string()).into())
    }

    pub fn snapshot_with_defaults(
        &self,
        session_id: &str,
        scene_revision: u64,
    ) -> Result<CapabilityExposureSnapshot, CapabilityExposureSessionStoreError> {
        self.snapshot(session_id, scene_revision, SwiftDate::now())
    }

    pub fn snapshot(
        &self,
        session_id: &str,
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilityExposureSnapshot, CapabilityExposureSessionStoreError> {
        let mut state = self.lock();
        Ok(
            active_entry(&mut state, session_id, scene_revision, now, self.ttl)?
                .snapshot
                .clone(),
        )
    }

    pub fn create_draft_with_defaults(
        &self,
        session_id: &str,
        tool_name: &str,
        input: &[u8],
        scene_revision: u64,
    ) -> Result<CapabilityInvocationDraft, CapabilityExposureSessionStoreError> {
        self.create_draft(
            session_id,
            tool_name,
            input,
            scene_revision,
            SwiftDate::now(),
        )
    }

    pub fn create_draft(
        &self,
        session_id: &str,
        tool_name: &str,
        input: &[u8],
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<CapabilityInvocationDraft, CapabilityExposureSessionStoreError> {
        let id = validated_session_id(session_id)?;
        let mut state = self.lock();
        let entry = active_entry(&mut state, session_id, scene_revision, now, self.ttl)?;
        let contract = entry
            .snapshot
            .contract_for_tool_name(tool_name)
            .ok_or_else(|| CapabilityDraftError::UnknownTool(tool_name.to_string()))?;
        if !contract.access.is_write() {
            return Err(
                CapabilityExposureSessionError::ReadCapabilityRequiresHostAdapter(
                    contract.id.clone(),
                )
                .into(),
            );
        }
        let validated_input: Data = match &self.tool_policy {
            Some(policy) => {
                policy
                    .evaluate(ToolCall::new(
                        tool_name,
                        Data::from_bytes(input.to_vec()),
                        ToolCallOrigin::Mcp,
                    ))?
                    .arguments
            }
            None => Data::from_bytes(input.to_vec()),
        };
        let snapshot = entry.snapshot.clone();
        let drafts = entry.drafts.clone();
        // Swift passed the store's current registry into the Draft store call,
        // not the registry captured when the entry was minted.
        let draft = drafts.create_draft_with_registry(
            tool_name,
            validated_input.as_slice(),
            &snapshot,
            scene_revision,
            now,
            &state.registry,
        )?;
        require_current_entry(&state, &id, &snapshot)?;
        if let Some(current) = state.sessions.get_mut(id.as_str()) {
            current.last_accessed_at = now;
        }
        Ok(draft)
    }

    pub fn validated_drafts_with_defaults(
        &self,
        session_id: &str,
        ids: &[String],
        scene_revision: u64,
    ) -> Result<
        (Vec<CapabilityInvocationDraft>, CapabilityExposureSnapshot),
        CapabilityExposureSessionStoreError,
    > {
        self.validated_drafts(session_id, ids, scene_revision, SwiftDate::now())
    }

    pub fn validated_drafts(
        &self,
        session_id: &str,
        ids: &[String],
        scene_revision: u64,
        now: SwiftDate,
    ) -> Result<
        (Vec<CapabilityInvocationDraft>, CapabilityExposureSnapshot),
        CapabilityExposureSessionStoreError,
    > {
        let id = validated_session_id(session_id)?;
        let mut state = self.lock();
        let entry = active_entry(&mut state, session_id, scene_revision, now, self.ttl)?;
        let snapshot = entry.snapshot.clone();
        let drafts = entry.drafts.clone();
        let validated = drafts.validated_drafts_with_registry(
            ids,
            &snapshot,
            scene_revision,
            now,
            &state.registry,
        )?;
        require_current_entry(&state, &id, &snapshot)?;
        if let Some(current) = state.sessions.get_mut(id.as_str()) {
            current.last_accessed_at = now;
        }
        Ok((validated, snapshot))
    }

    pub fn consume(
        &self,
        session_id: &str,
        ids: &[String],
    ) -> Result<(), CapabilityExposureSessionStoreError> {
        let id = validated_session_id(session_id)?;
        let state = self.lock();
        let entry = state
            .sessions
            .get(id.as_str())
            .ok_or(CapabilityExposureSessionError::SessionNotFound)?;
        entry.drafts.consume(ids);
        Ok(())
    }

    pub fn remove_session(
        &self,
        session_id: &str,
    ) -> Result<(), CapabilityExposureSessionStoreError> {
        let id = validated_session_id(session_id)?;
        let mut state = self.lock();
        state.sessions.remove(id.as_str());
        Ok(())
    }
}

impl Default for CapabilityExposureSessionStore {
    fn default() -> Self {
        Self::new()
    }
}

fn default_exposure_policy() -> CapabilityExposurePolicy {
    CapabilityExposurePolicy {
        allowed_domains: Some(std::iter::once("scene".to_string()).collect()),
        ..CapabilityExposurePolicy::default()
    }
}

fn validated_session_id(value: &str) -> Result<Uuid, CapabilityExposureSessionError> {
    Uuid::parse(value).ok_or(CapabilityExposureSessionError::InvalidSessionID)
}

fn active_entry<'a>(
    state: &'a mut StoreState,
    session_id: &str,
    scene_revision: u64,
    now: SwiftDate,
    ttl: f64,
) -> Result<&'a Entry, CapabilityExposureSessionStoreError> {
    let id = validated_session_id(session_id)?;
    purge_expired(state, ttl, now);
    let registry = &state.registry;
    let policy = &state.exposure_policy;
    let authorities = &state.plugin_authorities;
    let keep = state.sessions.get(id.as_str()).is_some_and(|entry| {
        entry.snapshot.scene_revision == Some(scene_revision)
            && snapshot_authorities_are_current(&entry.snapshot, registry, policy, authorities)
            && (now.0 - entry.snapshot.created_at.0) >= 0.0
            && (now.0 - entry.snapshot.created_at.0) <= ttl
    });
    if !keep {
        state.sessions.remove(id.as_str());
        return Err(CapabilityExposureSessionError::SessionNotFound.into());
    }
    Ok(state
        .sessions
        .get(id.as_str())
        .expect("entry was just checked"))
}

fn session_entry(
    state: &mut StoreState,
    id: &Uuid,
    scene_revision: u64,
    now: SwiftDate,
    ttl: f64,
) -> CapabilityExposureSnapshot {
    let key = id.as_str().to_string();
    if let Some(entry) = state.sessions.get(&key)
        && entry.snapshot.scene_revision == Some(scene_revision)
        && (now.0 - entry.snapshot.created_at.0) >= 0.0
        && (now.0 - entry.snapshot.created_at.0) <= ttl
    {
        return entry.snapshot.clone();
    }
    // Everything up to the install is synchronous, so a concurrent create
    // either sees the previous entry or the fresh one — never a half state.
    state.sessions.remove(&key);
    if state.sessions.len() >= CapabilityExposureSessionStore::MAXIMUM_SESSIONS {
        let oldest = state
            .sessions
            .iter()
            .min_by(|left, right| {
                left.1
                    .last_accessed_at
                    .0
                    .total_cmp(&right.1.last_accessed_at.0)
            })
            .map(|(session_id, _)| session_id.clone());
        if let Some(oldest) = oldest {
            state.sessions.remove(&oldest);
        }
    }
    state.generation = state.generation.wrapping_add(1);
    let generation = state.generation;
    let core_read_ids: BTreeSet<String> = [
        "scene.get_entities",
        "scene.get_selection",
        "scene.find_entities",
    ]
    .into_iter()
    .map(str::to_string)
    .collect();
    let mut initial_policy = state.exposure_policy.clone();
    initial_policy.maximum_capabilities =
        CapabilityExposureSessionStore::MAXIMUM_ACTIVE_CAPABILITIES;
    let preferred: Vec<String> = core_read_ids.iter().cloned().collect();
    let snapshot = state.registry.exposure_snapshot(
        &initial_policy,
        Some(scene_revision),
        generation,
        &preferred,
        Some(&core_read_ids),
        &state.plugin_authorities,
    );
    let drafts = Arc::new(CapabilityDraftStore::with_ttl(state.registry.clone(), ttl));
    state.sessions.insert(
        key,
        Entry {
            snapshot: snapshot.clone(),
            drafts,
            last_accessed_at: now,
        },
    );
    snapshot
}

/// A draft creation or teardown can invalidate/replace the entry. Never return
/// authority or reinstall state from that old lifetime.
fn require_current_entry(
    state: &StoreState,
    id: &Uuid,
    snapshot: &CapabilityExposureSnapshot,
) -> Result<(), CapabilityExposureSessionStoreError> {
    let registry = &state.registry;
    let policy = &state.exposure_policy;
    let authorities = &state.plugin_authorities;
    let current = state.sessions.get(id.as_str());
    if current.is_some_and(|entry| {
        entry.snapshot.id == snapshot.id
            && snapshot_authorities_are_current(&entry.snapshot, registry, policy, authorities)
    }) {
        Ok(())
    } else {
        Err(CapabilityExposureSessionError::SessionNotFound.into())
    }
}

fn purge_expired(state: &mut StoreState, ttl: f64, now: SwiftDate) {
    state.sessions.retain(|_, entry| {
        let age = now.0 - entry.snapshot.created_at.0;
        age >= 0.0 && age <= ttl
    });
}

/// Drops sessions whose referenced plugins changed authority, were disabled, or
/// whose exposure policy changed outside plugin scoping. Built-in-only sessions
/// survive a plugin catalog change, and a session referencing a plugin whose
/// authority is byte-identical survives a reload of that plugin.
fn discard_invalidated_sessions(
    state: &mut StoreState,
    previous_authorities: &BTreeMap<String, PluginCapabilityAuthority>,
    previous_policy: &CapabilityExposurePolicy,
) {
    let policy_changed =
        scoped_identity(&state.exposure_policy) != scoped_identity(previous_policy);
    let registry = &state.registry;
    let policy = &state.exposure_policy;
    let authorities = &state.plugin_authorities;
    state.sessions.retain(|_, entry| {
        if policy_changed {
            return false;
        }
        let referenced_plugin_ids: BTreeSet<String> = entry
            .snapshot
            .contracts
            .iter()
            .filter_map(|contract| contract.source.plugin_id.clone())
            .collect();
        let plugins_current = referenced_plugin_ids.into_iter().all(|plugin_id| {
            policy.enabled_plugin_ids.contains(&plugin_id)
                && authorities.get(&plugin_id) == previous_authorities.get(&plugin_id)
        });
        plugins_current && snapshot_contracts_are_current(&entry.snapshot, registry)
    });
}

fn snapshot_authorities_are_current(
    snapshot: &CapabilityExposureSnapshot,
    registry: &CapabilityRegistry,
    exposure_policy: &CapabilityExposurePolicy,
    plugin_authorities: &BTreeMap<String, PluginCapabilityAuthority>,
) -> bool {
    if !snapshot_contracts_are_current(snapshot, registry) {
        return false;
    }
    let plugin_ids: BTreeSet<String> = snapshot
        .contracts
        .iter()
        .filter_map(|contract| contract.source.plugin_id.clone())
        .collect();
    plugin_ids.into_iter().all(|plugin_id| {
        snapshot.authority(&plugin_id) == plugin_authorities.get(&plugin_id)
            && exposure_policy.enabled_plugin_ids.contains(&plugin_id)
    })
}

fn snapshot_contracts_are_current(
    snapshot: &CapabilityExposureSnapshot,
    registry: &CapabilityRegistry,
) -> bool {
    snapshot.contracts.iter().all(|contract| {
        registry
            .descriptor(&contract.id)
            .map(|descriptor| descriptor.contract())
            .as_ref()
            == Some(contract)
    })
}

/// Policy identity excluding the enabled plugin set, which is compared per
/// referenced plugin through the plugin authority records instead.
fn scoped_identity(policy: &CapabilityExposurePolicy) -> CapabilityExposurePolicy {
    let mut copy = policy.clone();
    copy.enabled_plugin_ids = BTreeSet::new();
    copy
}
