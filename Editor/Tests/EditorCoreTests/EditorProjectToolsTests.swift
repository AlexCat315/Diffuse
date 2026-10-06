import AIRuntime
import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("AI and MCP project workspace", .serialized)
@MainActor
struct EditorProjectToolsTests {
    private func project() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guava-project-tools-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func call(_ app: EditorApplication, _ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: args)
        return try JSONSerialization.jsonObject(with: await app.executeProjectTool(name: name, input: input)) as? [String: Any] ?? [:]
    }

    @Test("source updates preserve identity and reject stale hashes or dirty buffers")
    func sourceConcurrency() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path)
        defer { app.shutdown() }
        let created = try await call(app, "write_script", ["filename": "Game.swift", "source": "first source", "expected_sha256": NSNull()])
        let read = try await call(app, "read_script", ["filename": "Game.swift"])
        #expect(read["source"] as? String == "first source")
        let hash = try #require(read["sha256"] as? String)
        let replaced = try await call(app, "write_script", ["filename": "Game.swift", "source": "second source", "expected_sha256": hash])
        #expect(replaced["identifier"] as? String == created["identifier"] as? String)
        await #expect(throws: EditorProjectToolError.self) {
            _ = try await call(app, "write_script", ["filename": "Game.swift", "source": "stale", "expected_sha256": hash])
        }
        let current = try await call(app, "read_script", ["filename": "Game.swift"])
        app.scriptWorkspace.updateSelectedSource("unsaved user draft")
        await #expect(throws: EditorProjectToolError.self) {
            _ = try await call(app, "write_script", ["filename": "Game.swift", "source": "overwrite", "expected_sha256": current["sha256"] as? String ?? ""])
        }
        #expect(app.scriptWorkspace.snapshot.selectedDocument?.source == "unsaved user draft")
        #expect(try String(contentsOf: root.appendingPathComponent("Scripts/Game.swift"), encoding: .utf8) == "second source")
    }

    @Test("project tools cannot grant trust or read a symlink outside the project")
    func protectsBoundary() async throws {
        let root = try project()
        let outside = try project()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let app = try EditorApplication(projectDirectory: root.path)
        defer { app.shutdown() }
        _ = try await call(app, "write_script", ["filename": "Game.swift", "source": "native code"])
        await #expect(throws: EditorProjectToolError.self) { _ = try await call(app, "compile_scripts") }
        await #expect(throws: EditorProjectToolError.self) { _ = try await call(app, "trust_project") }
        #expect(!app.dynamicScriptManager.projectTrustState.allowsExecution)
        let secret = outside.appendingPathComponent("Outside.swift")
        try "outside".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Scripts/Escape.swift"), withDestinationURL: secret)
        await #expect(throws: EditorProjectToolError.self) {
            _ = try await call(app, "read_script", ["filename": "Escape.swift"])
        }
    }

    @Test("project outputs wait for scene review and source edits wait for stop")
    func respectsSceneState() async throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try EditorApplication(projectDirectory: root.path)
        defer { app.shutdown() }
        let cube = try #require(app.scene.spawnEntity(template: .cube))
        app.store.dispatch(.setSelectedEntity(cube))
        app.submitDeleteSelectedEntityIntent()
        #expect(app.store.state.assistant.pendingConfirmationRequest != nil)
        await #expect(throws: EditorProjectToolError.self) { _ = try await call(app, "save_scene") }
        app.skipPendingConfirmation()
        _ = try await call(app, "set_playback_state", ["state": "playing"])
        await #expect(throws: EditorProjectToolError.self) {
            _ = try await call(app, "write_script", ["filename": "Game.swift", "source": "blocked"])
        }
        _ = try await call(app, "set_playback_state", ["state": "stopped"])
        let saved = try await call(app, "save_scene")
        #expect(saved["path"] as? String == root.appendingPathComponent(".guava/editor-scene-manifest.json").path)
    }
}
