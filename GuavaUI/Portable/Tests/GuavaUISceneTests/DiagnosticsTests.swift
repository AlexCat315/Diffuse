import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUIDevToolsScene
import GuavaUIAgentCore

@Suite("AI diagnostics", .serialized)
@MainActor
struct DiagnosticsTests {
    @Test func queryIsFlatPagedSemanticAndRejectsStaleNodes() throws {
        let tree = NodeTree()
        let root = Node(), child = Node()
        root.addChild(child)
        child.accessibility = AccessibilitySemantics(.textField) {
            $0.label = "Password"; $0.value = "private"; $0.state.isSecure = true
        }
        tree.root = root
        let queries = UIDiagnostics(tree: tree)
        let first = try queries.queryNodes(limit: 1)
        #expect(first.total == 2 && first.nextOffset == 1)
        #expect(first.items[0].node.children.isEmpty)
        let field = try queries.queryNodes(text: "Password", role: "textField")
        #expect(field.items.count == 1)
        #expect(field.items[0].parentID == String(root.id.rawValue))
        #expect(field.items[0].semantics?.value == "<redacted>")
        root.removeChild(child)
        #expect(throws: AgentError.self) { _ = try queries.queryNodes(id: String(child.id.rawValue)) }
    }

    @Test func stateMetadataDoesNotEvaluateValuesAndReadsOnlyRequestedIDs() throws {
        let registry = StateRegistry()
        var reads = 0
        let id = try #require(registry.register(name: "count", valueType: "Int", scopeID: "scope") { reads += 1; return "7" })
        let queries = UIDiagnostics(tree: NodeTree(), state: registry)
        let metadata = try queries.queryState()
        #expect(metadata.metadata.total == 1 && metadata.values.isEmpty && reads == 0)
        let watched = try queries.queryState(ids: [id, "missing"])
        #expect(watched.values.first?.summary == "7" && reads == 1)
        #expect(watched.missingIDs == ["missing"])
        #expect(throws: AgentError.self) { _ = try queries.queryState(ids: [id, id]) }
        registry.unregister(id)
        #expect(try queries.queryState(ids: [id]).missingIDs == [id])
    }

    @Test func capturesShareRecorderWithoutStoppingInspectorAndCompareActualEvents() async throws {
        let tree = NodeTree()
        let queries = UIDiagnostics(tree: tree)
        tree.timeline.setEnabled(true)
        tree.timeline.end(tree.timeline.begin(), phase: "old", name: "Before capture")
        let capture = Task { try await queries.captureTrace(durationMilliseconds: 50) }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
        tree.timeline.end(tree.timeline.begin(), phase: "layout", name: "Actual layout")
        let first = try await capture.value
        #expect(tree.timeline.enabled)
        #expect(first.eventCount == 1 && first.dropped == 0)
        #expect(first.phases.map(\.phase) == ["layout"])
        let second = try await queries.captureTrace(durationMilliseconds: 50)
        #expect(second.eventCount == 0)
        let comparison = try queries.compareTraces(baselineID: first.id, candidateID: second.id)
        #expect(comparison.changes[0].candidate == nil && comparison.changes[0].averageDeltaMs == nil)
        queries.resetCaptures()
        #expect(throws: AgentError.self) { _ = try queries.queryTrace(id: first.id) }
        tree.timeline.setEnabled(false)
        #expect(!tree.timeline.enabled)
    }

    @Test func cancellationReleasesOwnRecordingAndDoesNotPublishCapture() async throws {
        let tree = NodeTree(), queries = UIDiagnostics(tree: NodeTree())
        let capture = Task { try await UIDiagnostics(tree: tree).captureTrace(durationMilliseconds: 5000) }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(10))
        #expect(tree.timeline.enabled)
        capture.cancel()
        await #expect(throws: CancellationError.self) { _ = try await capture.value }
        #expect(!tree.timeline.enabled)
        let empty = try await queries.captureTrace(durationMilliseconds: 50)
        #expect(empty.eventCount == 0)
    }
}
