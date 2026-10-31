//! `PreconditionCheckInput`, `PreconditionViolation` and `PreconditionChecker`.

use crate::capability_descriptor::{CapabilityPreconditionSpec, PreconditionKind};

/// Snapshot of the runtime state needed to evaluate capability preconditions.
#[derive(Clone, Debug, PartialEq)]
pub struct PreconditionCheckInput {
    pub verb: String,
    pub argument_names: std::collections::BTreeSet<String>,
    pub target_entity_ids: Vec<u64>,
    pub selected_entity_id: Option<u64>,
    pub scene_entity_ids: std::collections::BTreeSet<u64>,
    pub component_types_by_entity_id:
        std::collections::BTreeMap<u64, std::collections::BTreeSet<String>>,
    pub is_scene_editable: bool,
}

impl PreconditionCheckInput {
    /// Swift defaults: empty collections, no selection, scene editable.
    #[inline]
    pub fn new(verb: impl Into<String>) -> Self {
        PreconditionCheckInput {
            verb: verb.into(),
            argument_names: std::collections::BTreeSet::new(),
            target_entity_ids: Vec::new(),
            selected_entity_id: None,
            scene_entity_ids: std::collections::BTreeSet::new(),
            component_types_by_entity_id: std::collections::BTreeMap::new(),
            is_scene_editable: true,
        }
    }
}

/// A single precondition that was not satisfied.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreconditionViolation {
    pub kind: PreconditionKind,
    pub detail: String,
}

impl PreconditionViolation {
    #[inline]
    pub fn new(kind: PreconditionKind, detail: impl Into<String>) -> Self {
        PreconditionViolation {
            kind,
            detail: detail.into(),
        }
    }
}

/// Evaluates preconditions, returning every violation found (not just the first).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PreconditionChecker;

impl PreconditionChecker {
    pub fn new() -> Self {
        PreconditionChecker
    }

    pub fn check(
        &self,
        preconditions: &[CapabilityPreconditionSpec],
        input: &PreconditionCheckInput,
    ) -> Vec<PreconditionViolation> {
        preconditions
            .iter()
            .filter_map(|spec| Self::evaluate(spec, input))
            .collect()
    }

    fn evaluate(
        spec: &CapabilityPreconditionSpec,
        input: &PreconditionCheckInput,
    ) -> Option<PreconditionViolation> {
        match spec.kind {
            PreconditionKind::EntityExists => {
                let effective_id = input
                    .target_entity_ids
                    .first()
                    .copied()
                    .or(input.selected_entity_id);
                match effective_id {
                    Some(id) if input.scene_entity_ids.contains(&id) => None,
                    _ => Some(PreconditionViolation::new(
                        PreconditionKind::EntityExists,
                        "target entity does not exist in the scene",
                    )),
                }
            }

            PreconditionKind::SelectionRequired => {
                if !input.target_entity_ids.is_empty() || input.selected_entity_id.is_some() {
                    None
                } else {
                    Some(PreconditionViolation::new(
                        PreconditionKind::SelectionRequired,
                        format!(
                            "'{}' requires a target entity but none is selected or specified",
                            input.verb
                        ),
                    ))
                }
            }

            PreconditionKind::ArgumentPresent => {
                let name = spec.argument_name.as_deref().unwrap_or("<unknown>");
                if input.argument_names.contains(name) {
                    None
                } else {
                    Some(PreconditionViolation::new(
                        PreconditionKind::ArgumentPresent,
                        format!("required argument '{name}' is missing from the intent"),
                    ))
                }
            }

            PreconditionKind::SceneEditable => {
                if input.is_scene_editable {
                    None
                } else {
                    Some(PreconditionViolation::new(
                        PreconditionKind::SceneEditable,
                        "the scene is not editable (locked during playback or a conflicting transaction)",
                    ))
                }
            }

            PreconditionKind::EntityHasComponent => {
                let component_type = spec.component_type.as_deref().unwrap_or("<unknown>");
                if component_type == "<unknown>" {
                    return Some(PreconditionViolation::new(
                        PreconditionKind::EntityHasComponent,
                        "required component type is not specified",
                    ));
                }
                let effective_id = input
                    .target_entity_ids
                    .first()
                    .copied()
                    .or(input.selected_entity_id);
                let Some(id) = effective_id else {
                    return Some(PreconditionViolation::new(
                        PreconditionKind::EntityHasComponent,
                        format!(
                            "cannot verify required component '{component_type}' without an existing target entity"
                        ),
                    ));
                };
                if !input.scene_entity_ids.contains(&id) {
                    return Some(PreconditionViolation::new(
                        PreconditionKind::EntityHasComponent,
                        format!(
                            "cannot verify required component '{component_type}' without an existing target entity"
                        ),
                    ));
                }
                let has_component = input
                    .component_types_by_entity_id
                    .get(&id)
                    .is_some_and(|types| types.contains(component_type));
                if has_component {
                    None
                } else {
                    Some(PreconditionViolation::new(
                        PreconditionKind::EntityHasComponent,
                        format!(
                            "target entity {id} is missing required component '{component_type}'"
                        ),
                    ))
                }
            }
        }
    }
}
