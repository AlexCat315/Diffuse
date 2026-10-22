import Foundation
import LanguageServerRuntime
import Testing
@testable import EditorCore

@Suite("Language assistance replies")
struct AssistanceReplyTests {
    @Test("diagnostics keep tags and related locations")
    func diagnosticsKeepTagsAndRelations() throws {
        let object: [String: Any] = [
            "range": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 10]],
            "message": "never used", "severity": 4, "tags": [1, 2, 9],
            "relatedInformation": [["message": "declared here",
                                    "location": ["uri": "file:///p/A.swift",
                                                 "range": ["start": ["line": 0, "character": 0],
                                                           "end": ["line": 0, "character": 3]]]]],
        ]
        let diagnostic = try #require(ScriptLanguageReplies.parseDiagnostic(object))
        #expect(diagnostic.tags == [.unnecessary, .deprecated])
        #expect(diagnostic.related.count == 1)
        #expect(diagnostic.related[0].message == "declared here")
        #expect(diagnostic.related[0].location.documentURI == "file:///p/A.swift")
    }

    @Test("completion items with data keep their resolution, documented ones do not")
    func completionResolution() {
        let pending = ScriptLanguageReplies.parseCompletionItem(["label": "a", "data": ["id": 1]])
        let documented = ScriptLanguageReplies.parseCompletionItem(["label": "b", "data": ["id": 2], "documentation": "Docs"])
        #expect(pending?.resolution != nil)
        #expect(documented?.resolution == nil)
        #expect(documented?.documentation == "Docs")
    }

    @Test("workspace symbols accept SymbolInformation and file-only WorkspaceSymbol")
    func workspaceSymbols() throws {
        let payload = try LSPJSON.data([
            ["name": "Point", "kind": 23, "containerName": "Board",
             "location": ["uri": "file:///p/Point.swift",
                          "range": ["start": ["line": 3, "character": 7], "end": ["line": 3, "character": 12]]]],
            ["name": "demo", "kind": 12, "location": ["uri": "file:///p/Demo.swift"]],
            ["name": "broken"],
        ])
        let symbols = ScriptAssistanceReplies.workspaceSymbols(payload, limit: 10)
        #expect(symbols.map(\.name) == ["Point", "demo"])
        #expect(symbols[0].container == "Board")
        #expect(symbols[0].span.start.line == 3)
        #expect(symbols[1].span.start.line == 0)
    }

    @Test("watched files report creations, changes and deletions")
    func watchedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/node_modules"), withIntermediateDirectories: true)
        let kept = root.appendingPathComponent("Sources/Kept.swift"), removed = root.appendingPathComponent("Removed.swift")
        try "a".write(to: kept, atomically: true, encoding: .utf8)
        try "b".write(to: removed, atomically: true, encoding: .utf8)
        try "c".write(to: root.appendingPathComponent("Sources/node_modules/Ignored.swift"), atomically: true, encoding: .utf8)
        try "d".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let before = ScriptWatchedFiles.scan(root, extensions: ["swift"], names: ["Package.resolved"])

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: kept.path)
        try FileManager.default.removeItem(at: removed)
        let added = root.appendingPathComponent("Package.resolved")
        try "{}".write(to: added, atomically: true, encoding: .utf8)

        let changes = before.changes(to: ScriptWatchedFiles.scan(root, extensions: ["swift"], names: ["Package.resolved"]))
        #expect(Set(changes.map { "\($0.url.lastPathComponent):\($0.type.rawValue)" })
                == ["Kept.swift:2", "Removed.swift:3", "Package.resolved:1"])
    }
}
