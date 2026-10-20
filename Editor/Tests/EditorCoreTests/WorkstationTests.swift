import EditorCore
import Foundation
import GuavaUICompose
import Testing

@Test func documentsAndMediaOwnIndependentWorkflowTools() {
    let documents = EditorWorkspaceMode.documents.profile
    #expect(documents.capabilityIDs.isEmpty)
    #expect(documents.projectToolNames.contains("write_file"))
    #expect(!documents.projectToolNames.contains("compile_scripts"))
    let media = EditorWorkspaceMode.video.profile
    #expect(media.capabilityIDs.isEmpty)
    #expect(media.allowsPanel("media"))
    #expect(!media.allowsPanel("viewport"))
    #expect(media.projectToolNames.contains("export_media"))
    #expect(EditorLayoutPreset.default(for: .video) == .videoDefault)
}

@Test @MainActor func ordinaryDocumentToolsProtectUnsavedBuffers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-docs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try EditorApplication(projectDirectory: root.path)
    defer { app.shutdown() }
    app.store.dispatch(.setWorkspaceMode(.documents))
    _ = try await app.executeProjectTool(name: "write_file", input: Data(#"{"path":"Notes.md","text":"First"}"#.utf8), origin: .mcp)
    app.workstation.documents.open("Notes.md")
    app.workstation.documents.edit("Notes.md", text: "Unsaved")
    #expect(app.workstation.hasUnsavedChanges)
    await #expect(throws: (any Error).self) {
        try await app.executeProjectTool(name: "write_file", input: Data(#"{"path":"Notes.md","text":"Replacement","expected_text":"First"}"#.utf8), origin: .mcp)
    }
    #expect(try String(contentsOf: root.appendingPathComponent("Notes.md"), encoding: .utf8) == "First")
    #expect(app.workstation.saveAll())
    #expect(try String(contentsOf: root.appendingPathComponent("Notes.md"), encoding: .utf8) == "Unsaved")
}
