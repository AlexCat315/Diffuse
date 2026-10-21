internal import Foundation
internal import GuavaUICompose
internal import LanguageServerRuntime
internal import Testing
@testable import EditorCore

@Suite("Swift semantic editing protocol")
struct SemanticEditingTests {
    private let range = #"{"start":{"line":0,"character":4},"end":{"line":0,"character":9}}"#
    private let uri = "file:///shadow/Script.swift"

    private var context: ScriptSemanticContext {
        ScriptSemanticContext(documents: [uri: .init(scriptID: "script.one", revision: 42, version: 7)])
    }

    @Test("workspace edits map known documents and retain source revisions")
    func mapsWorkspaceEdit() throws {
        let payload = Data("{\"changes\":{\"\(uri)\":[{\"range\":\(range),\"newText\":\"value😀\"}]}}".utf8)
        let edit = try ScriptEditingReplies.workspaceEdit(payload, context: context)
        let document = try #require(edit.documents.first)
        #expect(document.scriptID == "script.one")
        #expect(document.sourceRevision == 42)
        #expect(document.edits.first?.text == "value😀")
        #expect(document.edits.first?.range.end.character == 9)
    }

    @Test("versioned changes reject stale versions and unknown files atomically")
    func rejectsUnsafeEdits() throws {
        let stale = Data("{\"documentChanges\":[{\"textDocument\":{\"uri\":\"\(uri)\",\"version\":6},\"edits\":[]}]}".utf8)
        #expect(throws: ScriptLanguageEditError.staleDocument("script.one")) {
            try ScriptEditingReplies.workspaceEdit(stale, context: context)
        }
        let outside = Data(#"{"changes":{"file:///etc/secret.swift":[]}}"#.utf8)
        #expect(throws: ScriptLanguageEditError.externalDocument("file:///etc/secret.swift")) {
            try ScriptEditingReplies.workspaceEdit(outside, context: context)
        }
        let resource = Data(#"{"documentChanges":[{"kind":"rename","oldUri":"file:///a","newUri":"file:///b"}]}"#.utf8)
        #expect(throws: ScriptLanguageEditError.unsupportedResourceOperation) {
            try ScriptEditingReplies.workspaceEdit(resource, context: context)
        }
    }

    @Test("malformed ranges and text edits fail closed")
    func rejectsMalformedEdits() {
        let malformed = Data("{\"changes\":{\"\(uri)\":[{\"range\":{\"start\":{\"line\":0,\"character\":9},\"end\":{\"line\":0,\"character\":4}},\"newText\":\"x\"}]}}".utf8)
        #expect(throws: ScriptLanguageEditError.malformedReply) {
            try ScriptEditingReplies.workspaceEdit(malformed, context: context)
        }
        #expect(ScriptLanguageReplies.parseSpan(["start": ["line": -1, "character": 0], "end": ["line": 0, "character": 0]]) == nil)
    }

    @Test("code actions preserve resolution tokens and reject implicit commands")
    func actionResolution() throws {
        let payload = Data(#"[{"title":"Add type","kind":"quickfix","isPreferred":true,"data":{"refactor":1}},{"title":"Run command","command":{"command":"swift.mutate"}}]"#.utf8)
        let actions = try ScriptEditingReplies.codeActions(payload, context: context)
        #expect(actions.count == 2)
        #expect(actions[0].isPreferred)
        #expect(actions[0].needsResolution)
        #expect(actions[0].resolution != nil)
        #expect(actions[1].disabledReason == ScriptLanguageEditError.unsupportedCommand.localizedDescription)
        #expect(!actions[1].needsResolution)
    }

    @Test("signature help understands UTF-16 parameter offsets and active parameter")
    func signatureOffsets() throws {
        let payload = Data(#"{"signatures":[{"label":"foo(a: Int, b: String)","documentation":{"kind":"markdown","value":"Docs"},"parameters":[{"label":[4,10]},{"label":"b: String"}],"activeParameter":1}],"activeSignature":4,"activeParameter":0}"#.utf8)
        let result = try #require(ScriptAssistanceReplies.signatures(payload))
        #expect(result.activeSignature == 0)
        #expect(result.activeParameter == 1)
        #expect(result.signatures[0].parameters[0].label == "a: Int")
        #expect(result.signatures[0].documentation == "Docs")
    }

    @Test("document symbols retain hierarchy and precise selection ranges")
    func symbolHierarchy() throws {
        let payload = Data("[{\"name\":\"Game\",\"kind\":23,\"range\":\(range),\"selectionRange\":\(range),\"children\":[{\"name\":\"update\",\"kind\":6,\"range\":\(range)}]}]".utf8)
        let result = ScriptAssistanceReplies.symbols(payload)
        #expect(result.count == 1)
        #expect(result[0].children.first?.name == "update")
        #expect(result[0].children.first?.selectionRange.start.character == 4)
    }

    @Test("details retain a bounded independent log with monotonic identifiers")
    func boundedDetails() {
        var details = ScriptLanguageServiceDetails(executablePath: "/toolchain/usr/bin/sourcekit-lsp")
        for value in 0..<350 { details.record("event \(value)") }
        #expect(details.logs.count == 300)
        #expect(details.logs.first?.id == 51)
        #expect(details.logs.last?.id == 350)
        #expect(details.health == .checking)
    }
}
