public import Foundation
public import GuavaUIDevToolsProtocol
import GuavaUIScene

public struct UIDiagnosticGeometryIssue: Codable, Sendable {
    public let nodeID: String
    public let invalidValues: [String: String]
    public let source: SourceLocationPayload?
}

/// Content cut off below a clipping node that cannot scroll: a container
/// squeezed below its content, or a region missing a scroll viewport.
public struct UIDiagnosticOverflowIssue: Codable, Sendable {
    public let nodeID: String
    public let debugName: String?
    /// Points of content below the node's bottom edge.
    public let hiddenHeight: Double
    /// The node's source, or its nearest authored ancestor's.
    public let source: SourceLocationPayload?
}

public struct UIDiagnosticLayoutSummary: Codable, Sendable {
    /// Every layout issue; each group lists at most the requested limit.
    public let total: Int
    public let invalidGeometry: [UIDiagnosticGeometryIssue]
    public let clippedOverflow: [UIDiagnosticOverflowIssue]
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

extension UIDiagnosticOverflowIssue {
    /// Vertical overflow hidden by clipping nodes other than scroll viewports.
    /// Descendant bounds stop at nested clipping nodes, matching what a
    /// scroll viewport would make reachable.
    static func collect(in root: Node) -> [UIDiagnosticOverflowIssue] {
        var issues: [UIDiagnosticOverflowIssue] = []
        func contentBottom(_ node: Node) -> CGFloat? {
            guard node.isLayoutVisible else { return nil }
            var bottom: CGFloat? = node.frame.width > 0 && node.frame.height > 0 ? node.absoluteFrame.maxY : nil
            guard !node.clipsToBounds else { return bottom }
            for child in node.children {
                if let child = contentBottom(child) { bottom = max(bottom ?? child, child) }
            }
            return bottom
        }
        func visit(_ node: Node) {
            guard node.isLayoutVisible else { return }
            let frame = node.absoluteFrame
            if node.clipsToBounds, !node.isScrollViewport, frame.width >= 1, frame.height >= 1, frame.maxY.isFinite {
                let bottom = node.children.compactMap(contentBottom).max() ?? frame.maxY
                if bottom - frame.maxY > 1 {
                    let authored = sequence(first: node, next: \.parent).lazy.compactMap(\.sourceLocation).first
                    issues.append(.init(nodeID: String(node.id.rawValue), debugName: node.attachments[SceneInspector.DebugAttachmentKey.debugName] as? String,
                        hiddenHeight: Double(bottom - frame.maxY),
                        source: authored.map { SourceLocationPayload(fileID: $0.fileID, filePath: $0.filePath,
                                                                     line: $0.line, column: $0.column) }))
                }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return issues
    }
}
