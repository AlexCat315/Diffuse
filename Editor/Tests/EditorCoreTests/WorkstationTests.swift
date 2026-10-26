import EditorCore
import Foundation
import CoveUICompose
import Testing

@Test func filesAndTimelineOwnIndependentWorkflowTools() {
    let files = EditorContent.files.profile
    #expect(files.capabilityIDs.isEmpty)
    #expect(files.projectToolNames.contains("write_file"))
    let timeline = EditorContent.timeline.profile
    #expect(timeline.capabilityIDs.isEmpty)
    #expect(timeline.projectToolNames.contains("export_media"))
}

@Test @MainActor func ordinaryDocumentToolsProtectUnsavedBuffers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-docs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try EditorApplication(projectDirectory: root.path)
    defer { app.shutdown() }
    app.store.dispatch(.setContent(.files))
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

@Test @MainActor func scriptTabsEditThroughTheScriptWorkspace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-script-docs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try EditorApplication(projectDirectory: root.path)
    defer { app.shutdown() }
    let workstation = app.workstation
    #expect(workstation.scripts.createScript(name: "First", source: "let first = 1\n"))
    #expect(workstation.scripts.createScript(name: "Second", source: "let second = 2\n"))
    let first = try #require(workstation.scripts.snapshot.documents.first { $0.file.displayName == "First" })
    let path = try #require(workstation.documentPath(forScript: first.file.identifier))
    #expect(workstation.scriptID(forDocument: path) == first.file.identifier)
    #expect(workstation.scriptID(forDocument: "Notes.md") == nil)

    // Opening the tab moves the language session to its script.
    workstation.documents.open(path)
    #expect(workstation.scripts.snapshot.selectedScriptID == first.file.identifier)
    workstation.scripts.updateSelectedSource(TextBuffer("let first = 10\n"))
    let tab = try #require(workstation.documents.snapshot.selected)
    #expect(workstation.isDocumentDirty(tab))

    // Switching tabs keeps unsaved script edits unsaved, like any document.
    let second = try #require(workstation.scripts.snapshot.documents.first { $0.file.displayName == "Second" })
    workstation.documents.open(try #require(workstation.documentPath(forScript: second.file.identifier)))
    #expect(workstation.scripts.snapshot.documents.first { $0.file.identifier == first.file.identifier }?.isDirty == true)
    #expect(try String(contentsOf: first.file.url, encoding: .utf8) == "let first = 1\n")

    // A plain close is refused; save writes; revert and a discarding close drop edits.
    workstation.closeDocument(path)
    #expect(workstation.documents.error != nil)
    #expect(workstation.documents.documents.contains { $0.path == path })
    #expect(workstation.saveDocument(path))
    #expect(try String(contentsOf: first.file.url, encoding: .utf8) == "let first = 10\n")
    workstation.documents.open(path)
    workstation.scripts.updateSelectedSource(TextBuffer("let first = 11\n"))
    workstation.revertDocument(path)
    #expect(!workstation.isDocumentDirty(try #require(workstation.documents.snapshot.selected)))
    workstation.scripts.updateSelectedSource(TextBuffer("let first = 12\n"))
    workstation.closeDocument(path, discard: true)
    #expect(!workstation.documents.documents.contains { $0.path == path })
    #expect(workstation.scripts.snapshot.documents.first { $0.file.identifier == first.file.identifier }?.isDirty == false)
}

@Test @MainActor func scriptsAreCreatedAndDeletedAsDocuments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-script-lifecycle-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try EditorApplication(projectDirectory: root.path)
    defer { app.shutdown() }
    let workstation = app.workstation

    // New scripts take the next free name and open in front.
    let first = try #require(workstation.createScript(source: "let a = 1\n"))
    let second = try #require(workstation.createScript(source: "let b = 2\n"))
    #expect(first.hasSuffix("NewScript.swift") && second.hasSuffix("NewScript2.swift"))
    #expect(workstation.documents.selectedPath == second)
    #expect(workstation.scripts.snapshot.selectedScriptID == workstation.scriptID(forDocument: second))
    #expect(workstation.documentPath(for: app.dynamicScriptManager.scriptsDirectoryURL) == "Scripts")

    // Deleting removes file and tab, unsaved edits included, and the front
    // tab keeps its language session.
    workstation.documents.open(first)
    workstation.scripts.updateSelectedSource(TextBuffer("let a = 10\n"))
    workstation.documents.open(second)
    #expect(workstation.deleteScript(atDocument: first))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(first).path))
    #expect(!workstation.documents.documents.contains { $0.path == first })
    #expect(workstation.scriptID(forDocument: first) == nil)
    #expect(workstation.scripts.snapshot.selectedScriptID == workstation.scriptID(forDocument: second))
    #expect(!workstation.deleteScript(atDocument: "Notes.md"))
}
