import Foundation
import Testing
import GuavaUIComposeCore
import GuavaUIDevToolsScene
import GuavaUIAgentCore
import GuavaUIDevToolsProtocol

private extension JSONValue {
    var diagnosticArray: [JSONValue]? {
        if case .array(let values) = self { values } else { nil }
    }
    var diagnosticNumber: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}

@Suite("AI diagnostics", .serialized)
@MainActor
struct DiagnosticsTests {
    @Test func immediateWireReadsShareToolboxSchemasResultsAndRedaction() async throws {
        let tree = NodeTree(), root = Node(), child = Node()
        root.addChild(child); tree.root = root
        child.accessibility = AccessibilitySemantics(.textField) {
            $0.label = "Password"; $0.value = "private"; $0.state.isSecure = true
        }
        let diagnostics = UIDiagnostics(tree: tree)
        let definitions = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.tools", id: 7))
        #expect(definitions.type == "diagnostics.tools.ok" && definitions.id == 7)
        let tools = try #require(definitions.payload?.objectValue?["tools"]?.diagnosticArray)
        #expect(Set(tools.compactMap { $0.objectValue?["name"]?.stringValue }) == [
            "get_diagnostics", "query_ui_nodes", "query_ui_recomposition", "query_ui_state", "list_skills", "read_skill"
        ])
        let args: JSONValue = .object(["text": .string("Password"), "role": .string("textField"), "limit": .number(1)])
        let request = DevToolsEnvelope(type: "diagnostics.call", id: 8,
            payload: .object(["name": .string("query_ui_nodes"), "arguments": args]))
        let response = diagnostics.handleReadRequest(request)
        let sdk = try await diagnostics.execute(name: "query_ui_nodes", input: JSONEncoder().encode(args))
        #expect(response.type == "diagnostics.call.ok" && response.id == 8)
        let wireObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response.payload)) as? NSDictionary
        let sdkObject = try JSONSerialization.jsonObject(with: sdk.json) as? NSDictionary
        #expect(wireObject == sdkObject)
        let data = try #require(response.payload?.objectValue?["data"]?.objectValue)
        #expect(data["total"]?.diagnosticNumber == 1)
        let field = try #require(data["items"]?.diagnosticArray?.first?.objectValue)
        #expect(field["semantics"]?.objectValue?["value"]?.stringValue == "<redacted>")
        #expect(field["node"]?.objectValue?["children"]?.diagnosticArray?.isEmpty == true)
    }

    @Test func immediateWireRejectsMalformedUnboundedAndAsyncRequests() throws {
        let diagnostics = UIDiagnostics(tree: NodeTree())
        func call(_ arguments: JSONValue, name: String = "query_ui_nodes") -> DevToolsEnvelope {
            diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", id: 1,
                payload: .object(["name": .string(name), "arguments": arguments])))
        }
        for arguments: JSONValue in [
            .array([]), .object(["limit": .number(0)]), .object(["unexpected": .bool(true)]),
            .object(["node_id": .string("unmounted")]), .object(["text": .string(String(repeating: "x", count: 262_145))])
        ] {
            let result = call(arguments)
            #expect(result.type == "diagnostics.call.err")
            #expect(result.payload?.objectValue?["code"]?.stringValue == "bad_request")
        }
        for name in ["capture_ui_trace", "get_ui_trace", "compare_ui_traces", "inspect.style.set", "missing"] {
            #expect(call(.object([:]), name: name).payload?.objectValue?["code"]?.stringValue == "unsupported_tool")
        }
        let listing = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.tools", payload: .array([])))
        #expect(listing.type == "diagnostics.tools.err")
        let tree = NodeTree(), root = Node(); tree.root = root
        root.accessibility = AccessibilitySemantics(.button) { $0.label = String(repeating: "x", count: 524_289) }
        let oversized = UIDiagnostics(tree: tree).handleReadRequest(DevToolsEnvelope(type: "diagnostics.call",
            payload: .object(["name": .string("query_ui_nodes")])))
        #expect(oversized.type == "diagnostics.call.err")
    }

    @Test func immediateWireStateDefaultsToMetadata() throws {
        let registry = StateRegistry(); var reads = 0
        let id = try #require(registry.register(name: "count", valueType: "Int", scopeID: "scope") { reads += 1; return "7" })
        let diagnostics = UIDiagnostics(tree: NodeTree(), state: registry)
        let payload: JSONValue = .object(["name": .string("query_ui_state")])
        let metadata = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", payload: payload))
        #expect(metadata.type == "diagnostics.call.ok" && reads == 0)
        #expect(metadata.payload?.objectValue?["data"]?.objectValue?["values"]?.diagnosticArray?.isEmpty == true)
        let values = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", payload: .object([
            "name": .string("query_ui_state"), "arguments": .object(["ids": .array([.string(id)])])
        ])))
        #expect(values.type == "diagnostics.call.ok" && reads == 1)
    }

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
