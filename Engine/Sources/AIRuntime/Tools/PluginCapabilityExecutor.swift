import CapabilityRuntime
import Foundation
import IntentRuntime
import PluginRuntime
import SceneRuntime

public typealias PluginQuerySnapshotProvider = @Sendable (
    _ pluginID: String,
    _ sceneRevision: UInt64
) async throws -> PluginQuerySnapshot?

public enum PluginCapabilityExecutorError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicatePlugin(String)
    case unknownPlugin(String)
    case capabilityUnavailable(String)
    case authorityChanged(String)
    case staleSceneRevision(expected: UInt64, actual: UInt64)
    case resultKindMismatch(String)
    case invalidReadResult(String)
    case payloadTooLarge(String)
    case invalidInput(capabilityID: String, reason: String)

    public var description: String {
        switch self {
        case let .duplicatePlugin(id): return "plugin '\(id)' has more than one execution binding"
        case let .unknownPlugin(id): return "plugin '\(id)' is not enabled"
        case let .capabilityUnavailable(id): return "plugin capability '\(id)' is unavailable"
        case let .authorityChanged(id):
            return "plugin '\(id)' changed code, authorisation, or PluginHost generation"
        case let .staleSceneRevision(expected, actual):
            return "scene revision changed (expected \(expected), actual \(actual))"
        case let .resultKindMismatch(id): return "plugin capability '\(id)' returned the wrong result kind"
        case let .invalidReadResult(id): return "read capability '\(id)' returned invalid JSON"
        case let .payloadTooLarge(id): return "plugin capability '\(id)' exceeded the 1 MiB payload limit"
        case let .invalidInput(id, reason): return "invalid input for '\(id)': \(reason)"
        }
    }
}

/// Connects authorised plugin Components to the same model Draft and host-owned
/// transaction pipeline as built-in capabilities. A plugin write is expanded
/// only to validated built-in calls; it can never emit TransactionOperation.
public struct PluginCapabilityExecutor: Sendable {
    public let registry: CapabilityRegistry
    public let pluginAuthorities: [String: PluginCapabilityAuthority]

    private let hostRegistry: CapabilityRegistry
    private let bindings: [String: PluginExecutionBinding]
    private let invoker: any PluginCapabilityInvoking

    public init(hostRegistry: CapabilityRegistry = .aiDefault,
                bindings: [PluginExecutionBinding],
                invoker: any PluginCapabilityInvoking) throws {
        var byID: [String: PluginExecutionBinding] = [:]
        var authorities: [String: PluginCapabilityAuthority] = [:]
        for binding in bindings {
            guard byID.updateValue(binding, forKey: binding.pluginID) == nil else {
                throw PluginCapabilityExecutorError.duplicatePlugin(binding.pluginID)
            }
            try binding.validate(hostGeneration: invoker.generation)
            authorities[binding.pluginID] = binding.authority
        }
        self.hostRegistry = hostRegistry
        self.bindings = byID
        self.invoker = invoker
        self.pluginAuthorities = authorities
        self.registry = try PluginCapabilityRegistryBuilder.build(base: hostRegistry,
                                                                  bindings: bindings)
    }

    public var exposurePolicy: CapabilityExposurePolicy {
        CapabilityExposurePolicy(activeReleasePhase: .stable,
                                 allowedDomains: ["scene", "plugin"],
                                 enabledPluginIDs: Set(bindings.keys),
                                 maximumCapabilities: 16)
    }

    public func requiredImports(forPluginID pluginID: String) throws
        -> Set<PluginImportPermission> {
        guard let binding = bindings[pluginID] else {
            throw PluginCapabilityExecutorError.unknownPlugin(pluginID)
        }
        try ensureLive(binding)
        return Set(binding.inspection.manifest.imports)
    }

    /// Planner configured for both submit-time checks and the coordinator's
    /// second check immediately before applying a confirmed transaction.
    public func makeInvocationPlanner(
        gate: ReleasePhaseGate = ReleasePhaseGate(),
        allowExternalSideEffects: Bool = false
    ) -> CapabilityInvocationPlanner {
        let expectedBindings = bindings
        let liveInvoker = invoker
        return CapabilityInvocationPlanner(
            registry: registry,
            gate: gate,
            allowExternalSideEffects: allowExternalSideEffects,
            pluginAuthorities: pluginAuthorities,
            pluginAuthorityValidator: { authority in
                guard let binding = expectedBindings[authority.pluginID],
                      binding.authority == authority else { return false }
                return (try? binding.validate(hostGeneration: liveInvoker.generation)) != nil
            }
        )
    }

    /// Executes a read capability immediately after revalidating its exact
    /// snapshot authority. The returned JSON is untrusted model context only.
    public func executeRead(toolName: String,
                            input: Data,
                            snapshot: CapabilityExposureSnapshot,
                            currentSceneRevision: UInt64,
                            querySnapshot: PluginQuerySnapshot? = nil) throws -> Data {
        guard input.count <= CapabilityDraftLimits.maximumInputBytes else {
            throw PluginCapabilityExecutorError.payloadTooLarge(toolName)
        }
        guard snapshot.sceneRevision == nil
                || snapshot.sceneRevision == currentSceneRevision else {
            throw PluginCapabilityExecutorError.staleSceneRevision(
                expected: snapshot.sceneRevision ?? currentSceneRevision,
                actual: currentSceneRevision
            )
        }
        guard let contract = snapshot.contract(forToolName: toolName),
              contract.access == .read,
              let pluginID = contract.source.pluginID else {
            throw PluginCapabilityExecutorError.capabilityUnavailable(toolName)
        }
        let binding = try validatedBinding(pluginID: pluginID,
                                           contract: contract,
                                           snapshot: snapshot,
                                           draftAuthority: snapshot.authority(forPluginID: pluginID))
        try validateInput(input, contract: contract)
        try validateQuerySnapshot(querySnapshot,
                                  binding: binding,
                                  sceneRevision: currentSceneRevision)
        let result = try invoker.prepareCapability(binding: binding,
                                                   capabilityID: contract.id,
                                                   input: input,
                                                   querySnapshot: querySnapshot)
        try ensureLive(binding)
        guard case let .read(payload) = result else {
            throw PluginCapabilityExecutorError.resultKindMismatch(contract.id)
        }
        guard payload.count <= PluginResourceLimits.secureDefault.maximumOutputBytes else {
            throw PluginCapabilityExecutorError.payloadTooLarge(contract.id)
        }
        guard (try? JSONSerialization.jsonObject(with: payload,
                                                 options: [.fragmentsAllowed])) != nil else {
            throw PluginCapabilityExecutorError.invalidReadResult(contract.id)
        }
        return payload
    }

    /// Expands write Drafts in order, prepares all built-in operations against
    /// one shadow scene, and returns a transaction that records both the outer
    /// plugin invocation and every host primitive it composed.
    public func buildTransaction(
        summary: String,
        reasoning: String? = nil,
        drafts: [CapabilityInvocationDraft],
        snapshot: CapabilityExposureSnapshot,
        scene: SceneRuntime,
        currentSceneRevision: UInt64,
        querySnapshots: [String: PluginQuerySnapshot] = [:],
        approvalPolicy: TransactionApprovalPolicy = .requiresApproval
    ) throws -> TransactionIR {
        guard drafts.count <= CapabilityDraftLimits.maximumDraftsPerPlan else {
            throw CapabilityDraftError.tooManyDrafts
        }
        if let duplicate = Dictionary(grouping: drafts, by: \.id)
            .first(where: { $0.value.count > 1 })?.key {
            throw CapabilityDraftError.duplicateDraftID(duplicate)
        }
        guard snapshot.sceneRevision == nil
                || snapshot.sceneRevision == currentSceneRevision else {
            throw PluginCapabilityExecutorError.staleSceneRevision(
                expected: snapshot.sceneRevision ?? currentSceneRevision,
                actual: currentSceneRevision
            )
        }

        enum InvocationSegment {
            case builtIn(Int)
            case plugin(CapabilityInvocationRecord, Int)
        }
        var primitiveDrafts: [CapabilityInvocationDraft] = []
        var segments: [InvocationSegment] = []

        for draft in drafts {
            guard draft.snapshotID == snapshot.id else {
                throw PluginCapabilityExecutorError.capabilityUnavailable(draft.capabilityID)
            }
            guard draft.sceneRevision == currentSceneRevision else {
                throw PluginCapabilityExecutorError.staleSceneRevision(
                    expected: draft.sceneRevision,
                    actual: currentSceneRevision
                )
            }
            guard let exposed = snapshot.contract(id: draft.capabilityID),
                  exposed.version == draft.capabilityVersion,
                  exposed.schemaHash == draft.schemaHash,
                  exposed.source.pluginID == draft.sourcePluginID else {
                throw PluginCapabilityExecutorError.capabilityUnavailable(draft.capabilityID)
            }
            try validateInput(draft.validatedInput, contract: exposed)

            guard let pluginID = exposed.source.pluginID else {
                guard draft.pluginAuthority == nil else {
                    throw PluginCapabilityExecutorError.authorityChanged(draft.capabilityID)
                }
                primitiveDrafts.append(draft)
                segments.append(.builtIn(1))
                continue
            }
            guard exposed.access.isWrite else {
                throw PluginCapabilityExecutorError.resultKindMismatch(exposed.id)
            }
            let binding = try validatedBinding(pluginID: pluginID,
                                               contract: exposed,
                                               snapshot: snapshot,
                                               draftAuthority: draft.pluginAuthority)
            let querySnapshot = querySnapshots[pluginID]
            try validateQuerySnapshot(querySnapshot,
                                      binding: binding,
                                      sceneRevision: currentSceneRevision)
            let result = try invoker.prepareCapability(binding: binding,
                                                       capabilityID: exposed.id,
                                                       input: draft.validatedInput,
                                                       querySnapshot: querySnapshot)
            try ensureLive(binding)
            guard case let .hostCalls(rawCalls) = result else {
                throw PluginCapabilityExecutorError.resultKindMismatch(exposed.id)
            }
            let calls = try PluginCompositionValidator.validate(
                rawCalls,
                manifest: binding.inspection.manifest,
                registry: hostRegistry
            )
            let outerRecord = CapabilityInvocationRecord(
                capabilityID: exposed.id,
                capabilityVersion: exposed.version,
                schemaHash: exposed.schemaHash,
                sourcePluginID: pluginID,
                pluginAuthority: binding.authority,
                inputDigest: exposed.inputDigest(draft.validatedInput),
                argumentNames: topLevelArgumentNames(draft.validatedInput),
                targetReferences: sceneReferences(in: draft.validatedInput),
                access: exposed.access,
                exposureSnapshotID: snapshot.id
            )
            segments.append(.plugin(outerRecord, calls.count))
            for call in calls {
                guard let primitive = hostRegistry.descriptor(for: call.capabilityID)?.contract else {
                    throw PluginCapabilityExecutorError.capabilityUnavailable(call.capabilityID)
                }
                let canonicalArguments = try canonicalObject(call.arguments,
                                                             capabilityID: call.capabilityID)
                primitiveDrafts.append(CapabilityInvocationDraft(
                    capabilityID: primitive.id,
                    capabilityVersion: primitive.version,
                    schemaHash: primitive.schemaHash,
                    validatedInput: canonicalArguments,
                    snapshotID: snapshot.id,
                    sceneRevision: currentSceneRevision,
                    createdAt: draft.createdAt
                ))
            }
        }

        if primitiveDrafts.isEmpty {
            return TransactionIR(summary: summary,
                                 operations: [],
                                 baseRevisions: TransactionBaseRevisions(
                                    sceneRevision: currentSceneRevision
                                 ),
                                 approvalPolicy: approvalPolicy,
                                 provenance: .proposal)
        }

        let plan = try SceneCapabilityDraftLowering.plan(summary: summary,
                                                         reasoning: reasoning,
                                                         drafts: primitiveDrafts)
        var primitiveContractsByID: [String: CapabilityContract] = [:]
        for draft in primitiveDrafts {
            if let contract = hostRegistry.descriptor(for: draft.capabilityID)?.contract {
                primitiveContractsByID[draft.capabilityID] = contract
            }
        }
        let primitiveContracts = Array(primitiveContractsByID.values)
        let primitiveSnapshot = CapabilityExposureSnapshot(
            id: snapshot.id,
            generation: snapshot.generation,
            sceneRevision: currentSceneRevision,
            contracts: primitiveContracts,
            createdAt: snapshot.createdAt
        )
        var transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            baseSceneRevision: currentSceneRevision,
            approvalPolicy: approvalPolicy,
            exposureSnapshot: primitiveSnapshot,
            registry: hostRegistry
        )

        var primitiveIndex = 0
        var invocationRecords: [CapabilityInvocationRecord] = []
        for segment in segments {
            let count: Int
            switch segment {
            case let .builtIn(value):
                count = value
            case let .plugin(outer, value):
                invocationRecords.append(outer)
                count = value
            }
            let end = primitiveIndex + count
            guard end <= transaction.capabilityInvocations.count else {
                throw PluginCapabilityExecutorError.capabilityUnavailable("host preparation records")
            }
            invocationRecords.append(contentsOf: transaction.capabilityInvocations[primitiveIndex..<end])
            primitiveIndex = end
        }
        guard primitiveIndex == transaction.capabilityInvocations.count else {
            throw PluginCapabilityExecutorError.capabilityUnavailable("host preparation records")
        }
        transaction.capabilityInvocations = invocationRecords
        return transaction
    }

    private func validatedBinding(pluginID: String,
                                  contract: CapabilityContract,
                                  snapshot: CapabilityExposureSnapshot,
                                  draftAuthority: PluginCapabilityAuthority?) throws
        -> PluginExecutionBinding {
        guard let binding = bindings[pluginID] else {
            throw PluginCapabilityExecutorError.unknownPlugin(pluginID)
        }
        guard let current = registry.descriptor(for: contract.id)?.contract,
              current == contract,
              binding.inspection.contracts.contains(contract),
              snapshot.authority(forPluginID: pluginID) == binding.authority,
              draftAuthority == binding.authority else {
            throw PluginCapabilityExecutorError.authorityChanged(pluginID)
        }
        do {
            try binding.validate(hostGeneration: invoker.generation)
        } catch {
            throw PluginCapabilityExecutorError.authorityChanged(pluginID)
        }
        return binding
    }

    private func validateInput(_ input: Data,
                               contract: CapabilityContract) throws {
        guard input.count <= CapabilityDraftLimits.maximumInputBytes else {
            throw PluginCapabilityExecutorError.payloadTooLarge(contract.id)
        }
        do {
            try JSONSchemaValidator.validate(data: input, against: contract.inputSchema)
        } catch {
            throw PluginCapabilityExecutorError.invalidInput(
                capabilityID: contract.id,
                reason: String(describing: error)
            )
        }
    }

    private func ensureLive(_ binding: PluginExecutionBinding) throws {
        do {
            try binding.validate(hostGeneration: invoker.generation)
        } catch {
            throw PluginCapabilityExecutorError.authorityChanged(binding.pluginID)
        }
    }

    private func validateQuerySnapshot(_ querySnapshot: PluginQuerySnapshot?,
                                       binding: PluginExecutionBinding,
                                       sceneRevision: UInt64) throws {
        let imports = Set(binding.inspection.manifest.imports)
        if let querySnapshot {
            guard querySnapshot.sceneRevision == sceneRevision else {
                throw PluginCapabilityExecutorError.staleSceneRevision(
                    expected: querySnapshot.sceneRevision,
                    actual: sceneRevision
                )
            }
            try querySnapshot.validate(for: imports)
        } else if !imports.isEmpty {
            throw PluginQuerySnapshotError.missingPayload(imports.sorted {
                $0.rawValue < $1.rawValue
            }[0])
        }
    }

    private func canonicalObject(_ data: Data,
                                 capabilityID: String) throws -> Data {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else {
                throw PluginCapabilityExecutorError.invalidInput(
                    capabilityID: capabilityID,
                    reason: "arguments must be an object"
                )
            }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch let error as PluginCapabilityExecutorError {
            throw error
        } catch {
            throw PluginCapabilityExecutorError.invalidInput(
                capabilityID: capabilityID,
                reason: String(describing: error)
            )
        }
    }

    private func topLevelArgumentNames(_ data: Data) -> [String] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?
            .keys.sorted() ?? []
    }

    private func sceneReferences(in data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var references: Set<String> = []
        func visit(_ value: Any) {
            if let string = value as? String,
               string.hasPrefix("scene:"),
               UInt64(string.dropFirst("scene:".count)) != nil {
                references.insert(string)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(visit)
            }
        }
        visit(object)
        return references.sorted()
    }
}
