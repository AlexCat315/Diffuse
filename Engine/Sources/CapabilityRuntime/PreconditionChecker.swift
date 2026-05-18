import Foundation

/// Snapshot of the runtime state needed to evaluate capability preconditions.
/// Assembled by the caller (e.g. the Editor's AI coordinator) before invoking
/// `PreconditionChecker.check`.
public struct PreconditionCheckInput: Sendable {
    /// The intent verb being validated (for error messages).
    public var verb: String
    /// Argument keys present in the IntentIR.
    public var argumentNames: Set<String>
    /// Entity IDs parsed from `IntentIR.targetObjectIDs` (e.g. `"scene:42"` to 42).
    public var targetEntityIDs: [UInt64]
    /// The editor's currently selected entity, if any.
    public var selectedEntityID: UInt64?
    /// All entity IDs that currently exist in the live scene.
    public var sceneEntityIDs: Set<UInt64>
    /// Component type names currently attached to known scene entities.
    public var componentTypesByEntityID: [UInt64: Set<String>]
    /// False when the scene is locked (e.g. during playback or a conflicting transaction).
    public var isSceneEditable: Bool

    public init(verb: String,
                argumentNames: Set<String> = [],
                targetEntityIDs: [UInt64] = [],
                selectedEntityID: UInt64? = nil,
                sceneEntityIDs: Set<UInt64> = [],
                componentTypesByEntityID: [UInt64: Set<String>] = [:],
                isSceneEditable: Bool = true) {
        self.verb = verb
        self.argumentNames = argumentNames
        self.targetEntityIDs = targetEntityIDs
        self.selectedEntityID = selectedEntityID
        self.sceneEntityIDs = sceneEntityIDs
        self.componentTypesByEntityID = componentTypesByEntityID
        self.isSceneEditable = isSceneEditable
    }
}

/// A single precondition that was not satisfied.
public struct PreconditionViolation: Sendable, Equatable {
    public var kind: CapabilityPreconditionSpec.Kind
    public var detail: String

    public init(kind: CapabilityPreconditionSpec.Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

/// Evaluates a list of `CapabilityPreconditionSpec`s against a
/// `PreconditionCheckInput`, returning every violation found (not just the
/// first).  The caller decides whether any violations are fatal.
public struct PreconditionChecker: Sendable {
    public init() {}

    public func check(preconditions: [CapabilityPreconditionSpec],
                      input: PreconditionCheckInput) -> [PreconditionViolation] {
        preconditions.compactMap { spec in evaluate(spec, input: input) }
    }

    // MARK: - Individual checks

    private func evaluate(_ spec: CapabilityPreconditionSpec,
                          input: PreconditionCheckInput) -> PreconditionViolation? {
        switch spec.kind {

        case .entityExists:
            let effectiveID = input.targetEntityIDs.first ?? input.selectedEntityID
            guard let id = effectiveID, input.sceneEntityIDs.contains(id) else {
                return PreconditionViolation(
                    kind: .entityExists,
                    detail: "target entity does not exist in the scene"
                )
            }
            return nil

        case .selectionRequired:
            guard !input.targetEntityIDs.isEmpty || input.selectedEntityID != nil else {
                return PreconditionViolation(
                    kind: .selectionRequired,
                    detail: "'\(input.verb)' requires a target entity but none is selected or specified"
                )
            }
            return nil

        case .argumentPresent:
            let name = spec.argumentName ?? "<unknown>"
            guard input.argumentNames.contains(name) else {
                return PreconditionViolation(
                    kind: .argumentPresent,
                    detail: "required argument '\(name)' is missing from the intent"
                )
            }
            return nil

        case .sceneEditable:
            guard input.isSceneEditable else {
                return PreconditionViolation(
                    kind: .sceneEditable,
                    detail: "the scene is not editable (locked during playback or a conflicting transaction)"
                )
            }
            return nil

        case .entityHasComponent:
            let componentType = spec.componentType ?? "<unknown>"
            guard componentType != "<unknown>" else {
                return PreconditionViolation(
                    kind: .entityHasComponent,
                    detail: "required component type is not specified"
                )
            }
            let effectiveID = input.targetEntityIDs.first ?? input.selectedEntityID
            guard let id = effectiveID, input.sceneEntityIDs.contains(id) else {
                return PreconditionViolation(
                    kind: .entityHasComponent,
                    detail: "cannot verify required component '\(componentType)' without an existing target entity"
                )
            }
            guard input.componentTypesByEntityID[id]?.contains(componentType) == true else {
                return PreconditionViolation(
                    kind: .entityHasComponent,
                    detail: "target entity \(id) is missing required component '\(componentType)'"
                )
            }
            return nil
        }
    }
}
