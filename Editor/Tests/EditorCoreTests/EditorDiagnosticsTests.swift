import Foundation
import Testing
import AIRuntime
import GuavaUIRuntime
import GuavaUIAgent
@testable import EditorCore

@Suite("Editor AI diagnostics", .serialized)
@MainActor
struct EditorDiagnosticsTests {
    private func call(_ app: EditorApplication, _ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: args)
        return try JSONSerialization.jsonObject(with: await app.executeProjectTool(name: name, input: input)) as? [String: Any] ?? [:]
    }

    @Test func headlessReportsAvailabilityAndSkillsWithoutInventingUIData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path)
        defer { app.shutdown() }
        let report = try await call(app, "get_diagnostics")
        #expect(report["ok"] as? Bool == true && report["uiAvailable"] as? Bool == false)
        #expect(report["frameSampleCount"] as? Int == 0)
        let skills = try await call(app, "list_skills")
        #expect((skills["data"] as? [[String: String]])?.first?["name"] == "ui-diagnostics")
        let skill = try await call(app, "read_skill", ["name": "ui-diagnostics"])
        #expect((skill["data"] as? [String: String])?["instructions"]?.contains("get_diagnostics") == true)
        await #expect(throws: EditorProjectToolError.self) { _ = try await call(app, "query_ui_nodes") }
    }

    @Test func sharedExecutorUsesAttachedFacadeAndPreservesExplicitStateBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path)
        defer { app.shutdown() }
        let tree = NodeTree(), node = Node(), registry = StateRegistry()
        node.viewTag = "Toolbar"; tree.root = node
        var reads = 0
        let id = try #require(registry.register(name: "count", valueType: "Int") { reads += 1; return "3" })
        app.setUIDiagnostics(UIDiagnostics(tree: tree, state: registry))
        let nodes = try await call(app, "query_ui_nodes", ["text": "Toolbar", "limit": 1])
        #expect((nodes["data"] as? [String: Any])?["total"] as? Int == 1)
        _ = try await call(app, "query_ui_state")
        #expect(reads == 0)
        _ = try await call(app, "query_ui_state", ["ids": [id]])
        #expect(reads == 1)
        #expect(UIDiagnosticTools.tools.allSatisfy { app.store.workspaceMode.profile.projectToolNames.contains($0.name) })
        #expect(ProjectToolset.tools.contains { $0.name == "capture_ui_trace" && $0.readOnly })
        app.setUIDiagnostics(nil)
        await #expect(throws: EditorProjectToolError.self) { _ = try await call(app, "capture_ui_trace", ["duration_ms": 50]) }
    }
}
