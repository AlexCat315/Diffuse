import Foundation

/// Compiler-captured source coordinates. fileID stays readable across machines;
/// filePath can be remapped by the Inspector when the app was built elsewhere.
public struct ComponentSourceLocation: Codable, Equatable, Sendable {
    public var fileID, filePath: String
    public var line, column: UInt
    public var explicit: Bool
    public init(fileID: String, filePath: String, line: UInt, column: UInt = 1, explicit: Bool = false) {
        self.fileID = fileID; self.filePath = filePath; self.line = line; self.column = column; self.explicit = explicit
    }
}

public struct RecompositionReason: Codable, Equatable, Sendable {
    public var kind: String
    public var detail: String?
    public var originScope: UInt64?
    public init(kind: String, detail: String? = nil, originScope: UInt64? = nil) {
        self.kind = String(kind.prefix(64)); self.detail = detail.map { String($0.prefix(160)) }; self.originScope = originScope
    }
}

/// Counts body evaluations, excluding the initial mount. Durations include body
/// evaluation and reconciliation, but exclude Yoga layout and GPU rendering.
public struct ComponentRecompositionMetrics: Sendable {
    public var count: UInt64 = 0
    public var initialMs: Double = 0
    public var lastMs: Double = 0
    public var totalMs: Double = 0
    public var maxMs: Double = 0
    public var lastReasons: [RecompositionReason] = []
    public init() {}
    public mutating func record(milliseconds: Double, initial: Bool, reasons: [RecompositionReason]) {
        let ms = milliseconds.isFinite ? max(0, milliseconds) : 0
        if initial { initialMs = ms; return }
        count &+= 1; lastMs = ms; totalMs += ms; maxMs = max(maxMs, ms)
        lastReasons = Array(reasons.prefix(16))
    }
    public mutating func reset() {
        let mount = initialMs; self = Self(); initialMs = mount
    }
}
