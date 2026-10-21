import Foundation
import GuavaUICompose
import ScriptRuntime
import Testing
@testable import EditorCore

@Suite("Atomic language workspace edits", .serialized)
struct LanguageWorkspaceEditTests {
    private func withWorkspace(_ body: (ScriptWorkspaceModel, DynamicScriptManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("guava-workspace-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = DynamicScriptManager(projectDirectory: root.path, scriptRuntime: ScriptRuntime(), engineModulePaths: [],
            scriptTrustStorageURL: root.appendingPathComponent("trust.json"))
        _ = try manager.createScript(name: "First", source: "let value = 1\n")
        _ = try manager.createScript(name: "Second", source: "let value = 2\n")
        let model = try ScriptWorkspaceModel(manager: manager)
        defer { model.shutdown() }
        try body(model, manager)
    }

    private func replacement(_ document: ScriptWorkspaceDocument, revision: UInt64? = nil) -> ScriptDocumentEdit {
        .init(scriptID: document.file.identifier, sourceRevision: revision ?? document.editRevision,
              edits: [.init(range: .init(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 9), text: "renamed")])
    }

    @Test("multi-file rename is one reversible buffer transaction and never writes automatically")
    func groupedUndoRedo() throws {
        try withWorkspace { model, manager in
            let original = model.snapshot.documents
            try model.applyLanguageEdit(.init(documents: original.map { replacement($0) }))
            #expect(model.snapshot.documents.allSatisfy { $0.source.stringValue.contains("renamed") && $0.isDirty })
            #expect(model.canUndoLanguageEdit)
            for document in original { #expect(try manager.readSource(at: document.file.url) == document.source.stringValue) }
            try model.undoLanguageEdit()
            #expect(model.snapshot.documents.map(\.source.stringValue) == original.map(\.source.stringValue))
            #expect(model.snapshot.documents.allSatisfy { !$0.isDirty && $0.editRevision == 2 })
            #expect(model.canRedoLanguageEdit)
            try model.redoLanguageEdit()
            #expect(model.snapshot.documents.allSatisfy { $0.source.stringValue.contains("renamed") && $0.editRevision == 3 })
        }
    }

    @Test("stale edits fail atomically, including when earlier documents were valid")
    func staleTransaction() throws {
        try withWorkspace { model, _ in
            let original = model.snapshot.documents
            let edit = ScriptWorkspaceEdit(documents: [replacement(original[0]), replacement(original[1], revision: 1)])
            #expect(throws: ScriptLanguageEditError.self) { try model.applyLanguageEdit(edit) }
            #expect(model.snapshot.documents == original)
            #expect(!model.canUndoLanguageEdit)
        }
    }

    @Test("overlapping and out-of-bounds server edits cannot partially change buffers")
    func invalidTransaction() throws {
        try withWorkspace { model, _ in
            let document = try #require(model.snapshot.selectedDocument)
            let range = ScriptLanguageSpan(startLine: 0, startCharacter: 4, endLine: 0, endCharacter: 9)
            let overlapping = ScriptDocumentEdit(scriptID: document.file.identifier, sourceRevision: 0,
                edits: [.init(range: range, text: "a"), .init(range: range, text: "b")])
            #expect(throws: ScriptLanguageEditError.overlappingEdits) { try model.applyLanguageEdit(.init(documents: [overlapping])) }
            let outside = ScriptDocumentEdit(scriptID: document.file.identifier, sourceRevision: 0,
                edits: [.init(range: .init(startLine: 99, startCharacter: 0, endLine: 99, endCharacter: 1), text: "x")])
            #expect(throws: ScriptLanguageEditError.invalidRange) { try model.applyLanguageEdit(.init(documents: [outside])) }
            #expect(model.snapshot.selectedDocument == document)
        }
    }

    @Test("typing after refactoring cannot be overwritten by a grouped undo")
    func preservesSubsequentTyping() throws {
        try withWorkspace { model, _ in
            let document = try #require(model.snapshot.selectedDocument)
            try model.applyLanguageEdit(.init(documents: [replacement(document)]))
            let renamed = try #require(model.snapshot.selectedDocument?.source)
            model.updateSelectedSource(renamed.insert("// typing\n", atCharacterIndex: 0))
            let typed = model.snapshot.selectedDocument?.source
            #expect(!model.canUndoLanguageEdit)
            #expect(throws: ScriptLanguageEditError.self) { try model.undoLanguageEdit() }
            #expect(model.snapshot.selectedDocument?.source == typed)
            model.updateSelectedSource(renamed)
            #expect(model.canUndoLanguageEdit)
            try model.undoLanguageEdit()
            #expect(model.snapshot.selectedDocument?.source.stringValue == document.source.stringValue)
        }
    }

    @Test("UTF-16 ranges must align to a grapheme boundary")
    func rejectsSplitEmoji() {
        let source = TextBuffer("😀a\n")
        #expect(throws: ScriptLanguageEditError.invalidRange) {
            try ScriptLanguageEditValidation.range(.init(startLine: 0, startCharacter: 1, endLine: 0, endCharacter: 2), in: source)
        }
        #expect(throws: Never.self) {
            try ScriptLanguageEditValidation.range(.init(startLine: 0, startCharacter: 2, endLine: 0, endCharacter: 3), in: source)
        }
    }
}
