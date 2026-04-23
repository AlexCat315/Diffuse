import CapabilityRuntime
import ObservationBus
import Testing

@Suite("CapabilityRuntime")
struct CapabilityRuntimeTests {
    @Test("default capability registry loads from bundled JSON resource")
    func defaultRegistryLoadsFromJSON() throws {
        let config = try CapabilityRegistry.loadDefaultConfig()

        #expect(!config.capabilities.isEmpty)
        #expect(config.scopes["scene_instance"] != nil)
        #expect(config.targetKinds["scene_instance_id"] != nil)
    }

    @Test("default prompt capability list excludes experimental verbs by default")
    func defaultPromptCapabilityListExcludesExperimentalVerbs() throws {
        let registry = try CapabilityRegistry.default()
        let promptVerbs = registry.defaultPromptCapabilities(for: CapabilityQueryContext(role: .editor,
                                                                                         phase: .beta))
            .map(\ .verbID)

        #expect(promptVerbs.contains("scene.set_transform"))
        #expect(!promptVerbs.contains("scene.commit_inferred_draft"))
    }

    @Test("release phase gate denies ship-only restricted capabilities")
    func releasePhaseGateDeniesShipRestrictedCapabilities() throws {
        let registry = try CapabilityRegistry.default()

        #expect(throws: CapabilityRegistryError.self) {
            try registry.resolveInvocation(verbID: "scene.commit_inferred_draft",
                                          context: CapabilityQueryContext(role: .editor,
                                                                          phase: .ship,
                                                                          includeExperimental: true))
        }
    }

    @Test("precondition checker evaluates role and field predicates")
    func preconditionCheckerEvaluatesRoleAndFieldPredicates() {
        let checker = PreconditionChecker()
        let preconditions = [
            Precondition(id: "has-selection",
                         kind: .targetState,
                         expr: .exists("editor.selection"),
                         message: "Selection required",
                         severity: .block),
            Precondition(id: "is-stable-id",
                         kind: .custom,
                         expr: .matchesRegexSafelist(value: .fieldRef("target.id"), pattern: .dottedIdentifier),
                         message: "Target id must be stable",
                         severity: .block),
            Precondition(id: "role",
                         kind: .role,
                         expr: .roleAtLeast(.editor),
                         message: "Editor role required",
                         severity: .block),
        ]
        let facts = CapabilityFacts(values: [
            "editor.selection": .string("hero"),
            "target.id": .string("scene.hero.main"),
        ])

        let allowedReport = checker.evaluate(preconditions, facts: facts, currentRole: .editor)
        let deniedReport = checker.evaluate(preconditions, facts: CapabilityFacts(), currentRole: .viewer)

        #expect(allowedReport.isAllowed)
        #expect(!deniedReport.isAllowed)
        #expect(deniedReport.blockingFailures.count == 3)
    }

    @Test("deprecated capabilities resolve with warnings instead of denial")
    func deprecatedCapabilitiesResolveWithWarnings() throws {
        let registry = try CapabilityRegistry.default()
        let resolution = try registry.resolveInvocation(verbID: "scene.snap_to_ground",
                                                        context: CapabilityQueryContext(role: .editor,
                                                                                        phase: .beta))

        #expect(resolution.spec.status == .deprecated)
        #expect(resolution.warnings.contains { $0.contains("deprecated") })
    }

    @Test("registry validation rejects capabilities referencing unknown scopes")
    func registryValidationRejectsUnknownScope() throws {
        let capability = CapabilitySpec(verbID: "scene.bad_scope",
                                        summary: "bad scope",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(capabilities: [capability],
                                              scopes: [:],
                                              targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")])

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation rejects unknown policy references")
    func registryValidationRejectsUnknownPolicyReference() throws {
        let capability = CapabilitySpec(verbID: "scene.bad_policy",
                                        summary: "bad policy",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        policyRefs: ["missing-policy"],
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["scene_instance": CapabilityScopeSpec(scopeID: "scene_instance")],
            targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")],
            policies: [:]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation rejects unknown effect kind references")
    func registryValidationRejectsUnknownEffectKindReference() throws {
        let capability = CapabilitySpec(verbID: "scene.bad_effect_kind",
                                        summary: "bad effect kind",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        effects: [CapabilityEffect(id: "effect.missing",
                                                                   kind: .writeField,
                                                                   targetKind: "scene_instance_id")],
                                        reversible: false,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["scene_instance": CapabilityScopeSpec(scopeID: "scene_instance")],
            targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")],
            effectKinds: ["effect.other": CapabilityEffectKindSpec(effectID: "effect.other", kind: .writeField)]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation rejects unknown argument types")
    func registryValidationRejectsUnknownArgumentType() throws {
        let capability = CapabilitySpec(verbID: "scene.bad_argument_type",
                                        summary: "bad argument type",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        arguments: [CapabilityArgumentSpec(name: "value", typeID: "missing-type")],
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["scene_instance": CapabilityScopeSpec(scopeID: "scene_instance")],
            targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")],
            argumentTypes: [:]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation enforces deprecated status requires superseded_by")
    func registryValidationEnforcesDeprecatedStatusFlow() throws {
        let capability = CapabilitySpec(verbID: "scene.deprecated_without_successor",
                                        summary: "deprecated without successor",
                                        category: "scene",
                                        scope: .sceneInstance,
                                        targetKind: "scene_instance_id",
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        requiredRole: .editor,
                                        status: .deprecated)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["scene_instance": CapabilityScopeSpec(scopeID: "scene_instance")],
            targetKinds: ["scene_instance_id": CapabilityTargetKindSpec(targetKindID: "scene_instance_id")]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation rejects none-preview capabilities with non-auto confirmation")
    func registryValidationRejectsIncompatiblePreviewConfirmation() throws {
        let capability = CapabilitySpec(verbID: "asset.invalid_preview_policy",
                                        summary: "invalid preview-policy pair",
                                        category: "asset",
                                        scope: .asset,
                                        targetKind: "asset_uri",
                                        reversible: false,
                                        previewSupport: CapabilityPreviewSupport(mode: .none),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .warn),
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["asset": CapabilityScopeSpec(scopeID: "asset")],
            targetKinds: ["asset_uri": CapabilityTargetKindSpec(targetKindID: "asset_uri")]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }

    @Test("registry validation enforces reversible effects rollback mapping")
    func registryValidationEnforcesReversibleEffectRollbackMapping() throws {
        let capability = CapabilitySpec(verbID: "asset.replace_without_rollback",
                                        summary: "replace asset without rollback",
                                        category: "asset",
                                        scope: .asset,
                                        targetKind: "asset_uri",
                                        effects: [CapabilityEffect(id: "asset.replace",
                                                                   kind: .replaceAsset,
                                                                   targetKind: "asset_uri")],
                                        reversible: true,
                                        previewSupport: CapabilityPreviewSupport(mode: .ghostWorld),
                                        confirmationPolicy: CapabilityConfirmationPolicy(level: .auto),
                                        requiredRole: .editor,
                                        status: .stable)
        let config = CapabilityRegistryConfig(
            capabilities: [capability],
            scopes: ["asset": CapabilityScopeSpec(scopeID: "asset")],
            targetKinds: ["asset_uri": CapabilityTargetKindSpec(targetKindID: "asset_uri")],
            effectKinds: ["asset.replace": CapabilityEffectKindSpec(effectID: "asset.replace", kind: .replaceAsset)]
        )

        #expect(throws: CapabilityRegistryError.self) {
            _ = try CapabilityRegistry(config: config)
        }
    }
}