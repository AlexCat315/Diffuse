import CapabilityRuntime
import Testing

@Suite("CapabilityRuntime")
struct CapabilityRuntimeTests {

    // MARK: - CapabilityRegistry

    @Test("default registry resolves all IntentTransactionBuilder verbs")
    func defaultRegistryCoversBuiltinVerbs() {
        let registry = CapabilityRegistry.default
        let requiredVerbs = [
            "scene.spawn_entity",
            "scene.set_name",
            "scene.duplicate_entity",
            "scene.delete_entity",
            "scene.set_transform",
            "scene.snap_to_ground",
            "scene.set_camera_pose",
        ]
        for verb in requiredVerbs {
            #expect(registry.descriptor(for: verb) != nil, "missing verb: \(verb)")
        }
    }

    @Test("registry resolves aliases to the primary descriptor")
    func registryResolvesAliases() {
        let registry = CapabilityRegistry.default
        let primary = registry.descriptor(for: "scene.spawn_entity")
        let alias   = registry.descriptor(for: "scene.create_instance")
        #expect(primary != nil)
        #expect(alias   != nil)
        #expect(primary == alias)
    }

    @Test("descriptor exposes derived validation metadata")
    func descriptorDerivedValidationMetadata() throws {
        let descriptor = try #require(CapabilityRegistry.default.descriptor(for: "scene.set_name"))

        #expect(descriptor.requiredArgumentNames == ["name"])
        #expect(descriptor.requiredComponentTypes.isEmpty)
        #expect(descriptor.requiresTargetEntity)
    }

    @Test("registry returns nil for unknown verbs")
    func registryUnknownVerb() {
        #expect(CapabilityRegistry.default.descriptor(for: "scene.unknown_verb") == nil)
    }

    @Test("merging overrides verbs from self with other")
    func registryMerging() {
        let base = CapabilityRegistry(capabilities: [
            CapabilityDescriptor(verb: "scene.spawn_entity", releasePhase: .stable),
        ])
        let override = CapabilityRegistry(capabilities: [
            CapabilityDescriptor(verb: "scene.spawn_entity", releasePhase: .experimental),
        ])
        let merged = base.merging(override)
        #expect(merged.descriptor(for: "scene.spawn_entity")?.releasePhase == .experimental)
    }

    // MARK: - ReleasePhaseGate

    @Test("stable gate allows stable and rejects beta and experimental")
    func stableGatePolicy() {
        let gate = ReleasePhaseGate(activePhase: .stable)
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .stable)))
        #expect(!gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .beta)))
        #expect(!gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .experimental)))
        #expect(!gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .disabled)))
    }

    @Test("beta gate allows stable and beta but not experimental")
    func betaGatePolicy() {
        let gate = ReleasePhaseGate(activePhase: .beta)
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .stable)))
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .beta)))
        #expect(!gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .experimental)))
    }

    @Test("experimental gate allows stable, beta, and experimental")
    func experimentalGatePolicy() {
        let gate = ReleasePhaseGate(activePhase: .experimental)
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .stable)))
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .beta)))
        #expect(gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .experimental)))
        #expect(!gate.isAllowed(CapabilityDescriptor(verb: "x", releasePhase: .disabled)))
    }

    @Test("gate denial reason is non-nil only for denied capabilities")
    func gateDenialReason() {
        let gate = ReleasePhaseGate(activePhase: .stable)
        #expect(gate.deniedReason(for: CapabilityDescriptor(verb: "x", releasePhase: .stable)) == nil)
        #expect(gate.deniedReason(for: CapabilityDescriptor(verb: "x", releasePhase: .beta)) != nil)
        #expect(gate.deniedReason(for: CapabilityDescriptor(verb: "x", releasePhase: .disabled)) != nil)
    }

    // MARK: - PreconditionChecker

    @Test("entityExists passes when target entity is in the scene")
    func preconditionEntityExistsPasses() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(
            verb: "scene.delete_entity",
            targetEntityIDs: [42],
            sceneEntityIDs: [42]
        )
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .entityExists)],
            input: input
        )
        #expect(violations.isEmpty)
    }

    @Test("entityExists fails when target entity is absent")
    func preconditionEntityExistsFails() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(
            verb: "scene.delete_entity",
            targetEntityIDs: [99],
            sceneEntityIDs: [1, 2, 3]
        )
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .entityExists)],
            input: input
        )
        #expect(violations.count == 1)
        #expect(violations[0].kind == .entityExists)
    }

    @Test("entityExists falls back to selectedEntityID when no target specified")
    func preconditionEntityExistsFallsBackToSelection() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(
            verb: "scene.set_name",
            targetEntityIDs: [],
            selectedEntityID: 7,
            sceneEntityIDs: [7]
        )
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .entityExists)],
            input: input
        )
        #expect(violations.isEmpty)
    }

    @Test("selectionRequired fails with no target and no selection")
    func preconditionSelectionRequiredFails() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(verb: "scene.set_name")
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .selectionRequired)],
            input: input
        )
        #expect(violations.count == 1)
        #expect(violations[0].kind == .selectionRequired)
    }

    @Test("argumentPresent fails when named argument is absent")
    func preconditionArgumentPresentFails() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(verb: "scene.set_name", argumentNames: [])
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .argumentPresent, argumentName: "name")],
            input: input
        )
        #expect(violations.count == 1)
        #expect(violations[0].kind == .argumentPresent)
    }

    @Test("argumentPresent passes when named argument is present")
    func preconditionArgumentPresentPasses() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(verb: "scene.set_name", argumentNames: ["name"])
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .argumentPresent, argumentName: "name")],
            input: input
        )
        #expect(violations.isEmpty)
    }

    @Test("entityHasComponent passes when target has the component type")
    func preconditionEntityHasComponentPasses() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(
            verb: "scene.set_light_color",
            targetEntityIDs: [42],
            sceneEntityIDs: [42],
            componentTypesByEntityID: [42: ["LightComponent"]]
        )
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .entityHasComponent,
                                                       componentType: "LightComponent")],
            input: input
        )
        #expect(violations.isEmpty)
    }

    @Test("entityHasComponent fails when target misses the component type")
    func preconditionEntityHasComponentFails() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(
            verb: "scene.set_light_color",
            targetEntityIDs: [42],
            sceneEntityIDs: [42],
            componentTypesByEntityID: [42: ["CameraComponent"]]
        )
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .entityHasComponent,
                                                       componentType: "LightComponent")],
            input: input
        )
        #expect(violations.count == 1)
        #expect(violations[0].kind == .entityHasComponent)
    }

    @Test("sceneEditable fails when scene is locked")
    func preconditionSceneEditableFails() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(verb: "scene.spawn_entity", isSceneEditable: false)
        let violations = checker.check(
            preconditions: [CapabilityPreconditionSpec(kind: .sceneEditable)],
            input: input
        )
        #expect(violations.count == 1)
        #expect(violations[0].kind == .sceneEditable)
    }

    @Test("multiple preconditions accumulate all violations")
    func preconditionMultipleViolations() {
        let checker = PreconditionChecker()
        let input = PreconditionCheckInput(verb: "scene.set_name", isSceneEditable: false)
        let violations = checker.check(
            preconditions: [
                CapabilityPreconditionSpec(kind: .sceneEditable),
                CapabilityPreconditionSpec(kind: .argumentPresent, argumentName: "name"),
            ],
            input: input
        )
        #expect(violations.count == 2)
    }

    // MARK: - CapabilityValidator (integration)

    @Test("validator succeeds for a fully satisfied spawn intent")
    func validatorSucceedsForSpawn() throws {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(verb: "scene.spawn_entity", isSceneEditable: true)
        let result = try validator.validate(verb: "scene.spawn_entity", input: input)
        #expect(result.requiresConfirmation == false)
        #expect(result.isDestructive == false)
        #expect(result.domain == "scene")
    }

    @Test("validator throws unknownVerb for unregistered verbs")
    func validatorThrowsUnknownVerb() {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(verb: "scene.nonexistent")
        #expect(throws: CapabilityValidationError.unknownVerb("scene.nonexistent")) {
            try validator.validate(verb: "scene.nonexistent", input: input)
        }
    }

    @Test("validator throws phaseDenied for beta verb with stable gate")
    func validatorThrowsPhaseDenied() throws {
        let validator = CapabilityValidator(gate: ReleasePhaseGate(activePhase: .stable))
        let input = PreconditionCheckInput(verb: "scene.set_rigid_body_motion_type",
                                           targetEntityIDs: [1],
                                           sceneEntityIDs: [1])
        let error = try #require(
            { () throws -> CapabilityValidationError? in
                do {
                    _ = try validator.validate(verb: "scene.set_rigid_body_motion_type", input: input)
                    return nil
                } catch let e as CapabilityValidationError { return e }
            }() as CapabilityValidationError?
        )
        guard case .phaseDenied = error else {
            Issue.record("expected phaseDenied, got \(error)")
            return
        }
    }

    @Test("validator throws preconditionViolations when entity missing")
    func validatorThrowsPreconditionViolations() throws {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(
            verb: "scene.delete_entity",
            targetEntityIDs: [999],
            sceneEntityIDs: []
        )
        let error = try #require(
            { () throws -> CapabilityValidationError? in
                do {
                    _ = try validator.validate(verb: "scene.delete_entity", input: input)
                    return nil
                } catch let e as CapabilityValidationError { return e }
            }() as CapabilityValidationError?
        )
        guard case let .preconditionViolations(vs) = error else {
            Issue.record("expected preconditionViolations, got \(error)")
            return
        }
        #expect(!vs.isEmpty)
    }

    @Test("validator resolves alias verbs correctly")
    func validatorResolvesAlias() throws {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(verb: "scene.create_instance", isSceneEditable: true)
        let result = try validator.validate(verb: "scene.create_instance", input: input)
        #expect(result.descriptor.verb == "scene.spawn_entity")
    }

    @Test("validator enforces component preconditions")
    func validatorEnforcesComponentPreconditions() throws {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(
            verb: "scene.set_light_color",
            targetEntityIDs: [7],
            sceneEntityIDs: [7],
            componentTypesByEntityID: [7: ["LightComponent"]]
        )

        let result = try validator.validate(verb: "scene.set_light_color", input: input)

        #expect(result.descriptor.requiredComponentTypes == ["LightComponent"])
    }

    @Test("probe returns error without throwing")
    func validatorProbeReturnsError() {
        let validator = CapabilityValidator()
        let input = PreconditionCheckInput(verb: "scene.unknown")
        let (result, error) = validator.probe(verb: "scene.unknown", input: input)
        #expect(result == nil)
        #expect(error != nil)
    }

    // MARK: - CapabilityReleasePhase ordering

    @Test("CapabilityReleasePhase ordering is disabled < experimental < beta < stable")
    func releasePhaseOrdering() {
        #expect(CapabilityReleasePhase.disabled < .experimental)
        #expect(CapabilityReleasePhase.experimental < .beta)
        #expect(CapabilityReleasePhase.beta < .stable)
        #expect(!(CapabilityReleasePhase.stable < .beta))
    }

    @Test("registry contains descriptors for set_mesh_visibility and set_animation_player")
    func meshVisibilityAndAnimationPlayerAreRegistered() {
        let registry = CapabilityRegistry.default
        let meshDesc = registry.descriptor(for: "scene.set_mesh_visibility")
        let animDesc = registry.descriptor(for: "scene.set_animation_player")
        #expect(meshDesc != nil, "scene.set_mesh_visibility must be registered")
        #expect(animDesc != nil, "scene.set_animation_player must be registered")
        #expect(meshDesc?.isDestructive == false)
        #expect(animDesc?.isDestructive == false)
    }
}
