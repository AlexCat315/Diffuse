import Foundation

/// JSON wire-format types for the GuavaUI DevTools protocol v0.1.
/// Mirror of GuavaUI-vscode/src/devtools/Protocol.ts and
/// GuavaUI-vscode/docs/protocol.md.
public enum DevToolsProtocol {
    public static let version = "guava-devtools/0.1"
}

/// Generic envelope used for all JSON messages on the wire.
public struct DevToolsEnvelope: Codable, Sendable {
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
public enum JSONValue: Codable, Sendable {
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

public struct HelloHostInfo: Codable, Sendable {
    public var pid: Int
    public var appTitle: String
    public var platform: String
    public init(pid: Int, appTitle: String, platform: String) {
        self.pid = pid; self.appTitle = appTitle; self.platform = platform
    }
}

public struct HelloPayload: Codable, Sendable {
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

public struct NodeFrame: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double,
                y: Double,
                w: Double,
                h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct NodePoint: Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double,
                y: Double) {
        self.x = x
        self.y = y
    }
}

public struct NodeFlags: Codable, Sendable {
    public var hitTestable: Bool
    public var focusable: Bool
    public var clipsToBounds: Bool
    public var hasBackground: Bool
    public var hasBorder: Bool

    public init(hitTestable: Bool,
                focusable: Bool,
                clipsToBounds: Bool,
                hasBackground: Bool,
                hasBorder: Bool) {
        self.hitTestable = hitTestable
        self.focusable = focusable
        self.clipsToBounds = clipsToBounds
        self.hasBackground = hasBackground
        self.hasBorder = hasBorder
    }
}

public struct NodeSummary: Codable, Sendable {
    public var id: String
    public var viewTag: String?
    public var debugName: String?
    public var frame: NodeFrame
    /// Window-space frame after parent origins and scroll offsets are applied.
    public var absoluteFrame: NodeFrame?
    /// Current scroll offset for scrollable containers.
    public var contentOffset: NodePoint?
    public var zIndex: Double?
    public var opacity: Double?
    public var layoutRole: String?
    public var semanticRole: String?
    public var flags: NodeFlags
    public var children: [NodeSummary]
    /// Stable runtime ElementID, encoded as decimal string. Optional so
    /// older clients keep working.
    public var elementID: String?

    public init(id: String,
                viewTag: String? = nil,
                debugName: String? = nil,
                frame: NodeFrame,
                absoluteFrame: NodeFrame? = nil,
                contentOffset: NodePoint? = nil,
                zIndex: Double? = nil,
                opacity: Double? = nil,
                layoutRole: String? = nil,
                semanticRole: String? = nil,
                flags: NodeFlags,
                children: [NodeSummary],
                elementID: String? = nil) {
        self.id = id
        self.viewTag = viewTag
        self.debugName = debugName
        self.frame = frame
        self.absoluteFrame = absoluteFrame
        self.contentOffset = contentOffset
        self.zIndex = zIndex
        self.opacity = opacity
        self.layoutRole = layoutRole
        self.semanticRole = semanticRole
        self.flags = flags
        self.children = children
        self.elementID = elementID
    }
}

public struct TreeSnapshotPayload: Codable, Sendable {
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

    public init(root: NodeSummary? = nil,
                invalidations: [InvalidationRecord]? = nil,
                renderInventory: RenderInventoryPayload? = nil,
                inputInventory: InputInventoryPayload? = nil) {
        self.root = root
        self.invalidations = invalidations
        self.renderInventory = renderInventory
        self.inputInventory = inputInventory
    }
}

/// One recorded invalidation event, JSON-friendly mirror of the runtime
/// `DirtyReason`.
public struct InvalidationRecord: Codable, Sendable {
    public var target: String        // ElementID as decimal string
    public var source: String        // human-readable source label
    public var phase: String         // "layout" | "render" | "input" | "structure"
    public var timestamp: Double

    public init(target: String,
                source: String,
                phase: String,
                timestamp: Double) {
        self.target = target
        self.source = source
        self.phase = phase
        self.timestamp = timestamp
    }
}

/// Snapshot summary of the render-side mirror. `layerRoots` lists every
/// `RenderObject` that begins a composition group (clip, opacity<1, shadow,
/// or the root). Phase 4b will tie cache hit/miss counts to these IDs.
public struct RenderInventoryPayload: Codable, Sendable {
    public var objectCount: Int
    public var layerRoots: [String]   // ElementID decimal strings, pre-order

    public init(objectCount: Int,
                layerRoots: [String]) {
        self.objectCount = objectCount
        self.layerRoots = layerRoots
    }
}

/// Snapshot summary of the input-side mirror. Lists the ElementIDs of every
/// focusable node (in tree order — matches FocusChain traversal) and every
/// hit-testable node. Phase 5b will extend this with hover / capture info.
public struct InputInventoryPayload: Codable, Sendable {
    public var nodeCount: Int
    public var focusables: [String]      // ElementID decimal strings
    public var hitTestables: [String]    // ElementID decimal strings

    public init(nodeCount: Int,
                focusables: [String],
                hitTestables: [String]) {
        self.nodeCount = nodeCount
        self.focusables = focusables
        self.hitTestables = hitTestables
    }
}

// MARK: - Selection

public struct SelectNodePayload: Codable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: - Error

public struct ErrorPayload: Codable, Sendable {
    public var code: String
    public var message: String

    public init(code: String,
                message: String) {
        self.code = code
        self.message = message
    }
}

/// Configuration sent by the client when it wants to start receiving mirror
/// frames. The server picks the actual size based on the host's logical
/// surface size; the client just declares whether it is ready to receive.
public struct MirrorStartPayload: Codable, Sendable {
    public var fps: Double?
    public var quality: Double?

    public init(fps: Double? = nil,
                quality: Double? = nil) {
        self.fps = fps
        self.quality = quality
    }
}

public struct MirrorStoppedPayload: Codable, Sendable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Mirror frame payload. The pixel buffer is base64-encoded JPEG; encoding
/// happens on the host so the client only has to decode once via
/// `createImageBitmap`.
public struct MirrorFramePayload: Codable, Sendable {
    public var seq: UInt64
    public var width: Int
    public var height: Int
    /// Logical (DIP) viewport width the host rendered against; lets clients
    /// map node-tree frames into mirror-canvas pixels.
    public var logicalWidth: Double
    public var logicalHeight: Double
    public var jpegBase64: String

    public init(seq: UInt64,
                width: Int,
                height: Int,
                logicalWidth: Double,
                logicalHeight: Double,
                jpegBase64: String) {
        self.seq = seq
        self.width = width
        self.height = height
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.jpegBase64 = jpegBase64
    }
}

// MARK: - Input bridge wire types

public struct MirrorInputPayload: Codable, Sendable {
    /// One of: pointerMove, pointerDown, pointerUp, wheel, keyDown, keyUp, text.
    public var kind: String
    public var x: Float?
    public var y: Float?
    public var deltaX: Float?
    public var deltaY: Float?
    public var button: Int?
    public var key: String?
    public var keyCode: Int?
    public var text: String?
    public var modifiers: Int?
    public var clickCount: Int?
    public var isRepeat: Bool?

    public init(kind: String,
                x: Float? = nil,
                y: Float? = nil,
                deltaX: Float? = nil,
                deltaY: Float? = nil,
                button: Int? = nil,
                key: String? = nil,
                keyCode: Int? = nil,
                text: String? = nil,
                modifiers: Int? = nil,
                clickCount: Int? = nil,
                isRepeat: Bool? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.button = button
        self.key = key
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
        self.clickCount = clickCount
        self.isRepeat = isRepeat
    }
}


public struct TimingFramePayload: Codable, Sendable {
    public var frame: UInt64
    /// Time spent on layout this frame, in milliseconds.
    public var layoutMs: Double
    /// Time spent encoding the draw list this frame, in milliseconds.
    public var drawMs: Double
    /// Time spent submitting commands and presenting this frame, in ms.
    public var presentMs: Double
    /// Total wall-clock duration of this frame, in milliseconds.
    public var totalMs: Double
    /// Number of nodes in the scene graph this frame.
    public var nodeCount: Int
    /// Number of draw batches emitted this frame.
    public var batchCount: Int

    public init(frame: UInt64,
                layoutMs: Double,
                drawMs: Double,
                presentMs: Double,
                totalMs: Double,
                nodeCount: Int,
                batchCount: Int) {
        self.frame = frame
        self.layoutMs = layoutMs
        self.drawMs = drawMs
        self.presentMs = presentMs
        self.totalMs = totalMs
        self.nodeCount = nodeCount
        self.batchCount = batchCount
    }
}


/// Adds the GuavaUI DevTools log message types to the wire schema.
public extension DevToolsProtocol {
    enum LogLevel: String, Codable, Sendable {
        case trace, debug, info, notice, warning, error, critical
    }
}

public struct LogEntryPayload: Codable, Sendable {
    public var level: String
    public var label: String
    public var message: String
    public var metadata: [String: String]?
    public var source: String
    public var file: String
    public var function: String
    public var line: UInt
    /// Seconds since 1970, with millisecond precision.
    public var timestamp: Double

    public init(level: String,
                label: String,
                message: String,
                metadata: [String: String]? = nil,
                source: String,
                file: String,
                function: String,
                line: UInt,
                timestamp: Double) {
        self.level = level
        self.label = label
        self.message = message
        self.metadata = metadata
        self.source = source
        self.file = file
        self.function = function
        self.line = line
        self.timestamp = timestamp
    }
}
