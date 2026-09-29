import Foundation
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP message framing")
struct SourceKitLSPTransportTests {
    @Test("decodes split and concatenated Content-Length messages")
    func decodesPartialAndMultipleFrames() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8)
        let combined = LSPMessageFramer.frame(first) + LSPMessageFramer.frame(second)
        var decoder = LSPMessageFramer.Decoder()

        #expect(try decoder.append(Data(combined.prefix(7))).isEmpty)
        let messages = try decoder.append(Data(combined.dropFirst(7)))

        #expect(messages == [first, second])
        #expect(decoder.buffer.isEmpty)
    }

    @Test("rejects frames without Content-Length")
    func rejectsMissingContentLength() {
        var decoder = LSPMessageFramer.Decoder()
        #expect(throws: SourceKitLSPClientError.protocolViolation("missing Content-Length header")) {
            try decoder.append(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}".utf8))
        }
    }

    @Test("survives a body delivered one byte at a time")
    func reassemblesByteAtATime() throws {
        let body = Data(#"{"jsonrpc":"2.0","id":7,"result":null}"#.utf8)
        let framed = LSPMessageFramer.frame(body)
        var decoder = LSPMessageFramer.Decoder()

        var seen: [Data] = []
        for byte in framed {
            seen.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(seen == [body])
    }

    @Test("round-trips a UTF-8 body through framing")
    func preservesUTF8Payload() throws {
        let body = Data(#"{"value":"Δt 秒"}"#.utf8)
        var decoder = LSPMessageFramer.Decoder()
        let framed = LSPMessageFramer.frame(body)

        #expect(try decoder.append(framed) == [body])
    }
}
