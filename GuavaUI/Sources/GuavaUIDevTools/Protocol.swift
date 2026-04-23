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
    /// Stable runtime ElementID, encoded as decimal string. Optional so
    /// older clients keep working.
    public var elementID: String?
}

public struct TreeSnapshotPayload: Codable {
    public var root: NodeSummary?
    /// Optional invalidation tail captured at snapshot time. Present when the
    /// host wires the runtime invalidation log into the inspector.
    public var invalidations: [InvalidationRecord]?
    /// Phase 4a: render-side mirror inventory. Counts every RenderObject
    /// and lists the ElementIDs that begin a layer (composition group).
    public var renderInventory: RenderInventoryPayload?
    /// Phase 5a: input-side mirror inventory. Counts every InputNode and
    /// surfaces the focusable / hit-testable populations so DevTools can
    /// audit interaction coverage without poking back at the live tree.
    public var inputInventory: InputInventoryPayload?
}

/// One recorded invalidation event, JSON-friendly mirror of the runtime
/// `DirtyReason`.
public struct InvalidationRecord: Codable {
    public var target: String        // ElementID as decimal string
    public var source: String        // human-readable source label
    public var phase: String         // "layout" | "render" | "input" | "structure"
    public var timestamp: Double
}

/// Snapshot summary of the render-side mirror. `layerRoots` lists every
/// `RenderObject` that begins a composition group (clip, opacity<1, shadow,
/// or the root). Phase 4b will tie cache hit/miss counts to these IDs.
public struct RenderInventoryPayload: Codable {
    public var objectCount: Int
    public var layerRoots: [String]   // ElementID decimal strings, pre-order
}

/// Snapshot summary of the input-side mirror. Lists the ElementIDs of every
/// focusable node (in tree order — matches FocusChain traversal) and every
/// hit-testable node. Phase 5b will extend this with hover / capture info.
public struct InputInventoryPayload: Codable {
    public var nodeCount: Int
    public var focusables: [String]      // ElementID decimal strings
    public var hitTestables: [String]    // ElementID decimal strings
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
