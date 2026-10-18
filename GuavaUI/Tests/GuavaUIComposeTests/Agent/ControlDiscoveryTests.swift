import Foundation
import Testing
import GuavaUIRuntime
import GuavaUIAgent
@testable import GuavaUICompose

@Suite("AI discovery of composed controls", .serialized)
@MainActor
struct AgentControlDiscoveryTests: GuavaUIComposeSerializedSuite {
    @Test("Validated AI tools discover real Form fields and ordinary buttons without evaluating private field values")
    func formTools() async throws {
        let graph = GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: Form([
                FormField("name", "Display name") { TextField("Name", text: .constant("Local private draft")) }
            ]) { Button("Save changes") {} }.frame(width: 640, height: 400))
            for _ in 0..<8 { graph.recomposer.commitAll(); graph.computeLayout(width: 640, height: 400) }
            return graph
        }
        defer { GlobalTestLock.locked { graph.install(root: EmptyView()) } }
        let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
        let toolbox = try diagnostics.toolbox()
        for (text, role) in [("Display name", "textField"), ("Save changes", "button")] {
            let input = try JSONSerialization.data(withJSONObject: ["text": text, "role": role, "visible_only": true])
            let result = try await toolbox.execute(name: "query_ui_nodes", input: input)
            let response = try #require(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
            let page = try #require(response["data"] as? [String: Any])
            #expect(page["total"] as? Int == 1)
            let items = try #require(page["items"] as? [[String: Any]])
            let presentation = try #require(items.first?["presentation"] as? [String: Any])
            #expect(presentation["isVisible"] as? Bool == true && presentation["inputEnabled"] as? Bool == true)
            #expect(presentation["visibleFrame"] != nil)
            #expect(!String(decoding: result.json, as: UTF8.self).contains("Local private draft"))
            if role == "textField" {
                let node = try #require(items.first?["node"] as? [String: Any])
                let id = try #require(node["id"] as? String)
                let readInput = try JSONSerialization.data(withJSONObject: ["node_id": id, "include_value": true])
                let value = try await toolbox.execute(name: "query_ui_nodes", input: readInput)
                #expect(String(decoding: value.json, as: UTF8.self).contains("Local private draft"))
            }
        }
        // Default pagination also passes the shared 512 KiB tool result limit.
        let all = try await toolbox.execute(name: "query_ui_nodes", input: Data("{}".utf8))
        #expect(!all.isError)
    }
}
