//! `CapabilityDescriptor` — static description of one registered capability.

use serde::{Deserialize, Serialize};

use crate::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilitySource, ReleasePhase,
};
use crate::capsule_schema::JsonSchema;

/// A single precondition that must hold before a capability may be invoked.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityPreconditionSpec {
    pub kind: PreconditionKind,
    /// For `ArgumentPresent`: the argument key that must exist.
    pub argument_name: Option<String>,
    /// For `EntityHasComponent`: the component type name (e.g. `"RigidBody"`).
    pub component_type: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PreconditionKind {
    /// At least one target entity must exist in the live scene.
    #[serde(rename = "entity_exists")]
    EntityExists,
    /// At least one entity must be selected or listed as a target.
    #[serde(rename = "selection_required")]
    SelectionRequired,
    /// A named argument must be present in the IntentIR argument map.
    #[serde(rename = "argument_present")]
    ArgumentPresent,
    /// The scene must be in an editable state.
    #[serde(rename = "scene_editable")]
    SceneEditable,
    /// The target entity must carry a specific component.
    #[serde(rename = "entity_has_component")]
    EntityHasComponent,
}

impl CapabilityPreconditionSpec {
    /// Swift defaults: both optional payloads nil.
    #[inline]
    pub fn new(kind: PreconditionKind) -> Self {
        CapabilityPreconditionSpec {
            kind,
            argument_name: None,
            component_type: None,
        }
    }

    #[inline]
    pub fn argument(kind: PreconditionKind, argument_name: impl Into<String>) -> Self {
        CapabilityPreconditionSpec {
            kind,
            argument_name: Some(argument_name.into()),
            component_type: None,
        }
    }

    #[inline]
    pub fn component(kind: PreconditionKind, component_type: impl Into<String>) -> Self {
        CapabilityPreconditionSpec {
            kind,
            argument_name: None,
            component_type: Some(component_type.into()),
        }
    }

    pub const ENTITY_EXISTS: CapabilityPreconditionSpec = CapabilityPreconditionSpec {
        kind: PreconditionKind::EntityExists,
        argument_name: None,
        component_type: None,
    };

    pub const SELECTION_REQUIRED: CapabilityPreconditionSpec = CapabilityPreconditionSpec {
        kind: PreconditionKind::SelectionRequired,
        argument_name: None,
        component_type: None,
    };

    pub const SCENE_EDITABLE: CapabilityPreconditionSpec = CapabilityPreconditionSpec {
        kind: PreconditionKind::SceneEditable,
        argument_name: None,
        component_type: None,
    };
}

/// Static description of one capability registered in the system.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityDescriptor {
    /// The intent verb this descriptor covers (e.g. `"scene.spawn_entity"`).
    pub verb: String,
    pub aliases: Vec<String>,
    pub release_phase: ReleasePhase,
    pub requires_confirmation: bool,
    pub is_destructive: bool,
    pub domain: String,
    pub preconditions: Vec<CapabilityPreconditionSpec>,
    pub version: i64,
    pub title: String,
    pub capability_description: String,
    pub access: CapabilityAccess,
    pub input_schema: JsonSchema,
    pub source: CapabilitySource,
    pub is_ai_exposed: bool,
}

impl CapabilityDescriptor {
    /// Swift's default-argument initializer, including its derived defaults:
    /// `title` falls back to the verb, an empty description falls back to the
    /// verb, and `access` falls back to destructive/reversible based on
    /// `is_destructive`.
    pub fn new(verb: impl Into<String>) -> Self {
        let verb = verb.into();
        CapabilityDescriptor {
            title: verb.clone(),
            capability_description: verb.clone(),
            access: CapabilityAccess::ReversibleWrite,
            input_schema: crate::capsule_schema::empty_object(),
            source: CapabilitySource::BUILTIN,
            verb,
            aliases: Vec::new(),
            release_phase: ReleasePhase::Stable,
            requires_confirmation: false,
            is_destructive: false,
            domain: "scene".to_string(),
            preconditions: Vec::new(),
            version: 1,
            is_ai_exposed: false,
        }
    }

    /// Applies Swift's derived defaults after the caller has set the raw fields.
    pub fn with_description(mut self, description: impl Into<String>) -> Self {
        let description = description.into();
        if self.title.is_empty() {
            self.title = self.verb.clone();
        }
        self.capability_description = if description.is_empty() {
            self.verb.clone()
        } else {
            description
        };
        self
    }

    /// Derives `access` the way Swift's initializer does when it is not given.
    pub fn with_derived_access(mut self) -> Self {
        self.access = if self.is_destructive {
            CapabilityAccess::DestructiveWrite
        } else {
            CapabilityAccess::ReversibleWrite
        };
        self
    }

    pub fn contract(&self) -> CapabilityContract {
        CapabilityContract::new(
            self.verb.clone(),
            self.version,
            self.title.clone(),
            self.capability_description.clone(),
            self.domain.clone(),
            self.access,
            self.release_phase,
            self.input_schema.clone(),
            self.source.clone(),
            None,
        )
    }

    /// Argument names required by `.argument_present` preconditions.
    pub fn required_argument_names(&self) -> std::collections::BTreeSet<String> {
        self.preconditions
            .iter()
            .filter(|spec| spec.kind == PreconditionKind::ArgumentPresent)
            .filter_map(|spec| spec.argument_name.clone())
            .collect()
    }

    /// Component types required by `.entity_has_component` preconditions.
    pub fn required_component_types(&self) -> std::collections::BTreeSet<String> {
        self.preconditions
            .iter()
            .filter(|spec| spec.kind == PreconditionKind::EntityHasComponent)
            .filter_map(|spec| spec.component_type.clone())
            .collect()
    }

    pub fn requires_target_entity(&self) -> bool {
        self.preconditions.iter().any(|spec| {
            matches!(
                spec.kind,
                PreconditionKind::EntityExists
                    | PreconditionKind::SelectionRequired
                    | PreconditionKind::EntityHasComponent
            )
        })
    }
}
