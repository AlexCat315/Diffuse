//! `CapabilityRegistry` — immutable registry with alias lookup and fail-closed
//! model exposure.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use thiserror::Error;

use crate::built_in_capability_catalog::BuiltInCapabilityCatalog;
use crate::capability_contract::{
    CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot, CapabilitySourceKind,
    PluginCapabilityAuthority, ReleasePhase,
};
use crate::capability_descriptor::{
    CapabilityDescriptor, CapabilityPreconditionSpec, PreconditionKind,
};
use crate::release::release_phase_gate::ReleasePhaseGate;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum CapabilityRegistryIntegrityError {
    #[error("duplicate capability {0} v{1}")]
    DuplicateCapability(String, i64),
    #[error("capability alias collision: {0}")]
    AliasCollision(String),
    #[error("provider tool-name collision: {0}")]
    ToolNameCollision(String),
}

/// Immutable registry of all capabilities known to the system.
#[derive(Clone, Debug)]
pub struct CapabilityRegistry {
    // Primary verb to descriptor.
    by_verb: BTreeMap<String, CapabilityDescriptor>,
    // Alias to primary verb.
    alias_by_verb: BTreeMap<String, String>,
    pub integrity_errors: Vec<CapabilityRegistryIntegrityError>,
}

impl CapabilityRegistry {
    pub fn new(capabilities: Vec<CapabilityDescriptor>) -> Self {
        let mut by_verb: BTreeMap<String, CapabilityDescriptor> = BTreeMap::new();
        let mut alias_by_verb: BTreeMap<String, String> = BTreeMap::new();
        let mut integrity_errors: Vec<CapabilityRegistryIntegrityError> = Vec::new();

        for capability in capabilities {
            if let Some(existing) = by_verb.get(&capability.verb) {
                integrity_errors.push(CapabilityRegistryIntegrityError::DuplicateCapability(
                    capability.verb.clone(),
                    existing.version,
                ));
                continue;
            }
            if alias_by_verb.contains_key(&capability.verb) {
                integrity_errors.push(CapabilityRegistryIntegrityError::AliasCollision(
                    capability.verb.clone(),
                ));
                continue;
            }
            by_verb.insert(capability.verb.clone(), capability.clone());
            for alias in &capability.aliases {
                if by_verb.contains_key(alias) || alias_by_verb.contains_key(alias) {
                    integrity_errors.push(CapabilityRegistryIntegrityError::AliasCollision(
                        alias.clone(),
                    ));
                    continue;
                }
                alias_by_verb.insert(alias.clone(), capability.verb.clone());
            }
        }

        let mut tool_groups: HashMap<String, Vec<&CapabilityDescriptor>> = HashMap::new();
        for descriptor in by_verb.values() {
            tool_groups
                .entry(descriptor.contract().tool_name())
                .or_default()
                .push(descriptor);
        }
        let mut collision_names: Vec<String> = tool_groups
            .into_iter()
            .filter(|(_, descriptors)| descriptors.len() > 1)
            .map(|(name, _)| name)
            .collect();
        collision_names.sort();
        for name in collision_names {
            integrity_errors.push(CapabilityRegistryIntegrityError::ToolNameCollision(name));
        }

        CapabilityRegistry {
            by_verb,
            alias_by_verb,
            integrity_errors,
        }
    }

    /// Returns the descriptor for `verb`, resolving aliases.
    pub fn descriptor(&self, verb: &str) -> Option<CapabilityDescriptor> {
        if let Some(capability) = self.by_verb.get(verb) {
            return Some(capability.clone());
        }
        self.alias_by_verb
            .get(verb)
            .and_then(|primary| self.by_verb.get(primary))
            .cloned()
    }

    /// All registered primary verbs, sorted.
    pub fn all_verbs(&self) -> Vec<String> {
        self.by_verb.keys().cloned().collect()
    }

    /// All provider-neutral contracts, sorted by capability id.
    pub fn all_contracts(&self) -> Vec<CapabilityContract> {
        let mut contracts: Vec<CapabilityContract> = self
            .by_verb
            .values()
            .map(CapabilityDescriptor::contract)
            .collect();
        contracts.sort_by(|left, right| left.id.cmp(&right.id));
        contracts
    }

    pub fn validate_integrity(&self) -> Result<(), CapabilityRegistryIntegrityError> {
        match self.integrity_errors.first() {
            Some(error) => Err(error.clone()),
            None => Ok(()),
        }
    }

    /// Builds a fail-closed model exposure allow-list. Plugin capabilities are
    /// absent until their plugin id is explicitly enabled, and external effects
    /// are absent unless the caller opts in.
    pub fn exposure_snapshot(
        &self,
        policy: &CapabilityExposurePolicy,
        scene_revision: Option<u64>,
        generation: u64,
        preferred_capability_ids: &[String],
        included_capability_ids: Option<&BTreeSet<String>>,
        plugin_authorities: &BTreeMap<String, PluginCapabilityAuthority>,
    ) -> CapabilityExposureSnapshot {
        if !self.integrity_errors.is_empty() {
            return CapabilityExposureSnapshot::new(
                crate::capability_contract::new_uuid(),
                generation,
                scene_revision,
                Vec::new(),
                crate::support::swift_date::SwiftDate::now(),
                BTreeMap::new(),
            );
        }

        let gate = ReleasePhaseGate::new(policy.active_release_phase);
        let mut allowed: Vec<&CapabilityDescriptor> = self
            .by_verb
            .values()
            .filter(|descriptor| {
                if !descriptor.is_ai_exposed {
                    return false;
                }
                if descriptor.access.is_write()
                    && !descriptor.input_schema.is_strict_capability_input()
                {
                    return false;
                }
                if let Some(included) = included_capability_ids
                    && !included.contains(&descriptor.verb)
                {
                    return false;
                }
                if let Some(ids) = &policy.allowed_capability_ids
                    && !ids.contains(&descriptor.verb)
                {
                    return false;
                }
                if !gate.is_allowed(descriptor) {
                    return false;
                }
                if let Some(domains) = &policy.allowed_domains
                    && !domains.contains(&descriptor.domain)
                {
                    return false;
                }
                if descriptor.access
                    == crate::capability_contract::CapabilityAccess::ExternalSideEffect
                    && !policy.allow_external_side_effects
                {
                    return false;
                }
                if descriptor.source.kind == CapabilitySourceKind::Plugin {
                    let Some(plugin_id) = &descriptor.source.plugin_id else {
                        return false;
                    };
                    if !policy.enabled_plugin_ids.contains(plugin_id) {
                        return false;
                    }
                    if plugin_authorities
                        .get(plugin_id)
                        .map(|authority| &authority.plugin_id)
                        != Some(plugin_id)
                    {
                        return false;
                    }
                }
                true
            })
            .collect();

        let mut preferred_order: BTreeMap<String, usize> = BTreeMap::new();
        for (offset, capability_id) in preferred_capability_ids.iter().enumerate() {
            preferred_order
                .entry(capability_id.clone())
                .or_insert(offset);
        }

        allowed.sort_by(|left, right| {
            match (
                preferred_order.get(&left.verb),
                preferred_order.get(&right.verb),
            ) {
                (Some(left_order), Some(right_order)) => left_order.cmp(right_order),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => left.verb.cmp(&right.verb),
            }
        });
        let contracts: Vec<CapabilityContract> = allowed
            .iter()
            .take(policy.maximum_capabilities)
            .map(|descriptor| descriptor.contract())
            .collect();
        let exposed_plugin_ids: BTreeSet<String> = contracts
            .iter()
            .filter_map(|contract| contract.source.plugin_id.clone())
            .collect();
        let exposed_authorities: BTreeMap<String, PluginCapabilityAuthority> = plugin_authorities
            .iter()
            .filter(|(plugin_id, _)| exposed_plugin_ids.contains(*plugin_id))
            .map(|(plugin_id, authority)| (plugin_id.clone(), authority.clone()))
            .collect();

        CapabilityExposureSnapshot::new(
            crate::capability_contract::new_uuid(),
            generation,
            scene_revision,
            contracts,
            crate::support::swift_date::SwiftDate::now(),
            exposed_authorities,
        )
    }

    /// Searches only capabilities permitted by `policy`.
    pub fn search_contracts(
        &self,
        query: &str,
        policy: &CapabilityExposurePolicy,
        plugin_authorities: &BTreeMap<String, PluginCapabilityAuthority>,
        limit: usize,
    ) -> Vec<CapabilityContract> {
        let needle = query.trim().to_lowercase();
        let mut search_policy = policy.clone();
        search_policy.maximum_capabilities = limit.max(self.all_verbs().len());
        let snapshot =
            self.exposure_snapshot(&search_policy, None, 0, &[], None, plugin_authorities);

        snapshot
            .contracts
            .into_iter()
            .filter(|contract| {
                needle.is_empty()
                    || contract.id.to_lowercase().contains(&needle)
                    || contract.title.to_lowercase().contains(&needle)
                    || contract.description.to_lowercase().contains(&needle)
            })
            .take(limit)
            .collect()
    }

    /// Returns a new registry with `other`'s capabilities merged in; `other`
    /// overrides same-verb entries.
    pub fn merging(&self, other: &CapabilityRegistry) -> CapabilityRegistry {
        let mut merged: BTreeMap<String, CapabilityDescriptor> = self.by_verb.clone();
        for (verb, descriptor) in &other.by_verb {
            merged.insert(verb.clone(), descriptor.clone());
        }
        let mut descriptors: Vec<CapabilityDescriptor> = merged.into_values().collect();
        descriptors.sort_by(|left, right| left.verb.cmp(&right.verb));
        CapabilityRegistry::new(descriptors)
    }

    /// Adds descriptors without allowing the new set to override existing
    /// registrations. A collision is retained as an integrity error.
    pub fn appending(&self, descriptors: &[CapabilityDescriptor]) -> CapabilityRegistry {
        let mut all: Vec<CapabilityDescriptor> = self.by_verb.values().cloned().collect();
        all.extend(descriptors.iter().cloned());
        CapabilityRegistry::new(all)
    }

    /// Replaces only generated contract fields while retaining host-owned aliases
    /// and runtime preconditions. Unknown ids are ignored.
    pub fn replacing_contracts(&self, contracts: &[CapabilityContract]) -> CapabilityRegistry {
        let mut merged: BTreeMap<String, CapabilityDescriptor> = self.by_verb.clone();
        for contract in contracts {
            let Some(existing) = merged.get(&contract.id) else {
                continue;
            };
            if existing.version != contract.version {
                continue;
            }
            let mut descriptor = existing.clone();
            descriptor.title = contract.title.clone();
            descriptor.capability_description = contract.description.clone();
            descriptor.domain = contract.domain.clone();
            descriptor.access = contract.access;
            descriptor.release_phase = contract.release_phase;
            descriptor.input_schema = contract.input_schema.clone();
            descriptor.source = contract.source.clone();
            descriptor.requires_confirmation = contract.access.is_write();
            descriptor.is_destructive =
                contract.access == crate::capability_contract::CapabilityAccess::DestructiveWrite;
            descriptor.is_ai_exposed = true;
            merged.insert(contract.id.clone(), descriptor);
        }
        let mut descriptors: Vec<CapabilityDescriptor> = merged.into_values().collect();
        descriptors.sort_by(|left, right| left.verb.cmp(&right.verb));
        CapabilityRegistry::new(descriptors)
    }

    /// Built-in registry covering all verbs in the AI edit plan pipeline and the
    /// UI intent path.
    pub fn default_registry() -> CapabilityRegistry {
        let editable = CapabilityPreconditionSpec::SCENE_EDITABLE;
        let entity_exists = CapabilityPreconditionSpec::ENTITY_EXISTS;
        let constraint = CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "PhysicsJoint",
        );
        let light = CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "LightComponent",
        );
        let camera = CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "CameraComponent",
        );
        let render_mesh = CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "RenderMeshComponent",
        );

        let mut descriptors: Vec<CapabilityDescriptor> = Vec::new();

        let read_only = |verb: &str, domain: &str| {
            let mut descriptor = CapabilityDescriptor::new(verb);
            descriptor.domain = domain.to_string();
            descriptor.access = crate::capability_contract::CapabilityAccess::Read;
            descriptor
        };

        let write_with =
            |verb: &str, domain: &str, preconditions: Vec<CapabilityPreconditionSpec>| {
                let mut descriptor = CapabilityDescriptor::new(verb);
                descriptor.domain = domain.to_string();
                descriptor.preconditions = preconditions;
                descriptor.requires_confirmation = false;
                descriptor.is_destructive = false;
                descriptor.access = crate::capability_contract::CapabilityAccess::ReversibleWrite;
                descriptor
            };

        // AI framework
        descriptors.push(read_only("system.search_capabilities", "system"));
        descriptors.push(read_only("system.submit_plan", "system"));

        // Read-only AI context
        descriptors.push(read_only("scene.describe_components", "scene"));
        descriptors.push(read_only("scene.get_entities", "scene"));
        descriptors.push(read_only("scene.get_selection", "scene"));
        descriptors.push(read_only("scene.find_entities", "scene"));

        // Spawn / create
        let mut spawn = write_with("scene.spawn_entity", "scene", vec![editable.clone()]);
        spawn.aliases = vec!["scene.create_instance".to_string()];
        descriptors.push(spawn);

        // Rename
        let mut set_name = write_with(
            "scene.set_name",
            "scene",
            vec![
                editable.clone(),
                entity_exists.clone(),
                CapabilityPreconditionSpec::argument(PreconditionKind::ArgumentPresent, "name"),
            ],
        );
        descriptors.push(set_name.clone());
        set_name.aliases.clear();

        // Duplicate
        descriptors.push(write_with(
            "scene.duplicate_entity",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));

        // Reparent
        let mut reparent = write_with(
            "scene.reparent_entity",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        );
        reparent.aliases = vec!["scene.move_entity".to_string()];
        descriptors.push(reparent);

        // Delete
        let mut delete = write_with(
            "scene.delete_entity",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        );
        delete.aliases = vec!["scene.delete_instance".to_string()];
        delete.requires_confirmation = true;
        delete.is_destructive = true;
        delete.access = crate::capability_contract::CapabilityAccess::DestructiveWrite;
        descriptors.push(delete);

        // Transform
        let mut transform = write_with(
            "scene.set_transform",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        );
        transform.aliases = vec!["scene.set_local_transform".to_string()];
        descriptors.push(transform);

        // Snap to ground
        descriptors.push(write_with(
            "scene.snap_to_ground",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));

        // Camera
        for verb in [
            "scene.set_camera_pose",
            "scene.set_camera_fov",
            "scene.set_camera_aspect_ratio",
            "scene.set_camera_active",
        ] {
            descriptors.push(write_with(
                verb,
                "scene",
                vec![editable.clone(), entity_exists.clone(), camera.clone()],
            ));
        }

        // Rigid body (beta: physics authoring not yet fully exposed in Editor)
        let beta = |verb: &str| {
            let mut descriptor =
                write_with(verb, "scene", vec![editable.clone(), entity_exists.clone()]);
            descriptor.release_phase = ReleasePhase::Beta;
            descriptor
        };
        descriptors.push(beta("scene.set_rigid_body_motion_type"));
        descriptors.push(beta("scene.set_rigid_body_mass"));
        let mut gravity = beta("scene.set_rigid_body_gravity_scale");
        gravity.aliases = vec![
            "scene.set_rigidbody_gravity_scale".to_string(),
            "scene.set_rigidbody_gravity".to_string(),
        ];
        descriptors.push(gravity);
        let mut allow_sleep = beta("scene.set_rigid_body_allow_sleep");
        allow_sleep.aliases = vec!["scene.set_rigidbody_allow_sleep".to_string()];
        descriptors.push(allow_sleep);

        // Collider
        descriptors.push(beta("scene.set_collider"));
        descriptors.push(beta("scene.set_collider_trigger"));
        let mut shape = beta("scene.set_collider_shape");
        shape.aliases = vec!["scene.set_collider_shape_type".to_string()];
        descriptors.push(shape);
        descriptors.push(beta("scene.set_collider_box_extents"));
        descriptors.push(beta("scene.set_collider_sphere_radius"));
        let mut capsule = beta("scene.set_collider_capsule");
        capsule.aliases = vec![
            "scene.set_collider_capsule_radius".to_string(),
            "scene.set_collider_capsule_half_height".to_string(),
        ];
        descriptors.push(capsule);
        let mut material = beta("scene.set_collider_material");
        material.aliases = vec![
            "scene.set_collider_friction".to_string(),
            "scene.set_collider_restitution".to_string(),
            "scene.set_collider_density".to_string(),
        ];
        descriptors.push(material);
        let mut layer = beta("scene.set_collider_layer");
        layer.aliases = vec!["scene.set_collider_layer_mask".to_string()];
        descriptors.push(layer);
        descriptors.push(write_with(
            "scene.set_constraint_enabled",
            "scene",
            vec![editable.clone(), entity_exists.clone(), constraint.clone()],
        ));
        // The beta helper set `.beta` on collider verbs; restore it for the
        // constraint verb which Swift registered as beta too.
        if let Some(last) = descriptors.last_mut() {
            last.release_phase = ReleasePhase::Beta;
        }

        // Light
        for verb in [
            "scene.set_light_type",
            "scene.set_light_color",
            "scene.set_light_intensity",
            "scene.set_light_range",
            "scene.set_light_spot_inner_angle",
            "scene.set_light_spot_angles",
            "scene.set_light_spot_outer_angle",
            "scene.set_light_cast_shadows",
        ] {
            descriptors.push(write_with(
                verb,
                "scene",
                vec![editable.clone(), entity_exists.clone(), light.clone()],
            ));
        }

        // Render/script/audio
        descriptors.push(write_with(
            "scene.set_mesh_color",
            "scene",
            vec![editable.clone(), entity_exists.clone(), render_mesh.clone()],
        ));
        descriptors.push(write_with(
            "scene.set_material",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));
        let mut script_bindings = write_with(
            "scene.set_script_bindings",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        );
        script_bindings.aliases = vec![
            "scene.set_script_enabled".to_string(),
            "scene.set_script_parameters".to_string(),
        ];
        descriptors.push(script_bindings);
        descriptors.push(write_with(
            "scene.set_script_property",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));
        descriptors.push(write_with(
            "scene.set_audio_source",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));

        // Mesh visibility
        descriptors.push(write_with(
            "scene.set_mesh_visibility",
            "scene",
            vec![editable.clone(), entity_exists.clone(), render_mesh.clone()],
        ));

        // Animation
        descriptors.push(write_with(
            "scene.set_animation_player",
            "scene",
            vec![editable.clone(), entity_exists.clone()],
        ));

        // Sequence
        let mut replace_document = CapabilityDescriptor::new("sequence.replace_document");
        replace_document.domain = "sequence".to_string();
        replace_document.release_phase = ReleasePhase::Beta;
        replace_document.requires_confirmation = true;
        replace_document.is_destructive = true;
        replace_document.access = crate::capability_contract::CapabilityAccess::DestructiveWrite;
        descriptors.push(replace_document);

        // Asset
        let mut scan = CapabilityDescriptor::new("asset.scan_project");
        scan.domain = "asset".to_string();
        scan.preconditions = vec![CapabilityPreconditionSpec::argument(
            PreconditionKind::ArgumentPresent,
            "root_path",
        )];
        descriptors.push(scan);

        let enriched: Vec<CapabilityDescriptor> = descriptors
            .into_iter()
            .map(|descriptor| BuiltInCapabilityCatalog::enrich(&descriptor))
            .collect();
        CapabilityRegistry::new(enriched)
    }
}

impl Default for CapabilityRegistry {
    fn default() -> Self {
        Self::default_registry()
    }
}
