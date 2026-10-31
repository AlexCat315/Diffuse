//! Ported from `Engine/Tests/PluginRuntimeTests/PluginRequirementTests.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_contract::{CapabilityAccess, CapabilityContract, ReleasePhase};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema;
use diffuse_capability::support::swift_date::SwiftDate;

use crate::PluginError;
use crate::contract::plugin_manifest::{
    CovePluginManifest, PluginManifestValidationError, PluginManifestValidator,
};
use crate::contract::requirements::{
    PluginRequirement, PluginRequirementKind, PluginRequirementResolver,
    PluginRequirementViolation, UnmetPluginRequirements,
};
use crate::contribution::registry::ContributionPointRegistry;
use crate::plugin_authorization::{
    PluginAuthorizationRecord, PluginCapabilityRegistryBuilder, PluginExecutionBinding,
    PluginInspection,
};

fn manifest(requires: Vec<PluginRequirement>) -> CovePluginManifest {
    CovePluginManifest::new(
        "studio.gizmo",
        1,
        "Gizmo",
        "Requirement test package",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        requires,
        Default::default(),
        Default::default(),
    )
}

fn inspection(requires: Vec<PluginRequirement>) -> PluginInspection {
    PluginInspection::new(
        manifest(requires),
        Some("component".to_string()),
        Some("wit".to_string()),
        Vec::new(),
    )
}

/// The Swift `#expect(throws: PluginManifestValidationError.case)` checks the
/// validation enum directly, so the helper returns it rather than the crate
/// union.
fn validate(requires: Vec<PluginRequirement>) -> Result<(), PluginManifestValidationError> {
    PluginManifestValidator::validate(
        &manifest(requires),
        &CapabilityRegistry::default_registry(),
        &ContributionPointRegistry::standard(),
    )
}

// @Test("manifests decode structured requirements and default to none")
#[test]
fn manifest_decoding() {
    let json = r#"
    {
      "id": "studio.gizmo",
      "version": 2,
      "name": "Gizmo",
      "description": "Draws gizmos",
      "access": "read",
      "imports": [],
      "composable_host_capabilities": [],
      "requires": [
        { "kind": "plugin", "id": "studio.core", "minimum_version": 2 },
        { "kind": "capability", "id": "studio.core.draw" }
      ]
    }
    "#;
    let decoded = PluginManifestValidator::decode_and_validate(
        json.as_bytes(),
        &CapabilityRegistry::default_registry(),
        &ContributionPointRegistry::standard(),
    )
    .expect("manifest decodes");
    // Swift sorted by (kind.rawValue, id): "capability" precedes "plugin".
    assert_eq!(
        decoded.requires,
        vec![
            PluginRequirement::new(PluginRequirementKind::Capability, "studio.core.draw"),
            PluginRequirement::with_minimum_version(
                PluginRequirementKind::Plugin,
                "studio.core",
                2
            ),
        ]
    );

    let legacy = r#"
    { "id": "safe.reader", "version": 1, "name": "Reader", "description": "Legacy",
      "access": "read", "imports": [], "composable_host_capabilities": [] }
    "#;
    let legacy_manifest = PluginManifestValidator::decode_and_validate(
        legacy.as_bytes(),
        &CapabilityRegistry::default_registry(),
        &ContributionPointRegistry::standard(),
    )
    .expect("legacy manifest decodes");
    assert!(legacy_manifest.requires.is_empty());
}

// @Test("requirement validation rejects duplicates, self-reference, and malformed ids")
#[test]
fn requirement_validation() {
    assert_eq!(
        validate(vec![
            PluginRequirement::with_minimum_version(
                PluginRequirementKind::Plugin,
                "studio.core",
                1
            ),
            PluginRequirement::with_minimum_version(
                PluginRequirementKind::Plugin,
                "studio.core",
                2
            ),
        ]),
        Err(PluginManifestValidationError::DuplicateRequirement(
            "studio.core".to_string()
        ))
    );
    assert_eq!(
        validate(vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "studio.gizmo"
        )]),
        Err(PluginManifestValidationError::RequirementOnSelf(
            "studio.gizmo".to_string()
        ))
    );
    assert_eq!(
        validate(vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "studio.gizmo.draw"
        )]),
        Err(PluginManifestValidationError::RequirementOnSelf(
            "studio.gizmo.draw".to_string()
        ))
    );
    assert_eq!(
        validate(vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "Bogus"
        )]),
        Err(PluginManifestValidationError::InvalidRequirement(
            "Bogus".to_string()
        ))
    );
    assert_eq!(
        validate(vec![PluginRequirement::with_minimum_version(
            PluginRequirementKind::Plugin,
            "studio.core",
            0
        )]),
        Err(PluginManifestValidationError::InvalidRequirement(
            "studio.core".to_string()
        ))
    );
    assert!(matches!(
        validate(vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "Scene.Set"
        )]),
        Err(PluginManifestValidationError::InvalidRequirement(_))
    ));

    // A well-formed requirement passes validation; existence is decided at
    // enable time, not by the manifest.
    assert_eq!(
        validate(vec![
            PluginRequirement::with_minimum_version(
                PluginRequirementKind::Plugin,
                "studio.core",
                1
            ),
            PluginRequirement::new(PluginRequirementKind::Capability, "scene.set_name"),
            // A separately named nested plugin is not this plugin's export.
            PluginRequirement::new(
                PluginRequirementKind::Capability,
                "studio.gizmo.tools.inspect"
            ),
        ]),
        Ok(())
    );
}

// @Test("resolution fails closed on missing and outdated dependencies")
#[test]
fn resolution() {
    let requirements = vec![
        PluginRequirement::with_minimum_version(PluginRequirementKind::Plugin, "studio.core", 2),
        PluginRequirement::new(PluginRequirementKind::Capability, "scene.set_name"),
        PluginRequirement::with_minimum_version(
            PluginRequirementKind::Capability,
            "studio.core.draw",
            3,
        ),
    ];
    let satisfied = PluginRequirementResolver::unmet(
        &requirements,
        "studio.gizmo",
        &BTreeMap::from([("studio.core".to_string(), 2)]),
        &BTreeMap::from([
            ("scene.set_name".to_string(), 1),
            ("studio.core.draw".to_string(), 3),
        ]),
    );
    assert!(satisfied.is_empty());

    let unmet = PluginRequirementResolver::unmet(
        &requirements,
        "studio.gizmo",
        &BTreeMap::from([("studio.core".to_string(), 1)]),
        &BTreeMap::from([("studio.core.draw".to_string(), 2)]),
    );
    assert_eq!(
        unmet,
        vec![
            PluginRequirementViolation::PluginVersionTooLow {
                id: "studio.core".to_string(),
                required_by: "studio.gizmo".to_string(),
                minimum_version: 2,
                actual: 1,
            },
            PluginRequirementViolation::MissingCapability {
                id: "scene.set_name".to_string(),
                required_by: "studio.gizmo".to_string(),
                minimum_version: None,
            },
            PluginRequirementViolation::CapabilityVersionTooLow {
                id: "studio.core.draw".to_string(),
                required_by: "studio.gizmo".to_string(),
                minimum_version: 3,
                actual: 2,
            },
        ]
    );

    let missing = PluginRequirementResolver::unmet(
        &requirements,
        "studio.gizmo",
        &BTreeMap::new(),
        &BTreeMap::new(),
    );
    assert_eq!(missing.len(), 3);
    assert_eq!(
        missing.first(),
        Some(&PluginRequirementViolation::MissingPlugin {
            id: "studio.core".to_string(),
            required_by: "studio.gizmo".to_string(),
            minimum_version: Some(2),
        })
    );
}

// @Test("dependents include plugin and exact capability requirements")
#[test]
fn dependents_include_plugin_and_exact_capability_requirements() {
    let core = CovePluginManifest::new(
        "studio.core",
        1,
        "Core",
        "d",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Default::default(),
        Default::default(),
    );
    let gizmo = CovePluginManifest::new(
        "studio.gizmo",
        1,
        "Gizmo",
        "d",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "studio.core",
        )],
        Default::default(),
        Default::default(),
    );
    let palette = CovePluginManifest::new(
        "studio.palette",
        1,
        "Palette",
        "d",
        CapabilityAccess::Read,
        Vec::new(),
        Vec::new(),
        vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "studio.core.draw",
        )],
        Default::default(),
        Default::default(),
    );
    let manifests = BTreeMap::from([
        ("studio.core".to_string(), core),
        ("studio.gizmo".to_string(), gizmo),
        ("studio.palette".to_string(), palette.clone()),
    ]);
    let found = PluginRequirementResolver::dependents(
        "studio.core",
        &BTreeSet::from(["studio.core.draw".to_string()]),
        &manifests,
    );
    assert_eq!(
        found,
        vec!["studio.gizmo".to_string(), "studio.palette".to_string()]
    );
    assert!(
        PluginRequirementResolver::dependents(
            "studio.core",
            &BTreeSet::new(),
            &BTreeMap::from([("studio.palette".to_string(), palette)]),
        )
        .is_empty()
    );
}

// @Test("authorization binds requirements and rejects incomplete records")
#[test]
fn authorization_binds_requirements() {
    let base = inspection(Vec::new());
    let extended = inspection(vec![PluginRequirement::new(
        PluginRequirementKind::Plugin,
        "studio.core",
    )]);

    let record =
        PluginAuthorizationRecord::from_inspection(&base, SwiftDate(0.0)).expect("authorizes");
    assert!(record.requires.is_empty());
    assert!(record.is_still_valid(&base));
    assert!(!record.is_still_valid(&extended));

    let extended_record =
        PluginAuthorizationRecord::from_inspection(&extended, SwiftDate(0.0)).expect("authorizes");
    assert_ne!(
        record.authority_digest(),
        extended_record.authority_digest()
    );
    assert!(extended_record.is_still_valid(&extended));

    let encoded = serde_json::to_vec(&record).expect("encodes");
    let decoded: PluginAuthorizationRecord = serde_json::from_slice(&encoded).expect("decodes");
    assert_eq!(decoded, record);
    let mut object: BTreeMap<String, serde_json::Value> =
        serde_json::from_slice(&encoded).expect("object");
    object.remove("requires");
    let legacy = serde_json::to_vec(&object).expect("encodes");
    // Swift's synthesized decoder required `requires`; the stored-record format
    // never omitted it.
    assert!(serde_json::from_slice::<PluginAuthorizationRecord>(&legacy).is_err());
}

// @Test("registry construction rejects missing dependencies, version mismatches and cycles")
#[test]
fn registry_requirements() {
    fn binding(id: &str, version: i64, requires: Vec<PluginRequirement>) -> PluginExecutionBinding {
        let manifest = CovePluginManifest::new(
            id,
            version,
            id,
            "Fixture",
            CapabilityAccess::Read,
            Vec::new(),
            Vec::new(),
            requires,
            Default::default(),
            Default::default(),
        );
        let contract = CapabilityContract::new(
            format!("{id}.inspect"),
            version,
            "Inspect",
            "Fixture",
            "plugin",
            CapabilityAccess::Read,
            ReleasePhase::Stable,
            capsule_schema::object(BTreeMap::new(), Vec::new(), None, false),
            diffuse_capability::capability_contract::CapabilitySource::plugin(id.to_string()),
            None,
        );
        let inspection = PluginInspection::new(
            manifest,
            Some("code".to_string()),
            Some("wit".to_string()),
            vec![contract],
        );
        let authorization = PluginAuthorizationRecord::from_inspection(&inspection, SwiftDate(0.0))
            .expect("authorizes");
        PluginExecutionBinding::new(format!("/{id}"), inspection, authorization, 1).expect("binds")
    }

    let core = binding("studio.core", 1, Vec::new());
    let dependent = binding(
        "studio.gizmo",
        1,
        vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "studio.core.inspect",
        )],
    );
    assert!(matches!(
        PluginCapabilityRegistryBuilder::build(
            &CapabilityRegistry::default_registry(),
            std::slice::from_ref(&dependent),
            &[],
        ),
        Err(PluginError::Requirements(_))
    ));
    let valid = PluginCapabilityRegistryBuilder::build(
        &CapabilityRegistry::default_registry(),
        &[dependent, core.clone()],
        &[],
    )
    .expect("builds");
    assert!(valid.descriptor("studio.gizmo.inspect").is_some());

    let outdated = binding(
        "studio.gizmo",
        1,
        vec![PluginRequirement::with_minimum_version(
            PluginRequirementKind::Plugin,
            "studio.core",
            2,
        )],
    );
    assert!(matches!(
        PluginCapabilityRegistryBuilder::build(
            &CapabilityRegistry::default_registry(),
            &[core, outdated],
            &[],
        ),
        Err(PluginError::Requirements(UnmetPluginRequirements { .. }))
    ));

    let cyclic_core = binding(
        "studio.core",
        1,
        vec![PluginRequirement::new(
            PluginRequirementKind::Plugin,
            "studio.gizmo",
        )],
    );
    let dependent_again = binding(
        "studio.gizmo",
        1,
        vec![PluginRequirement::new(
            PluginRequirementKind::Capability,
            "studio.core.inspect",
        )],
    );
    assert!(matches!(
        PluginCapabilityRegistryBuilder::build(
            &CapabilityRegistry::default_registry(),
            &[dependent_again, cyclic_core],
            &[],
        ),
        Err(PluginError::Requirements(_))
    ));
}
