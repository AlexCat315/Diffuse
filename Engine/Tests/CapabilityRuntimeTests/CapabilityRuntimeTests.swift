import CapabilityRuntime
import ObservationBus
import Testing

@Suite("CapabilityRuntime")
struct CapabilityRuntimeTests {
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
}