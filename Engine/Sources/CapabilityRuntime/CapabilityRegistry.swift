import Foundation

public enum CapabilityRegistryIntegrityError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateCapability(String, version: Int)
    case aliasCollision(String)
    case toolNameCollision(String)

    public var description: String {
        switch self {
        case let .duplicateCapability(id, version): return "duplicate capability \(id) v\(version)"
        case let .aliasCollision(alias): return "capability alias collision: \(alias)"
        case let .toolNameCollision(name): return "provider tool-name collision: \(name)"
        }
    }
}

/// Immutable registry of all capabilities known to the system.
///
/// Look up a descriptor by primary verb or by alias. The built-in registry
/// (`CapabilityRegistry.default`) covers every verb that
/// `IntentTransactionBuilder` handles. Callers can extend it via
/// `merging(_:)` to add domain-specific or experimental verbs.
public struct CapabilityRegistry: Sendable {
    // Primary verb to descriptor.
    private let byVerb: [String: CapabilityDescriptor]
    // Alias to primary verb (allows secondary lookup).
    private let aliasByVerb: [String: String]
    public let integrityErrors: [CapabilityRegistryIntegrityError]

    public init(capabilities: [CapabilityDescriptor] = []) {
        var byVerb: [String: CapabilityDescriptor] = [:]
        var aliasByVerb: [String: String] = [:]
        var integrityErrors: [CapabilityRegistryIntegrityError] = []
        for cap in capabilities {
            if let existing = byVerb[cap.verb] {
                integrityErrors.append(.duplicateCapability(cap.verb, version: existing.version))
                continue
            }
            if aliasByVerb[cap.verb] != nil {
                integrityErrors.append(.aliasCollision(cap.verb))
                continue
            }
            byVerb[cap.verb] = cap
            for alias in cap.aliases {
                if byVerb[alias] != nil || aliasByVerb[alias] != nil {
                    integrityErrors.append(.aliasCollision(alias))
                    continue
                }
                aliasByVerb[alias] = cap.verb
            }
        }
        let toolGroups = Dictionary(grouping: byVerb.values, by: { $0.contract.toolName })
        integrityErrors.append(contentsOf: toolGroups.compactMap { name, descriptors in
            descriptors.count > 1 ? .toolNameCollision(name) : nil
        })
        self.byVerb = byVerb
        self.aliasByVerb = aliasByVerb
        self.integrityErrors = integrityErrors
    }

    // MARK: - Lookup

    /// Returns the descriptor for `verb`, resolving aliases.
    public func descriptor(for verb: String) -> CapabilityDescriptor? {
        if let cap = byVerb[verb] { return cap }
        if let primary = aliasByVerb[verb] { return byVerb[primary] }
        return nil
    }

    /// All registered primary verbs, sorted.
    public func allVerbs() -> [String] {
        byVerb.keys.sorted()
    }

    /// All provider-neutral contracts, sorted by capability id.
    public func allContracts() -> [CapabilityContract] {
        byVerb.values.map(\.contract).sorted { $0.id < $1.id }
    }

    public func validateIntegrity() throws {
        if let first = integrityErrors.first { throw first }
    }

    /// Builds a fail-closed model exposure allow-list. Plugin capabilities are
    /// absent until their plugin id is explicitly enabled, and external effects
    /// are absent unless the caller opts in.
    public func exposureSnapshot(policy: CapabilityExposurePolicy = CapabilityExposurePolicy(),
                                 sceneRevision: UInt64? = nil,
                                 generation: UInt64 = 0,
                                 preferredCapabilityIDs: [String] = [],
                                 includedCapabilityIDs: Set<String>? = nil) -> CapabilityExposureSnapshot {
        guard integrityErrors.isEmpty else {
            return CapabilityExposureSnapshot(generation: generation,
                                              sceneRevision: sceneRevision,
                                              contracts: [])
        }
        let gate = ReleasePhaseGate(activePhase: policy.activeReleasePhase)
        var allowed = byVerb.values.filter { descriptor in
            guard descriptor.isAIExposed else { return false }
            if descriptor.access.isWrite && !descriptor.inputSchema.isStrictCapabilityInput { return false }
            if let includedCapabilityIDs, !includedCapabilityIDs.contains(descriptor.verb) { return false }
            guard gate.isAllowed(descriptor) else { return false }
            if let domains = policy.allowedDomains, !domains.contains(descriptor.domain) { return false }
            if descriptor.access == .externalSideEffect && !policy.allowExternalSideEffects { return false }
            if descriptor.source.kind == .plugin {
                guard let pluginID = descriptor.source.pluginID,
                      policy.enabledPluginIDs.contains(pluginID) else { return false }
            }
            return true
        }

        var preferredOrder: [String: Int] = [:]
        for (offset, capabilityID) in preferredCapabilityIDs.enumerated()
            where preferredOrder[capabilityID] == nil {
            preferredOrder[capabilityID] = offset
        }
        allowed.sort { lhs, rhs in
            switch (preferredOrder[lhs.verb], preferredOrder[rhs.verb]) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.verb < rhs.verb
            }
        }
        let contracts = allowed.prefix(policy.maximumCapabilities).map(\.contract)
        return CapabilityExposureSnapshot(generation: generation,
                                          sceneRevision: sceneRevision,
                                          contracts: contracts)
    }

    /// Searches only capabilities permitted by `policy`. Search results are
    /// contracts, never executable closures or scene runtime handles.
    public func searchContracts(query: String,
                                policy: CapabilityExposurePolicy = CapabilityExposurePolicy(),
                                limit: Int = 16) -> [CapabilityContract] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let snapshot = exposureSnapshot(
            policy: CapabilityExposurePolicy(activeReleasePhase: policy.activeReleasePhase,
                                             allowedDomains: policy.allowedDomains,
                                             enabledPluginIDs: policy.enabledPluginIDs,
                                             allowExternalSideEffects: policy.allowExternalSideEffects,
                                             maximumCapabilities: max(limit, allVerbs().count))
        )
        return snapshot.contracts.filter { contract in
            needle.isEmpty
                || contract.id.lowercased().contains(needle)
                || contract.title.lowercased().contains(needle)
                || contract.description.lowercased().contains(needle)
        }.prefix(max(0, limit)).map { $0 }
    }

    // MARK: - Composition

    /// Returns a new registry with `other`'s capabilities merged in.
    /// Descriptors in `other` override same-verb entries in `self`.
    public func merging(_ other: CapabilityRegistry) -> CapabilityRegistry {
        var merged = byVerb
        for descriptor in other.byVerb.values {
            merged[descriptor.verb] = descriptor
        }
        return CapabilityRegistry(capabilities: merged.values.sorted { $0.verb < $1.verb })
    }

    // MARK: - Built-in registry

    /// Built-in registry covering all verbs in the AI edit plan pipeline and the UI intent path.
    public static let `default`: CapabilityRegistry = {
        let editable = CapabilityPreconditionSpec(kind: .sceneEditable)
        let entityExists = CapabilityPreconditionSpec(kind: .entityExists)
        let selectionRequired = CapabilityPreconditionSpec(kind: .selectionRequired)
        let rigidBody = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "RigidBody")
        let collider = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "Collider")
        let constraint = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "Constraint")
        let light = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "LightComponent")
        let camera = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "CameraComponent")
        let renderMesh = CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "RenderMeshComponent")

        let descriptors = [

            // MARK: AI framework
            CapabilityDescriptor(
                verb: "system.search_capabilities",
                releasePhase: .stable,
                domain: "system",
                access: .read
            ),
            CapabilityDescriptor(
                verb: "system.submit_plan",
                releasePhase: .stable,
                domain: "system",
                access: .read
            ),

            // MARK: Read-only AI context
            CapabilityDescriptor(
                verb: "scene.get_entities",
                releasePhase: .stable,
                domain: "scene",
                access: .read
            ),
            CapabilityDescriptor(
                verb: "scene.get_selection",
                releasePhase: .stable,
                domain: "scene",
                access: .read
            ),
            CapabilityDescriptor(
                verb: "scene.find_entities",
                releasePhase: .stable,
                domain: "scene",
                access: .read
            ),

            // MARK: Spawn / create
            CapabilityDescriptor(
                verb: "scene.spawn_entity",
                aliases: ["scene.create_instance"],
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable]
            ),

            // MARK: Rename
            CapabilityDescriptor(
                verb: "scene.set_name",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    CapabilityPreconditionSpec(kind: .argumentPresent, argumentName: "name"),
                ]
            ),

            // MARK: Duplicate
            CapabilityDescriptor(
                verb: "scene.duplicate_entity",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Reparent
            CapabilityDescriptor(
                verb: "scene.reparent_entity",
                aliases: ["scene.move_entity"],
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Delete
            CapabilityDescriptor(
                verb: "scene.delete_entity",
                aliases: ["scene.delete_instance"],
                releasePhase: .stable,
                requiresConfirmation: true,
                isDestructive: true,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Transform
            CapabilityDescriptor(
                verb: "scene.set_transform",
                aliases: ["scene.set_local_transform"],
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Snap to ground
            CapabilityDescriptor(
                verb: "scene.snap_to_ground",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Camera
            CapabilityDescriptor(
                verb: "scene.set_camera_pose",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    camera,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_camera_fov",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    camera,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_camera_aspect_ratio",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    camera,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_camera_active",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    camera,
                ]
            ),

            // MARK: Rigid body (beta: physics authoring not yet fully exposed in Editor)
            CapabilityDescriptor(
                verb: "scene.set_rigid_body_motion_type",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    rigidBody,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_rigid_body_mass",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    rigidBody,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_rigid_body_gravity_scale",
                aliases: ["scene.set_rigidbody_gravity_scale", "scene.set_rigidbody_gravity"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, rigidBody]
            ),
            CapabilityDescriptor(
                verb: "scene.set_rigid_body_allow_sleep",
                aliases: ["scene.set_rigidbody_allow_sleep"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, rigidBody]
            ),

            // MARK: Collider
            CapabilityDescriptor(
                verb: "scene.set_collider",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_trigger",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_shape",
                aliases: ["scene.set_collider_shape_type"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_box_extents",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_sphere_radius",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_capsule",
                aliases: ["scene.set_collider_capsule_radius", "scene.set_collider_capsule_half_height"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_material",
                aliases: ["scene.set_collider_friction", "scene.set_collider_restitution", "scene.set_collider_density"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_collider_layer",
                aliases: ["scene.set_collider_layer_mask"],
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, collider]
            ),
            CapabilityDescriptor(
                verb: "scene.set_constraint_enabled",
                releasePhase: .beta,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, constraint]
            ),

            // MARK: Light
            CapabilityDescriptor(
                verb: "scene.set_light_type",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    light,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_color",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    light,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_intensity",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [
                    editable,
                    entityExists,
                    light,
                ]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_range",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, light]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_spot_inner_angle",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, light]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_spot_angles",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, light]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_spot_outer_angle",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, light]
            ),
            CapabilityDescriptor(
                verb: "scene.set_light_cast_shadows",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, light]
            ),

            // MARK: Render/script/audio
            CapabilityDescriptor(
                verb: "scene.set_mesh_color",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, renderMesh]
            ),
            CapabilityDescriptor(
                verb: "scene.set_material",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, renderMesh]
            ),
            CapabilityDescriptor(
                verb: "scene.set_script_bindings",
                aliases: ["scene.set_script_enabled", "scene.set_script_parameters"],
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),
            CapabilityDescriptor(
                verb: "scene.set_script_property",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),
            CapabilityDescriptor(
                verb: "scene.set_audio_source",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Mesh visibility
            CapabilityDescriptor(
                verb: "scene.set_mesh_visibility",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists, renderMesh]
            ),

            // MARK: Animation
            CapabilityDescriptor(
                verb: "scene.set_animation_player",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "scene",
                preconditions: [editable, entityExists]
            ),

            // MARK: Sequence
            CapabilityDescriptor(
                verb: "sequence.replace_document",
                releasePhase: .beta,
                requiresConfirmation: true,
                isDestructive: true,
                domain: "sequence",
                preconditions: []
            ),

            // MARK: Asset
            CapabilityDescriptor(
                verb: "asset.scan_project",
                releasePhase: .stable,
                requiresConfirmation: false,
                isDestructive: false,
                domain: "asset",
                preconditions: [
                    CapabilityPreconditionSpec(kind: .argumentPresent, argumentName: "root_path"),
                ]
            ),
        ]
        return CapabilityRegistry(capabilities: descriptors.map(BuiltInCapabilityCatalog.enrich))
    }()
}
