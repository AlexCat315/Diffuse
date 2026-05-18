import Foundation

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

    public init(capabilities: [CapabilityDescriptor] = []) {
        var byVerb: [String: CapabilityDescriptor] = [:]
        var aliasByVerb: [String: String] = [:]
        for cap in capabilities {
            byVerb[cap.verb] = cap
            for alias in cap.aliases {
                aliasByVerb[alias] = cap.verb
            }
        }
        self.byVerb = byVerb
        self.aliasByVerb = aliasByVerb
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

    /// Built-in registry matching all verbs handled by `IntentTransactionBuilder`.
    public static let `default`: CapabilityRegistry = {
        let editable = CapabilityPreconditionSpec(kind: .sceneEditable)
        let entityExists = CapabilityPreconditionSpec(kind: .entityExists)
        let selectionRequired = CapabilityPreconditionSpec(kind: .selectionRequired)

        return CapabilityRegistry(capabilities: [

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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "CameraComponent"),
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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "RigidBody"),
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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "RigidBody"),
                ]
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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "LightComponent"),
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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "LightComponent"),
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
                    CapabilityPreconditionSpec(kind: .entityHasComponent, componentType: "LightComponent"),
                ]
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
        ])
    }()
}
