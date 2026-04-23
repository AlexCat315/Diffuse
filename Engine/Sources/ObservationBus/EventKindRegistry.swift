import Foundation

public enum EventDomain: String, Sendable, Equatable, Codable {
    case project
    case scene
    case sequence
    case model
    case asset
    case transaction
    case diagnostics
    case ui
    case runtime
}

public enum EventPayloadSchemaID: String, Sendable, Equatable, Codable {
    case transactionLifecycle = "transaction_lifecycle"
    case sceneChanged = "scene_changed"
    case sceneEntityChanged = "scene_entity_changed"
    case sequenceChanged = "sequence_changed"
    case assetImportFinished = "asset_import_finished"
    case diagnosticsWarningRaised = "diagnostics_warning_raised"
    case selectionChanged = "selection_changed"
    case confirmationRequested = "confirmation_requested"
    case confirmationResolved = "confirmation_resolved"
    case runtimeTick = "runtime_tick"
    case runtimeMetricSampled = "runtime_metric_sampled"
}

public enum EventCardinality: String, Sendable, Equatable, Codable {
    case perTick = "per_tick"
    case perChange = "per_change"
    case perBatch = "per_batch"
}

public enum EventOrdering: String, Sendable, Equatable, Codable {
    case perAggregate = "per_aggregate"
    case perStream = "per_stream"
    case none
}

public enum EventRetentionClass: String, Sendable, Equatable, Codable {
    case hot
    case warm
    case cold
    case ephemeral
}

public enum EventCoalesceReducer: String, Sendable, Equatable, Codable {
    case keepLast = "keep_last"
    case mergeSet = "merge_set"
    case sum
    case unionDiff = "union_diff"
}

public struct EventCoalesceHint: Sendable, Equatable, Codable {
    public var keyFields: [String]
    public var reducer: EventCoalesceReducer

    public init(keyFields: [String], reducer: EventCoalesceReducer) {
        self.keyFields = keyFields
        self.reducer = reducer
    }
}

public enum EventKindID: String, CaseIterable, Sendable, Equatable, Codable {
    case sceneChanged = "scene.changed"
    case sceneEntityAdded = "scene.entity.added"
    case sceneEntityRemoved = "scene.entity.removed"
    case sequenceChanged = "sequence.changed"
    case assetImportFinished = "asset.import.finished"
    case transactionStaged = "transaction.staged"
    case transactionApplied = "transaction.applied"
    case transactionDiscarded = "transaction.discarded"
    case transactionFailed = "transaction.failed"
    case diagnosticsWarningRaised = "diagnostics.warning.raised"
    case selectionChanged = "selection.changed"
    case confirmationRequested = "ui.confirmation.requested"
    case confirmationResolved = "ui.confirmation.resolved"
    case runtimeTick = "runtime.tick"
    case runtimeMetricSampled = "runtime.metric.sampled"
}

public struct EventKindSpec: Sendable, Equatable, Codable {
    public var id: EventKindID
    public var domain: EventDomain
    public var payloadSchema: EventPayloadSchemaID
    public var cardinality: EventCardinality
    public var ordering: EventOrdering
    public var redactInPrompt: Bool
    public var retention: EventRetentionClass
    public var replayable: Bool
    public var crossProcessAllowed: Bool
    public var coalesceHint: EventCoalesceHint?
    public var addedIn: String
    public var deprecatedIn: String?

    public init(id: EventKindID,
                domain: EventDomain,
                payloadSchema: EventPayloadSchemaID,
                cardinality: EventCardinality,
                ordering: EventOrdering,
                redactInPrompt: Bool,
                retention: EventRetentionClass,
                replayable: Bool,
                crossProcessAllowed: Bool,
                coalesceHint: EventCoalesceHint? = nil,
                addedIn: String = "0.1.0",
                deprecatedIn: String? = nil) {
        self.id = id
        self.domain = domain
        self.payloadSchema = payloadSchema
        self.cardinality = cardinality
        self.ordering = ordering
        self.redactInPrompt = redactInPrompt
        self.retention = retention
        self.replayable = replayable
        self.crossProcessAllowed = crossProcessAllowed
        self.coalesceHint = coalesceHint
        self.addedIn = addedIn
        self.deprecatedIn = deprecatedIn
    }
}

public struct EventKindRegistry: Sendable {
    private let specs: [EventKindID: EventKindSpec]

    public static let `default` = EventKindRegistry(specs: Self.defaultSpecs())

    public init(specs: [EventKindID: EventKindSpec]) {
        self.specs = specs
    }

    public func spec(for kind: EventKindID) -> EventKindSpec {
        guard let spec = specs[kind] else {
            preconditionFailure("missing EventKindSpec for \(kind.rawValue)")
        }
        return spec
    }

    public func contains(_ kind: EventKindID) -> Bool {
        specs[kind] != nil
    }

    private static func defaultSpecs() -> [EventKindID: EventKindSpec] {
        [
            .sceneChanged: EventKindSpec(
                id: .sceneChanged,
                domain: .scene,
                payloadSchema: .sceneChanged,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true,
                coalesceHint: EventCoalesceHint(keyFields: ["entity_ids"], reducer: .keepLast)
            ),
            .sceneEntityAdded: EventKindSpec(
                id: .sceneEntityAdded,
                domain: .scene,
                payloadSchema: .sceneEntityChanged,
                cardinality: .perBatch,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .sceneEntityRemoved: EventKindSpec(
                id: .sceneEntityRemoved,
                domain: .scene,
                payloadSchema: .sceneEntityChanged,
                cardinality: .perBatch,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .sequenceChanged: EventKindSpec(
                id: .sequenceChanged,
                domain: .sequence,
                payloadSchema: .sequenceChanged,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .assetImportFinished: EventKindSpec(
                id: .assetImportFinished,
                domain: .asset,
                payloadSchema: .assetImportFinished,
                cardinality: .perBatch,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .warm,
                replayable: true,
                crossProcessAllowed: true
            ),
            .transactionStaged: EventKindSpec(
                id: .transactionStaged,
                domain: .transaction,
                payloadSchema: .transactionLifecycle,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .transactionApplied: EventKindSpec(
                id: .transactionApplied,
                domain: .transaction,
                payloadSchema: .transactionLifecycle,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .transactionDiscarded: EventKindSpec(
                id: .transactionDiscarded,
                domain: .transaction,
                payloadSchema: .transactionLifecycle,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .transactionFailed: EventKindSpec(
                id: .transactionFailed,
                domain: .transaction,
                payloadSchema: .transactionLifecycle,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .hot,
                replayable: true,
                crossProcessAllowed: true
            ),
            .diagnosticsWarningRaised: EventKindSpec(
                id: .diagnosticsWarningRaised,
                domain: .diagnostics,
                payloadSchema: .diagnosticsWarningRaised,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: false,
                retention: .warm,
                replayable: true,
                crossProcessAllowed: true
            ),
            .selectionChanged: EventKindSpec(
                id: .selectionChanged,
                domain: .ui,
                payloadSchema: .selectionChanged,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: true,
                retention: .ephemeral,
                replayable: false,
                crossProcessAllowed: true,
                coalesceHint: EventCoalesceHint(keyFields: ["entity_id"], reducer: .keepLast)
            ),
            .confirmationRequested: EventKindSpec(
                id: .confirmationRequested,
                domain: .ui,
                payloadSchema: .confirmationRequested,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: true,
                retention: .warm,
                replayable: true,
                crossProcessAllowed: true
            ),
            .confirmationResolved: EventKindSpec(
                id: .confirmationResolved,
                domain: .ui,
                payloadSchema: .confirmationResolved,
                cardinality: .perChange,
                ordering: .perStream,
                redactInPrompt: true,
                retention: .warm,
                replayable: true,
                crossProcessAllowed: true
            ),
            .runtimeTick: EventKindSpec(
                id: .runtimeTick,
                domain: .runtime,
                payloadSchema: .runtimeTick,
                cardinality: .perTick,
                ordering: .perStream,
                redactInPrompt: true,
                retention: .ephemeral,
                replayable: false,
                crossProcessAllowed: false
            ),
            .runtimeMetricSampled: EventKindSpec(
                id: .runtimeMetricSampled,
                domain: .runtime,
                payloadSchema: .runtimeMetricSampled,
                cardinality: .perBatch,
                ordering: .perStream,
                redactInPrompt: true,
                retention: .cold,
                replayable: true,
                crossProcessAllowed: true
            ),
        ]
    }
}