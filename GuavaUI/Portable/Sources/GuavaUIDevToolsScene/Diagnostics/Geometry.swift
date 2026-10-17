public import Foundation
public import GuavaUIDevToolsProtocol

public struct UIDiagnosticGeometryIssue: Codable, Sendable {
    public let nodeID: String
    public let invalidValues: [String: String]
    public let source: SourceLocationPayload?
}

public struct UIDiagnosticLayoutSummary: Codable, Sendable {
    public let total: Int
    public let items: [UIDiagnosticGeometryIssue]
}

extension UIDiagnosticNode {
    var geometryIssue: UIDiagnosticGeometryIssue? {
        let frame = node.frame
        let values = ["x": frame.x, "y": frame.y, "width": frame.w, "height": frame.h]
        let invalid = values.filter { !$0.value.isFinite || (["width", "height"].contains($0.key) && $0.value < 0) }
        guard !invalid.isEmpty else { return nil }
        return .init(nodeID: node.id, invalidValues: invalid.mapValues { String(describing: $0) }, source: node.source)
    }
}
