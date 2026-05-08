import Foundation

public struct WorldRevisionSnapshot: Sendable, Equatable, Codable {
    public var sceneRevision: UInt64?
    public var sequenceRevisionID: String?

    public init(sceneRevision: UInt64? = nil, sequenceRevisionID: String? = nil) {
        self.sceneRevision = sceneRevision
        self.sequenceRevisionID = sequenceRevisionID
    }
}

public enum EditAuthorKind: String, Sendable, Equatable, Codable {
    case human
    case ai
    case system
}

public struct CorrectionDelta: Sendable, Equatable, Codable {
    public var originalProposalID: String
    public var wasPartialAccept: Bool

    public init(originalProposalID: String, wasPartialAccept: Bool) {
        self.originalProposalID = originalProposalID
        self.wasPartialAccept = wasPartialAccept
    }
}

public struct EditProvenance: Sendable, Equatable, Codable {
    public var authorKind: EditAuthorKind
    public var sessionID: String?
    public var proposalID: String?
    public var correctionDelta: CorrectionDelta?
    public var timestamp: Date

    public init(authorKind: EditAuthorKind,
                sessionID: String? = nil,
                proposalID: String? = nil,
                correctionDelta: CorrectionDelta? = nil,
                timestamp: Date = Date()) {
        self.authorKind = authorKind
        self.sessionID = sessionID
        self.proposalID = proposalID
        self.correctionDelta = correctionDelta
        self.timestamp = timestamp
    }
}

/// An applied World change — the atomic unit of training data and audit history.
///
/// Every successful `TransactionExecutor.apply()` produces one Edit. The edit log
/// at `<project>/.guava/edit_log.jsonl` is the append-only stream of these records.
public struct Edit: Sendable, Equatable, Codable {
    public var id: String
    public var transactionID: String
    public var summary: String
    public var mutationSummaries: [String]
    public var changedDomains: [String]
    public var provenance: EditProvenance
    public var revisionBefore: WorldRevisionSnapshot
    public var revisionAfter: WorldRevisionSnapshot

    public init(id: String = UUID().uuidString,
                transactionID: String,
                summary: String,
                mutationSummaries: [String],
                changedDomains: [String],
                provenance: EditProvenance,
                revisionBefore: WorldRevisionSnapshot,
                revisionAfter: WorldRevisionSnapshot) {
        self.id = id
        self.transactionID = transactionID
        self.summary = summary
        self.mutationSummaries = mutationSummaries
        self.changedDomains = changedDomains
        self.provenance = provenance
        self.revisionBefore = revisionBefore
        self.revisionAfter = revisionAfter
    }
}

extension TransactionProvenance {
    var editAuthorKind: EditAuthorKind {
        switch self {
        case .authored: return .human
        case .proposal: return .ai
        case .inferred, .baked: return .system
        }
    }
}
