//! `CapabilityRuntimeTests` — Swift suite `CapabilityRuntime`.

use diffuse_capability::capability_contract::ReleasePhase;
use diffuse_capability::capability_descriptor::{
    CapabilityDescriptor, CapabilityPreconditionSpec, PreconditionKind,
};
use diffuse_capability::capability_registry::{
    CapabilityRegistry, CapabilityRegistryIntegrityError,
};
use diffuse_capability::capability_validator::{CapabilityValidationError, CapabilityValidator};
use diffuse_capability::drafts::precondition_checker::{
    PreconditionCheckInput, PreconditionChecker,
};
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;

fn descriptor(verb: &str, phase: ReleasePhase) -> CapabilityDescriptor {
    let mut descriptor = CapabilityDescriptor::new(verb);
    descriptor.release_phase = phase;
    descriptor
}

// "default registry resolves all IntentTransactionBuilder verbs"
#[test]
fn default_registry_covers_builtin_verbs() {
    let registry = CapabilityRegistry::default_registry();
    let required_verbs = [
        "scene.spawn_entity",
        "scene.set_name",
        "scene.duplicate_entity",
        "scene.reparent_entity",
        "scene.delete_entity",
        "scene.set_transform",
        "scene.snap_to_ground",
        "scene.set_camera_pose",
        "scene.set_camera_fov",
        "scene.set_camera_aspect_ratio",
        "scene.set_camera_active",
        "scene.set_light_type",
        "scene.set_light_color",
        "scene.set_light_intensity",
        "scene.set_light_cast_shadows",
        "scene.set_mesh_color",
        "scene.set_mesh_visibility",
        "scene.set_animation_player",
        "scene.set_audio_source",
        "scene.set_script_bindings",
        "scene.set_script_property",
        "scene.set_collider",
        "scene.set_collider_layer",
        "scene.set_constraint_enabled",
        "scene.set_rigid_body_motion_type",
        "scene.set_rigid_body_mass",
        "asset.scan_project",
        "sequence.replace_document",
    ];
    for verb in required_verbs {
        assert!(registry.descriptor(verb).is_some(), "missing verb: {verb}");
    }
}

// "registry resolves aliases to the primary descriptor"
#[test]
fn registry_resolves_aliases() {
    let registry = CapabilityRegistry::default_registry();
    let primary = registry.descriptor("scene.spawn_entity");
    let alias = registry.descriptor("scene.create_instance");
    assert!(primary.is_some());
    assert!(alias.is_some());
    assert_eq!(primary, alias);
}

// "descriptor exposes derived validation metadata"
#[test]
fn descriptor_derived_validation_metadata() {
    let registry = CapabilityRegistry::default_registry();
    let descriptor = registry
        .descriptor("scene.set_name")
        .expect("scene.set_name registered");

    assert_eq!(
        descriptor.required_argument_names(),
        std::iter::once("name".to_string()).collect()
    );
    assert!(descriptor.required_component_types().is_empty());
    assert!(descriptor.requires_target_entity());
}

// "registry returns nil for unknown verbs"
#[test]
fn registry_unknown_verb() {
    assert!(
        CapabilityRegistry::default_registry()
            .descriptor("scene.unknown_verb")
            .is_none()
    );
}

// "registry fails exposure closed when duplicate ids are present"
#[test]
fn duplicate_registry_fails_closed() {
    let mut duplicate = CapabilityDescriptor::new("scene.duplicate");
    duplicate.access = diffuse_capability::capability_contract::CapabilityAccess::Read;
    duplicate.is_ai_exposed = true;
    let registry = CapabilityRegistry::new(vec![duplicate.clone(), duplicate]);
    assert!(!registry.integrity_errors.is_empty());
    let snapshot =
        registry.exposure_snapshot(&Default::default(), None, 0, &[], None, &Default::default());
    assert!(snapshot.contracts.is_empty());
    assert!(registry.validate_integrity().is_err());
}

// "merging overrides verbs from self with other"
#[test]
fn registry_merging() {
    let base =
        CapabilityRegistry::new(vec![descriptor("scene.spawn_entity", ReleasePhase::Stable)]);
    let override_registry = CapabilityRegistry::new(vec![descriptor(
        "scene.spawn_entity",
        ReleasePhase::Experimental,
    )]);
    let merged = base.merging(&override_registry);
    assert_eq!(
        merged
            .descriptor("scene.spawn_entity")
            .map(|value| value.release_phase),
        Some(ReleasePhase::Experimental)
    );
}

// "stable gate allows stable and rejects beta and experimental"
#[test]
fn stable_gate_policy() {
    let gate = ReleasePhaseGate::new(ReleasePhase::Stable);
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Stable)));
    assert!(!gate.is_allowed(&descriptor("x", ReleasePhase::Beta)));
    assert!(!gate.is_allowed(&descriptor("x", ReleasePhase::Experimental)));
    assert!(!gate.is_allowed(&descriptor("x", ReleasePhase::Disabled)));
}

// "beta gate allows stable and beta but not experimental"
#[test]
fn beta_gate_policy() {
    let gate = ReleasePhaseGate::new(ReleasePhase::Beta);
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Stable)));
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Beta)));
    assert!(!gate.is_allowed(&descriptor("x", ReleasePhase::Experimental)));
}

// "experimental gate allows stable, beta, and experimental"
#[test]
fn experimental_gate_policy() {
    let gate = ReleasePhaseGate::new(ReleasePhase::Experimental);
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Stable)));
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Beta)));
    assert!(gate.is_allowed(&descriptor("x", ReleasePhase::Experimental)));
    assert!(!gate.is_allowed(&descriptor("x", ReleasePhase::Disabled)));
}

// "gate denial reason is non-nil only for denied capabilities"
#[test]
fn gate_denial_reason() {
    let gate = ReleasePhaseGate::new(ReleasePhase::Stable);
    assert!(
        gate.denied_reason(&descriptor("x", ReleasePhase::Stable))
            .is_none()
    );
    assert!(
        gate.denied_reason(&descriptor("x", ReleasePhase::Beta))
            .is_some()
    );
    assert!(
        gate.denied_reason(&descriptor("x", ReleasePhase::Disabled))
            .is_some()
    );
}

// "entityExists passes when target entity is in the scene"
#[test]
fn precondition_entity_exists_passes() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.delete_entity");
    input.target_entity_ids = vec![42];
    input.scene_entity_ids = std::iter::once(42).collect();
    let violations = checker.check(&[CapabilityPreconditionSpec::ENTITY_EXISTS], &input);
    assert!(violations.is_empty());
}

// "entityExists fails when target entity is absent"
#[test]
fn precondition_entity_exists_fails() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.delete_entity");
    input.target_entity_ids = vec![99];
    input.scene_entity_ids = [1, 2, 3].into_iter().collect();
    let violations = checker.check(&[CapabilityPreconditionSpec::ENTITY_EXISTS], &input);
    assert_eq!(violations.len(), 1);
    assert_eq!(violations[0].kind, PreconditionKind::EntityExists);
}

// "entityExists falls back to selectedEntityID when no target specified"
#[test]
fn precondition_entity_exists_falls_back_to_selection() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.set_name");
    input.selected_entity_id = Some(7);
    input.scene_entity_ids = std::iter::once(7).collect();
    let violations = checker.check(&[CapabilityPreconditionSpec::ENTITY_EXISTS], &input);
    assert!(violations.is_empty());
}

// "selectionRequired fails with no target and no selection"
#[test]
fn precondition_selection_required_fails() {
    let checker = PreconditionChecker::new();
    let input = PreconditionCheckInput::new("scene.set_name");
    let violations = checker.check(&[CapabilityPreconditionSpec::SELECTION_REQUIRED], &input);
    assert_eq!(violations.len(), 1);
    assert_eq!(violations[0].kind, PreconditionKind::SelectionRequired);
}

// "argumentPresent fails when named argument is absent"
#[test]
fn precondition_argument_present_fails() {
    let checker = PreconditionChecker::new();
    let input = PreconditionCheckInput::new("scene.set_name");
    let violations = checker.check(
        &[CapabilityPreconditionSpec::argument(
            PreconditionKind::ArgumentPresent,
            "name",
        )],
        &input,
    );
    assert_eq!(violations.len(), 1);
    assert_eq!(violations[0].kind, PreconditionKind::ArgumentPresent);
}

// "argumentPresent passes when named argument is present"
#[test]
fn precondition_argument_present_passes() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.set_name");
    input.argument_names = std::iter::once("name".to_string()).collect();
    let violations = checker.check(
        &[CapabilityPreconditionSpec::argument(
            PreconditionKind::ArgumentPresent,
            "name",
        )],
        &input,
    );
    assert!(violations.is_empty());
}

// "entityHasComponent passes when target has the component type"
#[test]
fn precondition_entity_has_component_passes() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.set_light_color");
    input.target_entity_ids = vec![42];
    input.scene_entity_ids = std::iter::once(42).collect();
    input
        .component_types_by_entity_id
        .insert(42, std::iter::once("LightComponent".to_string()).collect());
    let violations = checker.check(
        &[CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "LightComponent",
        )],
        &input,
    );
    assert!(violations.is_empty());
}

// "entityHasComponent fails when target misses the component type"
#[test]
fn precondition_entity_has_component_fails() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.set_light_color");
    input.target_entity_ids = vec![42];
    input.scene_entity_ids = std::iter::once(42).collect();
    input
        .component_types_by_entity_id
        .insert(42, std::iter::once("CameraComponent".to_string()).collect());
    let violations = checker.check(
        &[CapabilityPreconditionSpec::component(
            PreconditionKind::EntityHasComponent,
            "LightComponent",
        )],
        &input,
    );
    assert_eq!(violations.len(), 1);
    assert_eq!(violations[0].kind, PreconditionKind::EntityHasComponent);
}

// "sceneEditable fails when scene is locked"
#[test]
fn precondition_scene_editable_fails() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.spawn_entity");
    input.is_scene_editable = false;
    let violations = checker.check(&[CapabilityPreconditionSpec::SCENE_EDITABLE], &input);
    assert_eq!(violations.len(), 1);
    assert_eq!(violations[0].kind, PreconditionKind::SceneEditable);
}

// "multiple preconditions accumulate all violations"
#[test]
fn precondition_multiple_violations() {
    let checker = PreconditionChecker::new();
    let mut input = PreconditionCheckInput::new("scene.set_name");
    input.is_scene_editable = false;
    let violations = checker.check(
        &[
            CapabilityPreconditionSpec::SCENE_EDITABLE,
            CapabilityPreconditionSpec::argument(PreconditionKind::ArgumentPresent, "name"),
        ],
        &input,
    );
    assert_eq!(violations.len(), 2);
}

// "validator succeeds for a fully satisfied spawn intent"
#[test]
fn validator_succeeds_for_spawn() {
    let validator = CapabilityValidator::with_defaults();
    let input = PreconditionCheckInput::new("scene.spawn_entity");
    let result = validator
        .validate("scene.spawn_entity", &input)
        .expect("validate");
    assert!(!result.requires_confirmation());
    assert!(!result.is_destructive());
    assert_eq!(result.domain(), "scene");
}

// "validator throws unknownVerb for unregistered verbs"
#[test]
fn validator_throws_unknown_verb() {
    let validator = CapabilityValidator::with_defaults();
    let input = PreconditionCheckInput::new("scene.nonexistent");
    let error = validator
        .validate("scene.nonexistent", &input)
        .expect_err("must fail");
    assert_eq!(
        error,
        CapabilityValidationError::UnknownVerb("scene.nonexistent".to_string())
    );
}

// "validator throws phaseDenied for beta verb with stable gate"
#[test]
fn validator_throws_phase_denied() {
    let validator = CapabilityValidator::new(
        CapabilityRegistry::default_registry(),
        ReleasePhaseGate::new(ReleasePhase::Stable),
    );
    let mut input = PreconditionCheckInput::new("scene.set_rigid_body_motion_type");
    input.target_entity_ids = vec![1];
    input.scene_entity_ids = std::iter::once(1).collect();
    let error = validator
        .validate("scene.set_rigid_body_motion_type", &input)
        .expect_err("must fail");
    assert!(matches!(
        error,
        CapabilityValidationError::PhaseDenied { .. }
    ));
}

// "validator throws preconditionViolations when entity missing"
#[test]
fn validator_throws_precondition_violations() {
    let validator = CapabilityValidator::with_defaults();
    let mut input = PreconditionCheckInput::new("scene.delete_entity");
    input.target_entity_ids = vec![999];
    let error = validator
        .validate("scene.delete_entity", &input)
        .expect_err("must fail");
    match error {
        CapabilityValidationError::PreconditionViolations(violations) => {
            assert!(!violations.is_empty());
        }
        other => panic!("expected preconditionViolations, got {other:?}"),
    }
}

// "validator resolves alias verbs correctly"
#[test]
fn validator_resolves_alias() {
    let validator = CapabilityValidator::with_defaults();
    let input = PreconditionCheckInput::new("scene.create_instance");
    let result = validator
        .validate("scene.create_instance", &input)
        .expect("validate");
    assert_eq!(result.descriptor.verb, "scene.spawn_entity");
}

// "validator enforces component preconditions"
#[test]
fn validator_enforces_component_preconditions() {
    let validator = CapabilityValidator::with_defaults();
    let mut input = PreconditionCheckInput::new("scene.set_light_color");
    input.target_entity_ids = vec![7];
    input.scene_entity_ids = std::iter::once(7).collect();
    input
        .component_types_by_entity_id
        .insert(7, std::iter::once("LightComponent".to_string()).collect());

    let result = validator
        .validate("scene.set_light_color", &input)
        .expect("validate");
    assert_eq!(
        result.descriptor.required_component_types(),
        std::iter::once("LightComponent".to_string()).collect()
    );
}

// "probe returns error without throwing"
#[test]
fn validator_probe_returns_error() {
    let validator = CapabilityValidator::with_defaults();
    let input = PreconditionCheckInput::new("scene.unknown");
    let (result, error) = validator.probe("scene.unknown", &input);
    assert!(result.is_none());
    assert!(error.is_some());
}

// "CapabilityReleasePhase ordering is disabled < experimental < beta < stable"
#[test]
fn release_phase_ordering() {
    assert!(ReleasePhase::Disabled < ReleasePhase::Experimental);
    assert!(ReleasePhase::Experimental < ReleasePhase::Beta);
    assert!(ReleasePhase::Beta < ReleasePhase::Stable);
    assert!(!(ReleasePhase::Stable < ReleasePhase::Beta));
}

// "registry contains descriptors for set_mesh_visibility and set_animation_player"
#[test]
fn mesh_visibility_and_animation_player_are_registered() {
    let registry = CapabilityRegistry::default_registry();
    let mesh_descriptor = registry.descriptor("scene.set_mesh_visibility");
    let anim_descriptor = registry.descriptor("scene.set_animation_player");
    assert!(
        mesh_descriptor.is_some(),
        "scene.set_mesh_visibility must be registered"
    );
    assert!(
        anim_descriptor.is_some(),
        "scene.set_animation_player must be registered"
    );
    assert!(!mesh_descriptor.unwrap().is_destructive);
    assert!(!anim_descriptor.unwrap().is_destructive);
}

// The integrity error type must stay reachable for callers that match on it.
#[test]
fn integrity_error_display() {
    let error = CapabilityRegistryIntegrityError::DuplicateCapability("scene.x".to_string(), 1);
    assert_eq!(error.to_string(), "duplicate capability scene.x v1");
}
