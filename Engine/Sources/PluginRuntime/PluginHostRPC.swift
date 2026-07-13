import Foundation

public enum PluginHostMethod: String, Codable, Sendable {
    case handshake
    case validatePackage = "validate_package"
    case load
    case discover
    case prepare
    case unload
}

public struct PluginHostRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var method: PluginHostMethod
    public var pluginPath: String?
    public var capabilityID: String?
    public var input: Data?

    public init(id: UUID = UUID(),
                method: PluginHostMethod,
                pluginPath: String? = nil,
                capabilityID: String? = nil,
                input: Data? = nil) {
        self.id = id
        self.method = method
        self.pluginPath = pluginPath
        self.capabilityID = capabilityID
        self.input = input
    }
}

public struct PluginHostResponse: Codable, Sendable, Equatable {
    public var id: UUID
    public var ok: Bool
    public var payload: Data?
    public var error: String?

    public init(id: UUID, ok: Bool, payload: Data? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public enum PluginHostFrameError: Error, Sendable, Equatable {
    case frameTooLarge
    case incompleteFrame
    case trailingBytes
}

/// Four-byte big-endian length prefix followed by one JSON payload.
public enum PluginHostFrameCodec {
    public static let maximumFrameBytes = 1_024 * 1_024

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumFrameBytes else { throw PluginHostFrameError.frameTooLarge }
        let length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: length) { Data($0) }
        frame.append(payload)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from frame: Data) throws -> T {
        guard frame.count >= 4 else { throw PluginHostFrameError.incompleteFrame }
        let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= maximumFrameBytes else { throw PluginHostFrameError.frameTooLarge }
        let expected = 4 + Int(length)
        guard frame.count >= expected else { throw PluginHostFrameError.incompleteFrame }
        guard frame.count == expected else { throw PluginHostFrameError.trailingBytes }
        return try JSONDecoder().decode(type, from: frame.subdata(in: 4..<expected))
    }
}

/// Adapter seam for the pinned Wasmtime v45 Component runtime. Implementations
/// must configure fuel, memory limits, epoch interruption, and no ambient WASI.
public protocol WASIComponentRuntime: Sendable {
    var runtimeVersion: String { get }
    func validateComponent(_ package: ValidatedPluginPackage,
                           limits: PluginResourceLimits) throws
    func discover(_ package: ValidatedPluginPackage,
                  limits: PluginResourceLimits) throws -> Data
    func prepare(_ package: ValidatedPluginPackage,
                 capabilityID: String,
                 input: Data,
                 limits: PluginResourceLimits) throws -> Data
    func interrupt(pluginID: String)
}

public enum PluginRuntimeUnavailableError: Error, CustomStringConvertible {
    case unavailable

    public var description: String {
        "Wasmtime 45.0.0 Component runtime is not linked; plugin execution is fail-closed"
    }
}

/// Used on builds that do not carry the pinned Wasmtime artifact. Package
/// validation remains available, but component code can never execute.
public struct FailClosedWASIComponentRuntime: WASIComponentRuntime {
    public let runtimeVersion = "unavailable"
    public init() {}
    public func validateComponent(_ package: ValidatedPluginPackage,
                                  limits: PluginResourceLimits) throws { throw PluginRuntimeUnavailableError.unavailable }
    public func discover(_ package: ValidatedPluginPackage,
                         limits: PluginResourceLimits) throws -> Data { throw PluginRuntimeUnavailableError.unavailable }
    public func prepare(_ package: ValidatedPluginPackage,
                        capabilityID: String,
                        input: Data,
                        limits: PluginResourceLimits) throws -> Data { throw PluginRuntimeUnavailableError.unavailable }
    public func interrupt(pluginID: String) {}
}
