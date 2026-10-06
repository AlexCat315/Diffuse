import Foundation

public struct SourceLocationPayload: Codable, Sendable {
    public var fileID, filePath: String
    public var line, column: UInt
    public init(fileID: String, filePath: String, line: UInt, column: UInt) {
        self.fileID = fileID; self.filePath = filePath; self.line = line; self.column = column
    }
}
public struct RecompositionReasonPayload: Codable, Sendable {
    public var kind: String
    public var detail, originScopeID: String?
    public init(kind: String, detail: String?, originScopeID: String?) {
        self.kind = kind; self.detail = detail; self.originScopeID = originScopeID
    }
}
public struct RecompositionPayload: Codable, Sendable {
    public var count: UInt64
    public var initialMs, lastMs, totalMs, maxMs: Double
    public var reasons: [RecompositionReasonPayload]
    public init(count: UInt64, initialMs: Double, lastMs: Double, totalMs: Double, maxMs: Double, reasons: [RecompositionReasonPayload]) {
        self.count = count; self.initialMs = initialMs; self.lastMs = lastMs
        self.totalMs = totalMs; self.maxMs = maxMs; self.reasons = reasons
    }
}
