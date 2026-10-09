import Foundation

/// Read side and framing layer for the Language Server Protocol base protocol.
///
/// Every LSP message is `<headers>\r\n\r\n<body>` where `Content-Length` counts
/// body bytes. Pipe delivery is unreliable in both directions: data may split a
/// message across callbacks or deliver several messages at once, so the decoder
/// buffers until a frame completes. This type holds no process state, which
/// keeps it unit-testable without launching `sourcekit-lsp`.
public enum LSPMessageFramer {
    /// Maximum accepted header block size; larger suspect headers are rejected
    /// instead of buffering unboundedly.
    public static let maximumHeaderBytes = 16 * 1_024
    /// Maximum accepted message body size (32 MiB).
    public static let maximumBodyBytes = 32 * 1_024 * 1_024

    private static let headerTerminator = Data([13, 10, 13, 10])

    public struct Decoder {
        private(set) var buffer = Data()

        public init() {}

        /// Feed newly available bytes and return every fully framed body.
        public mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var messages: [Data] = []

            while true {
                guard let separator = buffer.range(of: LSPMessageFramer.headerTerminator) else {
                    guard buffer.count <= maximumHeaderBytes else {
                        throw SourceKitLSPClientError.protocolViolation("header exceeds size limit")
                    }
                    break
                }

                let headerData = buffer[..<separator.lowerBound]
                guard headerData.count <= maximumHeaderBytes,
                      let header = String(data: headerData, encoding: .ascii) else {
                    throw SourceKitLSPClientError.protocolViolation("invalid header encoding")
                }
                guard let contentLength = Self.contentLength(in: header) else {
                    throw SourceKitLSPClientError.protocolViolation("missing Content-Length header")
                }
                guard contentLength <= maximumBodyBytes else {
                    throw SourceKitLSPClientError.protocolViolation("message exceeds size limit")
                }

                let bodyStart = separator.upperBound
                guard buffer.count - bodyStart >= contentLength else { break }
                let bodyEnd = bodyStart + contentLength
                messages.append(Data(buffer[bodyStart..<bodyEnd]))
                buffer.removeSubrange(..<bodyEnd)
            }

            return messages
        }

        static func contentLength(in header: String) -> Int? {
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame,
                      let length = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                      length >= 0 else {
                    continue
                }
                return length
            }
            return nil
        }
    }

    /// Wrap a JSON body into a base-protocol frame ready to write to stdin.
    public static func frame(_ body: Data) -> Data {
        var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        result.append(body)
        return result
    }
}

/// JSON serialization used by both directions of the wire.
///
/// SourceKit-LSP accepts top-level fragments (`null`, arrays) as `params` /
/// `result` values, so `.fragmentsAllowed` is always set.
public enum LSPJSON {
    public static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    public static func object(_ value: Any?) throws -> Data {
        guard let value else { return Data("null".utf8) }
        return try data(value)
    }
}

/// A server-initiated message that has no matching outstanding request.
public struct SourceKitLSPNotification: Sendable {
    public let method: String
    public let params: Data

    public init(method: String, params: Data) {
        self.method = method
        self.params = params
    }
}
