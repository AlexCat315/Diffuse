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
    @Test func overviewReportsInvalidGeometryWithoutLosingJSONAndQueriesIdentifyTheNode() throws {
        let tree = NodeTree(), root = Node(), broken = Node(), negative = Node(), valid = Node()
        tree.root = root; root.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        root.addChild(broken); root.addChild(negative); root.addChild(valid)
        broken.frame = CGRect(x: 0, y: 0, width: CGFloat.nan, height: 20)
        broken.sourceLocation = .init(fileID: "App/Grid.swift", filePath: "/project/Grid.swift", line: 47, column: 2)
        broken.accessibility = AccessibilitySemantics(.button) { $0.label = "Broken" }
        negative.frame = CGRect(x: 0, y: 0, width: -4, height: 20)
        negative.accessibility = AccessibilitySemantics(.button) { $0.label = "Negative" }
        valid.frame = CGRect(x: 20, y: 20, width: 60, height: 30)
        valid.accessibility = AccessibilitySemantics(.button) { $0.label = "Valid" }
        let diagnostics = UIDiagnostics(tree: tree)
        let overview = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", payload: .object([
            "name": .string("get_diagnostics"), "arguments": .object(["limit": .number(1)])
        ])))
        #expect(overview.type == "diagnostics.call.ok")
        let issues = try #require(overview.payload?.objectValue?["data"]?.objectValue?["layoutIssues"]?.objectValue)
        #expect(issues["total"]?.diagnosticNumber == 2)
        let first = try #require(issues["items"]?.diagnosticArray?.first?.objectValue)
        #expect(first["nodeID"]?.stringValue == String(broken.id.rawValue))
        #expect(first["invalidValues"]?.objectValue?["width"]?.stringValue?.lowercased().contains("nan") == true)
        #expect(first["source"]?.objectValue?["line"]?.diagnosticNumber == 47)
        let visible = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", payload: .object([
            "name": .string("query_ui_nodes"), "arguments": .object(["role": .string("button"), "visible_only": .bool(true)])
        ])))
        #expect(visible.type == "diagnostics.call.ok")
        #expect(visible.payload?.objectValue?["data"]?.objectValue?["total"]?.diagnosticNumber == 1)
        let invalid = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", payload: .object([
            "name": .string("query_ui_nodes"), "arguments": .object(["node_id": .string(String(broken.id.rawValue))])
        ])))
        #expect(invalid.type == "diagnostics.call.err")
        #expect(invalid.payload?.objectValue?["message"]?.stringValue?.contains(String(broken.id.rawValue)) == true)
        #expect(invalid.payload?.objectValue?["message"]?.stringValue?.contains("get_diagnostics") == true)
    }

    @Test func diagnosticRegistryIsTheSingleDefinitionSource() {
        #expect(UIDiagnosticTool.allCases.map(\.rawValue) == UIDiagnosticTools.tools.map(\.name))
        #expect(Set(UIDiagnosticTool.allCases.map(\.rawValue)).count == UIDiagnosticTool.allCases.count)
        #expect(UIDiagnosticTool.immediateReadTools.map(\.rawValue) == [
            "get_diagnostics", "query_ui_nodes", "query_ui_recomposition", "query_ui_state",
            "list_skills", "read_skill",
        ])
        for tool in UIDiagnosticTool.allCases {
            let definition = tool.definition
            #expect(definition.name == tool.rawValue)
            #expect(definition.readOnly)
            #expect(definition.schema.additionalProperties == false)
            #expect(Set(definition.schema.required).isSubset(of: Set(definition.schema.properties.keys)))
        }
    }

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
