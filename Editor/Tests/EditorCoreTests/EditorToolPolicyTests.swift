import AIRuntime
import CapabilityRuntime
@testable import EditorCore
import Foundation
import IntentRuntime
import Testing

@Suite("Editor tool policy", .serialized)
struct EditorToolPolicyTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.withLock { names.append(name) } }
        var count: Int { lock.withLock { names.count } }
    }

    @Test("MCP evaluates writes once and built-in reads execute rewritten arguments")
    @MainActor
    func mcpPolicyUsesOneRewrittenCall() async throws {
        let calls = Calls()
        let registry = CapabilityRegistry.aiDefault
        let rename = try #require(registry.descriptor(for: "scene.set_name")?.contract)
        let describe = try #require(registry.descriptor(for: "scene.describe_components")?.contract)
        let policy = ToolPolicy(handlers: [{ call in
            calls.record(call.name)
            var next = call
            if call.name == describe.toolName {
                next.arguments = Data(#"{"type_id":"missing-component"}"#.utf8)
            }
            return .allow(next)
        }])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: root.path, seedPreviewScene: true, toolPolicy: policy)
        defer { app.shutdown() }
        let id = UUID().uuidString
        func mcp(_ parameters: [String: Any]) async throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: parameters)
            return try #require(JSONSerialization.jsonObject(with: await app.handleMCPMessage(payload)) as? [String: Any])
        }
        _ = try await mcp(["action": "search_capabilities", "session_id": id, "query": "rename"])
        let draft = try await mcp(["action": "invoke_capability", "session_id": id,
            "tool_name": rename.toolName, "arguments": ["entity_id": "scene:1", "name": "Renamed"]])
        #expect(draft["ok"] as? Bool == true)
        #expect(calls.count == 1)
        _ = try await mcp(["action": "search_capabilities", "session_id": id, "query": "describe components"])
        let read = try await mcp(["action": "invoke_capability", "session_id": id,
            "tool_name": describe.toolName, "arguments": [:]])
        #expect(read["ok"] as? Bool == true)
        let components = try #require(read["components"] as? [[String: Any]])
        #expect(components.isEmpty)
        #expect(calls.count == 2)
    }

    @Test("project tools run the injected host policy before any workspace effect")
    @MainActor
    func projectToolPolicyGatesExecution() async throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("cove-tool-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let denial = ToolPolicyDenial(code: .policy, reason: "write_file blocked by test policy")
        let policy = ToolPolicy(handlers: [
            { call in call.name == "write_file" ? .deny(denial) : .allow(call) },
        ])
        let application = try EditorApplication(projectDirectory: project.path,
                                                seedPreviewScene: true,
                                                toolPolicy: policy)
        defer { application.shutdown() }

        await #expect(throws: ToolPolicyError.denied(denial)) {
            try await application.executeProjectTool(
                name: "write_file",
                input: Data(#"{"path":"Notes.md","text":"Blocked"}"#.utf8),
                origin: .mcp
            )
        }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Notes.md").path))

        // A tool the policy allows keeps working, so the seam is not a blanket
        // failure.
        let listing = try await application.executeProjectTool(
            name: "get_project_info",
            input: Data("{}".utf8),
            origin: .mcp
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: listing) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == true)
    }
}
