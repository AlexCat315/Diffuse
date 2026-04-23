import Foundation

public enum IntentSource: String, Sendable, Equatable, Codable {
    case human
    case ai
    case system
}

public struct IntentIR: Sendable, Equatable, Codable {
    public var id: String
    public var verb: String
    public var summary: String
    public var targetObjectIDs: [String]
    public var source: IntentSource
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                verb: String,
                summary: String,
                targetObjectIDs: [String] = [],
                source: IntentSource,
                createdAt: Date = Date()) {
        self.id = id
        self.verb = verb
        self.summary = summary
        self.targetObjectIDs = targetObjectIDs
        self.source = source
        self.createdAt = createdAt
    }
}