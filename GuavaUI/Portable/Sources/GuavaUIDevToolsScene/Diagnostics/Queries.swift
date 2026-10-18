public import Foundation
import GuavaUIScene
import GuavaUIDevToolsProtocol
import GuavaUIAgentCore

public struct UIDiagnosticNode: Codable, Sendable {
    public var node: NodeSummary
    public let parentID: String?
    public let semantics: AccessibilitySemantics?
    public let presentation: UIDiagnosticPresentation
    /// Present only for an explicit single-node value read.
    public var valueTruncated: Bool? = nil
}

public struct UIDiagnosticPage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let total: Int
    public let nextOffset: Int?
    init(_ items: [Item], offset: Int, limit: Int) {
        let start = min(items.count, max(0, offset))
        let end = min(items.count, start + min(100, max(1, limit)))
        self.items = Array(items[start..<end]); total = items.count
        nextOffset = end < items.count ? end : nil
    }
}

/// Read-only facade over the same scene data used by the DevTools inspector.
/// Applications pass this facade to an agent adapter; live Nodes stay internal.
@MainActor
public final class UIDiagnostics {
    private let inspector: SceneInspector
    private let tree: NodeTree
    private let state: StateRegistry?
    private let traces = UITraceStore()

    public init(tree: NodeTree, state: StateRegistry? = nil) {
        self.tree = tree; self.state = state
        inspector = SceneInspector(tree: tree)
    }

    private func nodes(valueNodeID: String? = nil) -> [UIDiagnosticNode] {
        var result: [UIDiagnosticNode] = []
        var meanings: [String: AccessibilitySemantics] = [:]
        var truncatedValue: Bool?
        guard let root = tree.root else { return [] }
        let presentation = UIDiagnosticPresentation.capture(root: root)
        func collectMeanings(_ node: Node) {
            if var semantics = node.accessibility, !semantics.isHidden {
                semantics.label = AccessibilityTree.resolvedLabel(for: node)
                if semantics.state.isSecure { semantics.value = "<redacted>" }
                if String(node.id.rawValue) == valueNodeID {
                    // Secure values must not even invoke a lazy provider.
                    let value = semantics.state.isSecure ? "<redacted>" : node.resolvedAccessibilityValue
                    let preview = String(value.prefix(4097))
                    truncatedValue = preview.count > 4096
                    semantics.value = String(preview.prefix(4096))
                }
                meanings[String(node.id.rawValue)] = semantics
            }
            node.children.forEach(collectMeanings)
        }
        collectMeanings(root)
        meanings = AccessibilityTree.resolvingDescriptions(in: meanings)
        func collect(_ node: NodeSummary, parent: String?) {
            var value = node
            value.children = []
            // Expose one canonical live identity to query clients.
            value.id = node.elementID ?? node.id
            if let presentation = presentation[value.id] {
                result.append(UIDiagnosticNode(node: value, parentID: parent, semantics: meanings[value.id],
                    presentation: presentation, valueTruncated: value.id == valueNodeID ? truncatedValue : nil))
            }
            for child in node.children { collect(child, parent: value.id) }
        }
        if let root = inspector.snapshot().root { collect(root, parent: nil) }
        return result
    }

    public func queryNodes(id: String? = nil, text: String? = nil, role: String? = nil,
                           source: String? = nil, visibleOnly: Bool = false, inputEnabledOnly: Bool = false,
                           includeValue: Bool = false, offset: Int = 0, limit: Int = 50) throws -> UIDiagnosticPage<UIDiagnosticNode> {
        if includeValue && id == nil {
            throw AgentError.invalidConfiguration("include_value requires one explicit node_id.")
        }
        let all = nodes(valueNodeID: includeValue ? id : nil)
        if let id, !all.contains(where: { $0.node.id == id }) { throw AgentError.invalidConfiguration("Node is missing or unmounted: \(id)") }
        let matches = all.filter { item in
            let node = item.node
            return (id == nil || node.id == id)
                && (!visibleOnly || item.presentation.isVisible)
                && (!inputEnabledOnly || item.presentation.inputEnabled)
                && (text == nil || [node.debugName, node.viewTag, item.semantics?.label,
                                   item.semantics?.value, item.semantics?.help].compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(text!) })
                && (role == nil || node.semanticRole == role || node.layoutRole == role || item.semantics?.role.rawValue == role)
                && (source == nil || node.source?.filePath.localizedCaseInsensitiveContains(source!) == true)
        }
        return UIDiagnosticPage(matches, offset: offset, limit: limit)
    }

    public func queryRecomposition(text: String? = nil, minimumCount: UInt64 = 0,
                                  offset: Int = 0, limit: Int = 50) -> UIDiagnosticPage<UIDiagnosticNode> {
        let matches = nodes().filter { item in
            guard let metrics = item.node.recomposition, metrics.count >= minimumCount else { return false }
            return text == nil || [item.node.debugName, item.node.viewTag].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(text!) }
        }.sorted {
            let lhs = $0.node.recomposition!, rhs = $1.node.recomposition!
            if lhs.totalMs != rhs.totalMs { return lhs.totalMs > rhs.totalMs }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return $0.node.id < $1.node.id
        }
        return UIDiagnosticPage(matches, offset: offset, limit: limit)
    }

    public func queryState(ids: [String] = [], scopeID: String? = nil, offset: Int = 0, limit: Int = 50) throws -> UIStateQuery {
        guard let state else { throw AgentError.invalidConfiguration("State observation is unavailable in this host.") }
        guard StateWatchPayload(ids: ids).isValid else { throw AgentError.invalidConfiguration("Invalid state IDs.") }
        let registered = state.descriptors.filter { scopeID == nil || $0.scopeID == scopeID }
        let allowed = Set(registered.map(\.id))
        let values = state.values(for: ids.filter { allowed.contains($0) })
        return UIStateQuery(metadata: UIDiagnosticPage(registered, offset: offset, limit: limit),
            values: values, missingIDs: ids.filter { !allowed.contains($0) })
    }

    public func captureTrace(durationMilliseconds: Int = 500) async throws -> UITraceCapture {
        try await traces.capture(timeline: tree.timeline, milliseconds: durationMilliseconds)
    }
    public func queryTrace(id: String, offset: Int = 0, limit: Int = 50) throws -> UITraceQuery {
        try traces.query(id: id, offset: offset, limit: limit)
    }
    public func compareTraces(baselineID: String, candidateID: String) throws -> UITraceComparison {
        try traces.compare(baselineID: baselineID, candidateID: candidateID)
    }
    public func resetCaptures() { traces.reset() }
    public var stateObservationAvailable: Bool { state != nil }
    func layoutIssues(limit: Int) -> UIDiagnosticLayoutSummary {
        let issues = nodes().compactMap(\.geometryIssue)
        return UIDiagnosticLayoutSummary(total: issues.count, items: Array(issues.prefix(min(100, max(1, limit)))))
    }
}

public struct UIStateQuery: Codable, Sendable {
    public let metadata: UIDiagnosticPage<StateRegistry.Descriptor>
    public let values: [StateRegistry.Value]
    public let missingIDs: [String]
}
