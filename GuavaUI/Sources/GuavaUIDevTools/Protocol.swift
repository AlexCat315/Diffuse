import Foundation

/// JSON wire-format types for the GuavaUI DevTools protocol v0.1.
/// Mirror of GuavaUI-vscode/src/devtools/Protocol.ts and
/// GuavaUI-vscode/docs/protocol.md.
public enum DevToolsProtocol {
    public static let version = "guava-devtools/0.1"
}

/// Generic envelope used for all JSON messages on the wire.
public struct DevToolsEnvelope: Codable {
    public var type: String
    public var id: Int?
    public var payload: JSONValue?

    public init(type: String, id: Int? = nil, payload: JSONValue? = nil) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

/// Type-erased JSON value. Lets us route messages without committing to a
/// concrete payload Codable per inspector before parsing.
public enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported JSON token"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:        try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s } else { return nil }
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o } else { return nil }
    }
}

// MARK: - hello

public struct HelloHostInfo: Codable {
    public var pid: Int
    public var appTitle: String
    public var platform: String
    public init(pid: Int, appTitle: String, platform: String) {
        self.pid = pid; self.appTitle = appTitle; self.platform = platform
    }
}

public struct HelloPayload: Codable {
    public var `protocol`: String
    public var host: HelloHostInfo
    public var capabilities: [String]
    public init(host: HelloHostInfo, capabilities: [String]) {
        self.protocol = DevToolsProtocol.version
        self.host = host
        self.capabilities = capabilities
    }
}

// MARK: - Tree

public struct NodeFrame: Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}

public struct NodeFlags: Codable {
    public var hitTestable: Bool
    public var focusable: Bool
    public var clipsToBounds: Bool
    public var hasBackground: Bool
    public var hasBorder: Bool
}

public struct NodeSummary: Codable {
    public var id: String
    public var viewTag: String?
    public var debugName: String?
    public var frame: NodeFrame
    public var flags: NodeFlags
    public var children: [NodeSummary]
}

public struct TreeSnapshotPayload: Codable {
    public var root: NodeSummary?
}

// MARK: - Selection

public struct SelectNodePayload: Codable {
    public var id: String
}

// MARK: - Error

public struct ErrorPayload: Codable {
    public var code: String
    public var message: String
}
