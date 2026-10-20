import Foundation
import Testing
import StudioDocuments

@Test func fileListingUsesCanonicalProjectRelativePaths() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("Read me".utf8).write(to: directory.appendingPathComponent("README.md"))
    try Data("中文".utf8).write(to: directory.appendingPathComponent("Notes/设计.md"))
    let workspace = DocumentWorkspace(root: directory)
    #expect(workspace.files() == ["Notes/设计.md", "README.md"])
    for path in workspace.files() { #expect(try workspace.open(path).path == path) }
}

@Test func plainDocumentsSaveUnicodeAndProtectExternalChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = DocumentWorkspace(root: root)
    #expect(try workspace.open("notes/设计.md").isDirty)
    try workspace.edit("notes/设计.md", text: "# 工作站 🥭\n")
    try workspace.saveAll()
    #expect(workspace.documents.first?.isDirty == false)
    try workspace.edit("notes/设计.md", text: "New text")
    #expect(throws: DocumentError.unsavedChanges) { try workspace.close("notes/设计.md") }
    try Data("External edit".utf8).write(to: root.appendingPathComponent("notes/设计.md"))
    #expect(throws: DocumentError.changedOnDisk) { try workspace.saveAll() }
    #expect(workspace.documents.first?.text == "New text")
    try workspace.close("notes/设计.md", discard: true)
    #expect(try workspace.open("notes/设计.md").text == "External edit")
}

@Test func documentPathsAndBinaryFilesAreRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = DocumentWorkspace(root: root)
    for path in ["../outside", "/tmp/file", ".git/config", "a/../../file", "C:\\file"] {
        #expect(throws: DocumentError.invalidPath) { try workspace.open(path) }
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
    #expect(throws: DocumentError.invalidPath) { try workspace.open("outside/file") }
    try Data([0, 1, 255]).write(to: root.appendingPathComponent("binary"))
    #expect(throws: DocumentError.unsupportedText) { try workspace.open("binary") }
}
