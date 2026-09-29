import Foundation
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP transport")
struct ScriptLanguageServiceTests {
    @Test("decodes split and concatenated Content-Length messages")
    func decodesPartialAndMultipleFrames() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8)
        let combined = LSPContentLengthDecoder.frame(first) + LSPContentLengthDecoder.frame(second)
        var decoder = LSPContentLengthDecoder()

        #expect(try decoder.append(Data(combined.prefix(7))).isEmpty)
        let messages = try decoder.append(Data(combined.dropFirst(7)))

        #expect(messages == [first, second])
        #expect(decoder.buffer.isEmpty)
    }

    @Test("rejects frames without Content-Length")
    func rejectsMissingContentLength() {
        var decoder = LSPContentLengthDecoder()
        #expect(throws: SourceKitLSPClientError.protocolViolation("missing Content-Length header")) {
            try decoder.append(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}".utf8))
        }
    }

    @Test("resolves SourceKit-LSP from an explicit executable override")
    func resolvesExplicitSourceKitPath() throws {
        let url = try SourceKitLSPClient.resolveExecutableURL(environment: [
            "GUAVA_SOURCEKIT_LSP_PATH": "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp",
        ])

        #expect(url.path == "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp")
    }
}