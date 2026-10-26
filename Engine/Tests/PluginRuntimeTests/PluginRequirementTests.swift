import CapabilityRuntime
import Foundation
@testable import PluginRuntime
import Testing

@Suite("Plugin requirements")
struct PluginRequirementTests {
    private func manifest(_ requires: [PluginRequirement]) -> CovePluginManifest {
        CovePluginManifest(id: "studio.gizmo",
                            version: 1,
                            name: "Gizmo",
                            description: "Requirement test package",
                            access: .read,
                            requires: requires)
    }

    private func inspection(_ requires: [PluginRequirement]) -> PluginInspection {
        PluginInspection(manifest: manifest(requires),
                         componentHash: "component",
                         witHash: "wit",
                         contracts: [])
    }

    @Test("manifests decode structured requirements and default to none")
    func manifestDecoding() throws {
        let json = """
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
        """
        let decoded = try PluginManifestValidator.decodeAndValidate(Data(json.utf8))
        #expect(decoded.requires == [
            PluginRequirement(kind: .capability, id: "studio.core.draw"),
            PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 2),
        ])

        let legacy = """
        { "id": "safe.reader", "version": 1, "name": "Reader", "description": "Legacy",
          "access": "read", "imports": [], "composable_host_capabilities": [] }
        """
        let legacyManifest = try PluginManifestValidator.decodeAndValidate(Data(legacy.utf8))
        #expect(legacyManifest.requires.isEmpty)
    }

    @Test("requirement validation rejects duplicates, self-reference, and malformed ids")
    func requirementValidation() throws {
        #expect(throws: PluginManifestValidationError.duplicateRequirement("studio.core")) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 1),
                PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 2),
            ]))
        }
        #expect(throws: PluginManifestValidationError.requirementOnSelf("studio.gizmo")) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .plugin, id: "studio.gizmo"),
            ]))
        }
        #expect(throws: PluginManifestValidationError.requirementOnSelf("studio.gizmo.draw")) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .capability, id: "studio.gizmo.draw"),
            ]))
        }
        #expect(throws: PluginManifestValidationError.invalidRequirement("Bogus")) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .plugin, id: "Bogus"),
            ]))
        }
        #expect(throws: PluginManifestValidationError.invalidRequirement("studio.core")) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 0),
            ]))
        }
        #expect(throws: PluginManifestValidationError.self) {
            try PluginManifestValidator.validate(manifest([
                PluginRequirement(kind: .capability, id: "Scene.Set"),
            ]))
        }

        // A well-formed requirement passes validation; existence is decided at
        // enable time, not by the manifest.
        try PluginManifestValidator.validate(manifest([
            PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 1),
            PluginRequirement(kind: .capability, id: "scene.set_name"),
            // A separately named nested plugin is not this plugin's WIT export.
            PluginRequirement(kind: .capability, id: "studio.gizmo.tools.inspect"),
        ]))
    }

    @Test("resolution fails closed on missing and outdated dependencies")
    func resolution() {
        let requirements = [
            PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 2),
            PluginRequirement(kind: .capability, id: "scene.set_name"),
            PluginRequirement(kind: .capability, id: "studio.core.draw", minimumVersion: 3),
        ]
        let satisfied = PluginRequirementResolver.unmet(
            requirements,
            requiredBy: "studio.gizmo",
            enabledPlugins: ["studio.core": 2],
            providedCapabilities: ["scene.set_name": 1, "studio.core.draw": 3]
        )
        #expect(satisfied.isEmpty)

        let unmet = PluginRequirementResolver.unmet(
            requirements,
            requiredBy: "studio.gizmo",
            enabledPlugins: ["studio.core": 1],
            providedCapabilities: ["studio.core.draw": 2]
        )
        #expect(unmet == [
            .pluginVersionTooLow(id: "studio.core", requiredBy: "studio.gizmo",
                                 minimumVersion: 2, actual: 1),
            .missingCapability(id: "scene.set_name", requiredBy: "studio.gizmo",
                               minimumVersion: nil),
            .capabilityVersionTooLow(id: "studio.core.draw", requiredBy: "studio.gizmo",
                                     minimumVersion: 3, actual: 2),
        ])

        let missing = PluginRequirementResolver.unmet(
            requirements,
            requiredBy: "studio.gizmo",
            enabledPlugins: [:],
            providedCapabilities: [:]
        )
        #expect(missing.count == 3)
        #expect(missing.first == .missingPlugin(id: "studio.core", requiredBy: "studio.gizmo",
                                                minimumVersion: 2))
    }

    @Test("dependents include plugin and exact capability requirements")
    func dependents() {
        let core = CovePluginManifest(id: "studio.core", version: 1, name: "Core",
                                       description: "d", access: .read)
        let gizmo = CovePluginManifest(
            id: "studio.gizmo", version: 1, name: "Gizmo", description: "d", access: .read,
            requires: [PluginRequirement(kind: .plugin, id: "studio.core")]
        )
        let palette = CovePluginManifest(
            id: "studio.palette", version: 1, name: "Palette", description: "d", access: .read,
            requires: [PluginRequirement(kind: .capability, id: "studio.core.draw")]
        )
        let dependents = PluginRequirementResolver.dependents(
            of: "studio.core",
            providing: ["studio.core.draw"],
            among: ["studio.core": core, "studio.gizmo": gizmo, "studio.palette": palette]
        )
        #expect(dependents == ["studio.gizmo", "studio.palette"])
        #expect(PluginRequirementResolver.dependents(
            of: "studio.core", providing: [], among: ["studio.palette": palette]
        ).isEmpty)
    }

    @Test("authorization binds requirements and rejects incomplete records")
    func authorizationBindsRequirements() throws {
        let base = inspection([])
        let extended = inspection([PluginRequirement(kind: .plugin, id: "studio.core")])

        let record = try PluginAuthorizationRecord(inspection: base)
        #expect(record.requires.isEmpty)
        #expect(record.isStillValid(for: base))
        #expect(!record.isStillValid(for: extended))

        let extendedRecord = try PluginAuthorizationRecord(inspection: extended)
        #expect(record.authorityDigest != extendedRecord.authorityDigest)
        #expect(extendedRecord.isStillValid(for: extended))

        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PluginAuthorizationRecord.self, from: encoded) == record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "requires")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PluginAuthorizationRecord.self, from: legacyData)
        }
    }

    @Test("registry construction rejects missing dependencies, version mismatches and cycles")
    func registryRequirements() throws {
        func binding(_ id: String, version: Int = 1,
                     requires: [PluginRequirement] = []) throws -> PluginExecutionBinding {
            let manifest = CovePluginManifest(id: id, version: version, name: id,
                description: "Fixture", access: .read, requires: requires)
            let contract = CapabilityContract(id: id + ".inspect", version: version,
                title: "Inspect", description: "Fixture", domain: "plugin", access: .read,
                releasePhase: .stable, inputSchema: .object(properties: [:]), source: .plugin(id))
            let inspection = PluginInspection(manifest: manifest, componentHash: "code",
                                             witHash: "wit", contracts: [contract])
            return try PluginExecutionBinding(pluginPath: "/" + id, inspection: inspection,
                authorization: PluginAuthorizationRecord(inspection: inspection), hostGeneration: 1)
        }
        let core = try binding("studio.core")
        let dependent = try binding("studio.gizmo", requires: [
            PluginRequirement(kind: .capability, id: "studio.core.inspect"),
        ])
        #expect(throws: UnmetPluginRequirements.self) {
            try PluginCapabilityRegistryBuilder.build(base: .default, bindings: [dependent])
        }
        let valid = try PluginCapabilityRegistryBuilder.build(base: .default, bindings: [dependent, core])
        #expect(valid.descriptor(for: "studio.gizmo.inspect") != nil)
        let outdated = try binding("studio.gizmo", requires: [
            PluginRequirement(kind: .plugin, id: "studio.core", minimumVersion: 2),
        ])
        #expect(throws: UnmetPluginRequirements.self) {
            try PluginCapabilityRegistryBuilder.build(base: .default, bindings: [core, outdated])
        }
        let cyclicCore = try binding("studio.core", requires: [
            PluginRequirement(kind: .plugin, id: "studio.gizmo"),
        ])
        #expect(throws: UnmetPluginRequirements.self) {
            try PluginCapabilityRegistryBuilder.build(base: .default, bindings: [dependent, cyclicCore])
        }
    }
}
